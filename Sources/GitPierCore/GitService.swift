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
  private var writeWaiters: [(UUID, CheckedContinuation<Void, Error>)] = []
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
  public func configureExecutable(_ path: String) { gitPath = path }
  private func acquireWrite() async throws {
    try Task.checkCancellation()
    if !writeBusy {
      writeBusy = true
      return
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { writeWaiters.append((id, $0)) }
    } onCancel: { Task { await self.cancelWriteWaiter(id) } }
  }
  private func cancelWriteWaiter(_ id: UUID) {
    if let index = writeWaiters.firstIndex(where: { $0.0 == id }) { writeWaiters.remove(at: index).1.resume(throwing: CancellationError()) }
  }
  private func releaseWrite() {
    if writeWaiters.isEmpty { writeBusy = false } else { writeWaiters.removeFirst().1.resume() }
  }
  // Swift 6.0/6.1 checks the async closure's result across an isolation boundary.
  private func writing<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
    try await acquireWrite()
    defer { releaseWrite() }
    try Task.checkCancellation()
    return try await operation()
  }
  @discardableResult
  public func read(
    _ arguments: [String], input: Data? = nil, environment: [String: String] = [:],
    allowFailure: Bool = false, limit: Int = 16 * 1024 * 1024,
    timeout: TimeInterval = 120,
    onStderr: (@Sendable (Data) -> Void)? = nil
  ) async throws -> CommandResult {
    var env = ["LC_ALL": "en_US.UTF-8", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"]
    for (key, value) in authEnvironment { env[key] = value }
    for (key, value) in environment { env[key] = value }
    let result = try await runner.run(
      executable: gitPath, arguments: ["--no-pager"] + authArguments + arguments, directory: root,
      environment: env, input: input, timeout: timeout, limit: limit,
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
      of: "((?:https?|ssh)://)[^\\s/@]+(?::[^\\s/@]*)?@", with: "$1[redacted]@", options: .regularExpression
    ).replacingOccurrences(of: "(?i)([?&](?:access_token|token|password|auth|key|signature)=)[^&\\s]+",
      with: "$1[redacted]", options: .regularExpression)
  }
  /// Git terminates path output with one LF. Whitespace and embedded/trailing LF can
  /// belong to the actual directory name and must never be trimmed as presentation.
  private static func nativePath(_ data: Data) throws -> String {
    let bytes = data.last == 10 ? data.dropLast() : data[...]
    guard let path = String(data: bytes, encoding: .utf8), !path.isEmpty, !path.utf8.contains(0) else {
      throw GitPierError.invalidInput("Git returned an invalid repository path.")
    }
    return path
  }
  public func validate() async throws -> URL {
    let result = try await read(["rev-parse", "--show-toplevel"], allowFailure: true)
    guard result.code == 0 else { throw GitPierError.invalidRepository(root.path) }
    return URL(fileURLWithPath: try Self.nativePath(result.stdout))
      .resolvingSymlinksInPath()
  }
  public func metadataDirectories() async throws -> [URL] {
    var directories: [URL] = []
    for flag in ["--absolute-git-dir", "--git-common-dir"] {
      let path = try Self.nativePath(try await read(["rev-parse", flag]).stdout)
      directories.append(
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path))
    }
    var seen: Set<URL> = []
    return directories.map { $0.standardizedFileURL }.filter { seen.insert($0).inserted }
  }
  public func status(localOnly: Bool = false) async throws -> RepositoryStatus {
    if localOnly { try await requireLocalWorkspaceQueries() }
    var status = try StatusParser.parse(
      await read(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"],
        environment: localOnly ? ["GIT_NO_LAZY_FETCH": "1"] : [:]).stdout)
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
  /// Dashboard reads only porcelain counts, local tracking refs and repository identity.
  /// Reserve the existing worktree FIFO and common-directory queue, without touching Index.
  public func workspaceSnapshot(_ record: RepositoryRecord) async throws -> WorkspaceSnapshot {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
      guard attributes[.type] as? FileAttributeType == .typeDirectory else {
        throw WorkspaceFailure(.invalidRepository, "The repository path is not a directory.")
      }
      guard FileManager.default.isReadableFile(atPath: root.path),
            FileManager.default.isExecutableFile(atPath: root.path) else {
        throw WorkspaceFailure(.permissionDenied, "Permission denied while reading the repository directory.")
      }
      return try await writing {
        try await validateWorkspaceRoot()
        let directories = try await metadataDirectories()
        let gitDirectory = directories[0].resolvingSymlinksInPath().path
        let common = directories.last!.resolvingSymlinksInPath().path
        try await CommonDirectoryQueue.shared.acquire(common)
        do {
          try Task.checkCancellation()
          try await requireLocalWorkspaceQueries()
          var state = try StatusParser.parse(await read(
            ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"],
            environment: ["GIT_NO_LAZY_FETCH": "1"], limit: 16 * 1024 * 1024, timeout: 20).stdout)
          let collectedAt = Date(), collectedUptime = ProcessInfo.processInfo.systemUptime
          let dir = directories[0]
          let fm = FileManager.default
          if fm.fileExists(atPath: dir.appendingPathComponent("rebase-merge").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("rebase-apply").path) { state.operation = .rebase }
          else if fm.fileExists(atPath: dir.appendingPathComponent("MERGE_HEAD").path) { state.operation = .merge }
          else if fm.fileExists(atPath: dir.appendingPathComponent("CHERRY_PICK_HEAD").path) { state.operation = .cherryPick }
          else if fm.fileExists(atPath: dir.appendingPathComponent("REVERT_HEAD").path) { state.operation = .revert }
          let names = try await read(["remote"], limit: 256 * 1024, timeout: 15).text
            .split(separator: "\n").map(String.init)
          let target: WorkspaceFetchTarget?
          if state.upstream != nil { target = try? await upstreamFetchTarget(record) } else { target = nil }
          let snapshot = WorkspaceSnapshot(record: record, status: state, gitDirectory: gitDirectory,
            commonDirectory: common, remoteNames: names, collectedAt: collectedAt,
            remoteTarget: target, collectedUptime: collectedUptime)
          await CommonDirectoryQueue.shared.release(common)
          return snapshot
        } catch {
          await CommonDirectoryQueue.shared.release(common)
          throw error
        }
      }
    } catch is CancellationError { throw CancellationError() }
    catch let failure as WorkspaceFailure { throw failure }
    catch {
      let ns = error as NSError
      if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError) {
        throw WorkspaceFailure(.missingDirectory, "The repository directory does not exist.")
      }
      let summary = error.localizedDescription
      if ns.code == NSFileReadNoPermissionError || summary.localizedCaseInsensitiveContains("permission denied") {
        throw WorkspaceFailure(.permissionDenied, summary)
      }
      if summary.contains("not a git repository") { throw WorkspaceFailure(.invalidRepository, summary) }
      throw WorkspaceFailure(.gitQuery, summary)
    }
  }
  private func validateWorkspaceRoot() async throws {
    let path = try Self.nativePath(try await read(["rev-parse", "--show-toplevel"],
      environment: ["GIT_NO_LAZY_FETCH": "1"], timeout: 15).stdout)
    guard URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath() == root else {
      throw WorkspaceFailure(.invalidRepository, "The registered directory is no longer a Git working-tree root.")
    }
  }
  private func requireLocalWorkspaceQueries() async throws {
    let result = try await read(["config", "--null", "--get-regexp", "^(extensions\\.partialclone|remote\\..*\\.(promisor|partialclonefilter))$"],
      allowFailure: true, limit: 64 * 1024, timeout: 15)
    guard result.code == 0 || result.code == 1 else { throw GitPierError.command("config", result.code, Self.redact(result.errorText)) }
    let partial = result.stdout.split(separator: 0).contains { bytes in
      let row = String(decoding: bytes, as: UTF8.self)
      guard let split = row.firstIndex(of: "\n") else { return row.hasSuffix(".promisor") }
      let key = row[..<split], value = row[row.index(after: split)...].lowercased()
      if key.hasSuffix(".promisor") { return ["true", "yes", "on", "1"].contains(value) }
      return !value.isEmpty
    }
    if partial {
      let executable = gitPath, runner = self.runner
      let supported = try await WorkspaceGitCapabilities.shared.supportsLocalPartialClone(executable: executable) {
        let version = try await runner.run(executable: executable, arguments: ["--version"], directory: nil, timeout: 5, limit: 64 * 1024)
        guard version.code == 0 else { throw GitPierError.command("version", version.code, Self.redact(version.errorText)) }
        return version.text
      }
      guard supported else {
        throw WorkspaceFailure(.gitQuery, "Local workspace queries for partial clones require Git 2.43 or later to prevent implicit network access. Select a newer Git executable in Settings.")
      }
    }
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
      "rebase-apply/onto", "rebase-merge/orig-head", "rebase-merge/git-rebase-todo",
      "rebase-merge/done", "rebase-merge/message", "rebase-merge/amend",
      "rebase-merge/msgnum", "rebase-merge/end", "rebase-apply/orig-head",
      "rebase-apply/next", "rebase-apply/last", "rebase-apply/patch",
      "rebase-merge/author-script", "rebase-merge/gpg_sign_opt", "rebase-merge/message-squash",
      "rebase-merge/message-fixup", "rebase-merge/current-fixups", "rebase-merge/rewritten-list",
      "gitpier-rebase-messages.json",
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
  private func liveIndexURL() async throws -> URL {
    let path = try Self.nativePath(try await read(["rev-parse", "--git-path", "index"]).stdout)
    return path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
  }
  private func liveIndexDigest() async throws -> Data {
    let index = try await liveIndexURL()
    let attributes = try FileManager.default.attributesOfItem(atPath: index.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      (attributes[.size] as? Int ?? Int.max) <= 64 * 1024 * 1024 else { throw GitPierError.outputLimit }
    return Data(SHA256.hash(data: try Data(contentsOf: index)))
  }
  public func reviewSelectiveStaging(file: FileChange, comparison: DiffComparison,
                                    expectedPatch: String, expectedIndex: IndexSnapshot) async throws -> SelectiveStagingReview {
    guard file.kind == .modified, file.originalPath == nil, file.submodule == "N...", !file.isConflicted else {
      throw GitPierError.invalidInput("Line actions support regular text modifications. Use file or supported hunk actions for this file type.")
    }
    let operation = try await reviewOperation(expectedIndex: expectedIndex)
    guard try await status().files.contains(file) else { throw GitPierError.indexChanged }
    // diff drivers only affect headings here: native patches disable external Diff/textconv.
    let attributes = try await read(["--literal-pathspecs", "check-attr", "-z", "filter", "working-tree-encoding", "ident", "--", file.path]).stdout
      .split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
    for index in stride(from: 2, to: attributes.count, by: 3) {
      guard ["unspecified", "unset"].contains(attributes[index]) else {
        throw GitPierError.invalidInput("Line actions are disabled for custom filters, encodings or ident expansion (" + attributes[index - 1] + "=" + attributes[index] + "). Use file-level staging.")
      }
    }
    let raw = try await patch(for: file, comparison: comparison)
    guard let text = String(data: raw, encoding: .utf8), text == expectedPatch else { throw GitPierError.indexChanged }
    let document = DiffParser.parse(raw)
    guard SelectivePatch.supported(document) else { throw GitPierError.invalidInput("This Diff does not support safe line actions. Use file or supported hunk actions.") }
    let working = try conflictWorkingFile(file.path).0
    guard working.kind == .regular else { throw GitPierError.invalidInput("Line actions require a regular working file.") }
    let digest = try await liveIndexDigest()
    guard try await reviewOperation() == operation, try await liveIndexDigest() == digest,
      try conflictWorkingFile(file.path).0 == working else { throw GitPierError.indexChanged }
    return SelectiveStagingReview(file: file, comparison: comparison, operation: operation,
                                 indexDigest: digest, working: working, document: document)
  }
  public func applySelectedLines(_ selected: Set<Int>, expected: SelectiveStagingReview) async throws {
    let patch = try SelectivePatch.build(expected.document, selected: selected, reverse: expected.comparison == .staged)
    try await writing {
      let index = try await liveIndexURL()
      let transaction = try IndexEditTransaction(index: index)
      guard Data(SHA256.hash(data: transaction.original)) == expected.indexDigest,
        try await reviewOperation() == expected.operation,
        try conflictWorkingFile(expected.file.path).0 == expected.working,
        try await self.patch(for: expected.file, comparison: expected.comparison) == Data(expected.document.raw.utf8) else {
        throw GitPierError.indexChanged
      }
      let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-line-index-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                             attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: temporary) }
      let copy = temporary.appendingPathComponent("index")
      try transaction.original.write(to: copy)
      let env = ["GIT_INDEX_FILE": copy.path]
      let args = ["apply", "--cached", "--whitespace=nowarn"]
      try await read(args + ["--check", "-"], input: patch, environment: env)
      try await read(args + ["-"], input: patch, environment: env)
      guard try await reviewOperation() == expected.operation,
        try conflictWorkingFile(expected.file.path).0 == expected.working else { throw GitPierError.indexChanged }
      try transaction.publish(Data(contentsOf: copy))
    }
  }
  public func reviewPatchImport(_ data: Data, target: PatchTarget = .workingTree) async throws -> PatchImportReview {
    let sections = try PatchParser.sections(data)
    let operation = try await reviewOperation()
    let current = try await status()
    guard current.head != nil else { throw GitPierError.invalidInput("Create an initial commit before importing a patch.") }
    guard current.operation == nil, !current.files.contains(where: \.isConflicted) else {
      throw GitPierError.invalidInput("Complete the unfinished Git operation before importing a patch.")
    }
    let numstat = try await read(["apply", "--numstat", "-z", "-"], input: data).stdout
    let files = try PatchParser.files(numstat, sections: sections)
    guard !files.isEmpty else { throw GitPierError.invalidInput("The patch has no file changes.") }
    var working: [String: ConflictWorkingState] = [:]
    let gitlinks = try await read(["ls-files", "--stage", "-z"]).stdout.split(separator: 0).compactMap { record -> String? in
      let row = String(decoding: record, as: UTF8.self)
      guard row.hasPrefix("160000 "), let tab = row.firstIndex(of: "\t") else { return nil }
      return String(row[row.index(after: tab)...])
    }
    for file in files {
      guard !gitlinks.contains(where: { file.path == $0 || file.path.hasPrefix($0 + "/") }) else { throw GitPierError.unsafePath(file.path) }
      var parent = try conflictURL(file.path).deletingLastPathComponent()
      while parent.path != root.path && parent.path.hasPrefix(root.path + "/") {
        guard !FileManager.default.fileExists(atPath: parent.appendingPathComponent(".git").path) else { throw GitPierError.unsafePath(file.path) }
        parent = parent.deletingLastPathComponent()
      }
      let state = try conflictWorkingFile(file.path).0
      guard state.kind == .regular || state.kind == .absent else { throw GitPierError.unsafePath(file.path) }
      working[file.path] = state
    }
    let digest = try await liveIndexDigest()
    let args = ["apply", "--whitespace=nowarn"] + (target == .index ? ["--cached"] : [])
    try await read(args + ["--check", "-"], input: data)
    let summary = try await read(["apply", "--summary", "-"], input: data).text
    guard try await reviewOperation() == operation, try await liveIndexDigest() == digest else { throw GitPierError.indexChanged }
    for (path, state) in working { guard try conflictWorkingFile(path).0 == state else { throw GitPierError.indexChanged } }
    return PatchImportReview(patch: data, target: target, operation: operation, indexDigest: digest,
                             files: files, working: working, summary: summary)
  }
  public func applyImportedPatch(_ expected: PatchImportReview) async throws -> String {
    _ = try PatchParser.sections(expected.patch)
    return try await writing {
      guard try await reviewOperation() == expected.operation,
        try await liveIndexDigest() == expected.indexDigest else { throw GitPierError.indexChanged }
      for (path, state) in expected.working { guard try conflictWorkingFile(path).0 == state else { throw GitPierError.indexChanged } }
      let index = try await liveIndexURL()
      // Even worktree-only apply holds the Index lock to preserve partial staging during the operation.
      let transaction = try IndexEditTransaction(index: index)
      guard Data(SHA256.hash(data: transaction.original)) == expected.indexDigest else { throw GitPierError.indexChanged }
      let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-patch-index-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: temporary) }
      let copy = temporary.appendingPathComponent("index"); try transaction.original.write(to: copy)
      let env = ["GIT_INDEX_FILE": copy.path]
      let args = ["apply", "--whitespace=nowarn"] + (expected.target == .index ? ["--cached"] : [])
      try await read(args + ["--check", "-"], input: expected.patch, environment: env)
      guard try await reviewOperation() == expected.operation else { throw GitPierError.indexChanged }
      for (path, state) in expected.working { guard try conflictWorkingFile(path).0 == state else { throw GitPierError.indexChanged } }
      let result = try await read(args + ["-"], input: expected.patch, environment: env)
      if expected.target == .index {
        guard try await reviewOperation() == expected.operation else { throw GitPierError.indexChanged }
        for (path, state) in expected.working { guard try conflictWorkingFile(path).0 == state else { throw GitPierError.indexChanged } }
        try transaction.publish(Data(contentsOf: copy))
      }
      return Self.redact(result.text + result.errorText)
    }
  }
  public func exportFilePatch(_ file: FileChange, comparison: DiffComparison) async throws -> Data {
    try file.paths.forEach(InputValidation.repositoryPath)
    let args = ["--literal-pathspecs", "diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv"]
    if file.isUntracked {
      return try await read(args + ["--no-index", "--", "/dev/null", file.path], allowFailure: true,
                            limit: PatchParser.limit).stdout
    }
    return try await read(args + (comparison == .staged ? ["--cached"] : []) + ["--"] + file.paths,
                          limit: PatchParser.limit).stdout
  }
  public func exportCommitPatch(_ reference: String, format: PatchExportFormat = .diff) async throws -> Data {
    let hash = try await resolveCommit(reference)
    let commit = try await commitDetail(hash)
    if format == .commitEmail {
      guard commit.parents.count <= 1 else { throw GitPierError.invalidInput("Email patch export does not support merge commits. Export a Diff against a parent instead.") }
      return try await read(["format-patch", "--stdout", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", "-1", hash], limit: PatchParser.limit).stdout
    }
    if let parent = commit.parents.first {
      return try await exportRangePatch(from: parent, to: hash)
    }
    return try await read(["diff-tree", "--root", "--no-commit-id", "--binary", "--full-index",
                           "--no-ext-diff", "--no-textconv", "-p", hash], limit: PatchParser.limit).stdout
  }
  public func exportRangePatch(from: String, to: String, format: PatchExportFormat = .diff) async throws -> Data {
    let base = try await resolveCommit(from), tip = try await resolveCommit(to)
    if format == .commitEmail {
      guard try await read(["merge-base", "--is-ancestor", base, tip], allowFailure: true).code == 0 else {
        throw GitPierError.invalidInput("Email patch export requires an ancestor range.")
      }
      let merges = try await read(["rev-list", "--merges", base + ".." + tip]).stdout
      let count = Int(try await read(["rev-list", "--count", base + ".." + tip]).text.trimmingCharacters(in: .newlines)) ?? 0
      guard merges.isEmpty, count > 0, count <= 200 else { throw GitPierError.invalidInput("Email patch export requires 1–200 linear commits without merges.") }
      return try await read(["format-patch", "--stdout", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", base + ".." + tip], limit: PatchParser.limit).stdout
    }
    return try await read(["diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", base, tip],
                          limit: PatchParser.limit).stdout
  }
  private func rootLFSAttributes() throws -> (ConflictWorkingState, Data) {
    let url = try conflictURL(".gitattributes")
    if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      (attributes[.size] as? Int ?? 0) > LFSAttributes.limit { throw GitPierError.outputLimit }
    let (state, content) = try conflictWorkingFile(".gitattributes")
    guard state.kind == .regular || state.kind == .absent else { throw GitPierError.unsafePath(".gitattributes") }
    guard state.kind == .absent || content != nil else { throw GitPierError.outputLimit }
    let data = content ?? Data(); _ = try LFSAttributes.rules(data); return (state, data)
  }
  private func requireLFS() async throws -> String {
    let result = try await read(["lfs", "version"], allowFailure: true, limit: 8192)
    guard result.code == 0, result.text.hasPrefix("git-lfs/") else {
      throw GitPierError.invalidInput("Git LFS is not available for the selected Git environment. Install it separately and refresh; GitPier does not install or configure it globally.")
    }
    return result.text.trimmingCharacters(in: .newlines)
  }
  private func lfsFiltersConfigured() async throws -> Bool {
    let process = try await read(["config", "--get", "filter.lfs.process"], allowFailure: true)
    if process.code == 0 && !process.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
    let clean = try await read(["config", "--get", "filter.lfs.clean"], allowFailure: true)
    let smudge = try await read(["config", "--get", "filter.lfs.smudge"], allowFailure: true)
    return clean.code == 0 && smudge.code == 0 && !clean.stdout.isEmpty && !smudge.stdout.isEmpty
  }
  public func lfsState() async throws -> LFSState {
    let (_, attributes) = try rootLFSAttributes()
    let rules = try LFSAttributes.rules(attributes)
    let version = try await read(["lfs", "version"], allowFailure: true, limit: 8192)
    guard version.code == 0, version.text.hasPrefix("git-lfs/") else {
      return LFSState(installed: false, configured: false, version: "", diagnostic: Self.redact(version.errorText),
                      attributes: attributes, rules: rules, files: [], trackingSummary: "")
    }
    let configured = try await lfsFiltersConfigured()
    let listing = try await read(["lfs", "ls-files", "--json"], allowFailure: true, limit: 8 * 1024 * 1024)
    if listing.code != 0 {
      return LFSState(installed: true, configured: configured, version: version.text.trimmingCharacters(in: .newlines),
                      diagnostic: Self.redact(listing.errorText), attributes: attributes, rules: rules, files: [], trackingSummary: "")
    }
    let native = try JSONDecoder().decode(LFSNativeFiles.self, from: listing.stdout)
    var files: [LFSFile] = [], seen = Set<String>()
    for item in (native.files ?? []).prefix(5000) {
      try Task.checkCancellation(); try InputValidation.repositoryPath(item.name)
      guard seen.insert(item.name).inserted, item.size >= 0, item.oid_type == "sha256",
        item.oid.count == 64, item.oid.allSatisfy(\.isHexDigit) else { throw GitPierError.invalidInput("Git LFS returned invalid file metadata.") }
      let url = try conflictURL(item.name)
      var pointer: LFSPointer?
      if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
        attributes[.type] as? FileAttributeType == .typeRegular,
        (attributes[.size] as? Int ?? Int.max) <= LFSPointer.limit {
        pointer = LFSPointer.parse(try Data(contentsOf: url))
      }
      files.append(LFSFile(path: item.name, oid: item.oid, size: item.size, downloaded: item.downloaded,
                           materialized: item.checkout && pointer == nil, workingPointer: pointer))
    }
    let summary = try await read(["lfs", "track"], allowFailure: true, limit: LFSAttributes.limit)
    return LFSState(installed: true, configured: configured, version: version.text.trimmingCharacters(in: .newlines),
                    diagnostic: (native.files?.count ?? 0) > 5000 ? "The file list shows the first 5,000 LFS files. Network operations use the complete current reference." : nil,
                    attributes: attributes, rules: rules, files: files,
                    trackingSummary: Self.redact(summary.text + summary.errorText))
  }
  public func reviewLFSRule(_ pattern: String, track: Bool) async throws -> LFSRuleReview {
    _ = try await requireLFS()
    let operation = try await reviewOperation()
    guard try await status().operation == nil else { throw GitPierError.invalidInput("Complete the Git operation before editing LFS rules.") }
    let (working, before) = try rootLFSAttributes()
    let after = try LFSAttributes.edit(before, pattern: pattern, track: track)
    guard before != after else { throw GitPierError.invalidInput("This root LFS rule is already effective.") }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-lfs-rule-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temporary) }
    let old = temporary.appendingPathComponent("before"), new = temporary.appendingPathComponent("after")
    try before.write(to: old); try after.write(to: new)
    let diff = try await read(["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--", old.path, new.path], allowFailure: true).stdout
    guard try await reviewOperation() == operation, try rootLFSAttributes().0 == working else { throw GitPierError.indexChanged }
    return LFSRuleReview(operation: operation, working: working, before: before, after: after,
                         document: DiffParser.parse(diff), pattern: pattern, track: track)
  }
  public func applyLFSRule(_ expected: LFSRuleReview) async throws {
    try await writing {
      guard try await reviewOperation() == expected.operation, try rootLFSAttributes().0 == expected.working else { throw GitPierError.indexChanged }
      let file = try conflictURL(".gitattributes")
      try expected.after.write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: expected.working.kind == .absent ? 0o644 : expected.working.permissions], ofItemAtPath: file.path)
    }
  }
  private func lfsConfiguration() async throws -> Data {
    let result = try await read(["config", "--null", "--get-regexp", "^(lfs\\.|remote\\.|filter\\.lfs\\.)"], allowFailure: true)
    guard result.code == 0 || result.code == 1 else { throw GitPierError.invalidInput("Cannot review the LFS network configuration.") }
    return Data(SHA256.hash(data: result.stdout))
  }
  public func reviewLFSNetwork(_ action: LFSNetworkAction, remote: String) async throws -> LFSNetworkReview {
    _ = try await requireLFS(); try InputValidation.reference(remote)
    let configuration = try await lfsConfiguration()
    guard let destination = try await remotes().first(where: { $0.name == remote }) else { throw GitPierError.invalidInput("Choose an existing Git remote for LFS.") }
    let operation = try await reviewOperation(), state = try await status()
    guard operation.head != nil, state.operation == nil else { throw GitPierError.invalidInput("LFS network operations require a commit and no unfinished Git operation.") }
    if action == .pull, !state.tracked.isEmpty { throw GitPierError.invalidInput("Commit or preserve tracked changes before LFS Pull. LFS Fetch leaves working files unchanged.") }
    if action == .pull, !(try await lfsFiltersConfigured()) {
      throw GitPierError.invalidInput("Configure Git LFS filters and hooks separately before Pull. GitPier does not install them or alter global Git configuration.")
    }
    let settings = try conflictWorkingFile(".lfsconfig").0
    guard settings.kind == .regular || settings.kind == .absent else { throw GitPierError.unsafePath(".lfsconfig") }
    let digest = try await liveIndexDigest()
    guard try await reviewOperation() == operation, try await lfsConfiguration() == configuration,
      try conflictWorkingFile(".lfsconfig").0 == settings else { throw GitPierError.indexChanged }
    return LFSNetworkReview(action: action, remote: remote, remoteURL: Self.redact(destination.fetchURL),
                            operation: operation, indexDigest: digest, configuration: configuration, settings: settings)
  }
  public func performLFSNetwork(_ expected: LFSNetworkReview,
                                 progress: (@Sendable (GitTransferProgress) -> Void)? = nil) async throws -> String {
    try await writing { () async throws -> String in
      _ = try await requireLFS()
      if expected.action == .pull, !(try await lfsFiltersConfigured()) { throw GitPierError.indexChanged }
      guard try await reviewOperation() == expected.operation, try await liveIndexDigest() == expected.indexDigest,
        try await lfsConfiguration() == expected.configuration,
        try conflictWorkingFile(".lfsconfig").0 == expected.settings else { throw GitPierError.indexChanged }
      let decoder = GitProgressDecoder { value in progress?(value) }
      let receiver: @Sendable (Data) -> Void = { bytes in decoder.feed(bytes) }
      let fetched = try await read(["lfs", "fetch", "--", expected.remote, expected.operation.head!],
        environment: ["GIT_LFS_FORCE_PROGRESS": "1"], timeout: 3600, onStderr: receiver)
      guard expected.action == .pull else { return Self.redact(fetched.text + fetched.errorText) }
      // Native Pull semantics, split so HEAD/Index changes during download stop checkout.
      guard try await reviewOperation() == expected.operation, try await liveIndexDigest() == expected.indexDigest,
        try await lfsConfiguration() == expected.configuration, try await status().tracked.isEmpty,
        try conflictWorkingFile(".lfsconfig").0 == expected.settings else { throw GitPierError.indexChanged }
      let index = try await liveIndexURL()
      let transaction = try IndexEditTransaction(index: index)
      guard Data(SHA256.hash(data: transaction.original)) == expected.indexDigest else { throw GitPierError.indexChanged }
      let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-lfs-index-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: temporary) }
      let copy = temporary.appendingPathComponent("index"); try transaction.original.write(to: copy)
      let checked = try await read(["lfs", "checkout"], environment: ["GIT_INDEX_FILE": copy.path, "GIT_LFS_FORCE_PROGRESS": "1"],
                                   timeout: 3600, onStderr: receiver)
      guard try await reviewOperation() == expected.operation else { throw GitPierError.indexChanged }
      return Self.redact(fetched.text + fetched.errorText + checked.text + checked.errorText)
    }
  }
  private func submodulePath(_ path: String) throws -> URL {
    try InputValidation.repositoryPath(path)
    guard !path.contains("\n"), !path.contains("\r"),
      !path.split(separator: "/").contains(where: { $0.lowercased() == ".git" }) else { throw GitPierError.unsafePath(path) }
    let url = try conflictURL(path)
    if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      attributes[.type] as? FileAttributeType != .typeDirectory { throw GitPierError.unsafePath(path) }
    return url
  }
  private func submodulesFileState() throws -> ConflictWorkingState {
    let file = try conflictURL(".gitmodules")
    if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
      (attributes[.size] as? Int ?? 0) > 1024 * 1024 { throw GitPierError.outputLimit }
    let state = try conflictWorkingFile(".gitmodules").0
    guard state.kind == .regular || state.kind == .absent else { throw GitPierError.unsafePath(".gitmodules") }
    return state
  }
  private func moduleConfiguration(_ module: GitSubmodule? = nil) async throws -> Data {
    let parent = try await read(["config", "--null", "--get-regexp", "^submodule\\."], allowFailure: true)
    guard parent.code == 0 || parent.code == 1 else { throw GitPierError.invalidInput("Cannot review submodule configuration.") }
    var bytes = parent.stdout
    if let module, module.initialized {
      bytes.append(try await read(["-C", try submodulePath(module.path).path, "config", "--null", "--get-regexp", "^(remote\\.|branch\\.|submodule\\.)"], allowFailure: true).stdout)
    }
    return Data(SHA256.hash(data: bytes))
  }
  private struct SubmoduleScan: Sendable {
    var result: [GitSubmodule] = []
    var visited = Set<String>()
  }
  public func submodules(includeNested: Bool = true) async throws -> [GitSubmodule] {
    _ = try submodulesFileState()
    return try await scanSubmodules(root, relative: "", depth: 0, includeNested: includeNested, scan: SubmoduleScan()).result
  }
  // Keep recursive traversal on this actor. A local async function is nonisolated
  // in Swift 6.1 and cannot safely capture mutable result/visited collections.
  private func scanSubmodules(_ directory: URL, relative: String, depth: Int, includeNested: Bool,
                              scan initialScan: SubmoduleScan) async throws -> SubmoduleScan {
    var scan = initialScan
    let canonical = ProfessionalWorkflowParser.canonicalPath(directory.path)
    guard scan.visited.insert(canonical).inserted, scan.result.count < 100 else { return scan }
    let file = directory.appendingPathComponent(".gitmodules")
    var declarations: [(String, String)] = []
    if FileManager.default.fileExists(atPath: file.path) {
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? Int ?? Int.max) <= 1024 * 1024 else { throw GitPierError.unsafePath(".gitmodules") }
      let config = try await read(["-C", directory.path, "config", "--null", "--file", ".gitmodules", "--get-regexp", "^submodule\\..*\\.path$"], allowFailure: true)
      guard config.code == 0 || config.code == 1 else { throw GitPierError.invalidInput("The .gitmodules file is invalid. Inspect it in the editor.") }
      declarations = try SubmoduleParser.declarations(config.stdout)
    }
    let index = try SubmoduleParser.gitlinks(await read(["-C", directory.path, "ls-files", "--stage", "-z"]).stdout, index: true)
    let head = try SubmoduleParser.gitlinks(await read(["-C", directory.path, "ls-tree", "-r", "-z", "HEAD"], allowFailure: true).stdout, index: false)
    let configuredPaths = Set(declarations.map(\.1))
    declarations += index.keys.filter { !configuredPaths.contains($0) }.sorted().map { ($0, $0) }
    var seen = Set<String>()
    for (name, path) in declarations {
      try Task.checkCancellation()
      guard scan.result.count < 100 else { return scan }
      guard seen.insert(path).inserted else { throw GitPierError.invalidInput("Duplicate submodule paths require manual repair.") }
      let fullPath = relative.isEmpty ? path : relative + "/" + path
      let declared = try await read(["-C", directory.path, "config", "--file", ".gitmodules", "--get", "submodule." + name + ".url"], allowFailure: true).text.trimmingCharacters(in: .newlines)
      let registered = try await read(["-C", directory.path, "config", "--get", "submodule." + name + ".url"], allowFailure: true).text.trimmingCharacters(in: .newlines)
      let branch = try await read(["-C", directory.path, "config", "--file", ".gitmodules", "--get", "submodule." + name + ".branch"], allowFailure: true).text.trimmingCharacters(in: .newlines)
      var initialized = false, childHead: String?, changes: Int?, operation: GitOperation?, problem: String?
      var childURL: URL?
      do {
        let child = try submodulePath(fullPath); childURL = child
        if FileManager.default.fileExists(atPath: child.path) {
          let top = try await read(["-C", child.path, "rev-parse", "--show-toplevel"], allowFailure: true)
          if top.code == 0, ProfessionalWorkflowParser.canonicalPath(try Self.nativePath(top.stdout)) == ProfessionalWorkflowParser.canonicalPath(child.path) {
            initialized = true
            let service = await GitServiceRegistry.shared.service(for: child, gitPath: gitPath)
            let state = try await service.status(); childHead = state.head; changes = state.files.count; operation = state.operation
          }
        }
        if declared.isEmpty { problem = "Missing .gitmodules URL; inspect this gitlink in the terminal." }
        if index[path] == nil { problem = "This declaration has no staged gitlink." }
      } catch { problem = Self.redact(error.localizedDescription) }
      scan.result.append(GitSubmodule(name: name, path: fullPath, localPath: path, depth: depth,
        url: Self.redact(declared), configuredURL: Self.redact(registered), branch: branch,
        currentHead: childHead, indexCommit: index[path], parentCommit: head[path], registered: !registered.isEmpty,
        initialized: initialized, changes: changes, operation: operation, problem: problem))
      if includeNested, initialized, depth < 3, let childURL {
        scan = try await scanSubmodules(childURL, relative: fullPath, depth: depth + 1, includeNested: includeNested, scan: scan)
      }
    }
    return scan
  }
  private func currentSubmodule(_ path: String) async throws -> GitSubmodule {
    guard let module = try await submodules(includeNested: false).first(where: { $0.path == path }) else {
      throw GitPierError.invalidInput("This submodule changed. Refresh and review its state again.")
    }
    guard module.depth == 0, module.problem == nil, module.indexCommit != nil else {
      throw GitPierError.invalidInput("Manage nested or incomplete submodules by opening their parent repository. Deinit and removal are not supported.")
    }
    return module
  }
  private func validateChildIndexFlags(_ path: String) async throws {
    let entries = try await read(["-C", try submodulePath(path).path, "ls-files", "-v", "-z"]).stdout.split(separator: 0)
    guard !entries.contains(where: { $0.first == 83 || ($0.first.map { (97...122).contains($0) } ?? false) }) else {
      throw GitPierError.invalidInput("Inspect skip-worktree or assume-unchanged child entries in the terminal before updating the submodule.")
    }
  }
  public func reviewSubmodule(_ path: String, action: SubmoduleAction) async throws -> SubmoduleReview {
    let parent = try await reviewOperation()
    guard try await status().operation == nil else { throw GitPierError.invalidInput("Complete the parent Git operation before managing submodules.") }
    let module = try await currentSubmodule(path), working = try submodulesFileState()
    let configuration = try await moduleConfiguration(module)
    var childReview: GitOperationReview?, target = module.indexCommit, remote: String?
    if module.initialized {
      let child = try await GitServiceRegistry.shared.service(for: submodulePath(path), gitPath: gitPath)
      childReview = try await child.reviewOperation()
      if action == .recorded || action == .remote {
        try await validateChildIndexFlags(path)
        let state = try await child.status()
        guard state.operation == nil, state.files.isEmpty else {
          throw GitPierError.invalidInput("Preserve all modified and untracked child files and finish its Git operation before updating the submodule.")
        }
      }
      if action == .remote {
        let childURL = try submodulePath(path)
        let remotes = try await child.remotes()
        guard let selected = remotes.first(where: { $0.name == "origin" }) ?? (remotes.count == 1 ? remotes.first : nil) else {
          throw GitPierError.invalidInput("Select the child's remote in its own repository before a remote-tracking update.")
        }
        remote = selected.name
        var branch = try await read(["config", "--get", "submodule." + module.name + ".branch"], allowFailure: true).text.trimmingCharacters(in: .newlines)
        if branch.isEmpty { branch = module.branch }
        if branch == "." {
          guard !parent.branch.isEmpty, parent.branch != "(detached)" else { throw GitPierError.invalidInput("A submodule branch of '.' requires a parent branch.") }
          branch = parent.branch
        }
        if !branch.isEmpty { try InputValidation.reference(branch) }
        let reference = branch.isEmpty ? "HEAD" : "refs/heads/" + branch
        let data = try await read(["-C", childURL.path, "ls-remote", "--symref", "--", selected.name, reference]).text
        let hashes = data.components(separatedBy: "\n").compactMap { line -> String? in
          let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
          return fields.count == 2 && fields[1] == reference && [40, 64].contains(fields[0].count) && fields[0].allSatisfy(\.isHexDigit) ? fields[0] : nil
        }
        guard hashes.count == 1 else { throw GitPierError.invalidInput("The remote-tracking target is unavailable or ambiguous.") }
        target = hashes[0]
      }
    } else if action == .remote {
      throw GitPierError.invalidInput("Initialize and check out the recorded submodule before reviewing a remote-tracking update.")
    } else if action == .recorded {
      let url = try submodulePath(path)
      if FileManager.default.fileExists(atPath: url.path), !(try FileManager.default.contentsOfDirectory(atPath: url.path)).isEmpty {
        throw GitPierError.invalidInput("The uninitialized submodule directory contains unknown data. It will not be overwritten.")
      }
    }
    guard try await reviewOperation() == parent, try submodulesFileState() == working,
      try await moduleConfiguration(module) == configuration else { throw GitPierError.indexChanged }
    return SubmoduleReview(module: module, action: action, parent: parent, modulesFile: working,
                           configuration: configuration, child: childReview, target: target, remote: remote)
  }
  private func validateSubmoduleReview(_ expected: SubmoduleReview) async throws {
    guard try await reviewOperation() == expected.parent, try submodulesFileState() == expected.modulesFile,
      try await moduleConfiguration(expected.module) == expected.configuration else { throw GitPierError.indexChanged }
    let current = try await currentSubmodule(expected.module.path)
    guard current == expected.module else { throw GitPierError.indexChanged }
    if current.initialized && (expected.action == .recorded || expected.action == .remote) {
      try await validateChildIndexFlags(current.path)
    }
    if let expectedChild = expected.child {
      let child = try await GitServiceRegistry.shared.service(for: submodulePath(current.path), gitPath: gitPath)
      guard try await child.reviewOperation() == expectedChild else { throw GitPierError.indexChanged }
    }
  }
  func submoduleReservation<T: Sendable>(initialized: Bool, heldCommon: String,
                                         _ action: @Sendable () async throws -> T) async throws -> T {
    if initialized, try await commonDirectory().path != heldCommon { return try await lifecycleWrite(action) }
    return try await writing(action)
  }
  public func performSubmodule(_ expected: SubmoduleReview,
                               progress: (@Sendable (GitTransferProgress) -> Void)? = nil) async throws -> String {
    try await lifecycleWrite {
      let childURL = try submodulePath(expected.module.path)
      let child = await GitServiceRegistry.shared.service(for: childURL, gitPath: gitPath)
      let held = try await commonDirectory().path
      return try await child.submoduleReservation(initialized: expected.module.initialized, heldCommon: held) {
        try await self.validateSubmoduleReview(expected)
        let decoder = GitProgressDecoder { value in progress?(value) }
        let receiver: @Sendable (Data) -> Void = { bytes in decoder.feed(bytes) }
        if expected.action == .initialize || expected.action == .sync {
          let command = expected.action == .initialize ? "init" : "sync"
          let result = try await self.read(["--literal-pathspecs", "submodule", command, "--", expected.module.path])
          return Self.redact(result.text + result.errorText)
        }
        if !expected.module.initialized {
          let result = try await self.read(["--literal-pathspecs", "submodule", "update", "--init", "--checkout", "--", expected.module.path], timeout: 3600, onStderr: receiver)
          guard try await child.resolveCommit("HEAD") == expected.target else { throw GitPierError.invalidInput("The submodule checkout differs from the reviewed gitlink. Inspect its state before continuing.") }
          return Self.redact(result.text + result.errorText)
        }
        let target = expected.target!
        let exists = try await self.read(["-C", childURL.path, "cat-file", "-e", target + "^{commit}"], allowFailure: true)
        let temporaryReference = "refs/gitpier/submodule/" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var fetched = false
        func cleanup() async {
          if fetched {
            _ = try? await Task.detached { try await self.read(["-C", childURL.path, "update-ref", "-d", temporaryReference, target]) }.value
          }
        }
        do {
          if expected.action == .remote || exists.code != 0 {
            let remote = expected.remote ?? "origin"
            fetched = true
            _ = try await self.read(["-C", childURL.path, "fetch", "--no-write-fetch-head", "--no-tags", "--", remote, target + ":" + temporaryReference], timeout: 3600, onStderr: receiver)
          }
          try await self.validateSubmoduleReview(expected)
          let result = try await self.read(["-C", childURL.path, "checkout", "--detach", "--no-overwrite-ignore", target], timeout: 3600, onStderr: receiver)
          guard try await child.resolveCommit("HEAD") == target else { throw GitPierError.indexChanged }
          await cleanup()
          return Self.redact(result.text + result.errorText)
        } catch { await cleanup(); throw error }
      }
    }
  }
  public func reviewSubmoduleAdd(url: String, path: String) async throws -> SubmoduleAddReview {
    try InputValidation.remoteURL(url)
    guard !url.hasPrefix("./"), !url.hasPrefix("../") else {
      throw GitPierError.invalidInput("Choose an absolute submodule URL or path. Relative remote URLs require terminal review.")
    }
    let destination = try submodulePath(path)
    guard !FileManager.default.fileExists(atPath: destination.path) else { throw GitPierError.invalidInput("Choose a new submodule directory. Existing directories are preserved.") }
    let parent = try await reviewOperation(), state = try await status()
    guard parent.head != nil, state.operation == nil, !state.files.contains(where: { $0.path == ".gitmodules" || $0.path == path || $0.isConflicted }) else {
      throw GitPierError.invalidInput("Preserve .gitmodules changes and finish the parent Git operation before adding a submodule.")
    }
    let registered = try await submodules(includeNested: false)
    guard !registered.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") || $0.path.hasPrefix(path + "/") }) else { throw GitPierError.unsafePath(path) }
    let metadata = try await metadataFile("modules/" + path)
    guard !FileManager.default.fileExists(atPath: metadata.path) else { throw GitPierError.invalidInput("Existing submodule Git metadata requires manual review; it will not be reused or removed.") }
    let filters = try await read(["check-attr", "-z", "filter", "working-tree-encoding", "--", ".gitmodules"]).stdout.split(separator: 0, omittingEmptySubsequences: false)
    for index in stride(from: 2, to: filters.count, by: 3) {
      guard ["unspecified", "unset"].contains(String(decoding: filters[index], as: UTF8.self)) else { throw GitPierError.invalidInput("Submodule configuration uses a filter or encoding. Review it in the terminal before adding.") }
    }
    return try await SubmoduleAddReview(path: path, url: url, parent: parent, modulesFile: submodulesFileState(), configuration: moduleConfiguration())
  }
  public func addSubmodule(_ expected: SubmoduleAddReview,
                            progress: (@Sendable (GitTransferProgress) -> Void)? = nil) async throws -> String {
    try await lifecycleWrite {
      let current = try await reviewSubmoduleAdd(url: expected.url, path: expected.path)
      guard current.parent == expected.parent, current.modulesFile == expected.modulesFile,
        current.configuration == expected.configuration else { throw GitPierError.indexChanged }
      let child = try await GitServiceRegistry.shared.service(for: submodulePath(expected.path), gitPath: gitPath)
      let held = try await commonDirectory().path
      return try await child.submoduleReservation(initialized: false, heldCommon: held) {
        let decoder = GitProgressDecoder { value in progress?(value) }
        let before = try await self.read(["ls-files", "--stage", "-z"]).stdout
        let protected = SubmoduleParser.otherIndex(before, excluding: [expected.path, ".gitmodules"])
        let destination = try await self.submodulePath(expected.path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Download first. An external Index/.gitmodules change during a long clone
        // stops registration/staging, retaining the downloaded directory for review.
        try await Self.clone(url: expected.url, destination: destination, gitPath: self.gitPath,
                             environment: self.authEnvironment, authArguments: self.authArguments, progress: progress)
        guard try await self.reviewOperation() == expected.parent,
          try await self.submodulesFileState() == expected.modulesFile,
          try await self.moduleConfiguration() == expected.configuration else { throw GitPierError.indexChanged }
        let result = try await self.read(["submodule", "add", "--", expected.url, expected.path], timeout: 3600, onStderr: { bytes in decoder.feed(bytes) })
        let after = try await self.read(["ls-files", "--stage", "-z"]).stdout
        guard SubmoduleParser.otherIndex(after, excluding: [expected.path, ".gitmodules"]) == protected else {
          throw GitPierError.indexChanged
        }
        return Self.redact(result.text + result.errorText)
      }
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
        name: String(f[5].dropFirst(f[5].hasPrefix("refs/remotes/") ? "refs/remotes/".count : "refs/heads/".count)), current: f[1] == "*", remote: f[5].hasPrefix("refs/remotes/"), upstream: f[2],
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
  private func workspaceFetchIdentity(_ remote: String) async throws -> String {
    let pattern = "^remote\\." + NSRegularExpression.escapedPattern(for: remote) + "\\."
    let config = try await read(["config", "--null", "--get-regexp", pattern], allowFailure: true)
    guard config.code == 0 else { throw GitPierError.invalidInput("The remote no longer exists. Review Fetch again.") }
    let effective = try await read(["remote", "get-url", "--all", "--", remote]).stdout
    let common = try await commonDirectory()
    let attributes = try FileManager.default.attributesOfItem(atPath: common.path)
    let identity = Data("\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? "")".utf8)
    return SHA256.hash(data: config.stdout + effective + identity).map { String(format: "%02x", $0) }.joined()
  }
  public func reviewWorkspaceFetch(_ record: RepositoryRecord) async throws -> [WorkspaceFetchTarget] {
    try await lifecycleWrite {
      try await validateWorkspaceRoot()
      let common = try await commonDirectory().path
      var targets: [WorkspaceFetchTarget] = []
      for remote in try await remotes() {
        targets.append(WorkspaceFetchTarget(record: record, commonDirectory: common, remote: remote,
          configurationIdentity: try await self.workspaceFetchIdentity(remote.name)))
      }
      return targets
    }
  }
  /// Resolve only the branch's configured upstream remote, using local metadata exclusively.
  public func upstreamFetchTarget(_ record: RepositoryRecord) async throws -> WorkspaceFetchTarget? {
    let branch = try await read(["symbolic-ref", "-q", "HEAD"], allowFailure: true).text.trimmingCharacters(in: .newlines)
    guard branch.hasPrefix("refs/heads/") else { return nil }
    let name = try await read(["for-each-ref", "--format=%(upstream:remotename)", "--", branch]).text.trimmingCharacters(in: .newlines)
    guard !name.isEmpty, name != "." else { return nil }
    try InputValidation.reference(name)
    let identity = try await workspaceFetchIdentity(name)
    let url = try await read(["remote", "get-url", "--", name]).text.trimmingCharacters(in: .newlines)
    let remote = GitRemote(name: name, fetchURL: Self.redact(url), pushURL: "",
      configuredFetchURLs: [], configuredPushURLs: [], configurationID: identity)
    return WorkspaceFetchTarget(record: record, commonDirectory: try await commonDirectory().path,
      remote: remote, configurationIdentity: identity)
  }
  public func trackingReferenceIdentity(_ remote: String) async throws -> String {
    try InputValidation.reference(remote)
    let data = try await read(["for-each-ref", "--format=%(refname)%00%(objectname)", "refs/remotes/" + remote + "/"]).stdout
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  public func confirmedManualFetchTargets(_ reviewed: [WorkspaceFetchTarget], all: Bool) async -> [WorkspaceFetchTarget] {
    var valid: [WorkspaceFetchTarget] = []
    for target in reviewed {
      guard (try? await workspaceFetchIdentity(target.remote.name)) == target.configurationIdentity else { continue }
      if all {
        var skipped = false
        for flag in ["skipFetchAll", "skipDefaultUpdate"] {
          let value = try? await read(["config", "--bool", "--get", "remote." + target.remote.name + "." + flag], allowFailure: true).text
          if value?.trimmingCharacters(in: .newlines) == "true" { skipped = true }
        }
        if skipped { continue }
      }
      valid.append(target)
    }
    return valid
  }
  public func workspaceFetch(_ target: WorkspaceFetchTarget) async throws -> String {
    try await checkedWorkspaceFetch(target).output
  }
  public func checkedWorkspaceFetch(_ target: WorkspaceFetchTarget, automatic: Bool = false) async throws -> WorkspaceFetchResult {
    try InputValidation.reference(target.remote.name)
    // Automatic work never queues behind an in-app write. Manual requests retain the normal FIFO.
    if automatic, writeBusy { throw AutomaticFetchError.skipped("Repository busy. Check deferred.") }
    return try await lifecycleWrite(onlyIfIdle: automatic) {
      try await validateWorkspaceRoot()
      guard root.path == URL(fileURLWithPath: target.record.path).resolvingSymlinksInPath().path,
            try await commonDirectory().path == target.commonDirectory,
            try await workspaceFetchIdentity(target.remote.name) == target.configurationIdentity else {
        throw GitPierError.invalidInput("The repository or remote configuration changed. Review Fetch again.")
      }
      var arguments = ["fetch", "--progress", "--no-write-fetch-head", "--recurse-submodules=no", "--no-auto-gc"]
      var environment: [String: String] = [:]
      if automatic {
        let state: RepositoryStatus
        do { state = try await status(localOnly: true) }
        catch let failure as WorkspaceFailure { throw AutomaticFetchError.skipped(failure.summary) }
        guard state.operation == nil, !state.files.contains(where: \.isConflicted) else {
          throw AutomaticFetchError.skipped("Resolve the current Git operation before automatic Fetch.")
        }
        environment = try await automaticFetchEnvironment(target)
        arguments += ["--no-tags", "--no-prune", "--no-prune-tags"]
      }
      let refs = ["for-each-ref", "--format=%(refname)%00%(objectname)", "refs/remotes/" + target.remote.name + "/"]
      let before = try await read(refs).stdout
      let result = try await read(arguments + ["--", target.remote.name], environment: environment, timeout: automatic ? 60 : 120)
      let after = try await read(refs).stdout
      // A changed URL/refspec cannot inherit the old result even if transport succeeded.
      guard try await workspaceFetchIdentity(target.remote.name) == target.configurationIdentity else {
        throw GitPierError.invalidInput("Remote configuration changed during Fetch. Check again.")
      }
      return WorkspaceFetchResult(output: Self.redact(result.text + result.errorText), referencesUpdated: before != after)
    }
  }
  private func automaticFetchEnvironment(_ target: WorkspaceFetchTarget) async throws -> [String: String] {
    let name = target.remote.name
    for option in ["vcs", "uploadpack"] {
      let value = try await read(["config", "--get-all", "remote." + name + "." + option], allowFailure: true).text
      guard value.isEmpty else { throw AutomaticFetchError.skipped("Custom remote helpers require manual Fetch.") }
    }
    let config = try await read(["config", "--get-all", "remote." + name + ".fetch"], allowFailure: true).text
      .split(separator: "\n").map(String.init)
    guard config == ["+refs/heads/*:refs/remotes/" + name + "/*"] else {
      throw AutomaticFetchError.skipped("Custom fetch refspec requires manual Fetch.")
    }
    let mirror = try await read(["config", "--bool", "--get", "remote." + name + ".mirror"], allowFailure: true).text
    guard mirror.trimmingCharacters(in: .newlines) != "true" else {
      throw AutomaticFetchError.skipped("Mirror remotes require manual Fetch.")
    }
    let urls = try await read(["remote", "get-url", "--all", "--", name]).text.split(separator: "\n").map(String.init)
    guard urls.count == 1 else { throw AutomaticFetchError.skipped("Multiple fetch URLs require manual Fetch.") }
    let url = urls[0]
    try InputValidation.remoteURL(url)
    guard url.hasPrefix("https://") || url.hasPrefix("ssh://") || url.hasPrefix("file://") || url.hasPrefix("/")
      || (!url.contains("://") && url.contains(":") && !url.contains("::")) else {
      throw AutomaticFetchError.skipped("This transport requires manual Fetch.")
    }
    let ssh = authEnvironment["GIT_SSH_COMMAND"]
    let custom = try await read(["config", "--get", "core.sshCommand"], allowFailure: true).text
    guard ssh != nil || custom.isEmpty && ProcessInfo.processInfo.environment["GIT_SSH_COMMAND"] == nil
      && ProcessInfo.processInfo.environment["GIT_SSH"] == nil else {
      throw AutomaticFetchError.skipped("Custom SSH commands require manual Fetch.")
    }
    // Command-scoped overrides preserve TLS and host verification. App helpers read Keychain
    // with interaction forbidden. Unknown credential helpers are never invoked in the background.
    return ["GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false", "SSH_ASKPASS": "/usr/bin/false",
      "SSH_ASKPASS_REQUIRE": "never", "GITPIER_BACKGROUND": "1", "GCM_INTERACTIVE": "never",
      "GIT_SSH_COMMAND": (ssh ?? "/usr/bin/ssh") + " -oBatchMode=yes -oStrictHostKeyChecking=yes -oNumberOfPasswordPrompts=0",
      "GIT_SSH_VARIANT": "ssh", "GIT_CONFIG_COUNT": "4",
      "GIT_CONFIG_KEY_0": "credential.interactive", "GIT_CONFIG_VALUE_0": "false",
      "GIT_CONFIG_KEY_1": "credential.helper", "GIT_CONFIG_VALUE_1": "",
      "GIT_CONFIG_KEY_2": "credential.helper", "GIT_CONFIG_VALUE_2": try await automaticCredentialHelper(url),
      "GIT_CONFIG_KEY_3": "maintenance.auto", "GIT_CONFIG_VALUE_3": "false"]
  }
  private func automaticCredentialHelper(_ url: String) async throws -> String {
    // Explicit GitPier HTTPS profiles already install an app helper via command-line -c.
    if authEnvironment["GITPIER_CREDENTIAL_ID"] != nil { return "" }
    let configured = try await read(["config", "--get-urlmatch", "credential.helper", url], allowFailure: true).text.trimmingCharacters(in: .newlines)
    if configured == "store" || configured == "cache" { return configured }
    if configured == "osxkeychain", let executable = authEnvironment["GITPIER_HELPER_EXECUTABLE"] {
      return "!" + InputValidation.shellQuote(executable) + " --background-keychain-helper"
    }
    return ""
  }
  public func workspaceSearch(record: RepositoryRecord, query: String, kinds: Set<WorkspaceSearchKind>,
                              page: Int = 0, size: Int = 25) async throws -> WorkspaceRepositorySearchPage {
    guard !query.isEmpty, !query.utf8.contains(0), query.utf8.count <= 512, page >= 0, page <= 10000 else {
      throw GitPierError.invalidInput("Invalid workspace search query.")
    }
    let count = max(1, min(size, 50)), offset = page * count
    let environment = ["GIT_NO_LAZY_FETCH": "1"]
    return try await lifecycleWrite {
      try await validateWorkspaceRoot()
      try await requireLocalWorkspaceQueries()
      var hits: [WorkspaceSearchHit] = []; var more = false
      if kinds.contains(.file) {
        // Generated, controlled pathspec magic: all user glob metacharacters are literals.
        var escaped = ""
        for character in query {
          if "\\*?[]".contains(character) { escaped.append("\\") }
          escaped.append(character)
        }
        let data = try await read(["ls-files", "--cached", "--full-name", "-z", "--", ":(icase)*" + escaped + "*"],
          environment: environment, limit: 4 * 1024 * 1024, timeout: 20).stdout
        var paths: [String] = []; var seen: Set<String> = []
        for bytes in data.split(separator: 0) {
          guard let path = String(data: bytes, encoding: .utf8) else { throw GitPierError.invalidInput("Non-UTF-8 paths cannot be searched safely.") }
          try InputValidation.repositoryPath(path)
          if seen.insert(path).inserted { paths.append(path) }
        }
        more = paths.count > offset + count
        hits += paths.dropFirst(offset).prefix(count).map { WorkspaceSearchHit(repositoryID: record.id, kind: .file, value: $0, detail: record.name) }
      }
      if kinds.contains(.commit) {
        let format = "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%x00%D%x00"
        let result = try await read(["log", "--all", "--date-order", "--fixed-strings", "--regexp-ignore-case", "--grep=" + query,
          "--skip=\(offset)", "-n", "\(count + 1)", format, "-z", "--"], environment: environment,
          allowFailure: true, limit: 2 * 1024 * 1024, timeout: 20)
        guard result.code == 0 else { throw GitPierError.command("log", result.code, Self.redact(result.errorText)) }
        var commits = Self.parseHistory(result.stdout)
        more = more || commits.count > count
        commits = Array(commits.prefix(count))
        // A hash query also resolves one exact local object; never interpret user text as an option/ref expression.
        if page == 0, (4...64).contains(query.count), query.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) {
          let resolved = try await read(["rev-parse", "--verify", "--end-of-options", query + "^{commit}"], environment: environment, allowFailure: true)
          if resolved.code == 0 {
            let hash = resolved.text.trimmingCharacters(in: .newlines)
            if !commits.contains(where: { $0.hash == hash }) {
              let data = try await read(["show", "--no-patch", format, hash, "--"], environment: environment, limit: 2 * 1024 * 1024).stdout
              if let commit = Self.parseHistory(data).first { commits.insert(commit, at: 0) }
            }
          }
        }
        hits += commits.map { WorkspaceSearchHit(repositoryID: record.id, kind: .commit, value: $0.hash, detail: $0.subject, commit: $0) }
      }
      return WorkspaceRepositorySearchPage(hits: hits, hasMore: more)
    }
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
    return try await lifecycleWrite {
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
  public func interactiveRebaseCandidate(upstream reference: String) async throws -> InteractiveRebaseCandidate {
    let review = try await reviewOperation()
    let state = try await status()
    guard state.operation == nil, state.files.isEmpty, state.head != nil,
      state.branch != "(detached)", !state.branch.isEmpty else {
      throw GitPierError.invalidInput("Interactive rebase requires a clean working tree and Index, a local branch, and no unfinished Git operation.")
    }
    let flagged = try await read(["ls-files", "-v", "-z"]).stdout.split(separator: 0)
    guard !flagged.contains(where: { $0.first == 83 || ($0.first.map { (97...122).contains($0) } ?? false) }) else {
      throw GitPierError.invalidInput("Interactive rebase does not support skip-worktree or assume-unchanged entries. Inspect hidden working changes in the terminal first.")
    }
    let upstream = try await resolveCommit(reference)
    guard try await read(["merge-base", "--is-ancestor", upstream, "HEAD"], allowFailure: true).code == 0 else {
      throw GitPierError.invalidInput("Choose an ancestor of the current branch as the rebase starting point.")
    }
    let data = try await read(["log", "--reverse", "--topo-order", "-201",
      "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%b%x00%D%x00", "-z", upstream + "..HEAD"]).stdout
    let commits = Self.parseHistory(data)
    guard !commits.isEmpty, commits.count <= 200 else {
      throw GitPierError.invalidInput("Select between 1 and 200 commits for interactive rebase.")
    }
    var parent = upstream
    var shared = Set<String>()
    for commit in commits {
      guard commit.parents == [parent] else {
        throw GitPierError.invalidInput("This range contains merge or nonlinear history. Interactive rebase currently supports linear history only.")
      }
      parent = commit.hash
      if !(try await read(["for-each-ref", "--format=%(refname)", "--contains=" + commit.hash, "refs/remotes"]).stdout).isEmpty {
        shared.insert(commit.hash)
      }
    }
    guard try await reviewOperation() == review, try await status().files.isEmpty else { throw GitPierError.indexChanged }
    return InteractiveRebaseCandidate(review: review, upstream: upstream, commits: commits, sharedCommits: shared)
  }
  private func rebaseText(_ directory: URL, _ name: String) throws -> String {
    let url = directory.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else { return "" }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      (attributes[.size] as? Int ?? Int.max) <= 1024 * 1024 else {
      throw GitPierError.invalidInput("The rebase metadata is too large or uses an unsupported file type.")
    }
    guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
      throw GitPierError.invalidInput("The rebase metadata must be UTF-8.")
    }
    return text
  }
  private func rebaseWorkingFingerprint() async throws -> Data {
    var data = try await read(["status", "--porcelain=v2", "-z", "--untracked-files=all"]).stdout
    for file in try await status().files {
      for path in file.paths {
        let state = try conflictWorkingFile(path).0
        data.append(Data((path + "\0" + String(describing: state) + "\0").utf8))
      }
    }
    return Data(SHA256.hash(data: data))
  }
  public func rebaseState() async throws -> RebaseState? {
    guard try await status().operation == .rebase else { return nil }
    let review = try await reviewOperation()
    let metadata = try await metadataDirectories()[0]
    let merge = metadata.appendingPathComponent("rebase-merge")
    let interactive = FileManager.default.fileExists(atPath: merge.path)
    let directory = interactive ? merge : metadata.appendingPathComponent("rebase-apply")
    let fingerprint = try await rebaseWorkingFingerprint()
    let state = RebaseState(review: review, workingFingerprint: fingerprint,
      branch: try rebaseText(directory, "head-name").trimmingCharacters(in: .newlines),
      originalHead: try rebaseText(directory, "orig-head").trimmingCharacters(in: .newlines),
      upstream: try rebaseText(directory, "onto").trimmingCharacters(in: .newlines),
      done: try rebaseText(directory, "done"), todo: try rebaseText(directory, "git-rebase-todo"),
      message: try rebaseText(directory, "message"),
      current: Int(try rebaseText(directory, interactive ? "msgnum" : "next").trimmingCharacters(in: .newlines)) ?? 0,
      total: Int(try rebaseText(directory, interactive ? "end" : "last").trimmingCharacters(in: .newlines)) ?? 0,
      interactive: interactive)
    guard try await reviewOperation() == review,
      try await rebaseWorkingFingerprint() == fingerprint else { throw GitPierError.indexChanged }
    return state
  }
  private func savedRebaseMessages(_ metadata: URL) throws -> (URL, Data?, RebaseMessagePlan?) {
    let file = metadata.appendingPathComponent("gitpier-rebase-messages.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return (file, nil, nil) }
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      (attributes[.size] as? Int ?? Int.max) <= 16 * 1024 * 1024 else {
      throw GitPierError.invalidInput("Preserve and inspect the saved rebase message plan before continuing.")
    }
    let data = try Data(contentsOf: file)
    let plan = try JSONDecoder().decode(RebaseMessagePlan.self, from: data)
    try plan.validate()
    return (file, data, plan)
  }
  @discardableResult public func startInteractiveRebase(_ plan: InteractiveRebasePlan) async throws -> String {
    try plan.validate()
    return try await writing {
      guard try await reviewOperation() == plan.candidate.review, try await status().files.isEmpty,
        try await status().operation == nil else { throw GitPierError.indexChanged }
      // Recompute linearity and sharing against the fixed ancestor, never a moving reference.
      let current = try await interactiveRebaseCandidate(upstream: plan.candidate.upstream)
      guard current.commits.map(\.hash) == plan.candidate.commits.map(\.hash),
        current.sharedCommits == plan.candidate.sharedCommits else { throw GitPierError.indexChanged }
      let metadata = try await metadataDirectories()[0]
      let (saved, _, _) = try savedRebaseMessages(metadata)
      let messages = try RebaseMessagePlan(plan)
      let bytes = try JSONEncoder().encode(messages)
      let editors = try RebaseEditorFiles(todo: plan.todo(), messages: messages.messages,
                                        state: metadata.appendingPathComponent("rebase-merge"))
      defer { editors.remove() }
      // Persist data before launching Git so cancellation/crash/restart never loses reviewed messages.
      try bytes.write(to: saved, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: saved.path)
      let result = try await read(["rebase", "--interactive", "--force-rebase", "--no-autostash",
        "--no-autosquash", "--no-rebase-merges", "--no-update-refs", "--no-fork-point",
        "--reapply-cherry-picks", "--keep-empty", "--empty=ask", plan.candidate.upstream], environment: editors.environment)
      if try await status().operation == nil, (try? Data(contentsOf: saved)) == bytes { try FileManager.default.removeItem(at: saved) }
      return Self.redact(result.text + result.errorText)
    }
  }
  @discardableResult public func controlRebase(_ action: RebaseControl, expected: RebaseState,
                                               message: String? = nil) async throws -> String {
    if let message {
      guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !message.utf8.contains(0), message.utf8.count <= 64 * 1024 else {
        throw GitPierError.invalidInput("Enter a nonempty commit message within 64 KiB.")
      }
    }
    return try await writing {
      guard let actual = try await rebaseState(), actual.review == expected.review,
        actual.workingFingerprint == expected.workingFingerprint else { throw GitPierError.indexChanged }
      if action == .continue, try await status().files.contains(where: \.isConflicted) {
        throw GitPierError.invalidInput("Resolve and stage every conflict before continuing rebase.")
      }
      let metadata = try await metadataDirectories()[0]
      // A corrupt optional message plan must never prevent Git's native Abort recovery.
      let savedPlan: (URL, Data?, RebaseMessagePlan?)
      if action == .abort {
        savedPlan = (try? savedRebaseMessages(metadata))
          ?? (metadata.appendingPathComponent("gitpier-rebase-messages.json"), nil, nil)
      } else { savedPlan = try savedRebaseMessages(metadata) }
      let (saved, bytes, plan) = savedPlan
      let owned = plan?.head == actual.originalHead && plan?.upstream == actual.upstream && plan?.branch == actual.branch
      let editors = try RebaseEditorFiles(messages: owned ? plan?.messages ?? [:] : [:],
                                        state: metadata.appendingPathComponent(actual.interactive ? "rebase-merge" : "rebase-apply"),
                                        overrideMessage: action == .continue ? message : nil)
      defer { editors.remove() }
      let result = try await read(["rebase", "--" + action.rawValue], environment: editors.environment)
      if try await status().operation == nil, owned, (try? Data(contentsOf: saved)) == bytes {
        try FileManager.default.removeItem(at: saved)
      }
      return Self.redact(result.text + result.errorText)
    }
  }
  @discardableResult public func perform(_ arguments: [String], expected: GitOperationReview? = nil) async throws -> String {
    try await writing {
      if let expected, try await reviewOperation() != expected { throw GitPierError.indexChanged }
      if ["reset", "switch", "checkout", "merge", "rebase", "cherry-pick", "revert"].contains(arguments.first ?? "") {
        let nativeControl = arguments.count == 2 && arguments[0] == "rebase"
          && ["--continue", "--skip", "--abort"].contains(arguments[1])
        if try await status().operation == .rebase, !nativeControl {
          throw GitPierError.invalidInput("Review the unfinished rebase and use Continue, Skip or Abort before starting another history operation.")
        }
      }
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
      let reference = remote && !name.hasPrefix("refs/remotes/") ? "refs/remotes/" + name : name
      try await read(["switch"] + (remote ? ["--track"] : []) + [reference])
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

// MARK: - Professional workflows
extension GitService {
  public func resolveCommit(_ reference: String) async throws -> String {
    try InputValidation.reference(reference)
    let result = try await read(["rev-parse", "--verify", "--end-of-options", reference + "^{commit}"], allowFailure: true)
    guard result.code == 0 else {
      throw GitPierError.invalidInput("This commit is unavailable. It may have expired or been removed by Git garbage collection. Reflog cannot recover missing objects.")
    }
    return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  public func commitDetail(_ reference: String) async throws -> CommitRecord {
    let hash = try await resolveCommit(reference)
    let data = try await read(["show", "--no-patch", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%b%x00%D%x00", hash]).stdout
    guard let record = Self.parseHistory(data).first else { throw GitPierError.invalidInput("Unable to read commit details.") }
    return record
  }
  public func reflog(reference: String = "HEAD", skip: Int = 0, count: Int = 100, search: String = "", operation: String = "") async throws -> [ReflogEntry] {
    guard reference == "HEAD" || reference.hasPrefix("refs/heads/") else { throw GitPierError.invalidInput("Select HEAD or a local branch reflog.") }
    try InputValidation.reference(reference)
    guard !search.utf8.contains(0), !operation.utf8.contains(0) else { throw GitPierError.invalidInput("Invalid reflog filter.") }
    var args = ["log", "-g", "--date=raw", "--skip=\(max(0, skip))", "-n", "\(max(1, min(count, 500)))", "--format=%H%x00%gD%x00%gs%x00", "-z"]
    // Git does the filtering before pagination. Text searches target operation descriptions.
    if !search.isEmpty { args += ["--fixed-strings", "--regexp-ignore-case", "--grep-reflog=" + search] }
    if !operation.isEmpty {
      guard operation.allSatisfy({ $0.isLetter || $0 == "-" || $0 == " " || $0 == "(" || $0 == ")" }) else { throw GitPierError.invalidInput("Invalid reflog operation.") }
      // A single native filter combines type and message; escape the message as a literal regex.
      args.removeAll { $0 == "--fixed-strings" || $0.hasPrefix("--grep-reflog=") }
      args += ["--extended-regexp", "--regexp-ignore-case", "--grep-reflog=^" + NSRegularExpression.escapedPattern(for: operation) + "( \\([^)]*\\))?:.*" + NSRegularExpression.escapedPattern(for: search)]
    }
    let result = try await read(args + [reference], allowFailure: true, limit: 4 * 1024 * 1024)
    if result.code != 0 {
      if try await status().head == nil { return [] }
      throw GitPierError.command("reflog", result.code, result.errorText)
    }
    return ProfessionalWorkflowParser.reflog(result.stdout, offset: max(0, skip))
  }
  public func recoverReflogCommit(_ hash: String, branch: String) async throws {
    // Freeze a full object ID, rather than a moving HEAD@{n} selector.
    guard [40, 64].contains(hash.count), hash.allSatisfy(\.isHexDigit) else { throw GitPierError.invalidInput("Select a valid reflog commit.") }
    try InputValidation.reference(branch)
    try await writing {
      let commit = try await resolveCommit(hash)
      try await read(["check-ref-format", "--branch", branch])
      try await read(["branch", "--", branch, commit])
    }
  }
  public func commonDirectory() async throws -> URL {
    let path = try Self.nativePath(try await read(["rev-parse", "--git-common-dir"]).stdout)
    return (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL.resolvingSymlinksInPath()
  }
  private func lifecycleWrite<T: Sendable>(onlyIfIdle: Bool = false, _ action: () async throws -> T) async throws -> T {
    try await writing {
      let key = try await commonDirectory().path
      if onlyIfIdle {
        guard await CommonDirectoryQueue.shared.tryAcquire(key) else { throw AutomaticFetchError.skipped("Related repository busy. Check deferred.") }
      } else { try await CommonDirectoryQueue.shared.acquire(key) }
      do {
        try Task.checkCancellation()
        let result = try await action()
        await CommonDirectoryQueue.shared.release(key)
        return result
      } catch {
        await CommonDirectoryQueue.shared.release(key)
        throw error
      }
    }
  }
  public func worktrees(includeStatus: Bool = true) async throws -> [GitWorktree] {
    let data = try await read(["worktree", "list", "--porcelain", "-z"]).stdout
    guard String(data: data, encoding: .utf8) != nil else { throw GitPierError.invalidInput("Worktree paths must be valid UTF-8.") }
    let records = ProfessionalWorkflowParser.worktrees(data)
    guard includeStatus else { return records }
    var result: [GitWorktree] = []
    for record in records {
      try Task.checkCancellation()
      var changes: Int?
      if !record.missing && !record.bare {
        let state = try await read(["-C", record.path, "status", "--porcelain=v2", "-z", "--untracked-files=all"], allowFailure: true, limit: 4 * 1024 * 1024)
        if state.code == 0 { changes = try StatusParser.parse(state.stdout).files.count }
      }
      result.append(GitWorktree(path: record.path, head: record.head, branch: record.branch, main: record.main, bare: record.bare,
        locked: record.locked, lockReason: record.lockReason, prunable: record.prunable, pruneReason: record.pruneReason,
        missing: record.missing, changeCount: changes))
    }
    return result
  }
  private func linkedOwnership(path: String) async throws -> WorktreeOwnership {
    let common = try await commonDirectory()
    let directories = try Self.nativePath(try await read(["-C", path, "rev-parse", "--absolute-git-dir"]).stdout)
    let directory = URL(fileURLWithPath: directories).standardizedFileURL.resolvingSymlinksInPath()
    let family = try Self.nativePath(try await read(["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"]).stdout)
    guard directory.deletingLastPathComponent().path == common.appendingPathComponent("worktrees").path,
      URL(fileURLWithPath: family).standardizedFileURL.resolvingSymlinksInPath().path == common.path else {
      throw GitPierError.invalidInput("The directory does not belong to this repository's linked worktrees.")
    }
    let marker = directory.appendingPathComponent("gitpier-creation-id")
    let attributes = try? FileManager.default.attributesOfItem(atPath: marker.path)
    var creationID: String?
    if attributes?[.type] as? FileAttributeType == .typeRegular,
      (attributes?[.size] as? NSNumber)?.intValue ?? Int.max <= 128,
      let data = try? Data(contentsOf: marker), let value = String(data: data, encoding: .utf8), UUID(uuidString: value) != nil {
      creationID = value
    }
    return WorktreeOwnership(path: ProfessionalWorkflowParser.canonicalPath(path), commonDirectory: common.path, gitDirectory: directory.path, creationID: creationID)
  }
  public func createWorktree(destination: URL, branch: String, newBranch: Bool = false, startAt: String = "HEAD") async throws -> WorktreeOwnership {
    try InputValidation.reference(branch)
    return try await lifecycleWrite {
      let target = destination.standardizedFileURL
      guard target.path.hasPrefix("/"), !target.path.utf8.contains(0), target.resolvingSymlinksInPath() == target,
        (try? FileManager.default.attributesOfItem(atPath: target.path)) == nil else {
        throw GitPierError.invalidInput("Choose a new directory. Existing folders and symbolic links are never overwritten.")
      }
      let canonicalTarget = ProfessionalWorkflowParser.canonicalPath(target.path)
      let records = try await worktrees(includeStatus: false)
      guard !records.contains(where: { canonicalTarget == $0.path || canonicalTarget.hasPrefix($0.path + "/") }) else {
        throw GitPierError.invalidInput("Choose a directory outside the existing working trees.")
      }
      try await read(["check-ref-format", "--branch", branch])
      let base: String
      if newBranch { base = try await resolveCommit(startAt) }
      else {
        guard try await read(["show-ref", "--verify", "refs/heads/" + branch], allowFailure: true).code == 0 else { throw GitPierError.invalidInput("Select an existing local branch.") }
        // worktree add requires the short branch name to attach HEAD; a full ref detaches.
        // Existence is verified above, and Git enforces checked-out-branch protection.
        base = branch
      }
      try await read(["worktree", "add"] + (newBranch ? ["-b", branch] : []) + ["--", canonicalTarget, base])
      let identity = try await linkedOwnership(path: canonicalTarget)
      let creationID = UUID().uuidString
      let marker = URL(fileURLWithPath: identity.gitDirectory).appendingPathComponent("gitpier-creation-id")
      try Data(creationID.utf8).write(to: marker, options: .withoutOverwriting)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
      return WorktreeOwnership(path: identity.path, commonDirectory: identity.commonDirectory, gitDirectory: identity.gitDirectory, creationID: creationID)
    }
  }
  private func currentWorktree(_ expected: GitWorktree) async throws -> GitWorktree {
    guard let current = try await worktrees(includeStatus: false).first(where: { $0.path == expected.path }), current == GitWorktree(
      path: expected.path, head: expected.head, branch: expected.branch, main: expected.main, bare: expected.bare,
      locked: expected.locked, lockReason: expected.lockReason, prunable: expected.prunable, pruneReason: expected.pruneReason,
      missing: expected.missing, changeCount: nil) else {
      throw GitPierError.invalidInput("The worktree changed. Refresh and review it again.")
    }
    guard !current.main, !current.bare else { throw GitPierError.invalidInput("The main repository cannot be removed, locked or unlocked.") }
    return current
  }
  public func setWorktreeLock(_ worktree: GitWorktree, locked: Bool, reason: String = "") async throws {
    guard !reason.utf8.contains(0) else { throw GitPierError.invalidInput("Invalid lock reason.") }
    try await lifecycleWrite {
      let current = try await currentWorktree(worktree)
      guard current.locked != locked else { return }
      try await read(["worktree", locked ? "lock" : "unlock"] + (locked && !reason.isEmpty ? ["--reason", reason] : []) + ["--", current.path])
    }
  }
  public func reviewWorktreeRemoval(_ worktree: GitWorktree, ownership: WorktreeOwnership) async throws -> WorktreeRemovalReview {
    let current = try await currentWorktree(worktree)
    guard !current.missing, !current.prunable, !current.locked, ownership.creationID != nil,
      current.path == ownership.path, try await linkedOwnership(path: current.path) == ownership,
      URL(fileURLWithPath: current.path).resolvingSymlinksInPath().path == current.path else {
      throw GitPierError.invalidInput("Removal requires an available, unlocked worktree created by GitPier with unchanged Git metadata.")
    }
    if current.branch.isEmpty {
      let retaining = try await read(["for-each-ref", "--contains=" + current.head, "--format=%(refname)", "refs/heads", "refs/remotes", "refs/tags"])
      guard !retaining.stdout.isEmpty else {
        throw GitPierError.invalidInput("The detached worktree commit has no retaining branch or tag. Create a recovery branch before removal.")
      }
    }
    // Include ignored files: clean tracked files alone do not prove a directory is safe to delete.
    let state = try await read(["-C", current.path, "status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignored"])
    guard state.stdout.isEmpty else { throw GitPierError.invalidInput("The worktree contains modified, untracked or ignored files. Preserve them before removal; force deletion is not available.") }
    let linked = GitService(root: URL(fileURLWithPath: current.path), gitPath: gitPath, runner: runner)
    guard try await linked.status().operation == nil else { throw GitPierError.invalidInput("Finish the worktree's Git operation before removal.") }
    return WorktreeRemovalReview(worktree: current, ownership: ownership)
  }
  public func removeWorktree(_ review: WorktreeRemovalReview) async throws {
    try await lifecycleWrite {
      _ = try await reviewWorktreeRemoval(review.worktree, ownership: review.ownership)
      try await read(["worktree", "remove", "--", review.worktree.path])
    }
  }
  public func reviewWorktreeRepair(at destination: URL) async throws -> WorktreeRepairReview {
    let target = destination.standardizedFileURL
    guard target.resolvingSymlinksInPath() == target else { throw GitPierError.unsafePath(target.path) }
    let ownership = try await linkedOwnership(path: target.path)
    let registered = try String(contentsOf: URL(fileURLWithPath: ownership.gitDirectory).appendingPathComponent("gitdir"), encoding: .utf8).trimmingCharacters(in: .newlines)
    let old = ProfessionalWorkflowParser.canonicalPath(URL(fileURLWithPath: registered).deletingLastPathComponent().path)
    guard let record = try await worktrees(includeStatus: false).first(where: { $0.path == old }), !record.main,
      (old == target.path || record.missing) else { throw GitPierError.invalidInput("The original worktree is still present or its registration is unknown. Repair was refused.") }
    return WorktreeRepairReview(ownership: ownership, previous: record)
  }
  public func repairWorktree(at destination: URL) async throws -> WorktreeOwnership {
    try await repairWorktree(reviewWorktreeRepair(at: destination))
  }
  /// Repairs only a moved linked tree whose .git pointer and reviewed registration remain valid.
  public func repairWorktree(_ review: WorktreeRepairReview) async throws -> WorktreeOwnership {
    try await lifecycleWrite {
      guard try await reviewWorktreeRepair(at: URL(fileURLWithPath: review.ownership.path)) == review else {
        throw GitPierError.invalidInput("The worktree changed. Refresh and review it again.")
      }
      try await read(["worktree", "repair", "--", review.ownership.path])
      return review.ownership
    }
  }
  public func compareBranches(left: String, right: String, mode: BranchComparisonMode = .tips, count: Int = 100) async throws -> BranchComparisonResult {
    // Require actual full branch refs, preventing short-name tag ambiguity and revision injection.
    for ref in [left, right] {
      guard ref.hasPrefix("refs/heads/") || ref.hasPrefix("refs/remotes/") else { throw GitPierError.invalidInput("Select a local or remote-tracking branch.") }
      try await read(["check-ref-format", ref])
    }
    let a = try await resolveCommit(left), b = try await resolveCommit(right)
    let baseResult = try await read(["merge-base", "--all", a, b], allowFailure: true)
    guard baseResult.code == 0 || baseResult.code == 1 else { throw GitPierError.command("merge-base", baseResult.code, baseResult.errorText) }
    let bases = baseResult.text.split(separator: "\n").map(String.init)
    if mode == .mergeBase, bases.count != 1 { throw GitPierError.invalidInput("Three-point comparison requires one merge base. These branches have no common ancestor or have multiple merge bases. Use direct tip comparison.") }
    let counts = try await read(["rev-list", "--left-right", "--count", a + "..." + b]).text.split(whereSeparator: \.isWhitespace)
    let old = mode == .tips ? a : bases[0]
    return BranchComparisonResult(left: left, right: right, leftHash: a, rightHash: b, mergeBases: bases,
      leftOnlyCount: counts.first.flatMap { Int($0) } ?? 0, rightOnlyCount: counts.last.flatMap { Int($0) } ?? 0,
      leftOnly: try await comparisonCommits(base: b, tip: a, count: count), rightOnly: try await comparisonCommits(base: a, tip: b, count: count),
      diffBase: old, mode: mode, files: try await commitFiles(b, parent: old))
  }
  public func comparisonCommits(base: String, tip: String, skip: Int = 0, count: Int = 100) async throws -> [CommitRecord] {
    let a = try await resolveCommit(base), b = try await resolveCommit(tip)
    return Self.parseHistory(try await read(["log", "--skip=\(max(0, skip))", "-n", "\(max(1, min(count, 500)))", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%b%x00%D%x00", "-z", a + ".." + b]).stdout)
  }
  public func blame(path: String, revision: String? = nil, start: Int = 1, count: Int = 400) async throws -> BlamePage {
    try Task.checkCancellation()
    try InputValidation.repositoryPath(path)
    let hash: String?
    if let revision { hash = try await resolveCommit(revision) } else { hash = nil }
    let bytes: Data
    if let hash {
      let size = try await read(["cat-file", "-s", hash + ":" + path]).text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let length = Int(size), length <= 4 * 1024 * 1024 else { throw GitPierError.outputLimit }
      bytes = try await read(["show", hash + ":" + path], limit: 4 * 1024 * 1024).stdout
    } else {
      let url = root.appendingPathComponent(path).standardizedFileURL
      guard url.resolvingSymlinksInPath() == url, url.path.hasPrefix(root.path + "/") else { throw GitPierError.unsafePath(path) }
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 4 * 1024 * 1024 else { throw GitPierError.outputLimit }
      bytes = try Data(contentsOf: url)
      guard bytes.count <= 4 * 1024 * 1024 else { throw GitPierError.outputLimit }
    }
    guard !bytes.contains(0), String(data: bytes, encoding: .utf8) != nil else { throw GitPierError.invalidInput("Blame requires a UTF-8 text file; binary files are not supported.") }
    try Task.checkCancellation()
    let total = bytes.reduce(into: 0) { if $1 == 10 { $0 += 1 } } + (!bytes.isEmpty && bytes.last != 10 ? 1 : 0)
    let first = max(1, start), last = min(total, first + max(1, min(count, 1000)) - 1)
    guard first <= last else { return BlamePage(lines: [], totalLines: total, revision: hash) }
    let result = try await read(["--literal-pathspecs", "blame", "--line-porcelain", "--no-textconv", "-M", "-L", "\(first),\(last)"] + (hash.map { [$0] } ?? []) + ["--", path], allowFailure: true, limit: 4 * 1024 * 1024)
    if result.code != 0 {
      // A newly added/untracked file has no committed attribution. Do not invent a commit.
      let exists = try await read(["cat-file", "-e", "HEAD:" + path], allowFailure: true)
      if hash == nil, exists.code != 0 {
        let lines = String(decoding: bytes, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        return BlamePage(lines: (first...last).map { BlameLine(line: $0, originalLine: $0, hash: String(repeating: "0", count: 40), author: "Not Committed Yet", date: Date(), originalPath: path, text: String(lines[$0 - 1])) }, totalLines: total, revision: nil)
      }
      throw GitPierError.command("blame", result.code, result.errorText)
    }
    try Task.checkCancellation()
    return BlamePage(lines: ProfessionalWorkflowParser.blame(result.stdout), totalLines: total, revision: hash)
  }
}
