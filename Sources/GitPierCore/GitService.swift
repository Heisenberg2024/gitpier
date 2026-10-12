import Foundation
import CryptoKit

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
  private func metadataFile(_ name: String) async throws -> URL {
    let path = try await read(["rev-parse", "--git-path", name]).text
      .trimmingCharacters(in: .newlines)
    return path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
  }
  private func conflictOperationIdentity() async throws -> Data {
    let directory = try await metadataDirectories()[0]
    var bytes = Data()
    for name in [
      "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge/head-name",
      "rebase-merge/onto", "rebase-merge/stopped-sha", "rebase-apply/head-name",
      "rebase-apply/onto",
    ] {
      bytes.append(Data(name.utf8))
      bytes.append(0)
      if let data = try? Data(contentsOf: directory.appendingPathComponent(name)) {
        bytes.append(data)
      }
      bytes.append(0)
    }
    return bytes
  }
  private func conflictURL(_ path: String) throws -> URL {
    try InputValidation.repositoryPath(path)
    let url = root.appendingPathComponent(path).standardizedFileURL
    let parent = url.deletingLastPathComponent()
    guard url.path.hasPrefix(root.path + "/"),
      parent.resolvingSymlinksInPath().path == parent.path
    else { throw GitPierError.unsafePath(path) }
    return url
  }
  private func conflictWorkingFile(_ path: String) throws -> (ConflictWorkingState, Data?) {
    let url = try conflictURL(path)
    let fm = FileManager.default
    let info: [FileAttributeKey: Any]
    do { info = try fm.attributesOfItem(atPath: url.path) } catch let error as CocoaError
      where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
    {
      return (ConflictWorkingState(kind: .absent, digest: "", permissions: 0), nil)
    }
    let permissions = info[.posixPermissions] as? Int ?? 0o644
    if info[.type] as? FileAttributeType == .typeSymbolicLink {
      let target = try fm.destinationOfSymbolicLink(atPath: url.path)
      return (
        ConflictWorkingState(kind: .symbolicLink, digest: target, permissions: permissions), nil
      )
    }
    guard info[.type] as? FileAttributeType == .typeRegular else {
      return (ConflictWorkingState(kind: .other, digest: "", permissions: permissions), nil)
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    var content: Data? = Data()
    while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
      try Task.checkCancellation()
      hash.update(data: chunk)
      if let current = content, current.count + chunk.count <= ConflictSnapshot.textLimit {
        content?.append(chunk)
      } else {
        content = nil
      }
    }
    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    return (ConflictWorkingState(kind: .regular, digest: digest, permissions: permissions), content)
  }
  private func unmergedEntries(_ path: String) async throws -> Data {
    try await read(["--literal-pathspecs", "ls-files", "--unmerged", "-z", "--", path]).stdout
  }
  public func conflictSnapshot(_ path: String) async throws -> ConflictSnapshot {
    try await writing {
      _ = try conflictURL(path)
      let state = try await status()
      let entries = try await unmergedEntries(path)
      guard !entries.isEmpty else { throw GitPierError.conflictChanged }
      let operation = try await conflictOperationIdentity()
      let (working, contents) = try conflictWorkingFile(path)
      var versions: [ConflictVersion] = []
      for row in entries.split(separator: 0) {
        guard let tab = row.firstIndex(of: 9),
          String(data: Data(row[row.index(after: tab)...]), encoding: .utf8) == path,
          let header = String(data: Data(row[..<tab]), encoding: .utf8)
        else { throw GitPierError.unsafePath(path) }
        let fields = header.split(separator: " ").map(String.init)
        guard fields.count == 3, let stage = Int(fields[2]), (1...3).contains(stage) else {
          throw GitPierError.invalidInput("Invalid conflict Index entry.")
        }
        let regular = fields[0] == "100644" || fields[0] == "100755"
        let size =
          regular
          ? Int(
            try await read(["cat-file", "-s", fields[1]]).text.trimmingCharacters(in: .newlines))
          : nil
        let data =
          regular && (size ?? Int.max) <= ConflictSnapshot.textLimit
          ? try await read(["cat-file", "blob", fields[1]], limit: ConflictSnapshot.textLimit)
            .stdout : nil
        versions.append(
          ConflictVersion(stage: stage, mode: fields[0], objectID: fields[1], contents: data))
      }
      let attribute = try await read([
        "--literal-pathspecs", "check-attr", "-z", "conflict-marker-size", "--", path,
      ]).stdout
        .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
      let markerSize = attribute.count == 3 ? Int(attribute[2]) ?? 7 : 7
      guard (1...1024).contains(markerSize) else {
        throw GitPierError.invalidInput(
          "The conflict marker size exceeds the built-in editor limit.")
      }
      let snapshot = ConflictSnapshot(
        path: path, head: state.head, branch: state.branch, operation: state.operation,
        operationIdentity: operation, indexEntries: entries, versions: versions,
        working: working, workingContents: contents, markerSize: markerSize)
      try await validateConflictSnapshot(snapshot)
      return snapshot
    }
  }
  private func validateConflictSnapshot(_ expected: ConflictSnapshot) async throws {
    let current = try await status()
    guard current.head == expected.head, current.branch == expected.branch,
      current.operation == expected.operation,
      try await conflictOperationIdentity() == expected.operationIdentity,
      try await unmergedEntries(expected.path) == expected.indexEntries,
      try conflictWorkingFile(expected.path).0 == expected.working
    else { throw GitPierError.conflictChanged }
  }
  public func resolveConflict(_ expected: ConflictSnapshot, resolution: ConflictResolution)
    async throws
  {
    try await writing {
      try await validateConflictSnapshot(expected)
      guard expected.supportsVersions, expected.working.kind != .other else {
        throw GitPierError.invalidInput(
          "Resolve symlink, submodule or file-type conflicts in an external editor or terminal.")
      }
      let url = try conflictURL(expected.path)
      let fm = FileManager.default
      switch resolution {
      case .text(let text):
        guard expected.resultText != nil, !text.utf8.contains(0),
          text.utf8.count <= ConflictSnapshot.textLimit,
          !ConflictMarkers.containsMarkers(text, size: expected.markerSize)
        else {
          throw GitPierError.invalidInput(
            "Remove all conflict markers before saving a UTF-8 text result.")
        }
        var saved = text
        if let original = expected.resultText, original.contains("\r\n"),
          !original.replacingOccurrences(of: "\r\n", with: "").contains("\n")
        {
          saved = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        }
        guard saved.utf8.count <= ConflictSnapshot.textLimit else { throw GitPierError.outputLimit }
        try Data(saved.utf8).write(to: url, options: .atomic)
        try fm.setAttributes(
          [.posixPermissions: expected.working.permissions], ofItemAtPath: url.path)
      case .ours, .theirs:
        let version = {
          if case .ours = resolution { return expected.ours }; return expected.theirs
        }()
        if let version {
          if let text = version.text,
            ConflictMarkers.containsMarkers(text, size: expected.markerSize)
          {
            throw GitPierError.invalidInput("The selected version still contains conflict markers.")
          }
          try await read([
            "--literal-pathspecs", "checkout-index", "--force", "--stage=\(version.stage)", "--",
            expected.path,
          ])
        } else if expected.working.kind != .absent {
          try fm.removeItem(at: url)
        }
      case .delete:
        if expected.working.kind != .absent { try fm.removeItem(at: url) }
      }
      // Only this literal path is staged; unrelated external and partially staged content stays intact.
      let current = try await status()
      guard current.head == expected.head, current.branch == expected.branch,
        current.operation == expected.operation,
        try await conflictOperationIdentity() == expected.operationIdentity,
        try await unmergedEntries(expected.path) == expected.indexEntries
      else {
        throw GitPierError.conflictChanged
      }
      try await read(["--literal-pathspecs", "add", "-A", "--", expected.path])
      guard try await unmergedEntries(expected.path).isEmpty else {
        throw GitPierError.conflictChanged
      }
    }
  }
  public func reviewMerge() async throws -> MergeReview {
    try await writing {
      guard try await status().operation == .merge else { throw GitPierError.conflictChanged }
      let index = try await snapshot()
      let parentsFile = try await metadataFile("MERGE_HEAD")
      let messageFile = try await metadataFile("MERGE_MSG")
      let parents = try Data(contentsOf: parentsFile)
      let message = try String(contentsOf: messageFile, encoding: .utf8)
      return MergeReview(index: index, parents: parents, message: message)
    }
  }
  public func completeMerge(_ review: MergeReview) async throws -> CommitResult {
    try await commitReviewed(
      message: review.message, expected: review.index, mergeParents: review.parents)
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
        guard try await status().untracked.contains(where: { $0.path == file.path }) else {
          throw GitPierError.indexChanged
        }
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
    try await commitReviewed(
      message: message, expected: expected, amend: amend, selection: selection,
      reviewedPatches: reviewedPatches)
  }
  private func commitReviewed(
    message: String, expected: IndexSnapshot, amend: Bool = false, selection: [FileChange]? = nil,
    reviewedPatches: [String: Data] = [:], mergeParents: Data? = nil
  ) async throws -> CommitResult {
    let title = message.components(separatedBy: "\n").first ?? ""
    guard !title.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw GitPierError.invalidInput("A commit title is required.")
    }
    return try await writing {
      guard try await snapshot().identity == expected.identity else {
        throw GitPierError.indexChanged
      }
      let state = try await status()
      guard state.operation == (mergeParents == nil ? nil : .merge),
        !state.files.contains(where: \.isConflicted)
      else {
        throw GitPierError.invalidInput(
          "Resolve conflicts or complete the in-progress Git operation first.")
      }
      if let mergeParents {
        let parentsFile = try await metadataFile("MERGE_HEAD")
        guard try Data(contentsOf: parentsFile) == mergeParents else {
          throw GitPierError.conflictChanged
        }
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
      guard !liveReview.paths.isEmpty || amend || mergeParents != nil else {
        throw GitPierError.emptyIndex
      }
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
      let expectedParents = temp.appendingPathComponent("merge-parents")
      if let mergeParents { try mergeParents.write(to: expectedParents) }
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
          if mergeParents != nil {
            script +=
              "cmp -s \"$GITPIER_MERGE_HEAD\" \"$GITPIER_EXPECTED_MERGE_HEAD\" || { echo 'GitPier: merge parents changed; review again.' >&2; exit 1; }\n"
          }
        }
        let url = hooks.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
      }
      var env = [
        "GIT_INDEX_FILE": isolatedIndex.path, "GITPIER_REAL_INDEX": indexURL.path,
        "GITPIER_TREE": committedTree, "GITPIER_LIVE_TREE": liveReview.tree,
        "GITPIER_HEAD": liveReview.head ?? "", "GITPIER_GIT": gitPath,
        "GITPIER_CHECK_INDEX": temp.appendingPathComponent("checked-index").path,
      ]
      if mergeParents != nil {
        env["GITPIER_MERGE_HEAD"] = try await metadataFile("MERGE_HEAD").path
        env["GITPIER_EXPECTED_MERGE_HEAD"] = expectedParents.path
      }
      var args = ["-c", "core.hooksPath=" + hooks.path, "commit", "--file=-"]
      if mergeParents != nil { args.append("--cleanup=strip") }
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
  public func history(skip: Int = 0, count: Int = 100, path: String? = nil, query: HistoryQuery? = nil) async throws
    -> [CommitRecord]
  {
    var args = [
      "--literal-pathspecs", "log", "--topo-order", "--date-order", "--skip=\(max(0, skip))",
      "-\(max(1, min(count, 500)))", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%b%x00%D%x00",
      "-z",
    ]
    if let query {
      try query.validate()
      args += ["--fixed-strings", "--regexp-ignore-case"]
      if !query.message.isEmpty { args.append("--grep=" + query.message) }
      if !query.author.isEmpty { args.append("--author=" + query.author) }
      if !query.after.isEmpty { args.append("--since=" + query.after + "T00:00:00") }
      if !query.before.isEmpty { args.append("--until=" + query.before + "T23:59:59") }
      if !query.hash.isEmpty {
        let resolved = try await read(["rev-parse", "--verify", query.hash + "^{commit}"], allowFailure: true)
        guard resolved.code == 0 else { return [] }
        let hash = resolved.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.scope == .currentBranch {
          guard try await read(["merge-base", "--is-ancestor", hash, "HEAD"], allowFailure: true).code == 0 else { return [] }
        } else {
          guard !(try await read(["for-each-ref", "--format=%(objectname)", "--contains=" + hash, "refs/heads", "refs/remotes", "refs/tags"]).stdout).isEmpty else { return [] }
        }
        args += ["--no-walk", hash]
      } else if query.scope == .allReferences {
        args += ["--branches", "--remotes", "--tags"]
      } else { args.append("HEAD") }
    }
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
      let urls = try await remoteConfiguration(name)
      result.append(GitRemote(
        name: name, fetchURL: Self.redact(fetch), pushURL: Self.redact(push),
        configuredFetchURLs: urls.0.map(Self.redact), configuredPushURLs: urls.1.map(Self.redact),
        configurationID: Self.remoteConfigurationID(urls)))
    }
    return result
  }
  private func remoteConfiguration(_ name: String, local: Bool = false) async throws -> ([String], [String]) {
    var values: [[String]] = []
    for suffix in ["url", "pushurl"] {
      let result = try await read(
        ["config"] + (local ? ["--local"] : []) + ["--null", "--get-all", "remote.\(name).\(suffix)"],
        allowFailure: true)
      guard result.code == 0 || result.code == 1 else {
        throw GitPierError.command("config", result.code, Self.redact(result.errorText))
      }
      values.append(result.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
    }
    return (values[0], values[1])
  }
  private static func remoteConfigurationID(_ values: ([String], [String])) -> String {
    let data = (try? JSONEncoder().encode([values.0, values.1])) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  /// Edit the first fetch URL while retaining additional destinations. Multiple push URLs are
  /// intentionally read-only in this compact editor; Git's full configuration remains intact.
  public func saveRemote(name: String, fetchURL: String, pushURL: String, expected: GitRemote?) async throws {
    try InputValidation.reference(name)
    try await writing {
      if let expected {
        guard expected.name == name else { throw GitPierError.invalidInput("Refresh the remote before editing.") }
        let values = try await remoteConfiguration(name)
        guard Self.remoteConfigurationID(values) == expected.configurationID else {
          throw GitPierError.invalidInput("The remote configuration changed. Refresh and review it again.")
        }
        let local = try await remoteConfiguration(name, local: true)
        guard values.0 == local.0, values.1 == local.1, let oldFetch = values.0.first else {
          throw GitPierError.invalidInput("This remote inherits configuration. Edit it using Git in the terminal.")
        }
        let oldPush = values.1.first ?? ""
        let changeFetch = fetchURL != Self.redact(oldFetch)
        let changePush = pushURL != Self.redact(oldPush)
        if changeFetch {
          try InputValidation.remoteURL(fetchURL)
          guard !values.0.dropFirst().contains(oldFetch) else {
            throw GitPierError.invalidInput("Duplicate fetch URLs are preserved. Edit them using Git in the terminal.")
          }
        }
        if changePush {
          guard values.1.count <= 1 else {
            throw GitPierError.invalidInput("Multiple push URLs are preserved. Edit them using Git in the terminal.")
          }
          if !pushURL.isEmpty { try InputValidation.remoteURL(pushURL) }
        }
        // Validate every input before the first write. Unchanged redacted URLs retain secrets.
        if changeFetch {
          try await read(["config", "--local", "--fixed-value", "--replace-all", "remote.\(name).url", fetchURL, oldFetch])
        }
        if changePush {
          if pushURL.isEmpty {
            if !values.1.isEmpty {
              try await read(["config", "--local", "--fixed-value", "--unset-all", "remote.\(name).pushurl", oldPush])
            }
          } else {
            if values.1.isEmpty {
              try await read(["config", "--local", "--add", "remote.\(name).pushurl", pushURL])
            } else {
              try await read(["config", "--local", "--fixed-value", "--replace-all", "remote.\(name).pushurl", pushURL, oldPush])
            }
          }
        }
      } else {
        try InputValidation.remoteURL(fetchURL)
        if !pushURL.isEmpty { try InputValidation.remoteURL(pushURL) }
        try await read(["remote", "add", "--", name, fetchURL])
        if !pushURL.isEmpty { try await read(["remote", "set-url", "--push", "--", name, pushURL]) }
      }
      _ = try await remotes()
    }
  }
  public func network(
    _ operation: String, remote: String? = nil, branch: String? = nil,
    strategy: String = "configured", forceWithLease: Bool = false,
    forceReview: ForcePushReview? = nil,
    progress: (@Sendable (GitTransferProgress) -> Void)? = nil
  ) async throws -> String {
    guard ["fetch", "pull", "push"].contains(operation) else {
      throw GitPierError.invalidInput("Invalid network operation")
    }
    if let remote { try InputValidation.reference(remote) }
    if let branch { try InputValidation.reference(branch) }
    return try await writing {
      var args = [operation, "--progress"]
      if operation == "push" { args.append("--porcelain") }
      if operation == "fetch" && remote == nil { args.append("--all") }
      if operation == "pull" {
        if strategy == "rebase" { args.append("--rebase") }
        if strategy == "merge" { args.append("--no-rebase") }
      }
      if forceWithLease {
        guard operation == "push", let forceReview, remote == forceReview.remote,
          branch == forceReview.branch else {
          throw GitPierError.invalidInput("Review the force-push destination and lease before pushing.")
        }
        let current = try await status()
        guard current.head == forceReview.localHead, current.branch == forceReview.localBranch,
          current.operation == nil,
          try await forceDestinationIdentity(forceReview.remote) == forceReview.destinationIdentity else {
          throw GitPierError.invalidInput("The branch, HEAD or push destination changed. Review Force with Lease again.")
        }
        args.append("--force-with-lease=refs/heads/" + forceReview.branch + ":" + forceReview.remoteHead)
      }
      if operation == "push", remote != nil, branch != nil, !forceWithLease { args.append("--set-upstream") }
      if let remote { args.append(remote) }
      if let branch {
        if operation == "push", remote != nil {
          try await read(["check-ref-format", "refs/heads/" + branch])
          args.append((forceWithLease ? forceReview!.localHead : "HEAD") + ":refs/heads/" + branch)
        } else {
          args.append(branch)
        }
      }
      let localReference = operation == "push"
        ? try await read(["symbolic-ref", "-q", "HEAD"], allowFailure: true).text
          .trimmingCharacters(in: .whitespacesAndNewlines) : ""
      let localHead = operation == "push"
        ? try await read(["rev-parse", "--verify", "HEAD"], allowFailure: true).text
          .trimmingCharacters(in: .whitespacesAndNewlines) : ""
      let decoder = progress.map { GitProgressDecoder($0) }
      let result = try await read(args, allowFailure: true, onStderr: { bytes in decoder?.feed(bytes) })
      if result.code != 0 {
        if operation == "push", !forceWithLease,
          let rejection = Self.pushRejection(
            result, localReference: localReference, localHead: localHead,
            upstreamRemote: branch == nil ? nil : remote)
        { throw rejection }
        throw GitPierError.command(operation, result.code, Self.redact(result.errorText))
      }
      return Self.redact(result.text + result.errorText)
    }
  }
  private func forceDestinationIdentity(_ remote: String) async throws -> String {
    let configured = try await remoteConfiguration(remote)
    let effective = try await read(["remote", "get-url", "--push", "--all", "--", remote]).stdout
    guard effective.split(separator: 10).count == 1 else {
      throw GitPierError.invalidInput("Review multiple push destinations in the terminal before changing remote references.")
    }
    return Self.remoteConfigurationID(configured) + ":" + SHA256.hash(data: effective).map { String(format: "%02x", $0) }.joined()
  }
  public func reviewForcePush(remote: String, branch: String) async throws -> ForcePushReview {
    try InputValidation.reference(remote)
    try InputValidation.reference(branch)
    try await read(["check-ref-format", "refs/heads/" + branch])
    let state = try await status()
    guard let head = state.head, state.operation == nil else {
      throw GitPierError.invalidInput("Finish the Git operation before reviewing Force with Lease.")
    }
    let remoteHead = try await read(["rev-parse", "--verify", "refs/remotes/" + remote + "/" + branch], allowFailure: true)
    return ForcePushReview(remote: remote, branch: branch, localBranch: state.branch, localHead: head,
                          remoteHead: remoteHead.code == 0 ? remoteHead.text.trimmingCharacters(in: .whitespacesAndNewlines) : "",
                          destinationIdentity: try await forceDestinationIdentity(remote))
  }
  private static func pushRejection(
    _ result: CommandResult, localReference: String, localHead: String, upstreamRemote: String?
  ) -> PushRejection? {
    guard localReference.hasPrefix("refs/heads/"), !localHead.isEmpty else { return nil }
    let lines = result.text.split(separator: "\n").map(String.init)
    let destinations = lines.filter { $0.hasPrefix("To ") }.map { String($0.dropFirst(3)) }
    let records = lines.map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
      .filter { $0.count == 3 }
    // Multi-ref / multi-destination pushes and server policy failures need their own diagnosis.
    guard destinations.count == 1, let destination = destinations.first,
      !destination.isEmpty, !destination.hasPrefix("-"), records.count == 1,
      let record = records.first, record[0] == "!",
      record[2] == "[rejected] (fetch first)" || record[2] == "[rejected] (non-fast-forward)"
    else { return nil }
    let refs = record[1].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard refs.count == 2, refs[0] == localReference || refs[0] == "HEAD",
      refs[1].hasPrefix("refs/heads/") else { return nil }
    return PushRejection(
      localReference: localReference, localHead: localHead, remoteURL: destination,
      remoteReference: refs[1], upstreamRemote: upstreamRemote,
      diagnostic: "push failed (\(result.code))\n" + redact(result.text + result.errorText))
  }
  /// Fetch, merge and retry the confirmed destination under one working-tree write queue.
  /// No stash, rebase, force push or automatic conflict resolution is performed.
  public func mergeAndPush(
    _ rejection: PushRejection,
    phase: (@Sendable (PushRecoveryPhase) async -> (@Sendable (GitTransferProgress) -> Void)?)? = nil
  ) async throws -> String {
    try await writing {
      try await read(["check-ref-format", rejection.remoteReference])
      try await validatePushRecovery(rejection)
      let fetchProgress = await phase?(.fetching)
      let (remoteHead, fetched) = try await fetchPushRecovery(rejection, progress: fetchProgress)
      // Fetch awaited a network process; recheck external branch / Index / worktree changes.
      try Task.checkCancellation()
      try await validatePushRecovery(rejection)
      _ = await phase?(.merging)
      let merged = try await read([
        "-c", "merge.autoStash=false", "merge", "--no-edit", "--no-autostash", "--ff", remoteHead,
      ], allowFailure: true)
      guard merged.code == 0 else {
        throw GitPierError.command("merge", merged.code, Self.redact(merged.text + merged.errorText))
      }
      try Task.checkCancellation()
      let current = try await status()
      guard current.branch == String(rejection.localReference.dropFirst("refs/heads/".count)),
        current.operation == nil, !current.files.contains(where: \.isConflicted),
        try await read(["merge-base", "--is-ancestor", rejection.localHead, "HEAD"], allowFailure: true).code == 0,
        try await read(["merge-base", "--is-ancestor", remoteHead, "HEAD"], allowFailure: true).code == 0
      else { throw GitPierError.invalidInput("The branch changed during merge. Review it before pushing.") }
      let pushProgress = await phase?(.pushing)
      let pushed = try await pushConfirmedTarget(rejection, progress: pushProgress)
      return Self.redact(
        fetched.text + fetched.errorText + merged.text + merged.errorText + pushed.text
          + pushed.errorText)
    }
  }
  public func pushCompletedMerge(
    _ rejection: PushRejection, head: String,
    progress: (@Sendable (GitTransferProgress) -> Void)? = nil
  ) async throws -> String {
    try await writing {
      let current = try await status()
      guard current.head == head, current.operation == nil,
        current.branch == String(rejection.localReference.dropFirst("refs/heads/".count)),
        !current.files.contains(where: \.isConflicted)
      else { throw GitPierError.conflictChanged }
      let result = try await pushConfirmedTarget(rejection, progress: progress)
      return Self.redact(result.text + result.errorText)
    }
  }
  private func pushConfirmedTarget(
    _ rejection: PushRejection, progress: (@Sendable (GitTransferProgress) -> Void)?
  ) async throws -> CommandResult {
    var destination = rejection.remoteURL
    var pushArguments = ["push", "--progress", "--porcelain"]
    if let remote = rejection.upstreamRemote {
      let urls = try await read(["remote", "get-url", "--push", "--all", "--", remote]).text
        .split(separator: "\n").map(String.init)
      guard urls == [rejection.remoteURL] else {
        throw GitPierError.invalidInput("The push destination changed. Review it before pushing.")
      }
      destination = remote
      pushArguments.append("--set-upstream")
    } else {
      // Using the matching named remote also updates its tracking ref after a successful push.
      let names = try await read(["remote"]).text.split(separator: "\n").map(String.init)
      var matches: [String] = []
      for name in names {
        let urls = try await read(["remote", "get-url", "--push", "--all", "--", name]).text
          .split(separator: "\n").map(String.init)
        if urls == [rejection.remoteURL] { matches.append(name) }
      }
      if matches.count == 1 { destination = matches[0] }
    }
    let pushDecoder = progress.map { GitProgressDecoder($0) }
    let reference = try await read(["symbolic-ref", "-q", "HEAD"], allowFailure: true).text
      .trimmingCharacters(in: .newlines)
    let head = try await read(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    let pushed = try await read(
      pushArguments + ["--", destination, "HEAD:" + rejection.remoteReference],
      allowFailure: true, onStderr: { bytes in pushDecoder?.feed(bytes) })
    if pushed.code != 0 {
      if let updated = Self.pushRejection(
        pushed, localReference: reference, localHead: head, upstreamRemote: rejection.upstreamRemote
      ) {
        throw updated
      }
      throw GitPierError.command("push", pushed.code, Self.redact(pushed.text + pushed.errorText))
    }
    return pushed
  }
  private func fetchPushRecovery(
    _ rejection: PushRejection, progress: (@Sendable (GitTransferProgress) -> Void)?
  ) async throws -> (String, CommandResult) {
    // Other Git clients can overwrite FETCH_HEAD. Use a private ref, then merge its fixed object ID.
    let reference = "refs/gitpier/push-recovery/" + UUID().uuidString.lowercased()
    let decoder = progress.map { GitProgressDecoder($0) }
    do {
      let fetched = try await read(
        ["fetch", "--progress", "--no-tags", "--no-recurse-submodules", "--no-write-fetch-head", "--",
          rejection.remoteURL, rejection.remoteReference + ":" + reference],
        onStderr: { bytes in decoder?.feed(bytes) })
      let head = try await read(["rev-parse", "--verify", reference + "^{commit}"]).text
        .trimmingCharacters(in: .whitespacesAndNewlines)
      try await read(["update-ref", "-d", reference, head])
      return (head, fetched)
    } catch {
      // An unstructured task permits cleanup after cancellation; the parent still owns the write queue.
      let cleanup = Task { try? await self.read(["update-ref", "-d", reference]) }
      _ = await cleanup.value
      throw error
    }
  }
  private func validatePushRecovery(_ rejection: PushRejection) async throws {
    let current = try await status()
    guard current.head == rejection.localHead,
      current.branch == String(rejection.localReference.dropFirst("refs/heads/".count))
    else {
      throw GitPierError.invalidInput("The branch or HEAD changed since the rejected push. Retry Push to review the new state.")
    }
    guard current.operation == nil, current.tracked.isEmpty else {
      throw GitPierError.invalidInput("Commit or stash tracked changes and finish any Git operation before merging and pushing. Your local commit is preserved.")
    }
    if let remote = rejection.upstreamRemote {
      let urls = try await read(["remote", "get-url", "--push", "--all", "--", remote]).text
        .split(separator: "\n").map(String.init)
      guard urls == [rejection.remoteURL] else {
        throw GitPierError.invalidInput("The push destination changed. Review it before merging and pushing.")
      }
    }
  }
  /// Arguments are constructed by typed UI actions, never from a shell command field.
  public func reviewOperation(expectedIndex: IndexSnapshot? = nil) async throws -> GitOperationReview {
    if let expectedIndex, try await snapshot().identity != expectedIndex.identity { throw GitPierError.indexChanged }
    let state = try await status()
    let entries = try await read(["ls-files", "--stage", "-z"]).stdout
    let operation = try await conflictOperationIdentity()
    let after = try await status()
    guard state.head == after.head, state.branch == after.branch, state.operation == after.operation else {
      throw GitPierError.indexChanged
    }
    return GitOperationReview(head: state.head, branch: state.branch,
                              indexFingerprint: Data(SHA256.hash(data: entries)), operationIdentity: operation)
  }
  @discardableResult public func perform(_ arguments: [String], expected: GitOperationReview? = nil) async throws -> String {
    try await writing {
      if let expected, try await reviewOperation() != expected { throw GitPierError.indexChanged }
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
      guard try await stashes().contains(where: { $0.hash == stash.hash }) else {
        throw GitPierError.invalidInput("The stash was removed. Refresh and review the stash list again.")
      }
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
  public func stashFiles(_ stash: GitStash) async throws -> [StashFile] {
    try InputValidation.reference(stash.hash)
    guard try await stashes().contains(where: { $0.hash == stash.hash }) else {
      throw GitPierError.invalidInput("The stash was removed. Refresh the stash list.")
    }
    let tracked = try await commitFiles(stash.hash, parent: stash.hash + "^1")
      .map { StashFile(change: $0, commit: stash.hash, parent: stash.hash + "^1") }
    let untracked = try await read(["rev-parse", "--verify", stash.hash + "^3"], allowFailure: true)
    if untracked.code != 0 { return tracked }
    let hash = untracked.text.trimmingCharacters(in: .whitespacesAndNewlines)
    return tracked + (try await commitFiles(hash)).map { StashFile(change: $0, commit: hash, parent: nil) }
  }
  public func stashPatch(_ stash: GitStash, file: StashFile) async throws -> Data {
    guard try await stashes().contains(where: { $0.hash == stash.hash }) else {
      throw GitPierError.invalidInput("The stash was removed. Refresh the stash list.")
    }
    return try await commitPatch(file.commit, path: file.change.path, parent: file.parent)
  }
  public func deleteRemoteTag(_ name: String, remote: String) async throws -> String {
    try InputValidation.reference(name)
    try InputValidation.reference(remote)
    let review = try await reviewRemoteDeletion(remote: remote, reference: "refs/tags/" + name)
    return try await deleteRemoteReference(review)
  }
  public func reviewRemoteDeletion(remote: String, reference: String, expectedHash: String? = nil) async throws -> RemoteDeletionReview {
    try InputValidation.reference(remote)
    guard reference.hasPrefix("refs/heads/") || reference.hasPrefix("refs/tags/") else {
      throw GitPierError.invalidInput("Only reviewed remote branches and tags can be deleted.")
    }
    try await read(["check-ref-format", reference])
    let hash: String
    if let expectedHash { hash = expectedHash }
    else { hash = try await read(["rev-parse", "--verify", reference]).text.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard [40, 64].contains(hash.count), hash.allSatisfy(\.isHexDigit) else {
      throw GitPierError.invalidInput("Invalid reviewed reference hash.")
    }
    return RemoteDeletionReview(remote: remote, reference: reference, expectedHash: hash,
                               destinationIdentity: try await forceDestinationIdentity(remote))
  }
  public func deleteRemoteReference(_ review: RemoteDeletionReview) async throws -> String {
    try await writing {
      guard try await forceDestinationIdentity(review.remote) == review.destinationIdentity else {
        throw GitPierError.invalidInput("The remote destination changed. Review the deletion again.")
      }
      let result = try await read(["push", "--force-with-lease=" + review.reference + ":" + review.expectedHash,
                                   review.remote, ":" + review.reference])
      return Self.redact(result.text + result.errorText)
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
