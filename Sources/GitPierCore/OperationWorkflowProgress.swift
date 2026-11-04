import Foundation

public enum OperationWorkflowStep: String, Equatable, Sendable {
  case prepare, execute, commit, pushTarget, push, refresh
}

/// Measured object transfer only; preparation and elapsed time never invent a percentage.
public struct OperationProgressValue: Equatable, Sendable {
  private let kind: WorkflowOperationKind
  private var measured: Double?
  public init(kind: WorkflowOperationKind) { self.kind = kind }

  public mutating func receive(_ transfer: GitTransferProgress) {
    guard transfer.fraction.isFinite, (0...1).contains(transfer.fraction) else { return }
    let relevant: Bool
    switch kind {
    case .push, .commitAndPush, .mergeAndPush: relevant = transfer.phase == .writing
    case .clone, .fetch, .batchFetch, .automaticFetch, .pull: relevant = transfer.phase == .receiving
    default: relevant = [.receiving, .writing, .checkout].contains(transfer.phase)
    }
    guard relevant else { return }
    measured = max(measured ?? 0, transfer.fraction)
  }

  public func value(for state: WorkflowOperationState) -> Double? {
    if state == .succeeded { return 1 }
    // A finished transfer still needs Git's result and the final local refresh.
    if let measured { return min(0.99, measured) }
    if !state.active { return 0 }
    switch kind {
    case .push, .commit, .commitAndPush, .mergeAndPush, .clone, .fetch, .batchFetch, .automaticFetch, .pull:
      return 0
    default: return nil
    }
  }
}

/// The positions represent named steps, never an estimate of total time or bytes.
public struct OperationWorkflowProgress: Equatable, Sendable {
  public struct Step: Equatable, Sendable {
    public enum State: Equatable, Sendable { case pending, active, completed, interrupted, skipped }
    public let kind: OperationWorkflowStep
    public fileprivate(set) var state: State
  }

  public let id: UUID
  public private(set) var steps: [Step]
  public private(set) var index = 0
  public private(set) var transfer: GitTransferProgress?
  public private(set) var outcome: WorkflowOperationState?
  private var indicator: OperationProgressValue
  public var current: OperationWorkflowStep { steps[index].kind }
  public var indicatorValue: Double? {
    indicator.value(for: outcome ?? .running)
  }

  public init(id: UUID, kind: WorkflowOperationKind) {
    self.id = id
    indicator = OperationProgressValue(kind: kind)
    let plan: [OperationWorkflowStep]
    switch kind {
    case .commitAndPush: plan = [.prepare, .commit, .pushTarget, .push, .refresh]
    case .commit: plan = [.prepare, .commit, .refresh]
    case .mergeAndPush: plan = [.prepare, .execute, .commit, .push, .refresh]
    default: plan = [.prepare, .execute, .refresh]
    }
    steps = plan.enumerated().map { Step(kind: $0.element, state: $0.offset == 0 ? .active : .pending) }
  }

  public mutating func advance(to step: OperationWorkflowStep, previousCompleted: Bool = true) {
    guard outcome == nil, let next = steps.firstIndex(where: { $0.kind == step }), next > index else { return }
    steps[index].state = previousCompleted ? .completed : .interrupted
    for i in (index + 1)..<next { steps[i].state = .skipped }
    index = next
    steps[index].state = .active
    transfer = nil
  }

  @discardableResult public mutating func receive(_ progress: GitTransferProgress, step: OperationWorkflowStep) -> Bool {
    guard outcome == nil, current == step, [.execute, .push].contains(step),
      progress.fraction.isFinite, (0...1).contains(progress.fraction) else { return false }
    if let transfer {
      guard rank(progress.phase) >= rank(transfer.phase),
        progress.phase != transfer.phase || progress.fraction > transfer.fraction else { return false }
    }
    transfer = progress
    indicator.receive(progress)
    return true
  }

  public mutating func finish(_ state: WorkflowOperationState) {
    guard outcome == nil, !state.active else { return }
    outcome = state
    steps[index].state = state == .succeeded || current == .refresh ? .completed : .interrupted
    for i in (index + 1)..<steps.count { steps[i].state = .skipped }
    transfer = nil
  }

  mutating func confirmRemoteResult() {
    guard outcome == .resultUnknown else { return }
    outcome = .succeeded
    if let index = steps.firstIndex(where: { ($0.kind == .push || $0.kind == .execute) && $0.state == .interrupted }) {
      steps[index].state = .completed
    }
  }

  private func rank(_ phase: GitTransferPhase) -> Int {
    switch phase {
    case .counting: 0
    case .compressing: 1
    case .receiving, .writing: 2
    case .resolving: 3
    case .checkout: 4
    }
  }
}
