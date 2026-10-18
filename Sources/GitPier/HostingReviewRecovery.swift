import AppKit
import GitPierCore
import SwiftUI

extension HostingReviewSessionRegistry {
  /// Disk only. Launching, refreshing or opening this panel never obtains a token or sends a write.
  func refreshRecovery() async {
    let lifecycle = recoveryLifecycle, ticket = UUID()
    recoveryTicket = ticket
    do {
      let records = try await coordinator.recoveredOperations()
      let failed = await coordinator.recoveryFailure()
      guard recoveryLifecycle == lifecycle, recoveryTicket == ticket else { return }
      let groups = Dictionary(grouping: records, by: \.confirmationID).values.sorted { lhs, rhs in
        let leftUnknown = lhs.contains(where: \.isUnresolved), rightUnknown = rhs.contains(where: \.isUnresolved)
        if leftUnknown != rightUnknown { return leftUnknown }
        return (lhs.first?.startedAt ?? .distantPast) > (rhs.first?.startedAt ?? .distantPast)
      }
      recoveredOperations = groups.flatMap { $0.sorted { $0.sequence < $1.sequence } }
      recoveryError = failed ? HostingReviewJournalError.corrupt.localizedDescription : nil
    } catch {
      guard recoveryLifecycle == lifecycle, recoveryTicket == ticket else { return }
      recoveryError = error.localizedDescription
    }
    operationCenter?.reconcileJournal(recoveredOperations)
    for session in Array(sessions.values) { await session.refreshBlockState() }
  }
  var unresolvedOperations: [HostingReviewOperationRecord] { recoveredOperations.filter(\.isUnresolved) }
  func acknowledgeRecovery(_ record: HostingReviewOperationRecord) async {
    guard !recovering else { return }
    recovering = true; defer { recovering = false }
    recoveryActionError = nil
    do {
      try await coordinator.ackRecoveredOperation(record.id)
      recoveryEvidence[record.id] = nil
    } catch { recoveryActionError = error.localizedDescription }
    await refreshRecovery()
  }
  func clearCompletedHistory() async {
    guard !recovering else { return }
    recovering = true; defer { recovering = false }
    recoveryActionError = nil
    do { try await coordinator.pruneCompletedOperations() }
    catch { recoveryActionError = error.localizedDescription }
    await refreshRecovery()
  }
  /// The user selects a saved binding. Stable IDs must match before any receipt is inspected.
  /// A metadata inspection cannot prove an unsaved body or anchor, so it never clears Unknown.
  func inspectRecovery(_ record: HostingReviewOperationRecord, binding: RepositoryHostingBinding, hosting: HostingModel) async {
    guard !recovering, let account = hosting.account(record.identity.accountID),
      account.instance == record.identity.instance, account.user.stableID == record.identity.userID,
      binding.accountID == account.id, hosting.binding(binding.id) == binding else { return }
    recovering = true; defer { recovering = false }
    let lifecycle = recoveryLifecycle
    do {
      let api = hosting.api, tokens = hosting.tokens
      let receipt = try await coordinator.inspectRecoveredReceipt(record.id,
        validate: { @MainActor [weak self] in
          guard self?.recoveryLifecycle == lifecycle, hosting.account(account.id) == account,
            hosting.binding(binding.id) == binding else { throw HostingError.accountChanged }
        }, readback: { [weak self] value in
          guard let self else { throw HostingError.accountChanged }
          try await self.validateRecoveryLifecycle(lifecycle)
          let token = try await tokens.token(for: account)
          try await self.validateRecoveryLifecycle(lifecycle)
          return try await hosting.performAPI(account: account) {
            let context = try await api.reviewContext(binding, number: value.identity.requestNumber, account: account, token: token)
            guard value.identity.matches(context.target), context.revision == value.revision.value else { throw HostingReviewError.targetChanged }
            return try await api.readRecoveredReviewReceipt(record: value, context: context, account: account, token: token)
          }
        })
      guard recoveryLifecycle == lifecycle else { return }
      recoveryEvidence[record.id] = hosting.store.text("Receipt metadata located: ", "已定位结果元数据：") + receipt.id
        + hosting.store.text(". The unsaved body and code position cannot be restored or fully verified. Check the platform before acknowledging.", "。未保存的正文与代码位置无法恢复或完整验证，请在平台核实后再确认。")
    } catch {
      guard recoveryLifecycle == lifecycle else { return }
      recoveryEvidence[record.id] = hosting.message(error)
    }
    await refreshRecovery()
  }
  private func validateRecoveryLifecycle(_ lifecycle: UUID) throws {
    guard recoveryLifecycle == lifecycle else { throw HostingError.accountChanged }
    try Task.checkCancellation()
  }
}

struct HostingReviewRecoveryBanner: View {
  @EnvironmentObject var store: AppStore
  @ObservedObject var registry: HostingReviewSessionRegistry
  @State private var presented = false
  var body: some View {
    Group {
      if registry.recoveryError != nil || !registry.unresolvedOperations.isEmpty {
        HStack(alignment: .center, spacing: 10) {
          Label(registry.recoveryError != nil
            ? store.text("Review operation history needs attention. New review writes are blocked.", "审查操作日志需要处理，新的审查写入已被阻止。")
            : store.text("Remote review operations need checking", "存在尚未核实的远端审查操作") + " (\(registry.unresolvedOperations.count))",
            systemImage: "exclamationmark.bubble")
          Spacer()
          Button(store.text("Check Operations…", "核实操作…")) { presented = true }
            .accessibilityIdentifier("hosting.review.recovery.open")
        }.font(.callout).padding(10).background(Color.orange.opacity(0.12))
        Divider()
      }
    }
    .sheet(isPresented: $presented) {
      HostingReviewRecoveryView(registry: registry, hosting: store.hosting).environmentObject(store)
    }
  }
}

struct HostingReviewRecoveryView: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var registry: HostingReviewSessionRegistry
  @ObservedObject var hosting: HostingModel
  @State private var acknowledging: HostingReviewOperationRecord?
  @State private var clearing = false
  @State private var visibleCount = 50
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(store.text("Review Operation History", "审查操作日志")).font(.title2.weight(.semibold))
      Text(store.text("Only write intent and receipt metadata are saved. Comment bodies, code and full drafts are not persisted. Nothing is resent after restart.", "仅保存写入意图与结果元数据，不保存评论正文、代码或完整草稿。重启后不会重新发送任何操作。"))
        .font(.callout).foregroundStyle(.secondary)
      if let error = registry.recoveryError {
        Text(store.text("Recovery failed. Preserve the original journal files, restore disk access or recover the files from backup, then reload. Credentials are kept separately.", "恢复失败。请保留原始日志，恢复磁盘访问或从备份恢复文件后重新加载。凭证独立保存。") + "\n" + error)
          .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
      }
      if let error = registry.recoveryActionError { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(Array(registry.recoveredOperations.prefix(visibleCount))) { record in
            HostingReviewRecoveryRow(record: record, registry: registry, hosting: hosting) { acknowledging = record }
          }
          if registry.recoveredOperations.count > visibleCount {
            Button(store.text("Load More", "加载更多")) { visibleCount += 50 }
          }
          if registry.recoveredOperations.isEmpty && registry.recoveryError == nil {
            Text(store.text("No saved review operations.", "没有已保存的审查操作。"))
          }
        }.padding(6)
      }
      HStack {
        Button(store.text("Reload", "重新加载")) { Task { await registry.refreshRecovery() } }.disabled(registry.recovering)
        Button(store.text("Show Journal in Finder", "在 Finder 显示日志")) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: registry.journalURL.path) }
        Button(store.text("Clear Completed History…", "清理已完成日志…")) { clearing = true }
          .disabled(registry.recovering || registry.recoveryError != nil)
        Spacer()
        Button(store.text("Close", "关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
      }.controlSize(.small)
    }.padding(22).frame(minWidth: 720, idealWidth: 780, maxWidth: 900, minHeight: 440, idealHeight: 560, maxHeight: 680)
      .task { await registry.refreshRecovery() }
      .alert(store.text("Acknowledge the platform check?", "确认已核实平台？"), isPresented: Binding(get: { acknowledging != nil }, set: { if !$0 { acknowledging = nil } })) {
        Button(store.text("Cancel", "取消"), role: .cancel) { acknowledging = nil }
        Button(store.text("I Checked the Platform", "我已在平台核实")) {
          if let record = acknowledging { Task { await registry.acknowledgeRecovery(record) } }
          acknowledging = nil
        }
      } message: {
        Text(store.text("This only removes GitPier's unknown-result block for this operation. It does not prove that the previous write failed. Remove already published content from any in-memory draft. A new submission requires a new preview and confirmation; no request is retried.", "此操作只解除 GitPier 对该操作的未知结果阻止，不代表之前的远端写入没有成功。请从内存草稿中移除已经发布的内容。新的提交仍需重新预览和确认，不会重试任何请求。"))
      }
      .alert(store.text("Clear completed operation history?", "清理已完成操作日志？"), isPresented: $clearing) {
        Button(store.text("Cancel", "取消"), role: .cancel) {}
        Button(store.text("Clear Completed", "清理已完成记录")) { Task { await registry.clearCompletedHistory() } }
      } message: { Text(store.text("Only batches with no unresolved operations are removed. Unknown results are retained regardless of age.", "仅移除没有待核实操作的批次。未知结果不会因时间推移而删除。")) }
  }
}

private struct HostingReviewRecoveryRow: View {
  @EnvironmentObject var store: AppStore
  let record: HostingReviewOperationRecord
  @ObservedObject var registry: HostingReviewSessionRegistry
  @ObservedObject var hosting: HostingModel
  let acknowledge: () -> Void
  @State private var bindingID: UUID?
  private var bindings: [RepositoryHostingBinding] { hosting.metadata.bindings.filter { $0.accountID == record.identity.accountID } }
  private var binding: RepositoryHostingBinding? { bindings.first { $0.id == bindingID } ?? (bindings.count == 1 ? bindings.first : nil) }
  private var matchingSession: HostingReviewSession? { registry.sessions.values.first { $0.context.map { record.identity.matches($0.target) } == true } }
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(record.identity.instance.provider.title + " · #\(record.identity.requestNumber) · " + operationTitle).font(.headline)
      Text(record.identity.instance.baseURL.absoluteString).font(.caption).textSelection(.enabled)
      Text(store.text("Account ", "账号 ") + (hosting.account(record.identity.accountID).map { "@" + $0.user.login } ?? record.identity.accountID.uuidString)
        + " · " + store.text("Repository ID ", "仓库 ID ") + record.identity.repositoryID + " · " + store.text("Request ID ", "请求 ID ") + record.identity.requestID)
        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      Text(record.startedAt.formatted(date: .abbreviated, time: .standard) + " · " + stateTitle)
        .font(.callout).foregroundStyle(record.isUnresolved ? Color.orange : Color.secondary)
      if let receipt = record.receipt { Text(store.text("Receipt ID: ", "结果 ID：") + receipt.id).font(.caption).textSelection(.enabled) }
      if record.isUnresolved {
        Text(store.text("A remote write needs checking. Its comment body was not persisted on this Mac.", "存在需要核实的远端写入，评论正文未在本机持久化。"))
          .font(.caption).foregroundStyle(.secondary)
        if record.receipt != nil, !bindings.isEmpty {
          if bindings.count > 1 {
            Picker(store.text("Saved repository binding", "已保存的仓库关联"), selection: $bindingID) {
              Text(store.text("Choose repository…", "选择仓库…")).tag(nil as UUID?)
              ForEach(bindings) { value in Text(value.repository).tag(Optional(value.id)) }
            }
          }
          Button(store.text("Inspect Known Receipt (Read Only)", "只读回查已知结果")) {
            if let binding { Task { await registry.inspectRecovery(record, binding: binding, hosting: hosting) } }
          }.disabled(registry.recovering || binding == nil)
        }
        HStack {
          Link(store.text("Check in Browser", "在浏览器中核实"), destination: matchingSession?.context?.webURL ?? record.identity.instance.baseURL)
          Button(store.text("I Checked the Platform…", "我已在平台核实…"), action: acknowledge).disabled(registry.recovering)
            .accessibilityLabel(store.text("I Checked the Platform…", "我已在平台核实…"))
            .accessibilityIdentifier("hosting.review.recovery.ack." + record.id.uuidString)
        }.font(.caption)
      }
      if let evidence = registry.recoveryEvidence[record.id] { Text(evidence).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("hosting.review.recovery." + record.id.uuidString)
  }
  private var operationTitle: String {
    switch record.operation.kind {
    case .comment: store.text("Comment", "评论")
    case .inline: store.text("Inline Comment", "逐行评论")
    case .reply: store.text("Reply", "回复")
    case .review, .submitPending:
      switch record.operation.expectedState {
      case .pending: store.text("Save Pending Review", "保存待定审查")
      case .approved: store.text("Approve Review", "批准审查")
      case .changesRequested: store.text("Request Changes", "请求更改")
      default: store.text("Comment Review", "评论审查")
      }
    case .resolve: record.operation.resolved == true ? store.text("Resolve Discussion", "解决讨论") : store.text("Unresolve Discussion", "重新打开讨论")
    case .requestReviewers: store.text("Reviewer Request", "审查者请求")
    }
  }
  private var stateTitle: String {
    switch record.state {
    case .notSent: store.text("Not Sent — body was not saved", "未发送，正文未保存")
    case .possiblySent, .resultUnknown: store.text("Result Unknown — check the platform", "结果未知，请核实平台")
    case .submittedAndVerified: store.text("Submitted and Verified", "已提交并验证")
    case .definitelyFailedBeforeSend: store.text("Stopped Before Send", "发送前已停止")
    case .definitelyRejected: store.text("Rejected by Platform", "平台已拒绝")
    case .manuallyAcknowledged: store.text("Manually Checked — no retry performed", "已人工核实，未重试请求")
    }
  }
}
