import Foundation

/// Advice has no executor, timer, persistence, or implicit network access.
public struct ContextWorkflowInput: Equatable, Sendable {
  public var currentPage = ""
  public var repositoryID: UUID?
  public var workingTree = ""
  public var filesystemIdentity: String?
  public var linkedWorktree = false
  public var status = RepositoryStatus()
  public var available = true
  public var busy = false
  public var refreshing = false
  public var stale = false
  public var remoteCount = 0
  public var remotePhase = RemoteCheckPhase.notChecked
  public var remoteFresh = false
  public var retainingBranches: [String] = []
  public init() {}
}

public enum ContextWorkflowAction: String, CaseIterable, Sendable {
  case refresh, reviewChanges, resolveConflicts, continueOperation, createBranch, chooseBranch
  case addRemote, setUpstream, reviewFetch, reviewAuthentication
  case compareIncoming, compareOutgoing, reviewPull, reviewPush, mergeUpstream, rebaseUpstream
}

public struct ContextWorkflowAdvice: Equatable, Sendable {
  public enum Kind: String, Sendable {
    case unavailable, refreshing, busy, stale, conflicts, unfinishedOperation, detached
    case firstCommit, stagedChanges, localChanges, preserveBeforeSync, addFiles
    case localOnly, noUpstream, authentication, fetchFailed, checkingRemote, verifyRemote
    case missingUpstream, diverged, incoming, outgoing, aligned
  }
  public let kind: Kind
  public let actions: [ContextWorkflowAction]
  public init(_ kind: Kind, _ actions: [ContextWorkflowAction] = []) {
    self.kind = kind; self.actions = actions
  }
  public enum Priority: String, Sendable { case normal, suggestion, risk }
  /// Presentation severity only. Advice, permitted actions and write reviews
  /// continue to use the same Git facts and existing guards.
  public enum DisplayLevel: Int, CaseIterable, Sendable {
    case normal, suggestion, attention, warning, blocked
  }
  public func displayLevel(in input: ContextWorkflowInput) -> DisplayLevel {
    // A refresh/check must not blink a known conflict back to a normal bulb.
    // These are facts from the last local snapshot, never a live-remote claim.
    if [.busy, .refreshing, .checkingRemote].contains(kind) {
      if input.status.files.contains(where: \.isConflicted) || input.status.operation != nil { return .blocked }
      if input.status.head != nil && (input.status.branch == "(detached)" || input.status.branch.isEmpty) { return .warning }
      if input.status.upstreamComparable && input.status.behind > 0 {
        return input.status.files.isEmpty ? .attention : .warning
      }
      return .normal
    }
    if isReviewingChanges(input) { return .normal }
    switch kind {
    case .conflicts, .unfinishedOperation: return .blocked
    case .detached, .preserveBeforeSync: return .warning
    case .incoming, .diverged, .unavailable, .stale, .authentication, .fetchFailed, .missingUpstream:
      return .attention
    case .verifyRemote:
      return input.status.ahead > 0 || input.status.behind > 0 ? .attention : .suggestion
    case .aligned, .localOnly, .addFiles, .busy, .refreshing, .checkingRemote: return .normal
    default: return .suggestion
    }
  }
  public var isRoutineChangeReview: Bool { [.firstCommit, .stagedChanges, .localChanges].contains(kind) }
  public func isReviewingChanges(_ input: ContextWorkflowInput) -> Bool {
    isRoutineChangeReview && input.currentPage == "commit"
  }
  public func priority(in input: ContextWorkflowInput) -> Priority {
    if isReviewingChanges(input) { return .normal }
    switch kind {
    case .aligned, .localOnly, .addFiles, .busy, .refreshing, .checkingRemote: return .normal
    case .conflicts, .unfinishedOperation, .detached, .preserveBeforeSync, .diverged,
         .unavailable, .stale, .authentication, .fetchFailed, .missingUpstream: return .risk
    case .verifyRemote: return input.status.ahead > 0 || input.status.behind > 0 ? .risk : .suggestion
    default: return .suggestion
    }
  }
  /// Downrank navigation already available on the current page, without claiming
  /// that the underlying changes were staged, committed or resolved.
  public func visibleActions(in input: ContextWorkflowInput) -> [ContextWorkflowAction] {
    if isReviewingChanges(input) || kind == .localOnly { return [] }
    return actions
  }
  public static func evaluate(_ input: ContextWorkflowInput) -> Self {
    let state = input.status
    if input.busy { return Self(.busy) }
    if input.refreshing { return Self(.refreshing) }
    guard input.available else { return Self(.unavailable, [.refresh]) }
    if input.stale { return Self(.stale, [.refresh]) }
    if state.files.contains(where: \.isConflicted) {
      return Self(.conflicts, state.operation == .rebase ? [.resolveConflicts, .continueOperation] : [.resolveConflicts])
    }
    if state.operation != nil { return Self(.unfinishedOperation, [.continueOperation]) }
    if state.head != nil && (state.branch == "(detached)" || state.branch.isEmpty) {
      return Self(.detached, input.retainingBranches.isEmpty ? [.createBranch] : [.chooseBranch])
    }
    if state.head == nil {
      return state.files.isEmpty ? Self(.addFiles) : Self(.firstCommit, [.reviewChanges])
    }
    if !state.files.isEmpty {
      if state.upstreamComparable && state.behind > 0 { return Self(.preserveBeforeSync, [.reviewChanges]) }
      return Self(state.staged.isEmpty ? .localChanges : .stagedChanges, [.reviewChanges])
    }
    if input.remoteCount == 0 { return Self(.localOnly, [.addRemote]) }
    if input.remotePhase == .authenticationRequired { return Self(.authentication, [.reviewAuthentication]) }
    if input.remotePhase == .checking || input.remotePhase == .queued { return Self(.checkingRemote) }
    if state.upstream == nil { return Self(.noUpstream, [.setUpstream, .reviewFetch]) }
    if input.remotePhase == .failed { return Self(.fetchFailed, [.reviewFetch]) }
    // Never promote a cached ahead/behind count into a claim about a live server.
    if !input.remoteFresh || input.remotePhase == .skipped || input.remotePhase == .notChecked { return Self(.verifyRemote, [.reviewFetch]) }
    if !state.upstreamComparable { return Self(.missingUpstream, [.setUpstream, .reviewFetch]) }
    if state.ahead > 0 && state.behind > 0 {
      return Self(.diverged, [.compareIncoming, .mergeUpstream, .rebaseUpstream])
    }
    if state.behind > 0 { return Self(.incoming, [.compareIncoming, .reviewPull]) }
    if state.ahead > 0 { return Self(.outgoing, [.compareOutgoing, .reviewPush]) }
    return Self(.aligned)
  }
}

/// Ephemeral, immutable review. Configuration values and command output are never stored here.
public struct ContextWorkflowReview: Equatable, Sendable {
  public let gitExecutable: String
  public let workingTree: String
  public let commonDirectory: String
  public let gitDirectory: String
  public let filesystemIdentity: [String]
  public let operation: GitOperationReview
  public let status: RepositoryStatus
  public let remotes: [GitRemote]
  public let configurationFingerprint: Data
  public let upstreamReference: String?
  public let upstreamHash: String?
  public let upstreamRemote: String?
  public let upstreamDestination: String?
  public let singleBranchPush: Bool
  public let singleBranchPull: Bool
}
