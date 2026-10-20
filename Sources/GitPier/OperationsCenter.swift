import AppKit
import GitPierCore
import SwiftUI

@MainActor final class OperationsCenter: ObservableObject {
  @Published private(set) var history = OperationCenterHistory()
  private var fetchAttempts: [String: UUID] = [:]
  private var cancellations: [UUID: () -> Void] = [:]
  private var taskIDs: [UUID: UUID] = [:]
  func linkTask(_ operationID: UUID, taskID: UUID) { taskIDs[operationID] = taskID; pruneCallbacks() }
  func taskID(_ operationID: UUID) -> UUID? { taskIDs[operationID] }
  var records: [WorkflowOperationRecord] { history.records }
  var activeCount: Int { records.filter { $0.state.active }.count }
  func begin(id: UUID, kind: WorkflowOperationKind, repositoryID: UUID?,
    state: WorkflowOperationState = .queued, started: Date = Date(), identity: OperationRepositoryIdentity? = nil, cancel: (() -> Void)? = nil) {
    guard !records.contains(where: { $0.id == id }) else { return }
    if let repositoryID {
      for waiting in records where waiting.repositoryID == repositoryID && waiting.state == .waitingForUser {
        update(waiting.id, state: .needsAttention)
      }
    }
    if kind == .automaticFetch, let repositoryID { history.coalesceAutomatic(repositoryID: repositoryID) }
    cancellations[id] = cancel
    var record = WorkflowOperationRecord(id: id, kind: kind, repositoryID: repositoryID,
      startedAt: started, state: state, canCancel: cancel != nil)
    record.repositoryIdentity = identity
    record.phase = state == .queued ? .queued : .executing
    history.insert(record)
    pruneCallbacks()
  }
  func update(_ id: UUID, state: WorkflowOperationState? = nil, transfer: GitTransferProgress? = nil,
    cancellable: Bool? = nil, phase: WorkflowOperationPhase? = nil, recovery: OperationRecoveryAction? = nil) {
    guard var record = records.first(where: { $0.id == id }), !record.state.finished else { return }
    if let state { record.state = state; record.phase = state.active ? (state == .queued ? .queued : .executing) : state == .resultUnknown ? .verification : .completed }
    if let phase { record.phase = phase; record.progress = nil; record.transferPhase = nil }
    if let transfer { record.progress = transfer.fraction; record.transferPhase = transfer.phase; record.phase = .transferring }
    if let cancellable { record.canCancel = cancellable && cancellations[id] != nil }
    if let recovery { record.recovery = recovery }
    if record.cancellationRequested && record.state.active { record.phase = .cancelling; record.canCancel = false }
    if !record.state.active { cancellations[id] = nil; record.canCancel = false }
    if record.state.finished { record.completedAt = Date() }
    record.revision += 1
    history.update(record)
    pruneCallbacks()
  }
  func cancel(_ id: UUID) {
    guard var record = records.first(where: { $0.id == id }), record.state.active,
      record.canCancel, !record.cancellationRequested, let cancel = cancellations[id] else { return }
    record.cancellationRequested = true; record.phase = .cancelling; record.canCancel = false; record.revision += 1
    history.update(record)
    cancel()
  }
  private func pruneCallbacks() {
    let active = Set(records.filter { $0.state.active }.map(\.id))
    cancellations = cancellations.filter { active.contains($0.key) }
    let retained = Set(records.map(\.id)); taskIDs = taskIDs.filter { retained.contains($0.key) }
  }
  func observe(_ job: WorkspaceFetchJob, cancel: @escaping () -> Void) {
    if fetchAttempts[job.id] == job.attemptID && !records.contains(where: { $0.id == job.attemptID }) { return }
    fetchAttempts[job.id] = job.attemptID
    begin(id: job.attemptID, kind: job.automatic ? .automaticFetch : .batchFetch,
      repositoryID: job.target.record.id, started: job.startedAt, identity: OperationRepositoryIdentity(workingTree: job.target.record.path, commonDirectory: job.target.commonDirectory), cancel: cancel)
    let state: WorkflowOperationState
    switch job.state {
    case .queued: state = .queued
    case .running: state = .running
    case .succeeded: state = .succeeded
    case .failed: state = .failed
    case .cancelled: state = .cancelled
    }
    update(job.attemptID, state: state, recovery: job.authenticationFailure == nil ? .repository : .credentials)
  }
  func reconcileJournal(_ values: [HostingReviewOperationRecord]) {
    for group in Dictionary(grouping: values, by: \.confirmationID).values {
      guard let first = group.first else { continue }
      if records.contains(where: { $0.id == first.confirmationID && $0.state.active }) { continue }
      let state: WorkflowOperationState = group.contains(where: \.isUnresolved) ? .resultUnknown : group.allSatisfy { $0.state == .submittedAndVerified } ? .succeeded : .needsAttention
      var record = WorkflowOperationRecord(id: first.confirmationID, kind: .review,
        repositoryID: nil, startedAt: first.startedAt, state: state, recovery: .reviewJournal)
      record.phase = state == .resultUnknown ? .verification : .completed
      record.completedAt = state == .resultUnknown ? nil : group.map(\.updatedAt).max()
      history.reconcileReview(record)
    }
  }
}

struct OperationsCenterButton: View {
  @ObservedObject var center: OperationsCenter
  @EnvironmentObject var store: AppStore
  var body: some View {
    Button { store.showOperationsCenter = true } label: {
      Label("\(center.activeCount)", systemImage: "list.bullet.rectangle")
    }.help(store.text("Operations Center", "操作中心"))
      .accessibilityIdentifier("gitpier.operations.open")
  }
}
struct OperationsCenterView: View {
  @ObservedObject var center: OperationsCenter
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  var body: some View {
    let records = center.records
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text(store.text("Operations Center", "操作中心")).font(.title2.bold())
        Spacer()
        Button(store.text("Close", "关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
      }
      Text(store.text("Cancellation requests stop the running task when possible. Completed changes and remote writes may remain. Local tracking references are Fetch snapshots.", "取消请求会尽可能停止任务，已完成的修改或远程写入可能保留。远程跟踪引用来自 Fetch 快照。"))
        .font(.callout).foregroundStyle(.secondary)
      Text(store.text("Ordinary operations are kept for this session (up to 100 recent records). Review recovery is saved separately.", "普通操作仅保留本次会话，最近记录最多 100 条；审查恢复记录另行持久保存。"))
        .font(.caption).foregroundStyle(.secondary)
      ScrollView {
        // Separate section containers prevent lazy flattened ForEach identities
        // from reusing stale row content when an operation changes sections.
        VStack(alignment: .leading, spacing: 12) {
          section(store.text("Active", "正在执行"), records.filter { $0.state.active })
          section(store.text("Attention", "需要处理"), records.filter { $0.state.attention })
          section(store.text("Recent", "最近完成"), records.filter { !$0.state.active && !$0.state.attention })
        }
      }
    }.padding(22).frame(minWidth: 660, idealWidth: 760, minHeight: 440, idealHeight: 580)
      .background(Theme.editor(store.resolvedColorScheme))
      .accessibilityIdentifier("gitpier.operations.center")
  }
  private func section(_ title: String, _ values: [WorkflowOperationRecord]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
    Text(title).font(.headline)
    if values.isEmpty { Text(store.text("No operations", "暂无操作")).foregroundStyle(.secondary) }
    ForEach(values) { record in
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(operationTitle(record.kind, store: store)).fontWeight(.medium)
          Text(record.repositoryID.flatMap { id in store.repositories.first { $0.id == id }?.name } ?? (record.kind == .review ? store.text("Review history", "审查历史") : "GitPier")).foregroundStyle(.secondary).lineLimit(1)
          Spacer()
          Text(operationStateTitle(record, store: store)).foregroundStyle(record.state.attention ? Color.orange : Color.secondary)
          if record.state.active && record.canCancel && !record.cancellationRequested {
            Button(store.text("Cancel", "取消")) { center.cancel(record.id) }
          }
        }
        if record.state.active {
          if let transfer = record.transferPhase {
            Text(operationTransferTitle(transfer, store: store) + (record.progress.map { " \(Int($0 * 100))%" } ?? "")).font(.caption).foregroundStyle(.secondary)
          } else if record.phase == .refreshing { Text(store.text("Refreshing local status", "刷新本地状态")).font(.caption).foregroundStyle(.secondary) }
          OperationBar(value: record.progress).frame(height: 8)
        }
        HStack {
          Text(record.startedAt, style: .time).font(.caption).foregroundStyle(.secondary)
          Spacer()
          if let taskID = center.taskID(record.id) {
            Button(store.text("Open Task", "打开任务")) {
              dismiss(); Task {
                do { _ = try await store.taskWorkspaces.open(taskID, terminal: record.kind == .agentSession) }
                catch { store.error = error.localizedDescription }
              }
            }
            Button(store.text("Review Changes", "审查变更")) {
              dismiss(); Task {
                do { try await store.taskWorkspaces.review(taskID, baseline: true) }
                catch { store.error = error.localizedDescription }
              }
            }
          } else if record.recovery == .reviewJournal {
            Button(store.text("View Review History", "查看审查历史")) { dismiss(); store.showReviewRecovery = true }
          } else if record.repositoryID != nil {
            Button(store.text("Open Repository", "打开仓库")) {
              dismiss(); Task { await store.openOperation(record) }
            }
          }
        }
      }.padding(12).background(Color.secondary.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("gitpier.operation." + record.id.uuidString)
    }
    }
  }
}
@MainActor func operationTitle(_ kind: WorkflowOperationKind, store: AppStore) -> String {
  switch kind {
  case .git: return store.text("Git operation", "Git 操作")
  case .clone: return store.text("Clone", "克隆")
  case .fetch: return store.text("Fetch", "获取")
  case .batchFetch: return store.text("Batch Fetch", "批量获取")
  case .automaticFetch: return store.text("Automatic Fetch", "自动获取")
  case .pull: return store.text("Pull", "拉取")
  case .push: return store.text("Push", "推送")
  case .commit: return store.text("Commit", "提交")
  case .commitAndPush: return store.text("Commit & Push", "提交并推送")
  case .merge: return store.text("Merge", "合并")
  case .mergeAndPush: return store.text("Merge & Push", "合并并推送")
  case .rebase: return store.text("Rebase", "变基")
  case .createWorktree: return store.text("Create Worktree", "创建工作树")
  case .removeWorktree: return store.text("Remove Worktree", "移除工作树")
  case .review: return store.text("Submit Review", "提交审查")
  case .createTask: return store.text("Create Task Workspace", "创建任务工作空间")
  case .archiveTask: return store.text("Archive / Reopen Task", "归档 / 重新打开任务")
  case .reviewTask: return store.text("Review Task Changes", "审查任务变更")
  case .agentSession: return store.text("Codex Session", "Codex 会话")
  }
}
@MainActor func operationStateTitle(_ record: WorkflowOperationRecord, store: AppStore) -> String {
  if record.cancellationRequested && record.state.active { return store.text("Cancelling…", "取消中…") }
  switch record.state {
  case .queued: return store.text("Queued", "排队中")
  case .running: return store.text("Running", "执行中")
  case .waitingForUser: return store.text("Waiting for you", "等待用户操作")
  case .succeeded: return store.text("Succeeded", "成功")
  case .failed: return store.text("Failed · Open repository for details", "失败 · 打开仓库查看详情")
  case .cancelled: return store.text("Cancelled · changes may remain", "已取消 · 可能保留部分修改")
  case .needsAttention: return store.text("Needs attention", "需要处理")
  case .resultUnknown: return store.text("Result unknown · verify in Review history", "结果未知 · 请在审查历史核实")
  case .agentExited: return store.text("Agent exited · review changes and tests", "Agent 已退出 · 请审查变更及测试")
  }
}

@MainActor private func operationTransferTitle(_ phase: GitTransferPhase, store: AppStore) -> String {
  switch phase {
  case .counting: return store.text("Counting", "统计对象")
  case .compressing: return store.text("Compressing", "压缩对象")
  case .receiving: return store.text("Receiving", "接收对象")
  case .resolving: return store.text("Resolving", "整理差异")
  case .writing: return store.text("Writing", "写入对象")
  case .checkout: return store.text("Updating files", "更新文件")
  }
}
