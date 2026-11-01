import Foundation

/// A comparison with a locally available upstream tip, never a live-server claim.
public enum BranchSyncState: Equatable, Sendable {
  case synced, ahead(Int), behind(Int), diverged(ahead: Int, behind: Int), noUpstream, unknown

  public init(upstream: String?, comparable: Bool, ahead: Int?, behind: Int?) {
    guard let upstream, !upstream.isEmpty else { self = .noUpstream; return }
    guard comparable, let ahead, let behind, ahead >= 0, behind >= 0 else { self = .unknown; return }
    switch (ahead, behind) {
    case (0, 0): self = .synced
    case (_, 0): self = .ahead(ahead)
    case (0, _): self = .behind(behind)
    default: self = .diverged(ahead: ahead, behind: behind)
    }
  }
}

extension RepositoryStatus {
  public var syncState: BranchSyncState {
    guard head != nil, !branch.isEmpty, branch != "(detached)" else { return .unknown }
    return BranchSyncState(upstream: upstream, comparable: upstreamComparable, ahead: ahead, behind: behind)
  }
}
extension WorkspaceSnapshot {
  public var syncState: BranchSyncState {
    guard head != nil, !branch.isEmpty, !detached else { return .unknown }
    return BranchSyncState(upstream: upstream, comparable: upstreamComparable, ahead: ahead, behind: behind)
  }
}

public struct BranchHealth: Identifiable, Equatable, Sendable {
  public var id: String { reference }
  public let reference: String
  public let name: String
  public let hash: String
  public let current: Bool
  public let upstream: String?
  public let upstreamShort: String
  public let tracking: String
  public let upstreamExists: Bool?
  public let ahead: Int?
  public let behind: Int?
  public var syncState: BranchSyncState {
    BranchSyncState(upstream: upstream, comparable: upstreamExists == true, ahead: ahead, behind: behind)
  }
  public var diverged: Bool { if case .diverged = syncState { return true }; return false }
  public let mergedIntoTarget: Bool?
  public let lastCommit: Date?
  public let worktreePaths: [String]
  /// Activity is informational, never permission to delete a branch.
  public func inactive(asOf date: Date, days: Int = 90) -> Bool {
    lastCommit.map { date.timeIntervalSince($0) > Double(days) * 86400 } ?? false
  }
}
public struct BranchHealthSnapshot: Sendable {
  public let branches: [BranchHealth]
  public let currentBranch: String?
  public let head: String?
  public let detached: Bool
  public let operation: GitOperation?
  public let targetReference: String?
  public let targetHash: String?
  public let availableTargets: [String]
  public let suggestedTargetReference: String?
  public let shallow: Bool
  public let collectedAt: Date
  public let fetchTargetID: String?
  public let fetchRemoteName: String?
}
