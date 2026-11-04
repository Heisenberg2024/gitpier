import AppKit
import GitPierCore
import SwiftUI

enum OperationResult: Equatable { case running, succeeded, needsAttention, failed, cancelled, resultUnknown }
struct OperationTicket: Sendable, Equatable {
  let id: UUID
  let stage: Int
}
struct OperationState {
  var title: String
  var workflow: OperationWorkflowProgress
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
  @discardableResult func begin(_ title: String, cancellable: Bool = true, kind: WorkflowOperationKind = .git, observed: Bool = true) -> OperationTicket {
    dismissal?.cancel()
    id = UUID()
    stage = 0
    originalTitle = title
    canCancel = cancellable
    let workflow = OperationWorkflowProgress(id: id, kind: kind)
    state = OperationState(title: title, workflow: workflow)
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
  let cancel: () -> Void
  var body: some View {
    if let state = progress.state {
      HStack(spacing: 8) {
        Image(systemName: OperationStatusPresentation(state.result).symbol)
          .foregroundStyle(OperationStatusPresentation(state.result).color).accessibilityHidden(true)
        Text(label(state)).lineLimit(1).truncationMode(.middle).frame(
          maxWidth: 240, alignment: .leading)
        WorkflowProgressBar(workflow: state.workflow).frame(width: 100, height: 8)
        if state.result == .running && progress.canCancel {
          IconButton("xmark.circle", help: store.text("Cancel operation", "取消操作"), action: cancel)
        }
      }.font(.system(size: 10)).foregroundStyle(
        state.result == .failed
          ? Color.red : state.result == .needsAttention ? Color.orange : Color.secondary
      )
      .accessibilityElement(children: .contain).accessibilityIdentifier(
        "gitpier.operation.progress")
    } else {
      OtherOperationProgressView(center: store.operations)
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

/// Keep other repositories' operations reachable while the user changes pages or opens Dashboard.
private struct OtherOperationProgressView: View {
  @ObservedObject var center: OperationsCenter
  @EnvironmentObject var store: AppStore
  var body: some View {
    if let record = center.records.first(where: { $0.state.active && $0.kind != .automaticFetch && $0.workflow != nil }),
      let workflow = record.workflow {
      Button { store.showOperationsCenter = true } label: {
        HStack(spacing: 8) {
          Text([record.repositoryID.flatMap { store.models[$0]?.record.name }, operationTitle(record.kind, store: store),
            WorkflowProgressPresentation.label(workflow, store: store)].compactMap { $0 }.joined(separator: " · "))
            .lineLimit(1).truncationMode(.middle)
          WorkflowProgressBar(workflow: workflow).frame(width: 100, height: 8)
        }
      }.buttonStyle(.workspace).help(store.text("Open Operations Center", "打开操作中心"))
    }
  }
}

enum WorkflowProgressPresentation {
  @MainActor static func label(_ workflow: OperationWorkflowProgress, currentTitle: String? = nil, store: AppStore) -> String {
    if workflow.outcome != nil {
      let count = workflow.steps.filter { $0.state == .completed }.count
      return store.text("\(count) of \(workflow.steps.count) steps completed", "已完成 \(count)/\(workflow.steps.count) 步")
    }
    let fallbackTitle = switch workflow.current {
    case .prepare: store.text("Preparing", "准备中")
    case .execute: store.text("Running Git", "正在执行 Git")
    case .commit: store.text("Committing", "正在提交")
    case .pushTarget: store.text("Checking Push target", "检查推送目标")
    case .push: store.text("Pushing", "正在推送")
    case .refresh: store.text("Refreshing results", "正在刷新结果")
    }
    let step = store.text("Step \(workflow.index + 1)/\(workflow.steps.count)", "第 \(workflow.index + 1)/\(workflow.steps.count) 步")
    let transfer = workflow.transfer.map { " · " + operationTransferTitle($0.phase, store: store) + " \(Int($0.fraction * 100))%" } ?? ""
    return step + " · " + (currentTitle ?? fallbackTitle) + transfer
  }
}

/// Completed steps stay filled. Only the active step uses the native transfer indicator.
struct WorkflowProgressBar: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let workflow: OperationWorkflowProgress
  var body: some View {
    Group {
      if workflow.outcome == .succeeded && workflow.steps.allSatisfy({ $0.state == .completed }) {
        OperationBar(value: 1)
      } else {
        steps
      }
    }.clipShape(Capsule()).accessibilityHidden(true)
  }
  private var steps: some View {
    GeometryReader { geometry in
      let width = max(0, (geometry.size.width - CGFloat(workflow.steps.count - 1) * 2) / CGFloat(workflow.steps.count))
      HStack(spacing: 2) {
        ForEach(workflow.steps.indices, id: \.self) { index in
          Group {
            switch workflow.steps[index].state {
            case .completed:
              Rectangle().fill(Color.accentColor)
            case .active:
              if reduceMotion, workflow.transfer == nil {
                Rectangle().fill(Color.accentColor.opacity(0.40))
              } else {
                OperationBar(value: workflow.transfer?.fraction)
              }
            case .interrupted:
              Rectangle().fill(Color.orange.opacity(0.5))
            case .pending, .skipped:
              Rectangle().fill(Color.secondary.opacity(0.16))
            }
          }.frame(width: width).clipped()
        }
      }
    }
  }
}
struct OperationBar: NSViewRepresentable {
  let value: Double?
  func makeNSView(context: Context) -> NSProgressIndicator {
    let view = NSProgressIndicator()
    view.style = .bar
    view.minValue = 0
    view.maxValue = 1
    view.controlSize = .small
    view.isDisplayedWhenStopped = true
    view.usesThreadedAnimation = true
    view.setAccessibilityLabel(localizedUI("Git operation progress"))
    return view
  }
  func updateNSView(_ view: NSProgressIndicator, context: Context) {
    view.setAccessibilityLabel(localizedUI("Git operation progress"))
    if let value {
      if view.isIndeterminate {
        view.isIndeterminate = false
        view.stopAnimation(nil)
      }
      view.doubleValue = min(1, max(0, value))
    } else {
      if !view.isIndeterminate { view.isIndeterminate = true }
      view.startAnimation(nil)
    }
  }
  static func dismantleNSView(_ view: NSProgressIndicator, coordinator: ()) {
    view.stopAnimation(nil)
  }
}
