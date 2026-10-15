import Foundation

/// Local-only, memory-only card data. No Index tree, patches, credentials or history.
public struct WorkspaceSnapshot: Equatable, Sendable {
  public let repositoryID: UUID
  public let path: String
  public let branch: String
  public let head: String?
  public let upstream: String?
  public let ahead: Int
  public let behind: Int
  public let tracked: Int
  public let untracked: Int
  public let staged: Int
  public let conflicts: Int
  public let operation: GitOperation?
  public let gitDirectory: String
  public let commonDirectory: String
  public let remoteNames: [String]
  public let collectedAt: Date
  public var detached: Bool { branch == "(detached)" }
  public var isWorktree: Bool { gitDirectory != commonDirectory }
  public var modified: Bool { tracked + untracked > 0 }
  public init(record: RepositoryRecord, status: RepositoryStatus, gitDirectory: String,
              commonDirectory: String, remoteNames: [String] = [], collectedAt: Date = Date()) {
    repositoryID = record.id; path = record.path; branch = status.branch; head = status.head
    upstream = status.upstream; ahead = status.ahead; behind = status.behind
    tracked = status.tracked.count; untracked = status.untracked.count
    staged = status.staged.count; conflicts = status.files.filter(\.isConflicted).count
    operation = status.operation; self.gitDirectory = gitDirectory
    self.commonDirectory = commonDirectory; self.remoteNames = remoteNames; self.collectedAt = collectedAt
  }
}

public enum WorkspaceCollectionState: String, Sendable { case unscanned, queued, collecting, fresh, stale, failed }
public enum WorkspaceFailureKind: String, Sendable { case missingDirectory, invalidRepository, permissionDenied, gitQuery }
public struct WorkspaceFailure: Error, Equatable, Sendable {
  public let kind: WorkspaceFailureKind
  public let summary: String
  public init(_ kind: WorkspaceFailureKind, _ summary: String) {
    self.kind = kind; self.summary = GitService.redact(summary)
  }
}
public struct WorkspaceEntry: Equatable, Sendable {
  public var record: RepositoryRecord
  public var snapshot: WorkspaceSnapshot?
  public var state: WorkspaceCollectionState = .unscanned
  public var failure: WorkspaceFailure?
  public var lastAttempt: Date?
  public init(record: RepositoryRecord) { self.record = record }
  /// Failed refreshes preserve old counts for display, but exclude them from current summaries.
  public var usable: WorkspaceSnapshot? { failure == nil ? snapshot : nil }
}

public enum WorkspaceFilter: String, CaseIterable, Sendable {
  case modified, staged, ahead, behind, conflicts, unavailable, favorites
  public func matches(_ entry: WorkspaceEntry) -> Bool {
    if self == .favorites { return entry.record.favorite }
    if self == .unavailable { return entry.failure != nil }
    guard let value = entry.usable else { return false }
    switch self {
    case .modified: return value.modified
    case .staged: return value.staged > 0
    case .ahead: return value.upstream != nil && value.ahead > 0
    case .behind: return value.upstream != nil && value.behind > 0
    case .conflicts: return value.conflicts > 0
    default: return false
    }
  }
}
public struct WorkspaceSummary: Equatable, Sendable {
  public let total: Int
  public let scanned: Int
  public let fresh: Int
  public let physicalRepositories: Int
  public let unknownPhysical: Int
  public let counts: [WorkspaceFilter: Int]
  public init(_ entries: [WorkspaceEntry]) {
    total = entries.count
    scanned = entries.filter { $0.snapshot != nil || $0.failure != nil }.count
    fresh = entries.filter { $0.state == .fresh }.count
    physicalRepositories = Set(entries.compactMap { $0.usable?.commonDirectory }).count
    unknownPhysical = entries.filter { $0.usable == nil }.count
    counts = Dictionary(uniqueKeysWithValues: WorkspaceFilter.allCases.map { filter in
      (filter, entries.filter { filter.matches($0) }.count)
    })
  }
}
