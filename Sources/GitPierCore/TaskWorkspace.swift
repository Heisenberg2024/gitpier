import Darwin
import Foundation

public enum TaskWorkspaceError: String, Error, LocalizedError, Sendable {
  case invalid, unavailable, changed, corrupt, unsupportedVersion, capacity, activeSession, inUse
  public var errorDescription: String? {
    switch self {
    case .inUse: "Task workspaces are open in another GitPier instance. Close that instance before using tasks or removing worktrees."
    case .invalid: "Choose a valid task name, local baseline and linked worktree."
    case .unavailable: "The task worktree is unavailable. Check its location and repair its registration before continuing."
    case .changed: "The task or worktree changed. Refresh and review it again."
    case .corrupt: "Task metadata could not be read safely. The original files have been preserved."
    case .unsupportedVersion: "Task metadata belongs to an unsupported version. The original files have been preserved."
    case .capacity: "Task metadata has reached its size or record limit. Existing tasks have been preserved."
    case .activeSession: "Stop the agent and close this worktree's terminal sessions before continuing."
    }
  }
}

public enum TaskWorkspaceStatus: String, Codable, CaseIterable, Sendable {
  case ready, running, needsAttention, agentExited, changesAvailable, reviewed, archived, interrupted, unavailable
}
public enum LocalAgentProvider: String, Codable, Sendable { case codex }
public enum AgentProcessState: String, Codable, Sendable {
  case idle, launching, running, waitingForInput, exited, failed, interrupted
  public var active: Bool { self == .launching || self == .running || self == .waitingForInput }
}

/// Device/inode identity supplements Git's marker; a reused path alone is never sufficient.
public struct TaskDirectoryIdentity: Codable, Equatable, Sendable {
  public let device: UInt64
  public let inode: UInt64
  public static func read(_ path: String) throws -> Self {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    func systemPath(_ value: String) -> String {
      if value == "/var" || value.hasPrefix("/var/") { return "/private" + value }
      if value == "/tmp" || value.hasPrefix("/tmp/") { return "/private" + value }
      return value
    }
    guard url.path == path, systemPath(url.resolvingSymlinksInPath().path) == systemPath(path) else { throw TaskWorkspaceError.unavailable }
    var info = stat()
    guard lstat(systemPath(path), &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw TaskWorkspaceError.unavailable }
    return Self(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino))
  }
}

public struct TaskWorkspaceBinding: Codable, Equatable, Sendable {
  public let ownership: WorktreeOwnership
  /// Association never upgrades external ownership. Removal still needs the original AppStore receipt.
  public let managed: Bool
  public let directoryIdentity: TaskDirectoryIdentity
  public let gitIdentity: TaskDirectoryIdentity
  public let commonIdentity: TaskDirectoryIdentity
  public init(ownership: WorktreeOwnership, managed: Bool) throws {
    guard !managed || ownership.creationID != nil else { throw TaskWorkspaceError.invalid }
    self.ownership = ownership; self.managed = managed
    directoryIdentity = try .read(ownership.path)
    gitIdentity = try .read(ownership.gitDirectory)
    commonIdentity = try .read(ownership.commonDirectory)
  }
  public func validateDirectories() throws {
    guard try TaskDirectoryIdentity.read(ownership.path) == directoryIdentity,
      try TaskDirectoryIdentity.read(ownership.gitDirectory) == gitIdentity,
      try TaskDirectoryIdentity.read(ownership.commonDirectory) == commonIdentity else { throw TaskWorkspaceError.changed }
  }
}

public struct TaskAgentSession: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let taskID: UUID
  public let provider: LocalAgentProvider
  public let executablePath: String
  public let executableVersion: String
  public let startedAt: Date
  public var state: AgentProcessState
  public var exitCode: Int32?
  public var endedAt: Date?
  public init(taskID: UUID, executablePath: String, executableVersion: String, now: Date = Date()) {
    id = UUID(); self.taskID = taskID; provider = .codex
    self.executablePath = executablePath; self.executableVersion = executableVersion
    startedAt = now; state = .launching
  }
}

public struct TaskWorkspaceReview: Codable, Equatable, Sendable {
  public let head: String
  public let fingerprint: String
  public let reviewedAt: Date
  public init(head: String, fingerprint: String, reviewedAt: Date = Date()) {
    self.head = head; self.fingerprint = fingerprint; self.reviewedAt = reviewedAt
  }
}

/// Metadata only. No prompt, transcript, source, environment or credential payload.
public struct TaskWorkspace: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var savedDescription: String?
  public let repositoryID: UUID
  public let repositoryRoot: String
  public var binding: TaskWorkspaceBinding
  public let branch: String
  public let baseCommit: String
  public let createdAt: Date
  public var updatedAt: Date
  public var status: TaskWorkspaceStatus
  public var agent: TaskAgentSession?
  public var review: TaskWorkspaceReview?
  public var archived: Bool
  public var path: String { binding.ownership.path }
  public var commonDirectory: String { binding.ownership.commonDirectory }
  public init(id: UUID = UUID(), name: String, savedDescription: String? = nil, repositoryID: UUID,
    repositoryRoot: String, binding: TaskWorkspaceBinding, branch: String, baseCommit: String, now: Date = Date()) throws {
    self.id = id; self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.savedDescription = savedDescription; self.repositoryID = repositoryID; self.repositoryRoot = repositoryRoot
    self.binding = binding; self.branch = branch; self.baseCommit = baseCommit
    createdAt = now; updatedAt = now; status = .ready; archived = false
    try validate()
  }
  public func validate() throws {
    func text(_ value: String, limit: Int, empty: Bool = false) -> Bool {
      (empty || !value.isEmpty) && value.utf8.count <= limit && !value.utf8.contains(0)
    }
    guard text(name, limit: 240), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      savedDescription.map({ text($0, limit: 4096, empty: true) }) ?? true,
      [40, 64].contains(baseCommit.count), baseCommit.allSatisfy(\.isHexDigit),
      text(branch, limit: 1024, empty: true), branch.isEmpty || branch.hasPrefix("refs/heads/"),
      [repositoryRoot, path, commonDirectory, binding.ownership.gitDirectory].allSatisfy({
        text($0, limit: 4096) && $0.hasPrefix("/") && URL(fileURLWithPath: $0).standardizedFileURL.path == $0
      }), !binding.managed || binding.ownership.creationID.flatMap(UUID.init(uuidString:)) != nil,
      createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite, updatedAt >= createdAt,
      archived == (status == .archived) else { throw TaskWorkspaceError.invalid }
    if let agent {
      guard agent.taskID == id, text(agent.executablePath, limit: 4096), agent.executablePath.hasPrefix("/"),
        text(agent.executableVersion, limit: 256), agent.startedAt.timeIntervalSince1970.isFinite,
        agent.endedAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= agent.startedAt }) ?? true,
        !agent.state.active || (!archived && agent.endedAt == nil && agent.exitCode == nil)
      else { throw TaskWorkspaceError.invalid }
    }
    if let review {
      guard [40, 64].contains(review.head.count), review.head.allSatisfy(\.isHexDigit),
        review.fingerprint.count == 64, review.fingerprint.allSatisfy(\.isHexDigit),
        review.reviewedAt.timeIntervalSince1970.isFinite else { throw TaskWorkspaceError.invalid }
    }
  }
  public mutating func recoverInterruptedSession() {
    if var session = agent, session.state.active {
      session.state = .interrupted; session.endedAt = max(Date(), session.startedAt); agent = session
      if !archived { status = .interrupted }
    }
  }
  public mutating func setArchived(_ value: Bool, now: Date = Date()) throws {
    guard agent?.state.active != true else { throw TaskWorkspaceError.activeSession }
    archived = value; status = value ? .archived : .ready; updatedAt = max(now, updatedAt)
  }
}

public struct TaskWorkspaceSnapshot: Sendable {
  public let taskID: UUID
  public let head: String
  public let status: RepositoryStatus
  public let comparison: BranchComparisonResult
  public var hasChanges: Bool { !status.files.isEmpty || comparison.leftHash != head }
}
