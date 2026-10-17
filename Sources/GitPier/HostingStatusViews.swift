import GitPierCore
import SwiftUI

@MainActor func hostingCITitle(_ state: HostingCIState, store: AppStore) -> String {
  switch state { case .pending: store.text("Pending", "等待中"); case .running: store.text("Running", "运行中"); case .success: store.text("Success", "成功"); case .failed: store.text("Failed", "失败"); case .cancelled: store.text("Cancelled", "已取消"); case .skipped: store.text("Skipped", "已跳过"); case .unknown: store.text("Unknown", "未知"); case .noChecks: store.text("No Checks", "无检查") }
}
struct HostingRequestStatusLine: View {
  @EnvironmentObject var store: AppStore
  @ObservedObject var hosting: HostingModel
  let binding: RepositoryHostingBinding
  let account: HostingAccount
  let request: HostingPullRequest
  @State private var summary: HostingRequestSignals?
  @State private var error: String?
  var body: some View {
    Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(label)
      .task(id: request.sha + request.updatedAt) {
        do { summary = try await hosting.signals(request, binding: binding, account: account) }
        catch is CancellationError {} catch { self.error = hosting.message(error) }
      }
  }
  var label: String {
    if let error { return error }
    guard let summary else { return store.text("Reviews / CI: loading…", "审查 / CI：加载中…") }
    let review: String
    if let e = summary.reviewError { review = hosting.message(e) }
    else if summary.reviewStates.contains(where: { $0.uppercased() == "CHANGES_REQUESTED" || $0 == "REQUEST_CHANGES" }) { review = store.text("Changes requested", "要求修改") }
    else if summary.reviewStates.contains(where: { $0.uppercased() == "APPROVED" }) { review = store.text("Approved", "已批准") }
    else { review = store.text("No approval reported", "暂无批准记录") }
    return review + " · CI: " + (summary.ciError.map { hosting.message($0) } ?? hostingCITitle(summary.ciState, store: store))
  }
}

struct HostingDashboardBadge: View {
  @EnvironmentObject var store: AppStore
  @ObservedObject var hosting: HostingModel
  let recordID: UUID
  let branch: String
  let head: String?
  let snapshotRevision: Date?
  @State private var label = ""
  @State private var expiresAt = Date.distantPast
  var body: some View {
    Group { if !label.isEmpty { Text(label).font(uiFont(size: 10)).foregroundStyle(.secondary).lineLimit(1).help(label) } }
      .task(id: "\(recordID)|\(hosting.revision)|\(snapshotRevision?.timeIntervalSince1970 ?? 0)|" + (head ?? "")) {
        label = ""
        guard let binding = hosting.binding(recordID), let account = hosting.account(binding.accountID), hosting.states[account.id] == .connected else { return }
        do {
          // Only a list page and exact-HEAD checks; no request details or local Git operations.
          let result = try await hosting.networkBudget.perform { try await hosting.requests(binding, account: account, filter: .open, page: 1, refresh: false) }
          try Task.checkCancellation()
          var text = (account.instance.provider == .gitlab ? "MR " : "PR ") + String(result.items.count) + (result.nextPage == nil ? "" : "+")
          // A list row has no verified local source-repository identity. Exact current-branch
          // shortcuts are resolved only by the explicit, source-aware action in the Hosting page.
          if let head {
            do {
              let token = try await hosting.tokens.token(for: account), api = hosting.api
              let budget = hosting.networkBudget
              let checks = try await hosting.performAPI(account: account) { try await budget.perform { try await api.checks(binding, sha: head, account: account, token: token) } }
              var signals = HostingRequestSignals(); signals.checks = checks
              text += " · CI: " + hostingCITitle(signals.ciState, store: store)
            } catch is CancellationError { throw CancellationError() }
              catch { text += " · CI: " + hosting.message(error); await hosting.failed(error, account: account) }
          }
          try Task.checkCancellation(); label = text
        } catch is CancellationError {} catch { label = "" }
      }
  }
}
