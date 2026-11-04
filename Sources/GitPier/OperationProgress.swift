import AppKit
import GitPierCore
import SwiftUI

enum OperationResult: Equatable { case running, succeeded, needsAttention, failed, cancelled, resultUnknown }
struct OperationTicket: Sendable, Equatable {
  let id: UUID
  let stage: Int
}
enum OperationProgressPresentation: Equatable { case workflow, waiting }

struct OperationState {
  var title: String
  var workflow: OperationWorkflowProgress
  var presentation: OperationProgressPresentation = .workflow
  var transfer: GitTransferProgress? { workflow.transfer }
  var result: OperationResult = .running
}
/// Frequent transfer updates affect only this object and the status-bar child view.
@MainActor final class OperationProgress: ObservableObject {
  @Published private(set) var state: OperationState?
  @Published private(set) var canCancel = false
  weak var center: OperationsCenter?
  var repositoryIdentity: (() -> OperationRepositoryIdentity?)?
  var repositoryID: UUID?
  var cancelOperation: (() -> Void)?
  private var id = UUID()
  private var stage = 0
  private var originalTitle = ""
  private var dismissal: Task<Void, Never>?
  var ticket: OperationTicket { OperationTicket(id: id, stage: stage) }
  @discardableResult func begin(_ title: String, cancellable: Bool = true, kind: WorkflowOperationKind = .git,
    observed: Bool = true, presentation: OperationProgressPresentation = .workflow) -> OperationTicket {
    dismissal?.cancel()
    id = UUID()
    stage = 0
    originalTitle = title
    canCancel = cancellable
    let workflow = OperationWorkflowProgress(id: id, kind: kind)
    state = OperationState(title: title, workflow: workflow, presentation: presentation)
    if observed { center?.begin(id: id, kind: kind, repositoryID: repositoryID, identity: repositoryIdentity?(), workflow: workflow, cancel: cancellable ? cancelOperation : nil) }
    return ticket
  }
  func advance(_ title: String, cancellable: Bool? = nil, phase: WorkflowOperationPhase = .executing,
    step: OperationWorkflowStep? = nil, previousCompleted: Bool = true) {
    guard var value = state, value.result == .running else { return }
    stage += 1
    if let cancellable { canCancel = cancellable }
    value.title = title
    if phase != .cancelling {
      value.workflow.advance(to: step ?? (phase == .refreshing ? .refresh : .execute), previousCompleted: previousCompleted)
    }
    state = value
    center?.update(id, cancellable: canCancel, phase: phase, workflow: value.workflow)
  }
  func markRunning() { center?.update(id, state: .running) }
  func markExecuting() {
    guard let value = state, value.workflow.current == .prepare,
      value.workflow.steps.contains(where: { $0.kind == .execute }) else { return }
    advance(value.title, step: .execute)
  }
  func recordLocalCommit(_ hash: String) {
    guard state?.result == .running else { return }
    center?.update(id, localCommit: hash)
  }
  func recordBranch(_ branch: String) { center?.update(id, branch: branch) }
  func recordUnverifiedCommit() { center?.update(id, localCommitUnverified: true) }
  func recordPushCheckpoint(_ checkpoint: PushCheckpoint) {
    guard state?.result == .running else { return }
    center?.update(id, pushCheckpoint: checkpoint)
  }
  func receiver() -> @Sendable (GitTransferProgress) -> Void {
    let expected = ticket
    return { [weak self] progress in
      Task { @MainActor [weak self] in
        guard let self, self.ticket == expected, var value = self.state, value.result == .running else { return }
        let step = value.workflow.current
        guard value.workflow.receive(progress, step: step) else { return }
        self.state = value
        self.center?.update(expected.id, transfer: progress, workflow: value.workflow)
      }
    }
  }
  func finish(_ result: OperationResult, ticket expected: OperationTicket, waitingForUser: Bool = false,
    detail: String? = nil) {
    guard id == expected.id, var value = state, value.result == .running else { return }
    let outcome: WorkflowOperationState
    switch result {
    case .running: return
    case .succeeded: outcome = .succeeded
    case .failed: outcome = .failed
    case .cancelled: outcome = .cancelled
    case .resultUnknown: outcome = .resultUnknown
    case .needsAttention: outcome = waitingForUser ? .waitingForUser : .needsAttention
    }
    value.title = originalTitle
    value.result = result
    value.workflow.finish(outcome)
    state = value
    canCancel = false
    center?.update(id, state: outcome, detail: detail, workflow: value.workflow)
    scheduleDismissal(result)
  }

  /// Only the Center's confirmed readback can change an unknown terminal result.
  /// An older record must never take the place of a newer operation in the footer.
  func applyVerifiedPush(_ record: WorkflowOperationRecord) {
    guard record.id == id, record.state == .succeeded, record.verifiedAt != nil,
      let workflow = record.workflow, var value = state, value.result == .resultUnknown else { return }
    value.result = .succeeded
    value.workflow = workflow
    state = value
    scheduleDismissal(.succeeded)
  }

  private func scheduleDismissal(_ result: OperationResult) {
    dismissal?.cancel()
    let completed = id
    dismissal = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(result == .succeeded ? 5 : 8)) } catch { return }
      guard self?.id == completed else { return }
      self?.state = nil
    }
  }
}

struct OperationProgressView: View {
  @ObservedObject var progress: OperationProgress
  @EnvironmentObject var store: AppStore
  var showsOtherOperations = true
  var leadingBar = false
  var barWidth: CGFloat = 100
  let cancel: () -> Void
  var body: some View {
    if let state = progress.state {
      OperationProgressContent(title: label(state), workflow: state.workflow,
        status: OperationStatusPresentation(state.result),
        cancel: state.result == .running && progress.canCancel ? cancel : nil, leadingBar: leadingBar,
        barWidth: barWidth, presentation: state.presentation)
      .foregroundStyle(
        state.result == .failed
          ? Color.red : state.result == .needsAttention ? Color.orange : Color.secondary
      )
      .accessibilityElement(children: .contain).accessibilityIdentifier(
        "gitpier.operation.progress")
    } else if showsOtherOperations {
      OtherOperationProgressView(center: store.operations, leadingBar: leadingBar, barWidth: barWidth)
    }
  }
  func label(_ state: OperationState) -> String {
    switch state.result {
    case .succeeded: return state.title + store.text(" · Completed", " · 已完成")
    case .needsAttention: return state.title + store.text(" · Needs attention", " · 需要处理")
    case .failed: return state.title + store.text(" · Failed", " · 失败")
    case .cancelled: return state.title + store.text(" · Cancelled", " · 已取消")
    case .resultUnknown: return state.title + store.text(" · Result unknown", " · 结果未知")
    case .running:
      return WorkflowProgressPresentation.label(state.workflow, currentTitle: state.title, store: store)
    }
  }
}

private struct OperationProgressContent: View {
  @EnvironmentObject var store: AppStore
  let title: String
  let workflow: OperationWorkflowProgress
  let status: OperationStatusPresentation
  var cancel: (() -> Void)?
  var leadingBar = false
  var barWidth: CGFloat = 100
  var presentation: OperationProgressPresentation = .workflow
  var body: some View {
    HStack(spacing: 8) {
      if leadingBar { WorkflowProgressBar(workflow: workflow, width: barWidth, presentation: presentation) }
      Image(systemName: status.symbol).foregroundStyle(status.color)
        .frame(width: 12).accessibilityHidden(true)
      Text(title).lineLimit(1).truncationMode(.middle).frame(maxWidth: 240, alignment: .leading)
        .accessibilityIdentifier("gitpier.operation.summary")
      // Reserve the same target before the trailing bar when cancellation is unavailable.
      ZStack {
        if let cancel {
          IconButton("xmark.circle", help: store.text("Cancel operation", "取消操作"), action: cancel)
        }
      }.frame(width: Theme.iconTarget, height: Theme.iconTarget)
      if !leadingBar { WorkflowProgressBar(workflow: workflow, width: barWidth, presentation: presentation) }
    }.font(.system(size: 10))
  }
}

/// Keep other repositories' operations reachable while the user changes pages or opens Dashboard.
private struct OtherOperationProgressView: View {
  @ObservedObject var center: OperationsCenter
  @EnvironmentObject var store: AppStore
  var leadingBar = false
  var barWidth: CGFloat = 100
  var body: some View {
    if let record = center.records.first(where: { $0.state.active && $0.kind != .automaticFetch && $0.workflow != nil }),
      let workflow = record.workflow {
      Button { store.showOperationsCenter = true } label: {
        OperationProgressContent(title: [record.repositoryID.flatMap { store.models[$0]?.record.name },
          operationTitle(record.kind, store: store), WorkflowProgressPresentation.label(workflow, store: store)]
            .compactMap { $0 }.joined(separator: " · "),
          workflow: workflow, status: OperationStatusPresentation(record.state), cancel: nil, leadingBar: leadingBar,
          barWidth: barWidth)
      }.buttonStyle(.workspace).help(store.text("Open Operations Center", "打开操作中心"))
        .accessibilityIdentifier("gitpier.operation.background")
    }
  }
}

enum WorkflowProgressPresentation {
  @MainActor static func label(_ workflow: OperationWorkflowProgress, currentTitle: String? = nil, store: AppStore) -> String {
    if let outcome = workflow.outcome {
      switch outcome {
      case .succeeded: return store.text("Completed", "已完成")
      case .failed: return store.text("Failed", "失败")
      case .cancelled: return store.text("Cancelled", "已取消")
      case .needsAttention: return store.text("Needs attention", "需要处理")
      case .waitingForUser: return store.text("Waiting for you", "等待用户操作")
      case .resultUnknown: return store.text("Result unknown", "结果未知")
      case .agentExited: return store.text("Agent exited", "Agent 已退出")
      case .queued, .running: break
      }
    }
    let fallbackTitle = switch workflow.current {
    case .prepare: store.text("Preparing", "准备中")
    case .execute: store.text("Running Git", "正在执行 Git")
    case .commit: store.text("Committing", "正在提交")
    case .pushTarget: store.text("Checking Push target", "检查推送目标")
    case .push: store.text("Pushing", "正在推送")
    case .refresh: store.text("Refreshing results", "正在刷新结果")
    }
    let transfer = workflow.transfer.map { " · " + operationTransferTitle($0.phase, store: store) + " \(Int($0.fraction * 100))%" } ?? ""
    return (currentTitle ?? fallbackTitle) + transfer
  }
}

/// Workflow steps remain internal; measured progress never resets at a phase boundary.
struct WorkflowProgressBar: View {
  let workflow: OperationWorkflowProgress
  var width: CGFloat = 100
  var presentation: OperationProgressPresentation = .workflow
  var body: some View {
    Group {
      if presentation == .waiting, workflow.outcome != nil {
        // Keep the summary anchored without turning a completed refresh into a measured fill.
        Color.clear.frame(width: width, height: 12)
      } else {
        OperationBar(value: presentation == .waiting ? nil : workflow.indicatorValue, width: width)
      }
    }.accessibilityHidden(true)
  }
}

struct OperationBar: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  let value: Double?
  var width: CGFloat = 100
  var body: some View {
    Group {
      if value == nil && !reduceMotion {
        IndeterminateOperationBar()
      } else {
        NativeOperationBar(value: value, animates: !reduceMotion, increasedContrast: contrast == .increased)
      }
    }.frame(width: width, height: 12).fixedSize()
  }
}

/// Preserve v2.0.0's system waiting animation; measured transfers keep their existing renderer.
private struct IndeterminateOperationBar: NSViewRepresentable {
  @EnvironmentObject var store: AppStore
  func makeNSView(context: Context) -> NSProgressIndicator {
    let view = NSProgressIndicator()
    view.style = .bar
    view.minValue = 0; view.maxValue = 1
    view.controlSize = .small
    view.isDisplayedWhenStopped = true
    view.usesThreadedAnimation = true
    view.isIndeterminate = true
    return view
  }
  func updateNSView(_ view: NSProgressIndicator, context: Context) {
    view.setAccessibilityLabel(store.text("Git operation progress", "Git 操作进度"))
    if !view.isIndeterminate { view.isIndeterminate = true }
    view.startAnimation(nil)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSProgressIndicator, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 100, height: 12)
  }
  static func dismantleNSView(_ view: NSProgressIndicator, coordinator: ()) { view.stopAnimation(nil) }
}
