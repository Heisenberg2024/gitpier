import Darwin
import Foundation

public enum LocalAgentError: String, Error, LocalizedError, Sendable {
  case notInstalled, notExecutable, invalidVersion, changed, invalidHome
  public var errorDescription: String? {
    switch self {
    case .notInstalled: "Codex CLI Not Installed. Choose an installed executable or see the official installation guide."
    case .notExecutable: "The selected Codex CLI path is not an accessible executable file."
    case .invalidVersion: "This executable did not report a supported Codex CLI identity and version."
    case .changed: "The Codex CLI executable changed. Detect it again before starting a session."
    case .invalidHome: "Choose an existing absolute Codex Home directory without symbolic links or parent traversal. Leave it empty to inherit CODEX_HOME or use the CLI default."
    }
  }
}

public enum AgentLoginStatus: Equatable, Sendable {
  public enum Failure: Equatable, Sendable { case timedOut, executionFailed, outputLimit }
  case notChecked, loggedIn, loginRequired, unconfirmed(Failure)
}

/// An in-memory snapshot shared by every Codex probe and its confirmed PTY launch.
/// Never encoded, logged, or populated from credential/configuration files.
public struct AgentEnvironment: Equatable, Sendable {
  public let values: [String: String]
  public let customHome: Bool
  public let inheritedCodexHome: Bool
  public let inheritedHome: Bool
  public init(inheriting inherited: [String: String] = ProcessInfo.processInfo.environment, codexHome: String = "") throws {
    var env = inherited
    for key in Array(env.keys) where key.hasPrefix("GITPIER_") || key.hasPrefix("GIT_CONFIG_")
      || ["GIT_INDEX_FILE", "GIT_DIR", "GIT_WORK_TREE", "GIT_ASKPASS", "SSH_ASKPASS"].contains(key) { env[key] = nil }
    inheritedHome = env["HOME"]?.isEmpty == false
    if !inheritedHome { env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path }
    var paths = (env["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") && !$0.utf8.contains(0) }
    for path in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] where !paths.contains(path) { paths.append(path) }
    env["PATH"] = paths.joined(separator: ":")
    inheritedCodexHome = env["CODEX_HOME"] != nil
    customHome = !codexHome.isEmpty
    if customHome {
      guard codexHome.hasPrefix("/"), !codexHome.utf8.contains(0), !codexHome.split(separator: "/").contains(".."),
        URL(fileURLWithPath: codexHome).standardizedFileURL.path == codexHome,
        (try? TaskDirectoryIdentity.read(codexHome)) != nil else { throw LocalAgentError.invalidHome }
      env["CODEX_HOME"] = codexHome
    }
    env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"; env["TERM_PROGRAM"] = "GitPier"
    values = env
  }
  func run(executable: String, arguments: [String], timeout: TimeInterval, limit: Int) async throws -> CommandResult {
    try await ProcessRunner().run(executable: executable, arguments: arguments, directory: nil,
      environment: values, timeout: timeout, limit: limit, excludingEnvironmentKeys: Array(ProcessInfo.processInfo.environment.keys))
  }
}

public struct AgentExecutable: Equatable, Sendable {
  public let provider: LocalAgentProvider
  public let path: String
  public let version: String
  public let environment: AgentEnvironment
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
  public static func detect(explicitPath: String = "", searchPath: String? = nil, environment: AgentEnvironment? = nil) async throws -> Self {
    let environment = try environment ?? AgentEnvironment()
    let candidates: [String]
    if !explicitPath.isEmpty {
      guard explicitPath.hasPrefix("/"), !explicitPath.utf8.contains(0) else { throw LocalAgentError.notExecutable }
      candidates = [explicitPath]
    } else {
      var paths = (searchPath ?? environment.values["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") && !$0.utf8.contains(0) }
      for fallback in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] where !paths.contains(fallback) { paths.append(fallback) }
      candidates = paths.map { URL(fileURLWithPath: $0).appendingPathComponent("codex").path }
    }
    guard let selected = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
      throw explicitPath.isEmpty ? LocalAgentError.notInstalled : LocalAgentError.notExecutable
    }
    let path = URL(fileURLWithPath: selected).standardizedFileURL.resolvingSymlinksInPath().path
    let identity = try identify(path)
    // A bounded version probe only, never login/config, credential files or package installation.
    let result = try await environment.run(executable: path, arguments: ["--version"], timeout: 5, limit: 16 * 1024)
    guard result.code == 0, let version = parseVersion(result.text) else { throw LocalAgentError.invalidVersion }
    let help = try await environment.run(executable: path, arguments: ["--help"], timeout: 5, limit: 128 * 1024)
    guard help.code == 0, ["--no-daemon", "--sandbox", "workspace-write", "--ask-for-approval", "on-request"].allSatisfy(help.text.contains) else {
      throw LocalAgentError.invalidVersion
    }
    let combined = try await environment.run(executable: path, arguments: AgentLaunchConfiguration.safeArguments + ["--help"], timeout: 5, limit: 128 * 1024)
    guard combined.code == 0 else { throw LocalAgentError.invalidVersion }
    let executable = Self(provider: .codex, path: path, version: version, environment: environment, identity: identity)
    try executable.validate()
    return executable
  }
  /// User-triggered only. Discard all output; never include it in errors or persisted state.
  public func checkLogin(timeout: TimeInterval = 8) async throws -> AgentLoginStatus {
    try validate()
    let result: CommandResult
    do { result = try await environment.run(executable: path, arguments: ["login", "status"], timeout: timeout, limit: 16 * 1024) }
    catch is CancellationError { throw CancellationError() }
    catch GitPierError.timeout { return .unconfirmed(.timedOut) }
    catch GitPierError.outputLimit { return .unconfirmed(.outputLimit) }
    catch { return .unconfirmed(.executionFailed) }
    try Task.checkCancellation(); try validate()
    if result.code == 0 { return .loggedIn }
    let output = (result.text + result.errorText).trimmingCharacters(in: .whitespacesAndNewlines)
    if result.code == 1, output == "Not logged in" { return .loginRequired }
    return .unconfirmed(.executionFailed)
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
  public static let safeArguments = ["--no-daemon", "--sandbox", "workspace-write", "--ask-for-approval", "on-request"]
  public var arguments: [String] { Self.safeArguments }
  public init(executable: AgentExecutable, task: TaskWorkspace, snapshot: TaskWorkspaceSnapshot) throws {
    guard !task.archived, task.agent?.state.active != true, snapshot.taskID == task.id,
      snapshot.status.operation == nil else { throw TaskWorkspaceError.invalid }
    try executable.validate(); try task.binding.validateDirectories()
    self.executable = executable; taskID = task.id; directory = task.path; head = snapshot.head; branch = task.branch; status = snapshot.status
    directoryIdentity = task.binding.directoryIdentity
  }
}
