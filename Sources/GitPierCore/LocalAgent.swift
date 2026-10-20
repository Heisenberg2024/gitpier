import Darwin
import Foundation

public enum LocalAgentError: String, Error, LocalizedError, Sendable {
  case notInstalled, notExecutable, invalidVersion, changed
  public var errorDescription: String? {
    switch self {
    case .notInstalled: "Codex CLI Not Installed. Choose an installed executable or see the official installation guide."
    case .notExecutable: "The selected Codex CLI path is not an accessible executable file."
    case .invalidVersion: "This executable did not report a supported Codex CLI identity and version."
    case .changed: "The Codex CLI executable changed. Detect it again before starting a session."
    }
  }
}

public struct AgentExecutable: Equatable, Sendable {
  public let provider: LocalAgentProvider
  public let path: String
  public let version: String
  private let identity: Identity
  private struct Identity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modified: Int64
    let modifiedNS: Int64
    let changed: Int64
    let changedNS: Int64
  }
  private static func identify(_ path: String) throws -> Identity {
    var state = stat()
    guard lstat(path, &state) == 0, state.st_mode & S_IFMT == S_IFREG,
      FileManager.default.isExecutableFile(atPath: path) else { throw LocalAgentError.notExecutable }
    return Identity(device: state.st_dev, inode: state.st_ino, size: state.st_size,
      modified: Int64(state.st_mtimespec.tv_sec), modifiedNS: Int64(state.st_mtimespec.tv_nsec),
      changed: Int64(state.st_ctimespec.tv_sec), changedNS: Int64(state.st_ctimespec.tv_nsec))
  }
  public func validate() throws {
    guard try Self.identify(path) == identity else { throw LocalAgentError.changed }
  }
  /// Stat metadata only, forwarded to the internal exec helper for its final check.
  public var launchIdentityArguments: [String] {
    [UInt64(bitPattern: Int64(identity.device)), UInt64(identity.inode), UInt64(identity.size),
      UInt64(bitPattern: identity.modified), UInt64(bitPattern: identity.modifiedNS),
      UInt64(bitPattern: identity.changed), UInt64(bitPattern: identity.changedNS)].map(String.init)
  }
  public static func detect(explicitPath: String = "", searchPath: String? = ProcessInfo.processInfo.environment["PATH"]) async throws -> Self {
    let candidates: [String]
    if !explicitPath.isEmpty {
      guard explicitPath.hasPrefix("/"), !explicitPath.utf8.contains(0) else { throw LocalAgentError.notExecutable }
      candidates = [explicitPath]
    } else {
      var paths = (searchPath ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") && !$0.utf8.contains(0) }
      for fallback in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] where !paths.contains(fallback) { paths.append(fallback) }
      candidates = paths.map { URL(fileURLWithPath: $0).appendingPathComponent("codex").path }
    }
    guard let selected = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
      throw explicitPath.isEmpty ? LocalAgentError.notInstalled : LocalAgentError.notExecutable
    }
    let path = URL(fileURLWithPath: selected).standardizedFileURL.resolvingSymlinksInPath().path
    let identity = try identify(path)
    // A bounded version probe only, never login/config, credential files or package installation.
    let result = try await ProcessRunner().run(executable: path, arguments: ["--version"], directory: nil, timeout: 5, limit: 16 * 1024)
    guard result.code == 0, let version = parseVersion(result.text) else { throw LocalAgentError.invalidVersion }
    let help = try await ProcessRunner().run(executable: path, arguments: ["--help"], directory: nil, timeout: 5, limit: 128 * 1024)
    guard help.code == 0, ["--no-daemon", "--sandbox", "workspace-write", "--ask-for-approval", "on-request"].allSatisfy(help.text.contains) else {
      throw LocalAgentError.invalidVersion
    }
    let executable = Self(provider: .codex, path: path, version: version, identity: identity)
    try executable.validate()
    return executable
  }
  public static func parseVersion(_ text: String) -> String? {
    let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard version.utf8.count <= 256,
      version.range(of: #"^codex-cli [0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil else { return nil }
    return version
  }
}

/// Fixed official interactive options. Prompts and descriptions never become shell commands.
public struct AgentLaunchConfiguration: Equatable, Sendable {
  public let executable: AgentExecutable
  public let taskID: UUID
  public let directory: String
  public let head: String
  public let branch: String
  public let status: RepositoryStatus
  public let directoryIdentity: TaskDirectoryIdentity
  public let arguments = ["--no-daemon", "--sandbox", "workspace-write", "--ask-for-approval", "on-request"]
  public init(executable: AgentExecutable, task: TaskWorkspace, snapshot: TaskWorkspaceSnapshot) throws {
    guard !task.archived, task.agent?.state.active != true, snapshot.taskID == task.id,
      snapshot.status.operation == nil else { throw TaskWorkspaceError.invalid }
    try executable.validate(); try task.binding.validateDirectories()
    self.executable = executable; taskID = task.id; directory = task.path; head = snapshot.head; branch = task.branch; status = snapshot.status
    directoryIdentity = task.binding.directoryIdentity
  }
}
