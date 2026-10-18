import AppKit
import GitPierCore
import SwiftUI

enum OperationResult: Equatable { case running, succeeded, needsAttention, failed, cancelled }
struct OperationTicket: Sendable, Equatable {
  let id: UUID
  let stage: Int
}
struct OperationState {
  var title: String
  var transfer: GitTransferProgress?
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
    state = OperationState(title: title)
    if observed { center?.begin(id: id, kind: kind, repositoryID: repositoryID, identity: repositoryIdentity?(), cancel: cancellable ? cancelOperation : nil) }
    return ticket
  }
  func advance(_ title: String, cancellable: Bool? = nil, phase: WorkflowOperationPhase = .executing) {
    stage += 1
    if let cancellable { canCancel = cancellable }
    state = OperationState(title: title)
    center?.update(id, cancellable: canCancel, phase: phase)
  }
  func markRunning() { center?.update(id, state: .running) }
  func receiver() -> @Sendable (GitTransferProgress) -> Void {
    let expected = ticket
    return { [weak self] progress in
      Task { @MainActor [weak self] in
        guard let self, self.ticket == expected, self.state?.result == .running else { return }
        self.state?.transfer = progress
        self.center?.update(expected.id, transfer: progress)
      }
    }
  }
  func finish(_ result: OperationResult, ticket expected: OperationTicket, waitingForUser: Bool = false) {
    guard id == expected.id, state?.result == .running else { return }
    state?.title = originalTitle
    state?.result = result
    state?.transfer = nil
    canCancel = false
    let outcome: WorkflowOperationState
    switch result {
    case .running: return
    case .succeeded: outcome = .succeeded
    case .failed: outcome = .failed
    case .cancelled: outcome = .cancelled
    case .needsAttention: outcome = waitingForUser ? .waitingForUser : .needsAttention
    }
    center?.update(id, state: outcome)
    let completed = id
    dismissal = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(result == .succeeded ? 1.5 : 3)) } catch { return }
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
        Text(label(state)).lineLimit(1).truncationMode(.middle).frame(
          maxWidth: 240, alignment: .leading)
        OperationBar(
          value: state.result == .running
            ? state.transfer?.fraction : state.result == .succeeded ? 1 : 0
        )
        .frame(width: 100, height: 8)
        if state.result == .running && progress.canCancel {
          Button(action: cancel) { Image(systemName: "xmark.circle") }.buttonStyle(.workspace)
            .help(store.text("Cancel operation", "取消操作"))
        }
      }.font(.system(size: 10)).foregroundStyle(
        state.result == .failed
          ? Color.red : state.result == .needsAttention ? Color.orange : Color.secondary
      )
      .accessibilityElement(children: .contain).accessibilityIdentifier(
        "gitpier.operation.progress")
    }
  }
  func label(_ state: OperationState) -> String {
    switch state.result {
    case .succeeded: return state.title + store.text(" · Completed", " · 已完成")
    case .needsAttention: return state.title + store.text(" · Needs attention", " · 需要处理")
    case .failed: return state.title + store.text(" · Failed", " · 失败")
    case .cancelled: return state.title + store.text(" · Cancelled", " · 已取消")
    case .running:
      guard let transfer = state.transfer else { return state.title }
      let phase: String
      switch transfer.phase {
      case .counting: phase = store.text("Counting", "统计对象")
      case .compressing: phase = store.text("Compressing", "压缩对象")
      case .receiving: phase = store.text("Receiving", "接收对象")
      case .resolving: phase = store.text("Resolving", "整理差异")
      case .writing: phase = store.text("Writing", "写入对象")
      case .checkout: phase = store.text("Updating files", "更新文件")
      }
      return state.title + " · " + phase + " \(Int(transfer.fraction * 100))%"
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
    view.setAccessibilityLabel("Git operation progress")
    return view
  }
  func updateNSView(_ view: NSProgressIndicator, context: Context) {
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
