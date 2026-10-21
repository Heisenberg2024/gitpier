import Foundation

/// Non-sensitive, in-memory observation only. Execution remains with the existing coordinators.
public enum WorkflowOperationKind: String, CaseIterable, Sendable {
  case git, clone, fetch, batchFetch, automaticFetch, pull, push, commit, commitAndPush, merge, mergeAndPush, rebase
  case createWorktree, removeWorktree, review
  case createTask, openTask, archiveTask, reviewTask, agentSession
}
public enum WorkflowOperationState: String, CaseIterable, Sendable {
  case queued, running, waitingForUser, succeeded, failed, cancelled, needsAttention, resultUnknown, agentExited
  public var active: Bool { self == .queued || self == .running }
  public var attention: Bool { [.waitingForUser, .failed, .needsAttention, .resultUnknown].contains(self) }
  public var finished: Bool { !active && self != .waitingForUser }
}
public enum WorkflowOperationPhase: String, Sendable {
  case queued, executing, transferring, refreshing, cancelling, completed, verification
}
public struct OperationRepositoryIdentity: Equatable, Sendable {
  public let workingTree: String
  public let commonDirectory: String?
  public init(workingTree: String, commonDirectory: String?) {
    self.workingTree = workingTree; self.commonDirectory = commonDirectory
  }
}
public enum OperationRecoveryAction: String, Sendable {
  case repository, conflicts, rebase, upstream, credentials, reviewJournal
}
public struct WorkflowOperationRecord: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let kind: WorkflowOperationKind
  public let repositoryID: UUID?
  public let startedAt: Date
  public var completedAt: Date?
  public var state: WorkflowOperationState
  public var progress: Double?
  public var phase: WorkflowOperationPhase = .queued
  public var transferPhase: GitTransferPhase?
  public var repositoryIdentity: OperationRepositoryIdentity?
  public var cancellationRequested = false
  public var canCancel: Bool
  public var recovery: OperationRecoveryAction
  public var revision: UInt64 = 0
  public init(id: UUID = UUID(), kind: WorkflowOperationKind, repositoryID: UUID? = nil,
    startedAt: Date = Date(), state: WorkflowOperationState = .queued, canCancel: Bool = false,
    recovery: OperationRecoveryAction = .repository) {
    self.id = id; self.kind = kind; self.repositoryID = repositoryID; self.startedAt = startedAt
    self.state = state; self.canCancel = canCancel; self.recovery = recovery
  }
}

/// A bounded event reducer, with no timers, disk scans, task queues, commands, or error bodies.
public struct OperationCenterHistory: Sendable {
  public private(set) var records: [WorkflowOperationRecord] = []
  public let recentLimit: Int
  public init(recentLimit: Int = 100) { self.recentLimit = max(1, min(1000, recentLimit)) }
  @discardableResult public mutating func insert(_ record: WorkflowOperationRecord) -> Bool {
    guard !records.contains(where: { $0.id == record.id }) else { return false }
    records.insert(record, at: 0); prune(); return true
  }
  /// Equal and old revisions are duplicates. Terminal records cannot be revived by late events.
  @discardableResult public mutating func update(_ value: WorkflowOperationRecord) -> Bool {
    guard let i = records.firstIndex(where: { $0.id == value.id }),
      records[i].kind == value.kind, records[i].repositoryID == value.repositoryID,
      records[i].startedAt == value.startedAt, value.revision > records[i].revision,
      !records[i].state.finished else { return false }
    var checked = value
    checked.progress = value.progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
    if checked.state.finished { checked.canCancel = false; checked.progress = nil }
    records[i] = checked; prune(); return true
  }
  /// Only authoritative journal readback may resolve an unknown Review. Never replays a write.
  public mutating func reconcileReview(_ record: WorkflowOperationRecord) {
    guard record.kind == .review, record.recovery == .reviewJournal else { return }
    if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
    else { records.insert(record, at: 0) }
    prune()
  }
  public mutating func coalesceAutomatic(repositoryID: UUID) {
    records.removeAll { $0.repositoryID == repositoryID && $0.kind == .automaticFetch && $0.state.finished }
  }
  private mutating func prune() {
    // Unresolved journal entries remain visible; their separate durable store owns its limits.
    var recent = 0
    records = records.filter {
      if $0.state.active || $0.state == .waitingForUser || $0.state == .resultUnknown { return true }
      recent += 1; return recent <= recentLimit
    }
  }
}
