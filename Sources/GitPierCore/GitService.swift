import Foundation

/// One shared actor per canonical working tree. A queue spans awaits, unlike actor isolation alone.
public actor GitService {
  public nonisolated let root: URL
  private let runner: ProcessRunner
  private var gitPath: String
  private var authArguments: [String] = []
  private var authEnvironment: [String: String] = [:]
  private var writeBusy = false
  private var writeWaiters: [CheckedContinuation<Void, Never>] = []
  // Different working-tree actors can share info/exclude. Hold only across synchronous file I/O.
  private static let localExcludeLock = NSLock()
  public init(root: URL, gitPath: String = "/usr/bin/git", runner: ProcessRunner = ProcessRunner())
  {
    self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    self.gitPath = gitPath
    self.runner = runner
  }
  public func configure(
    gitPath: String, authArguments: [String] = [], authEnvironment: [String: String] = [:]
  ) {
    self.gitPath = gitPath
    self.authArguments = authArguments
    self.authEnvironment = authEnvironment
  }
  private func acquireWrite() async {
    if !writeBusy {
      writeBusy = true
      return
    }
    await withCheckedContinuation { writeWaiters.append($0) }
  }
  private func releaseWrite() {
    if writeWaiters.isEmpty { writeBusy = false } else { writeWaiters.removeFirst().resume() }
  }
  // Swift 6.0/6.1 checks the async closure's result across an isolation boundary.
  private func writing<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
    await acquireWrite()
    defer { releaseWrite() }
    try Task.checkCancellation()
    return try await operation()
  }
  @discardableResult
  public func read(
    _ arguments: [String], input: Data? = nil, environment: [String: String] = [:],
    allowFailure: Bool = false, limit: Int = 16 * 1024 * 1024,
    onStderr: (@Sendable (Data) -> Void)? = nil
  ) async throws -> CommandResult {
    var env = ["LC_ALL": "en_US.UTF-8", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"]
    for (key, value) in authEnvironment { env[key] = value }
    for (key, value) in environment { env[key] = value }
    let result = try await runner.run(
      executable: gitPath, arguments: ["--no-pager"] + authArguments + arguments, directory: root,
      environment: env, input: input, limit: limit,
      excludingEnvironmentKeys: ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE"],
      onStderr: onStderr)
    if result.code != 0 && !allowFailure {
      throw GitPierError.command(
        arguments.first ?? "git", result.code, Self.redact(result.errorText))
    }
    return result
  }
  public static func redact(_ text: String) -> String {
    text.replacingOccurrences(
      of: "(https?://)[^\\s/@]+(?::[^\\s/@]*)?@", with: "$1[redacted]@", options: .regularExpression
    )
  }
  public func validate() async throws -> URL {
    let result = try await read(["rev-parse", "--show-toplevel"], allowFailure: true)
    guard result.code == 0 else { throw GitPierError.invalidRepository(root.path) }
    return URL(fileURLWithPath: result.text.trimmingCharacters(in: .whitespacesAndNewlines))
      .resolvingSymlinksInPath()
  }
  public func metadataDirectories() async throws -> [URL] {
    var directories: [URL] = []
    for flag in ["--absolute-git-dir", "--git-common-dir"] {
      let path = try await read(["rev-parse", flag]).text.trimmingCharacters(
        in: .whitespacesAndNewlines)
      directories.append(
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path))
    }
    var seen: Set<URL> = []
    return directories.map { $0.standardizedFileURL }.filter { seen.insert($0).inserted }
  }
  public func status() async throws -> RepositoryStatus {
    var status = try StatusParser.parse(
      await read(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"]).stdout)
    let dir = try await metadataDirectories()[0]
    let fm = FileManager.default
    if fm.fileExists(atPath: dir.appendingPathComponent("rebase-merge").path)
      || fm.fileExists(atPath: dir.appendingPathComponent("rebase-apply").path)
    {
      status.operation = .rebase
    } else if fm.fileExists(atPath: dir.appendingPathComponent("MERGE_HEAD").path) {
      status.operation = .merge
    } else if fm.fileExists(atPath: dir.appendingPathComponent("CHERRY_PICK_HEAD").path) {
      status.operation = .cherryPick
    } else if fm.fileExists(atPath: dir.appendingPathComponent("REVERT_HEAD").path) {
      status.operation = .revert
    }
    return status
  }
  public func snapshot(status knownStatus: RepositoryStatus? = nil) async throws -> IndexSnapshot {
    let state: RepositoryStatus
    if let knownStatus { state = knownStatus } else { state = try await status() }
    guard !state.files.contains(where: \.isConflicted) else {
      throw GitPierError.invalidInput("Resolve conflicts before committing.")
    }
    let tree = try await indexTree()
    let patch = try await read([
      "diff", "--cached", "--binary", "--full-index", "--no-ext-diff", "--no-textconv",
    ]).stdout
    let paths = try await read(["diff", "--cached", "--name-only", "-z"]).stdout.split(separator: 0)
      .map { String(decoding: $0, as: UTF8.self) }
    return IndexSnapshot(
      tree: tree, head: state.head, branch: state.branch, paths: paths, patch: patch)
  }
  /// write-tree refreshes Index cache extensions. Run it on a copy so read-only refresh cannot feed the watcher.
  private func indexTree() async throws -> String {
    let location = try await read(["rev-parse", "--git-path", "index"]).text.trimmingCharacters(
      in: .whitespacesAndNewlines)
    let source =
      location.hasPrefix("/")
      ? URL(fileURLWithPath: location) : root.appendingPathComponent(location)
    if !FileManager.default.fileExists(atPath: source.path) {
      return try await read(["hash-object", "-t", "tree", "--stdin"], input: Data()).text
        .trimmingCharacters(
          in: .whitespacesAndNewlines)
    }
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(
      "GitPier-index-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temp) }
    let copy = temp.appendingPathComponent("index")
    try FileManager.default.copyItem(at: source, to: copy)
    return try await read(["write-tree"], environment: ["GIT_INDEX_FILE": copy.path]).text
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
  public func stage(_ files: [FileChange]) async throws {
    try await writing { try await stageSelected(files) }
  }
  private func stageSelected(_ files: [FileChange]) async throws {
    try files.flatMap(\.paths).forEach(InputValidation.repositoryPath)
    guard !files.isEmpty else { return }
    var paths = Set(files.map(\.path))
    for original in files.compactMap(\.originalPath) {
      let tracked = try await read(["--literal-pathspecs", "ls-files", "-z", "--", original]).stdout
      if !tracked.isEmpty
        || FileManager.default.fileExists(atPath: root.appendingPathComponent(original).path)
      {
        paths.insert(original)
      }
    }
    try await read(["--literal-pathspecs", "add", "--"] + paths.sorted())
  }
  public func unstage(_ files: [FileChange]) async throws {
    let paths = Array(Set(files.flatMap(\.paths)))
    try paths.forEach(InputValidation.repositoryPath)
    guard !paths.isEmpty else { return }
    try await writing {
      let head = try await read(["rev-parse", "--verify", "HEAD"], allowFailure: true)
      if head.code == 0 {
        try await read(["--literal-pathspecs", "restore", "--staged", "--"] + paths)
      } else {
        try await read(["--literal-pathspecs", "rm", "--cached", "--ignore-unmatch", "--"] + paths)
      }
    }
  }
  /// Discards only unstaged tracked content; untracked deletion requires explicit UI confirmation.
  public func discard(_ file: FileChange) async throws {
    try InputValidation.repositoryPath(file.path)
    try await writing {
      if file.isUntracked {
        // Resolving parent components prevents a symlink directory escaping the working tree.
        let target = root.appendingPathComponent(file.path)
        let parent = target.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard parent == root.path || parent.hasPrefix(root.path + "/") else {
          throw GitPierError.unsafePath(file.path)
        }
        try FileManager.default.removeItem(at: target)
      } else {
        guard !file.isConflicted else {
          throw GitPierError.invalidInput(
            "Open the conflict in your editor and resolve it explicitly.")
        }
        try await read(["--literal-pathspecs", "restore", "--worktree", "--", file.path])
      }
    }
  }
  public func ignore(_ path: String) async throws {
    try InputValidation.repositoryPath(path)
    guard !path.contains("\n"), !path.contains("\r") else {
      throw GitPierError.invalidInput(
        "Paths containing newlines cannot be added as a single ignore rule.")
    }
    try await writing {
      let url = root.appendingPathComponent(".gitignore")
      if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
        attributes[.type] as? FileAttributeType == .typeSymbolicLink
      {
        throw GitPierError.invalidInput("Refusing to modify a symlinked .gitignore.")
      }
      var bytes = (try? Data(contentsOf: url)) ?? Data()
      if !bytes.isEmpty && bytes.last != 10 { bytes.append(10) }
      let escaped = path.reduce(into: "") { value, character in
        if "\\*?[]#! ".contains(character) { value.append("\\") }
        value.append(character)
      }
      bytes.append(Data(("/" + escaped + "\n").utf8))
      try bytes.write(to: url, options: .atomic)
    }
  }
  /// Local, repository-root-anchored exclusion. Never removes tracked content from the Index.
  public func excludeLocally(_ path: String) async throws {
    try InputValidation.repositoryPath(path)
    guard !path.contains("\n"), !path.contains("\r") else {
      throw GitPierError.invalidInput(
        "Paths containing newlines cannot be added as a single ignore rule.")
    }
    try await writing {
      // The menu's status may be stale: recheck the actual Index, including intent-to-add entries.
      guard
        try await read(["--literal-pathspecs", "ls-files", "--cached", "-z", "--", path])
          .stdout.isEmpty
      else {
        throw GitPierError.invalidInput("Local ignore is only available for untracked files.")
      }
      let ignored = try await read(["check-ignore", "-q", "--", path], allowFailure: true)
      if ignored.code == 0 { return }
      guard ignored.code == 1 else {
        throw GitPierError.command("check-ignore", ignored.code, Self.redact(ignored.errorText))
      }
      let untracked = try await read([
        "--literal-pathspecs", "ls-files", "--others", "--exclude-standard", "-z", "--", path,
      ]).stdout
      guard !untracked.isEmpty else {
        // Another worktree may have excluded this path between the two read commands.
        if try await read(["check-ignore", "-q", "--", path], allowFailure: true).code == 0 {
          return
        }
        throw GitPierError.invalidInput("The untracked file is no longer present. Refresh changes.")
      }
      // Linked worktrees have a .git pointer file; Git resolves their shared info/exclude location.
      var location = try await read(["rev-parse", "--git-path", "info/exclude"]).text
      if location.hasSuffix("\n") { location.removeLast() }
      guard !location.isEmpty else { throw GitPierError.invalidRepository(root.path) }
      let url =
        (location.hasPrefix("/")
        ? URL(fileURLWithPath: location) : root.appendingPathComponent(location))
        .standardizedFileURL
      try Self.localExcludeLock.withLock { try appendLocalExclude(path, at: url) }
    }
  }
  private func appendLocalExclude(_ path: String, at url: URL) throws {
    let fm = FileManager.default
    func attributes(_ target: URL) throws -> [FileAttributeKey: Any]? {
      do { return try fm.attributesOfItem(atPath: target.path) } catch let error as CocoaError
        where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
      { return nil }
    }
    let parent = url.deletingLastPathComponent()
    if let info = try attributes(parent) {
      guard info[.type] as? FileAttributeType == .typeDirectory else {
        throw GitPierError.invalidInput(
          "Refusing to modify a symlinked or invalid Git info directory.")
      }
    } else {
      try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    }
    let existing = try attributes(url)
    if let existing, existing[.type] as? FileAttributeType != .typeRegular {
      throw GitPierError.invalidInput(
        "Refusing to modify a symlinked or invalid info/exclude file.")
    }
    var bytes = existing == nil ? Data() : try Data(contentsOf: url)
    let escaped = path.reduce(into: "") { value, character in
      if "\\*?[]#! ".contains(character) { value.append("\\") }
      value.append(character)
    }
    let rule = Data(("/" + escaped).utf8)
    guard
      !bytes.split(separator: 10).contains(where: {
        Data($0.last == 13 ? $0.dropLast() : $0) == rule
      })
    else { return }
    if !bytes.isEmpty && bytes.last != 10 { bytes.append(10) }
    bytes.append(rule)
    bytes.append(10)
    try bytes.write(to: url, options: .atomic)
    if let permissions = existing?[.posixPermissions] {
      try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
  }
  public func commit(
    message: String, expected: IndexSnapshot, amend: Bool = false, selection: [FileChange]? = nil,
    reviewedPatches: [String: Data] = [:]
  ) async throws
    -> CommitResult
  {
    let title = message.components(separatedBy: "\n").first ?? ""
    guard !title.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw GitPierError.invalidInput("A commit title is required.")
    }
    return try await writing {
      guard try await snapshot().identity == expected.identity else {
        throw GitPierError.indexChanged
      }
      let state = try await status()
      guard state.operation == nil, !state.files.contains(where: \.isConflicted) else {
        throw GitPierError.invalidInput(
          "Resolve conflicts or complete the in-progress Git operation first.")
      }
      var liveReview = expected
      if let selection {
        guard !selection.isEmpty else { throw GitPierError.emptyIndex }
        for file in selection {
          try file.paths.forEach(InputValidation.repositoryPath)
          guard state.files.first(where: { $0.path == file.path }) == file else {
            throw GitPierError.indexChanged
          }
          if !file.isStaged, let reviewed = reviewedPatches[file.path],
            try await patch(for: file, comparison: .unstaged) != reviewed
          {
            throw GitPierError.invalidInput(
              "Selected file changed after review. Refresh and review it again: " + file.path)
          }
        }
        // Checkbox changes are local. Only Commit explicitly stages selected, previously unstaged files.
        // Partial/external staged content remains authoritative for already staged files.
        try await stageSelected(selection.filter { !$0.isStaged })
        liveReview = try await snapshot()
        guard liveReview.head == expected.head, liveReview.branch == expected.branch else {
          throw GitPierError.indexChanged
        }
        for file in selection where file.isStaged {
          let changed = try await read(
            ["--literal-pathspecs", "diff", "--quiet", expected.tree, liveReview.tree, "--"]
              + file.paths, allowFailure: true)
          guard changed.code == 0 else { throw GitPierError.indexChanged }
        }
      }
      guard !liveReview.paths.isEmpty || amend else { throw GitPierError.emptyIndex }
      let temp = FileManager.default.temporaryDirectory.appendingPathComponent(
        "GitPier-commit-" + UUID().uuidString)
      try FileManager.default.createDirectory(
        at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: temp) }
      let realIndex = try await read(["rev-parse", "--git-path", "index"]).text.trimmingCharacters(
        in: .whitespacesAndNewlines)
      let indexURL =
        realIndex.hasPrefix("/")
        ? URL(fileURLWithPath: realIndex) : root.appendingPathComponent(realIndex)
      let isolatedIndex = temp.appendingPathComponent("index")
      try FileManager.default.copyItem(at: indexURL, to: isolatedIndex)
      var committedTree = liveReview.tree
      if let selection {
        let included = Set(selection.flatMap(\.paths))
        let excluded = liveReview.paths.filter { !included.contains($0) }
        if !excluded.isEmpty {
          let args =
            liveReview.head == nil
            ? ["--literal-pathspecs", "rm", "--cached", "--force", "--ignore-unmatch", "--"]
            : ["--literal-pathspecs", "restore", "--source=HEAD", "--staged", "--"]
          try await read(args + excluded, environment: ["GIT_INDEX_FILE": isolatedIndex.path])
        }
        committedTree = try await read(
          ["write-tree"], environment: ["GIT_INDEX_FILE": isolatedIndex.path]
        ).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedPatch = try await read(
          ["diff", "--cached", "--quiet"], environment: ["GIT_INDEX_FILE": isolatedIndex.path],
          allowFailure: true)
        if selectedPatch.code == 0 && !amend { throw GitPierError.emptyIndex }
      }
      let originalHooks = try await read(["rev-parse", "--git-path", "hooks"]).text
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let hookURL =
        originalHooks.hasPrefix("/")
        ? URL(fileURLWithPath: originalHooks) : root.appendingPathComponent(originalHooks)
      let hooks = temp.appendingPathComponent("hooks")
      try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
      // Honor original hooks. commit-msg is the last pre-commit gate: hook-added changes require another review.
      for name in ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit", "post-rewrite"]
      {
        let hookInvocation =
          ["post-commit", "post-rewrite"].contains(name)
          ? "GIT_INDEX_FILE=\"$GITPIER_REAL_INDEX\" \"$original\" \"$@\"" : "\"$original\" \"$@\""
        var script =
          "#!/bin/sh\noriginal="
          + InputValidation.shellQuote(hookURL.appendingPathComponent(name).path)
          + "\nif [ -x \"$original\" ]; then " + hookInvocation + " || exit $?; fi\n"
        if name == "commit-msg" {
          script +=
            "tree=$(\"$GITPIER_GIT\" write-tree) || exit $?\n[ \"$tree\" = \"$GITPIER_TREE\" ] || { echo 'GitPier: a hook changed the staged tree; review those changes before committing.' >&2; exit 1; }\n"
          script +=
            "cp \"$GITPIER_REAL_INDEX\" \"$GITPIER_CHECK_INDEX\" || exit $?\nlive=$(GIT_INDEX_FILE=\"$GITPIER_CHECK_INDEX\" \"$GITPIER_GIT\" write-tree) || exit $?\n[ \"$live\" = \"$GITPIER_LIVE_TREE\" ] || { echo 'GitPier: the real Index changed; review staged changes again.' >&2; exit 1; }\n"
          script +=
            "head=$(\"$GITPIER_GIT\" rev-parse --verify HEAD 2>/dev/null || true)\n[ \"$head\" = \"$GITPIER_HEAD\" ] || { echo 'GitPier: HEAD changed; review again.' >&2; exit 1; }\n"
        }
        let url = hooks.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
      }
      let env = [
        "GIT_INDEX_FILE": isolatedIndex.path, "GITPIER_REAL_INDEX": indexURL.path,
        "GITPIER_TREE": committedTree, "GITPIER_LIVE_TREE": liveReview.tree,
        "GITPIER_HEAD": liveReview.head ?? "", "GITPIER_GIT": gitPath,
        "GITPIER_CHECK_INDEX": temp.appendingPathComponent("checked-index").path,
      ]
      var args = ["-c", "core.hooksPath=" + hooks.path, "commit", "--file=-"]
      if amend { args.append("--amend") }
      let result = try await read(args, input: Data(message.utf8), environment: env)
      let hash = try await read(["rev-parse", "HEAD"]).text.trimmingCharacters(
        in: .whitespacesAndNewlines)
      let currentTree = try await indexTree()
      // The live Index is never replaced. It already contains the committed tree; external additions remain staged.
      return CommitResult(
        hash: hash, output: result.text + result.errorText,
        indexChangedDuringCommit: currentTree != liveReview.tree)
    }
  }
  public func patch(
    for file: FileChange, comparison: DiffComparison, ignoreWhitespace: Bool = false
  ) async throws -> Data {
    try file.paths.forEach(InputValidation.repositoryPath)
    if file.isUntracked {
      return try await read(
        ["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--", "/dev/null", file.path],
        allowFailure: true
      ).stdout
    }
    var args = [
      "--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--find-renames",
      "--unified=5",
    ]
    if comparison == .staged { args.append("--cached") }
    if ignoreWhitespace { args.append("--ignore-all-space") }
    return try await read(args + ["--"] + file.paths).stdout
  }
  public func fileContents(_ file: FileChange, comparison: DiffComparison, after: Bool) async throws
    -> Data?
  {
    try file.paths.forEach(InputValidation.repositoryPath)
    if comparison == .unstaged && after {
      let url = root.appendingPathComponent(file.path)
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
        return nil
      }
      if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
        return Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)
      }
      guard attributes[.type] as? FileAttributeType == .typeRegular,
        (attributes[.size] as? Int ?? 0) <= 8 * 1024 * 1024
      else { throw GitPierError.outputLimit }
      return try Data(contentsOf: url)
    }
    let reference =
      comparison == .staged && !after ? "HEAD:" + (file.originalPath ?? file.path) : ":" + file.path
    let result = try await read(["show", reference], allowFailure: true, limit: 8 * 1024 * 1024)
    return result.code == 0 ? result.stdout : nil
  }
  public func applyHunk(_ patch: Data, reverse: Bool, toIndex: Bool, expected: IndexSnapshot? = nil)
    async throws
  {
    try await writing {
      if let expected, try await snapshot().identity != expected.identity {
        throw GitPierError.indexChanged
      }
      var args = ["apply", "--recount", "--whitespace=nowarn"]
      if reverse { args.append("--reverse") }
      if toIndex { args.append("--cached") }
      try await read(args + ["--check", "-"], input: patch)
      try await read(args + ["-"], input: patch)
    }
  }
  public func history(skip: Int = 0, count: Int = 100, path: String? = nil) async throws
    -> [CommitRecord]
  {
    var args = [
      "log", "--topo-order", "--date-order", "--skip=\(max(0, skip))",
      "-\(max(1, min(count, 500)))", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%b%x00%D%x00",
      "-z",
    ]
    if let path {
      try InputValidation.repositoryPath(path)
      args += ["--", path]
    }
    let result = try await read(args, allowFailure: true)
    if result.code != 0 {
      if try await status().head == nil { return [] }
      throw GitPierError.command("log", result.code, result.errorText)
    }
    return Self.parseHistory(result.stdout)
  }
  public static func parseHistory(_ data: Data) -> [CommitRecord] {
    let fields = data.split(separator: 0, omittingEmptySubsequences: false).map {
      String(decoding: $0, as: UTF8.self)
    }
    var records: [CommitRecord] = []
    var i = 0
    while i < fields.count {
      if fields[i].isEmpty {
        i += 1
        continue
      }
      guard i + 7 < fields.count else { break }
      records.append(
        CommitRecord(
          hash: fields[i].trimmingCharacters(in: .whitespacesAndNewlines),
          parents: fields[i + 1].split(separator: " ").map(String.init), author: fields[i + 2],
          email: fields[i + 3], date: Date(timeIntervalSince1970: Double(fields[i + 4]) ?? 0),
          subject: fields[i + 5], body: fields[i + 6], decorations: fields[i + 7]))
      i += 8
    }
    return records
  }
  public func commitFiles(_ hash: String, parent: String? = nil) async throws -> [FileChange] {
    try InputValidation.reference(hash)
    var args = [
      "diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-z", "--find-renames",
    ]
    if let parent {
      try InputValidation.reference(parent)
      args += [parent, hash]
    } else {
      args.append(hash)
    }
    let fields = try await read(args).stdout.split(separator: 0).map {
      String(decoding: $0, as: UTF8.self)
    }
    var files: [FileChange] = []
    var i = 0
    while i + 1 < fields.count {
      let code = fields[i].first ?? "M"
      let path = fields[i + 1]
      i += 2
      let kind: ChangeKind =
        code == "A"
        ? .added
        : code == "D" ? .deleted : code == "R" ? .renamed : code == "C" ? .copied : .modified
      if code == "R" || code == "C", i < fields.count {
        files.append(
          FileChange(path: fields[i], originalPath: path, index: code, worktree: ".", kind: kind))
        i += 1
      } else {
        files.append(FileChange(path: path, index: code, worktree: ".", kind: kind))
      }
    }
    return files
  }
  public func commitPatch(_ hash: String, path: String, parent: String? = nil) async throws -> Data
  {
    try InputValidation.reference(hash)
    try InputValidation.repositoryPath(path)
    if let parent {
      try InputValidation.reference(parent)
      return try await read([
        "--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", parent, hash, "--", path,
      ]).stdout
    }
    return try await read([
      "--literal-pathspecs", "show", "--format=", "--no-ext-diff", "--no-textconv", hash, "--",
      path,
    ]).stdout
  }
  public func branches() async throws -> [GitBranch] {
    let result = try await read([
      "for-each-ref",
      "--format=%(refname:short)%00%(HEAD)%00%(upstream:short)%00%(upstream:track)%00%(objectname)%00%(refname)",
      "refs/heads", "refs/remotes",
    ])
    return result.text.split(separator: "\n").compactMap { row in
      let f = row.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
      guard f.count == 6 else { return nil }
      return GitBranch(
        name: f[0], current: f[1] == "*", remote: f[5].hasPrefix("refs/remotes/"), upstream: f[2],
        tracking: f[3], hash: f[4])
    }
  }
  public func remotes() async throws -> [GitRemote] {
    let names = try await read(["remote"]).text.split(separator: "\n").map(String.init)
    var result: [GitRemote] = []
    for name in names {
      let fetch = try await read(["remote", "get-url", "--", name]).text.trimmingCharacters(
        in: .whitespacesAndNewlines)
      let push = try await read(["remote", "get-url", "--push", "--", name]).text
        .trimmingCharacters(in: .whitespacesAndNewlines)
      result.append(GitRemote(name: name, fetchURL: Self.redact(fetch), pushURL: Self.redact(push)))
    }
    return result
  }
  public func network(
    _ operation: String, remote: String? = nil, branch: String? = nil,
    strategy: String = "configured", forceWithLease: Bool = false,
    progress: (@Sendable (GitTransferProgress) -> Void)? = nil
  ) async throws -> String {
    guard ["fetch", "pull", "push"].contains(operation) else {
      throw GitPierError.invalidInput("Invalid network operation")
    }
    if let remote { try InputValidation.reference(remote) }
    if let branch { try InputValidation.reference(branch) }
    return try await writing {
      var args = [operation, "--progress"]
      if operation == "fetch" && remote == nil { args.append("--all") }
      if operation == "pull" {
        if strategy == "rebase" { args.append("--rebase") }
        if strategy == "merge" { args.append("--no-rebase") }
      }
      if forceWithLease {
        guard operation == "push" else {
          throw GitPierError.invalidInput("Force is only available for push")
        }
        args.append("--force-with-lease")
      }
      if operation == "push", remote != nil, branch != nil { args.append("--set-upstream") }
      if let remote { args.append(remote) }
      if let branch {
        if operation == "push", remote != nil {
          try await read(["check-ref-format", "refs/heads/" + branch])
          args.append("HEAD:refs/heads/" + branch)
        } else {
          args.append(branch)
        }
      }
      let decoder = progress.map { GitProgressDecoder($0) }
      let result = try await read(args, onStderr: { bytes in decoder?.feed(bytes) })
      return Self.redact(result.text + result.errorText)
    }
  }
  /// Arguments are constructed by typed UI actions, never from a shell command field.
  @discardableResult public func perform(_ arguments: [String]) async throws -> String {
    try await writing {
      let result = try await read(arguments)
      return Self.redact(result.text + result.errorText)
    }
  }
  public func createBranch(_ name: String, at reference: String? = nil) async throws {
    try InputValidation.reference(name)
    if let reference { try InputValidation.reference(reference) }
    try await writing {
      try await read(["check-ref-format", "--branch", name])
      try await read(["branch", name] + (reference.map { [$0] } ?? []))
    }
  }
  public func switchBranch(_ name: String, remote: Bool = false) async throws {
    try InputValidation.reference(name)
    _ = try await writing {
      // Git itself refuses overwriting modifications; never add --force/--discard-changes.
      try await read(["switch"] + (remote ? ["--track"] : []) + [name])
    }
  }
  public func stashes() async throws -> [GitStash] {
    let data = try await read(["stash", "list", "--format=%gd%x00%H%x00%s"]).text
    return data.split(separator: "\n").compactMap { row in
      let f = row.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
      return f.count == 3 ? GitStash(reference: f[0], hash: f[1], message: f[2]) : nil
    }
  }
  public func stashOperation(_ action: String, stash: GitStash) async throws -> String {
    guard ["apply", "pop", "drop"].contains(action) else {
      throw GitPierError.invalidInput("Invalid stash action")
    }
    return try await writing {
      if action != "apply" {
        let actual = try await read(["rev-parse", "--verify", stash.reference]).text
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard actual == stash.hash else {
          throw GitPierError.invalidInput(
            "The stash list changed. Refresh and review the selected stash again.")
        }
      }
      let result = try await read([
        "stash", action, action == "apply" ? stash.hash : stash.reference,
      ])
      return result.text + result.errorText
    }
  }
  public func deleteRemoteTag(_ name: String, remote: String) async throws -> String {
    try InputValidation.reference(name)
    try InputValidation.reference(remote)
    return try await writing {
      let hash = try await read(["rev-parse", "--verify", "refs/tags/" + name]).text
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let result = try await read([
        "push", "--force-with-lease=refs/tags/" + name + ":" + hash, remote, ":refs/tags/" + name,
      ])
      return result.text + result.errorText
    }
  }
  public func tags() async throws -> [String] {
    try await read(["tag", "--list", "--sort=-creatordate"]).text.split(separator: "\n").map(
      String.init)
  }
  public func identity() async throws -> [String: String] {
    let keys = [
      "user.name", "user.email", "commit.gpgsign", "gpg.format", "user.signingkey",
      "core.hooksPath", "pull.rebase",
    ]
    let pattern =
      "^(" + keys.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")$"
    let values = try await read(["config", "--null", "--get-regexp", pattern], allowFailure: true)
    guard values.code == 0 || values.code == 1 else {
      throw GitPierError.command("config", values.code, values.errorText)
    }
    var result = Dictionary(uniqueKeysWithValues: keys.map { ($0, "") })
    for field in values.stdout.split(separator: 0) {
      guard let split = field.firstIndex(of: 10) else { continue }
      let key = String(decoding: field[..<split], as: UTF8.self)
      if result[key] != nil {
        result[key] = String(decoding: field[field.index(after: split)...], as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    return result
  }
  public static func clone(
    url: String, destination: URL, gitPath: String = "/usr/bin/git",
    environment: [String: String] = [:], authArguments: [String] = [],
    progress: (@Sendable (GitTransferProgress) -> Void)? = nil
  ) async throws {
    try InputValidation.remoteURL(url)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw GitPierError.invalidInput("Clone destination must not already exist.")
    }
    var env = environment
    env["GIT_TERMINAL_PROMPT"] = "0"
    let decoder = progress.map { GitProgressDecoder($0) }
    let result = try await ProcessRunner().run(
      executable: gitPath,
      arguments: authArguments + ["clone", "--progress", "--", url, destination.path],
      directory: destination.deletingLastPathComponent(), environment: env, timeout: 600,
      excludingEnvironmentKeys: ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE"],
      onStderr: { bytes in decoder?.feed(bytes) })
    guard result.code == 0 else {
      throw GitPierError.command("clone", result.code, Self.redact(result.errorText))
    }
  }
}

public actor GitServiceRegistry {
  public static let shared = GitServiceRegistry()
  private var services: [String: GitService] = [:]
  public func service(for url: URL, gitPath: String = "/usr/bin/git") -> GitService {
    let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
    if let service = services[canonical.path] { return service }
    let service = GitService(root: canonical, gitPath: gitPath)
    services[canonical.path] = service
    return service
  }
}
