import GitPierCore
import SwiftUI

@MainActor private final class HostingReviewInboxModel: ObservableObject {
  @Published var items: [HostingReviewDashboardItem] = []
  @Published var loading = false
  @Published var error: String?
  @Published var nextPage: Int?
  @Published var fetchedAt: Date?
  @Published var incomplete = false
  private let cache = HostingReviewDashboardCache()
  private var generation = UUID()
  private var task: Task<Void, Never>?
  func reset() { generation = UUID(); task?.cancel(); task = nil; loading = false; items = []; error = nil; nextPage = nil; fetchedAt = nil; incomplete = false }
  func load(hosting: HostingModel, account: HostingAccount, kind: HostingReviewDashboardKind, more: Bool = false, refresh: Bool = false) {
    let page = more ? nextPage ?? 1 : 1
    if !more { reset() }
    let ticket = UUID(); generation = ticket; task?.cancel(); loading = true; error = nil
    task = Task {
      defer { if generation == ticket { loading = false; task = nil } }
      do {
        guard hosting.account(account.id) == account else { throw HostingError.accountChanged }
        let result: HostingReviewDashboardPage
        if !refresh, let existing = await cache.get(account: account, kind: kind, page: page) { result = existing }
        else {
          let tokens = hosting.tokens, api = hosting.api, budget = hosting.networkBudget
          result = try await hosting.performAPI(account: account) {
            let token = try await tokens.token(for: account)
            return try await budget.perform { try await api.reviewDashboard(account: account, token: token, kind: kind, page: page) }
          }
          try Task.checkCancellation()
          guard hosting.account(account.id) == account else { throw HostingError.accountChanged }
          await cache.put(result, account: account, kind: kind, page: page)
        }
        try Task.checkCancellation()
        guard generation == ticket, hosting.account(account.id) == account else { return }
        let known = Set(items.map(\.id)); items += result.items.filter { !known.contains($0.id) }
        nextPage = result.nextPage; fetchedAt = result.fetchedAt; incomplete = incomplete || result.incomplete
      } catch is CancellationError {} catch { if generation == ticket { self.error = hosting.message(error) } }
    }
  }
}

/// Explicit account-wide inbox. Merely rendering a Dashboard or opening this sheet sends no API call.
struct HostingReviewDashboardView: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var hosting: HostingModel
  var onOpen: ((HostingReviewDashboardItem) -> Void)? = nil
  @StateObject private var inbox = HostingReviewInboxModel()
  @State private var accountID: UUID?
  @State private var kind = HostingReviewDashboardKind.requestedReviews
  private var account: HostingAccount? { accountID.flatMap { hosting.account($0) } }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      Text(store.text("Account-wide platform results, including repositories outside this workspace. Queries run only when you choose Load. No Git Fetch or repository scan.", "显示整个平台账号的结果，包含当前工作空间之外的仓库。仅点击加载后查询，不执行 Git Fetch 或仓库扫描。"))
        .font(.callout).foregroundStyle(.secondary)
      queryControls
      providerExplanation
      queryStatus
      requestList
      if inbox.nextPage != nil { Button(store.text("Load More", "加载更多")) { if let account { inbox.load(hosting: hosting, account: account, kind: kind, more: true) } }.disabled(inbox.loading) }
    }.padding(20).frame(minWidth: 780, idealWidth: 960, minHeight: 440, idealHeight: 620)
      .onChange(of: accountID) { _, _ in inbox.reset() }.onChange(of: kind) { _, _ in inbox.reset() }
      .onChange(of: hosting.revision) { _, _ in inbox.reset() }.onDisappear { inbox.reset() }
  }
  private var header: some View {
    HStack {
      Text(store.text("Account Review Inbox", "账号审查收件箱")).font(.title2.weight(.semibold))
      Spacer()
      Button(store.text("Done", "完成")) { dismiss() }
    }
  }
  private var accountPicker: some View {
    Picker(store.text("Account", "账号"), selection: $accountID) {
      Text(store.text("Select Account", "选择账号")).tag(UUID?.none)
      ForEach(hosting.metadata.accounts) { account in
        Text(accountLabel(account)).tag(Optional(account.id))
      }
    }.frame(maxWidth: 420)
  }
  private func accountLabel(_ account: HostingAccount) -> String {
    let provider = account.instance.provider.title
    let host = account.instance.baseURL.host ?? ""
    return "\(provider) · @\(account.user.login) · \(host)"
  }
  private var filterPicker: some View {
    Picker(store.text("Filter", "筛选"), selection: $kind) {
      Text(store.text("Review Requested", "请求我审查")).tag(HostingReviewDashboardKind.requestedReviews)
      Text(store.text("My Open PR / MR", "我打开的 PR / MR")).tag(HostingReviewDashboardKind.myOpenRequests)
    }.frame(maxWidth: 260)
  }
  private var queryControls: some View {
    HStack {
      accountPicker
      filterPicker
      Button(store.text("Load", "加载")) { if let account { inbox.load(hosting: hosting, account: account, kind: kind) } }
        .disabled(inbox.loading || account == nil || account?.instance.provider == .gitea)
      Button { if let account { inbox.load(hosting: hosting, account: account, kind: kind, refresh: true) } } label: { Image(systemName: "arrow.clockwise") }
        .disabled(inbox.loading || account == nil || account?.instance.provider == .gitea)
    }
  }
  @ViewBuilder private var providerExplanation: some View {
    if let account, account.instance.provider == .gitea {
      Text(store.text("This Gitea instance has no verified account-wide review query. Open its dashboard in your browser.", "尚未验证此 Gitea 实例的账号级待审查查询，请在浏览器中查看平台工作台。"))
      Link(store.text("Open Platform", "打开平台"), destination: account.instance.baseURL)
    }
    if account?.instance.provider == .gitlab, kind == .requestedReviews {
      Text(store.text("GitLab lists open merge requests where this account is assigned as a reviewer; it does not mean every item is unreviewed.", "GitLab 列出当前账号被分配为审查者的打开 MR，不代表每一项都尚未审查。"))
        .font(.caption).foregroundStyle(.secondary)
    }
  }
  @ViewBuilder private var queryStatus: some View {
    if let error = inbox.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
    if inbox.incomplete { Text(store.text("The provider returned a partial or capped search snapshot. Open the platform to see more.", "平台返回了不完整或达到上限的查询快照，请在平台查看完整结果。")) .font(.caption).foregroundStyle(.orange) }
    if let date = inbox.fetchedAt { Text(store.text("Platform snapshot: ", "平台快照时间：") + date.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary) }
    if inbox.loading { ProgressView().controlSize(.small) }
  }
  private var requestList: some View {
    List(inbox.items) { item in requestRow(item) }
  }
  private func requestRow(_ item: HostingReviewDashboardItem) -> some View {
    let title: String = "\(item.repository) #\(item.number) · \(item.title)"
    let subtitle: String = "@\(item.author) · \(item.updatedAt)"
    return HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).fontWeight(.medium)
        Text(subtitle).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if let onOpen, hosting.metadata.bindings.contains(where: { $0.accountID == item.accountID && $0.repository == item.repository }),
        hosting.account(item.accountID)?.instance == item.instance {
        Button(store.text("Open in GitPier", "在 GitPier 中打开")) { onOpen(item) }
      }
      Link(store.text("Open in Browser", "在浏览器中打开"), destination: item.webURL)
    }.padding(.vertical, 5)
  }
}

/// Place beside a Hosting repository's existing controls. The caller chooses its native navigation.
struct HostingCurrentBranchShortcut: View {
  @EnvironmentObject var store: AppStore
  @ObservedObject var hosting: HostingModel
  @ObservedObject var model: RepositoryModel
  let binding: RepositoryHostingBinding
  let account: HostingAccount
  let onOpen: (HostingPullRequest) -> Void
  @State private var task: Task<Void, Never>?
  @State private var generation = UUID()
  @State private var loading = false
  @State private var matches: [HostingPullRequest] = []
  @State private var explanation: String?
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Button(store.text("Find Current Branch PR / MR", "查找当前分支的 PR / MR")) { find() }.disabled(loading)
        if loading { ProgressView().controlSize(.small) }
        ForEach(matches) { request in Button("#\(request.number)") { open(request) }.disabled(loading) }
      }
      if let explanation { Text(explanation).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
      if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
    }.onDisappear { generation = UUID(); task?.cancel(); task = nil; loading = false }
      .onChange(of: model.status.head) { _, _ in generation = UUID(); task?.cancel(); loading = false; matches = []; explanation = nil }
      .onChange(of: model.status.branch) { _, _ in generation = UUID(); task?.cancel(); loading = false; matches = []; explanation = nil }
      .onChange(of: hosting.revision) { _, _ in generation = UUID(); task?.cancel(); loading = false; matches = []; explanation = nil }
  }
  private func snapshot() async throws -> HostingCurrentBranchSnapshot {
    let account = account, binding = binding
    guard hosting.account(account.id) == account, hosting.binding(binding.id) == binding else { throw HostingError.accountChanged }
    let git = await model.git(), status = try await git.status(localOnly: true), remotes = try await git.remotes()
    guard let remote = remotes.first(where: { $0.name == binding.remote }),
      let source = HostingRemoteParser.repository(remote.fetchURL, instance: account.instance) else { throw HostingReviewError.targetChanged }
    let sourceID: String
    if account.instance.provider == .gitlab {
      let tokens = hosting.tokens, api = hosting.api, budget = hosting.networkBudget
      sourceID = try await hosting.performAPI(account: account) {
        let token = try await tokens.token(for: account)
        return try await budget.perform { try await api.reviewSourceRepositoryID(source, account: account, token: token) }
      }
    } else { sourceID = "" }
    return try HostingCurrentBranchSnapshot(account: account, branch: status.branch, head: status.head,
      sourceRemoteURL: remote.fetchURL, sourceRepositoryID: sourceID)
  }
  private func find() {
    let hosting = hosting, account = account, binding = binding
    task?.cancel(); let ticket = UUID(); generation = ticket; loading = true; matches = []; error = nil; explanation = nil
    task = Task {
      defer { if generation == ticket { loading = false; task = nil } }
      do {
        let local = try await snapshot()
        var page = 1, differs = false
        while page <= 20 {
          let currentPage = page
          let result = try await hosting.networkBudget.perform { try await hosting.requests(binding, account: account, filter: .open, page: currentPage, refresh: true) }
          try Task.checkCancellation(); guard generation == ticket else { return }
          let exact = result.items.filter { local.matches($0, account: account) }
          differs = differs || result.items.contains { local.sameSource($0, account: account) }
          if !exact.isEmpty { matches = exact; break }
          guard let next = result.nextPage, next > page else { break }; page = next
        }
        let current = try await model.git().status(localOnly: true)
        guard current.branch == local.branch, current.head == local.head else { throw HostingReviewError.targetChanged }
        try Task.checkCancellation(); guard generation == ticket else { return }
        explanation = store.text("Local ", "本地 ") + local.branch + " · " + String(local.head.prefix(12)) + " · " + local.sourceRepository + " · "
          + (matches.isEmpty ? (differs ? store.text("The platform source has a different commit.", "平台来源分支的提交与本地不同。") : store.text("No exact source/commit match in the queried pages.", "已查询的页面中没有来源仓库与提交均匹配的请求。")) : store.text("Matches this platform snapshot; opening rechecks both sides.", "匹配当前平台快照；打开时会再次核对双方。"))
      } catch is CancellationError {} catch { if generation == ticket { self.error = hosting.message(error); matches = [] } }
    }
  }
  private func open(_ request: HostingPullRequest) {
    let account = account, binding = binding
    task?.cancel(); let ticket = UUID(); generation = ticket; loading = true; error = nil
    task = Task {
      defer { if generation == ticket { loading = false; task = nil } }
      do {
        let local = try await snapshot(), api = hosting.api, tokens = hosting.tokens, budget = hosting.networkBudget
        let fresh = try await hosting.performAPI(account: account) {
          let token = try await tokens.token(for: account)
          return try await budget.perform { try await api.request(binding, number: request.number, account: account, token: token) }
        }
        let current = try await model.git().status(localOnly: true)
        guard current.branch == local.branch, current.head == local.head, local.matches(fresh, account: account) else { throw HostingReviewError.revisionChanged }
        try Task.checkCancellation(); guard generation == ticket else { return }; onOpen(fresh)
      } catch is CancellationError {} catch { if generation == ticket { self.error = hosting.message(error); matches = [] } }
    }
  }
}

/// Reuse the existing BranchComparisonView after showing this explicit data-source boundary.
struct HostingLocalComparisonExplanation: View {
  @EnvironmentObject var store: AppStore
  var body: some View {
    Text(store.text("Read-only local branch comparison. Local branches and remote-tracking refs are stored on this Mac; remote-tracking refs reflect your last Fetch and are not live platform branches. This view does not Fetch, Push, switch branches or modify the Index.", "只读本地分支比较。本地分支及远程跟踪引用都保存在此 Mac；远程跟踪引用反映上次 Fetch 的结果，并非平台分支的实时状态。此页面不会 Fetch、Push、切换分支或修改 Index。"))
      .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
  }
}
