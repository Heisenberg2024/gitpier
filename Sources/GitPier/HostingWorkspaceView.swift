import AppKit
import GitPierCore
import SwiftUI

struct HostingWorkspaceView: View {
  @EnvironmentObject var store: AppStore
  @ObservedObject var model: RepositoryModel
  @ObservedObject var hosting: HostingModel
  @State private var bindingSheet = false
  @State private var settingsSheet = false
  @State private var createSheet = false
  @State private var filter: HostingRequestFilter = .open
  @State private var items: [HostingPullRequest] = []
  @State private var selected: HostingPullRequest?
  @State private var nextPage: Int? = nil
  @State private var loading = false
  @State private var error: String?
  @State private var generation = UUID()
  @State private var requestTask: Task<Void, Never>?
  init(model: RepositoryModel) { self.model = model; hosting = model.store.hosting }
  var binding: RepositoryHostingBinding? { hosting.binding(model.record.id) }
  var account: HostingAccount? { binding.flatMap { hosting.account($0.accountID) } }
  var title: String { account?.instance.provider == .gitlab ? store.text("Merge Requests", "合并请求") : store.text("Pull Requests", "拉取请求") }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(title).font(.headline)
        Spacer()
        Button(store.text("Accounts…", "账号…")) { settingsSheet = true }
        Button(store.text("Repository Binding…", "仓库关联…")) { bindingSheet = true }
        if binding != nil {
          Button(store.text("Refresh", "刷新")) { load(reset: true, refresh: true) }.disabled(loading)
          Button(store.text("Create…", "创建…")) { createSheet = true }.disabled(account == nil || model.busy)
        }
      }.padding(12)
      Divider()
      if let binding, let account {
        HStack {
          Text(binding.repository + " · " + binding.remote + " · @" + account.user.login).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          Spacer()
          Picker(store.text("State", "状态"), selection: $filter) {
            ForEach(HostingRequestFilter.allCases, id: \.self) { Text(filterName($0)).tag($0) }
          }.labelsHidden().frame(width: 140)
        }.padding(.horizontal, 12).padding(.vertical, 8)
        if let error {
          HStack {
            Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            Spacer()
            Button(store.text("Verify / Reauthorize…", "验证 / 重新授权…")) { settingsSheet = true }
          }.padding(12)
        }
        if loading && items.isEmpty { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        else if items.isEmpty {
          ContentUnavailableView(store.text("No Requests", "暂无请求"), systemImage: "arrow.triangle.pull",
            description: Text(store.text("Choose a state or refresh. Platform failures leave local Git operations available.", "请选择状态或刷新。平台错误不影响本地 Git 操作。")))
        } else {
          HSplitView {
            List(selection: Binding(get: { selected?.number }, set: { id in selected = items.first { $0.number == id } })) {
              ForEach(items) { item in
                VStack(alignment: .leading, spacing: 6) {
                  HStack(alignment: .firstTextBaseline) {
                    Text("#\(item.number)").foregroundStyle(.secondary).monospacedDigit()
                    Text(item.title).fontWeight(.medium).lineLimit(2)
                    Spacer(minLength: 0)
                  }
                  Text("@" + item.author + " · " + (item.draft ? store.text("Draft", "草稿") : requestState(item.state))).font(.caption).foregroundStyle(.secondary)
                  Text(item.source + " → " + item.target).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                  Text(store.text("Updated ", "更新于 ") + item.updatedAt).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                  HostingRequestStatusLine(hosting: hosting, binding: binding, account: account, request: item)
                }.padding(.vertical, 5).tag(item.number)
              }
              if nextPage != nil { Button(store.text("Load More", "加载更多")) { load(reset: false, refresh: false) }.disabled(loading) }
            }.frame(minWidth: 240, idealWidth: 340, maxWidth: 420)
            if let selected {
              HostingRequestDetail(hosting: hosting, binding: binding, account: account, request: selected)
                .id("\(selected.number)|\(hosting.revision)|\(filter.rawValue)")
                .frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
            } else { ContentUnavailableView(store.text("Select a Request", "选择请求"), systemImage: "doc.text.magnifyingglass").frame(maxWidth: .infinity) }
          }
        }
      } else {
        ContentUnavailableView {
          Label(store.text("Connect a Hosting Repository", "关联托管仓库"), systemImage: "arrow.triangle.pull")
        } description: { Text(store.text("Choose an account, remote and repository. This does not change Git remotes, upstreams or credentials.", "请选择账号、Remote 和仓库。关联不会修改 Git Remote、Upstream 或凭证。")) }
        actions: { Button(store.text("Link Repository…", "关联仓库…")) { bindingSheet = true } }
      }
    }
    .sheet(isPresented: $bindingSheet) { HostingBindingSheet(hosting: hosting, model: model).environmentObject(store) }
    .sheet(isPresented: $settingsSheet) { VStack { HostingSettingsView(hosting: hosting); Button(store.text("Done", "完成")) { settingsSheet = false }.padding(12) }.frame(width: 760, height: 580).environmentObject(store) }
    .sheet(isPresented: $createSheet) { if let binding, let account { HostingCreateSheet(hosting: hosting, model: model, binding: binding, account: account).environmentObject(store) } }
    .onAppear { load(reset: true, refresh: false) }
    .onChange(of: filter) { _, _ in load(reset: true, refresh: false) }
    .onChange(of: hosting.revision) { _, _ in load(reset: true, refresh: false) }
    .onDisappear { requestTask?.cancel(); generation = UUID() }
  }
  func load(reset: Bool, refresh: Bool) {
    requestTask?.cancel(); let id = UUID(); generation = id; loading = false; error = nil
    if reset { items = []; selected = nil; nextPage = nil }
    guard let binding, let account else { return }
    let page = reset ? 1 : nextPage ?? 1; loading = true
    requestTask = Task {
      do {
        let result = try await hosting.requests(binding, account: account, filter: filter, page: page, refresh: refresh)
        try Task.checkCancellation(); guard generation == id else { return }
        let known = Set(items.map(\.number)); items += result.items.filter { !known.contains($0.number) }; nextPage = result.nextPage
      } catch is CancellationError {} catch { if generation == id { self.error = hosting.message(error) } }
      if generation == id { loading = false }
    }
  }
  func filterName(_ filter: HostingRequestFilter) -> String {
    switch filter { case .open: store.text("Open", "打开"); case .draft: store.text("Draft", "草稿"); case .closed: store.text("Closed", "关闭"); case .merged: store.text("Merged", "已合并"); case .all: store.text("All", "全部") }
  }
  func requestState(_ state: String) -> String { filterName(HostingRequestFilter(rawValue: state) ?? .open) }
}

struct HostingBindingSheet: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var hosting: HostingModel
  @ObservedObject var model: RepositoryModel
  @State private var accountID: UUID?
  @State private var remote = ""
  @State private var repository = ""
  @State private var error: String?
  @State private var busy = false
  @State private var request: Task<Void, Never>?
  init(hosting: HostingModel, model: RepositoryModel) {
    self.hosting = hosting; self.model = model
    let existing = hosting.binding(model.record.id)
    let id = existing?.accountID ?? hosting.metadata.accounts.first?.id
    let remote = existing?.remote ?? model.remotes.first?.name ?? ""
    _accountID = State(initialValue: id); _remote = State(initialValue: remote)
    let account = id.flatMap { hosting.account($0) }
    let fetch = model.remotes.first { $0.name == remote }?.fetchURL
    let suggested = account.flatMap { account in fetch.flatMap { HostingRemoteParser.repository($0, instance: account.instance) } }
    _repository = State(initialValue: existing?.repository ?? suggested ?? "")
  }
  var suggestion: String? {
    guard let id = accountID, let account = hosting.account(id), let remote = model.remotes.first(where: { $0.name == remote }) else { return nil }
    return HostingRemoteParser.repository(remote.fetchURL, instance: account.instance)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(store.text("Repository Binding", "仓库关联")).font(.title2.weight(.semibold))
      Form {
        Picker(store.text("Account", "账号"), selection: $accountID) {
          Text(store.text("Choose Account", "选择账号")).tag(UUID?.none)
          ForEach(hosting.metadata.accounts) { account in Text(account.instance.provider.title + " · @" + account.user.login + " · " + account.instance.baseURL.absoluteString).tag(Optional(account.id)) }
        }
        Picker("Remote", selection: $remote) { Text(store.text("Choose Remote", "选择 Remote")).tag(""); ForEach(model.remotes) { Text($0.name).tag($0.name) } }
        TextField(store.text("Owner / Group / Repository", "所有者 / Group / 仓库"), text: $repository)
        if let suggestion, suggestion != repository {
          HStack {
            Text(store.text("Remote suggests: ", "Remote 建议：") + suggestion).font(.caption).foregroundStyle(.secondary)
            Button(store.text("Use Suggestion", "使用建议")) { repository = suggestion }
          }
        }
        Text(store.text("The repository is verified through the selected account's API. SSH ports may differ from the HTTPS API port; verify the suggestion before linking. Worktrees can each select the same hosting repository and retain independent branches.", "将通过所选账号的 API 验证仓库。SSH 端口可能不同于 HTTPS API 端口，请确认建议后再关联。各 Worktree 可关联同一托管仓库，并保留各自分支。"))
          .font(.caption).foregroundStyle(.secondary)
      }
      if let error { Text(error).foregroundStyle(.orange).font(.callout) }
      if hosting.metadata.accounts.isEmpty { Text(store.text("Connect an account in Settings → Code Hosting first.", "请先在设置 → 代码托管中连接账号。")) }
      HStack {
        Button(store.text("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
        if hosting.binding(model.record.id) != nil {
          Button(store.text("Unlink", "解除关联")) { do { try hosting.unbind(model.record.id); dismiss() } catch { self.error = hosting.message(error) } }
        }
        Spacer()
        if busy { ProgressView().controlSize(.small) }
        Button(store.text("Verify & Link", "验证并关联")) {
          guard let id = accountID, let account = hosting.account(id) else { return }; busy = true; error = nil
          request = Task {
            defer { busy = false }
            do {
              let binding = try RepositoryHostingBinding(repositoryID: model.record.id, accountID: id, remote: remote, repository: repository)
              try await hosting.bind(binding, account: account); try Task.checkCancellation(); dismiss()
            } catch is CancellationError {} catch { self.error = hosting.message(error); await hosting.failed(error, account: account) }
          }
        }.buttonStyle(.borderedProminent).disabled(accountID == nil || remote.isEmpty || repository.isEmpty || busy)
      }.disabled(busy)
    }.padding(22).frame(width: 630).textFieldStyle(.roundedBorder)
    .onDisappear { request?.cancel() }
  }
}

struct HostingRequestDetail: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.colorScheme) var scheme
  @ObservedObject var hosting: HostingModel
  let binding: RepositoryHostingBinding
  let account: HostingAccount
  let request: HostingPullRequest
  @State private var detail: HostingPullRequest?
  @State private var commits: [HostingCommit] = []
  @State private var files: [HostingChangedFile] = []
  @State private var reviews: [HostingReview] = []
  @State private var comments: [HostingReview] = []
  @State private var checks: [HostingCheck] = []
  @State private var filePage: Int? = nil
  @State private var commitPage: Int? = nil
  @State private var reviewPage: Int? = nil
  @State private var commentPage: Int? = nil
  @State private var selectedFile: String?
  @State private var diff = DiffDocument.empty
  @State private var tab = 0
  @State private var loading = true
  @State private var moreLoading = false
  @State private var error: String?
  @State private var ciError: String?
  @State private var moreTask: Task<Void, Never>?
  @State private var remotePatch: String?
  @State private var patchTask: Task<Void, Never>?
  @State private var patchLoading = false
  @State private var reviewComments: [String: [HostingReview]] = [:]
  var current: HostingPullRequest { detail ?? request }
  init(hosting: HostingModel, binding: RepositoryHostingBinding, account: HostingAccount, request: HostingPullRequest, initialTab: Int = 0) {
    self.hosting = hosting; self.binding = binding; self.account = account; self.request = request; _tab = State(initialValue: initialTab)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
          Text("#\(current.number) " + current.title).font(.title3.weight(.semibold)).textSelection(.enabled)
          Text("@" + current.author + " · " + current.source + " → " + current.target).font(.caption).foregroundStyle(.secondary)
          Text(store.text("Created ", "创建于 ") + current.createdAt + " · " + current.state + (current.draft ? " · Draft" : "")).font(.caption2).foregroundStyle(.secondary)
        }
        Spacer()
        if let url = current.webURL { Link(store.text("Open in Browser", "在浏览器中打开"), destination: url).font(.caption) }
      }
      Picker("", selection: $tab) {
        Text(store.text("Overview", "概览")).tag(0); Text(store.text("Commits", "提交")).tag(1)
        Text(store.text("Files", "文件")).tag(2); Text(store.text("Reviews", "审查")).tag(3); Text("CI").tag(4)
      }.pickerStyle(.segmented)
      if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
      if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
      else {
        switch tab {
        case 0:
          ScrollView { VStack(alignment: .leading, spacing: 14) {
            // Plain selectable text deliberately renders no HTML, remote images, scripts or active Markdown.
            Text(current.body.isEmpty ? store.text("No Description", "暂无描述") : current.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Text(store.text("Reviewers: ", "审查者：") + (current.reviewers.isEmpty ? "—" : current.reviewers.joined(separator: ", "))).font(.caption).foregroundStyle(.secondary)
          } }
        case 1:
          List { ForEach(commits) { c in VStack(alignment: .leading, spacing: 4) { Text(String(c.id.prefix(12))).font(.system(.caption, design: .monospaced)); Text(c.message).textSelection(.enabled) } }
            if commitPage != nil { moreButton(1) }
          }
        case 2:
          VStack(spacing: 0) {
            HStack { Label(store.text("Read-only Remote Diff", "只读远端 Diff"), systemImage: "lock").font(.caption).foregroundStyle(.secondary); Spacer(); if filePage != nil { moreButton(2) } }
            HSplitView {
              List(selection: $selectedFile) { ForEach(files) { f in VStack(alignment: .leading) { Text(f.path).lineLimit(2); Text(f.kind + (f.oldPath.isEmpty ? "" : " · " + f.oldPath)).font(.caption).foregroundStyle(.secondary) }.tag(f.path) } }.frame(minWidth: 130, idealWidth: 170, maxWidth: 240)
              if patchLoading { ProgressView().frame(maxWidth: .infinity) }
              else if remotePatch != nil {
                DiffTable(document: diff, path: selectedFile ?? "", key: "hosting|\(account.identity)|\(binding.repository)|\(current.number)|\(current.sha)", settings: store.settings, dark: scheme == .dark, selectedHunk: -1,
                  beforeTitle: current.target, afterTitle: current.source).frame(maxWidth: .infinity, maxHeight: .infinity)
              } else { ContentUnavailableView(store.text("Preview Unavailable", "无可用预览"), systemImage: "doc", description: Text(store.text("Select a file. Binary, large or omitted patches can be viewed in your browser.", "请选择文件。二进制、大型或平台未返回的 Patch 可在浏览器中查看。"))).frame(maxWidth: .infinity) }
            }
          }
        case 3:
          List {
            ForEach(reviews) { review in
              reviewRow(review)
              if account.instance.provider == .gitea {
                if let values = reviewComments[review.id] { ForEach(values) { reviewRow($0) } }
                else { Button(store.text("Load Review Comments", "加载审查评论")) { loadReviewComments(review.id) }.disabled(moreLoading) }
              }
            }; if reviewPage != nil { moreButton(3) }
            ForEach(comments) { review in reviewRow(review) }; if commentPage != nil { moreButton(4) }
            if reviews.isEmpty && comments.isEmpty { Text(store.text("No Reviews or Comments", "暂无审查或评论")) }
          }
        default:
          List {
            Text(store.text("Commit: ", "提交：") + current.sha).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            if let ciError { Text(ciError).foregroundStyle(.orange) }
            else if let error { Text(error).foregroundStyle(.orange) }
            else if checks.isEmpty { Text(store.text("No Checks", "无检查")) }
            ForEach(checks) { check in HStack { Text(check.name); Spacer(); Text(ciTitle(check.state)).foregroundStyle(check.state == .success ? Color.green : .secondary); if let url = check.webURL { Link(store.text("Logs", "日志"), destination: url) } } }
          }
        }
      }
    }.padding(14)
    .task { await load() }
    .onChange(of: selectedFile) { _, _ in loadPatch() }
    .onDisappear { moreTask?.cancel(); patchTask?.cancel() }
  }
  func reviewRow(_ review: HostingReview) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("@" + review.author + " · " + review.state).font(.caption).foregroundStyle(.secondary)
      if !review.path.isEmpty { Text(review.path + ":" + review.line).font(.system(.caption, design: .monospaced)) }
      Text(review.body).textSelection(.enabled)
    }.padding(.vertical, 4)
  }
  func ciTitle(_ state: HostingCIState) -> String {
    switch state { case .pending: store.text("Pending", "等待中"); case .running: store.text("Running", "运行中"); case .success: store.text("Success", "成功"); case .failed: store.text("Failed", "失败"); case .cancelled: store.text("Cancelled", "已取消"); case .skipped: store.text("Skipped", "已跳过"); case .unknown: store.text("Unknown", "未知"); case .noChecks: store.text("No Checks", "无检查") }
  }
  func load() async {
    loading = true; defer { loading = false }
    do {
      let token = try await hosting.tokens.token(for: account)
      let loaded = try await hosting.api.request(binding, number: request.number, account: account, token: token)
      try Task.checkCancellation(); detail = loaded
      // Independent panes report failure explicitly; CI permission failures never become No Checks.
      do { checks = try await hosting.api.checks(binding, sha: loaded.sha, account: account, token: token) }
      catch is CancellationError { throw CancellationError() } catch { ciError = hosting.message(error); await hosting.failed(error, account: account) }
      try await loadPage(1, token: token); try await loadPage(2, token: token); try await loadPage(3, token: token); try await loadPage(4, token: token)
    } catch is CancellationError {} catch { self.error = hosting.message(error); await hosting.failed(error, account: account) }
  }
  func loadPage(_ kind: Int, token: HostingToken) async throws {
    switch kind {
    case 1:
      let p = try await hosting.api.commits(binding, number: request.number, account: account, token: token, page: commitPage ?? 1)
      try Task.checkCancellation(); let ids = Set(commits.map(\.id)); commits += p.items.filter { !ids.contains($0.id) }; commitPage = p.nextPage
    case 2:
      let p = try await hosting.api.files(binding, number: request.number, account: account, token: token, page: filePage ?? 1)
      try Task.checkCancellation(); let ids = Set(files.map(\.id)); files += p.items.filter { !ids.contains($0.id) }; filePage = p.nextPage
      if selectedFile == nil { selectedFile = files.first?.path }
    case 3:
      let p = try await hosting.api.reviews(binding, number: request.number, account: account, token: token, page: reviewPage ?? 1)
      try Task.checkCancellation(); let ids = Set(reviews.map(\.id)); reviews += p.items.filter { !ids.contains($0.id) }; reviewPage = p.nextPage
    default:
      let p = try await hosting.api.reviews(binding, number: request.number, account: account, token: token, comments: true, page: commentPage ?? 1)
      try Task.checkCancellation(); let ids = Set(comments.map(\.id)); comments += p.items.filter { !ids.contains($0.id) }; commentPage = p.nextPage
    }
  }
  func moreButton(_ kind: Int) -> some View {
    Button(store.text("Load More", "加载更多")) {
      moreLoading = true
      moreTask = Task { defer { moreLoading = false }; do { let token = try await hosting.tokens.token(for: account); try await loadPage(kind, token: token) }
        catch is CancellationError {} catch { self.error = hosting.message(error); await hosting.failed(error, account: account) } }
    }.disabled(moreLoading)
  }
  func loadPatch() {
    patchTask?.cancel(); remotePatch = nil; diff = .empty; patchLoading = false
    guard let file = files.first(where: { $0.path == selectedFile }) else { return }
    if let patch = file.patch { remotePatch = patch; diff = DiffParser.parse(Data(patch.utf8)); return }
    guard account.instance.provider == .gitea else { return }; patchLoading = true
    patchTask = Task {
      defer { if selectedFile == file.path { patchLoading = false } }
      do {
        let token = try await hosting.tokens.token(for: account)
        let patch = try await hosting.api.giteaPatch(binding, number: request.number, file: file, account: account, token: token)
        try Task.checkCancellation(); guard selectedFile == file.path else { return }
        remotePatch = patch; diff = DiffParser.parse(Data((patch ?? "").utf8))
      } catch is CancellationError {} catch { self.error = hosting.message(error); await hosting.failed(error, account: account) }
    }
  }
  func loadReviewComments(_ id: String) {
    moreLoading = true
    moreTask = Task {
      defer { moreLoading = false }
      do { let token = try await hosting.tokens.token(for: account); let values = try await hosting.api.giteaReviewComments(binding, number: request.number, reviewID: id, account: account, token: token)
        try Task.checkCancellation(); reviewComments[id] = values
      } catch is CancellationError {} catch { self.error = hosting.message(error) }
    }
  }
}

struct HostingCreateSheet: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var hosting: HostingModel
  @ObservedObject var model: RepositoryModel
  let binding: RepositoryHostingBinding
  let account: HostingAccount
  @State private var source = ""
  @State private var target = "main"
  @State private var sourceRepository = ""
  @State private var title = ""
  @State private var description = ""
  @State private var draft = false
  @State private var review: HostingCreationReview?
  @State private var error: String?
  @State private var busy = false
  @State private var uncertain = false
  @State private var created: HostingPullRequest?
  @State private var requestTask: Task<Void, Never>?
  let initialDraft: HostingCreateDraft?
  init(hosting: HostingModel, model: RepositoryModel, binding: RepositoryHostingBinding, account: HostingAccount, initialDraft: HostingCreateDraft? = nil) {
    self.hosting = hosting; self.model = model; self.binding = binding; self.account = account; self.initialDraft = initialDraft
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(account.instance.provider == .gitlab ? store.text("Create Merge Request", "创建合并请求") : store.text("Create Pull Request", "创建拉取请求")).font(.title2.weight(.semibold))
      Text(account.instance.provider.title + " · " + binding.repository + " · @" + account.user.login).font(.callout).foregroundStyle(.secondary)
      if let created {
        Label(store.text("Created ", "已创建 ") + "#\(created.number) " + created.title, systemImage: "checkmark.circle")
        if let url = created.webURL { Link(store.text("Open in Browser", "在浏览器中打开"), destination: url) }
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            TextField(store.text("Source Repository (owner/name, including forks)", "来源仓库（owner/name，支持 Fork）"), text: $sourceRepository)
            HStack { TextField(store.text("Source Branch", "来源分支"), text: $source); Image(systemName: "arrow.right"); TextField(store.text("Target Branch", "目标分支"), text: $target) }
            TextField(store.text("Title", "标题"), text: $title)
            Text(store.text("Description", "描述")).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $description).font(.body).frame(minHeight: 160).overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            if account.instance.provider != .gitea { Toggle(store.text("Draft", "草稿"), isOn: $draft) }
            if let review {
              VStack(alignment: .leading, spacing: 6) {
                Text(store.text("Confirm Creation", "确认创建")).font(.headline)
                Text(review.draft.sourceRepository + ":" + review.draft.source + " → " + binding.repository + ":" + review.draft.target)
                Text(review.draft.title)
                Text(store.text("Draft: ", "草稿：") + (review.draft.draft ? store.text("Yes", "是") : store.text("No", "否")))
                Text(review.sourceSHA).font(.system(.caption, design: .monospaced))
              }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            Text(store.text("Checks source and target branches, pushed source SHA, existing requests and unfinished Git operations. No automatic Push. A timed-out creation must be checked before retrying.", "会检查来源与目标分支、已推送来源 SHA、已有请求及未完成的 Git 操作。不会自动 Push。创建超时后必须先检查结果再重试。"))
              .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
          }.disabled(busy || review != nil).textFieldStyle(.roundedBorder).padding(6)
        }
      }
      HStack {
        Button(store.text("Close", "关闭")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
        if review != nil { Button(store.text("Edit", "编辑")) { review = nil }.disabled(busy) }
        Spacer()
        if busy { ProgressView().controlSize(.small) }
        if created == nil {
          if uncertain {
            Button(store.text("Check Existing Requests", "检查已有请求")) { checkUncertain() }.disabled(busy)
          } else {
            Button(review == nil ? store.text("Review…", "审查…") : store.text("Confirm & Create", "确认并创建")) { submit() }
              .buttonStyle(.borderedProminent).disabled(busy || source.isEmpty || target.isEmpty || title.isEmpty)
          }
        }
      }
    }.padding(22).frame(width: 650, height: 600)
    .onAppear {
      source = initialDraft?.source ?? model.status.branch; sourceRepository = initialDraft?.sourceRepository ?? binding.repository
      target = initialDraft?.target ?? "main"; title = initialDraft?.title ?? ""; description = initialDraft?.body ?? ""; draft = initialDraft?.draft ?? false
    }
    .onDisappear { requestTask?.cancel() }
  }
  func draftValue() -> HostingCreateDraft { HostingCreateDraft(sourceRepository: sourceRepository, source: source, target: target, title: title, body: description, draft: draft) }
  func submit() {
    busy = true; error = nil
    requestTask = Task {
      defer { busy = false }
      do {
        guard hosting.binding(binding.id) == binding, hosting.account(account.id)?.identity == account.identity else { throw HostingError.accountChanged }
        let state = try await model.git().hostingCreationState(sourceBranch: source)
        let token = try await hosting.tokens.token(for: account)
        if let review {
          let git = await model.git()
          created = try await hosting.api.create(review, localHead: state.head, localBranch: state.branch, operationInProgress: state.operation != nil || model.busy, account: account, token: token) {
            let final = try await git.hostingCreationState(sourceBranch: review.draft.source)
            guard final.head == review.sourceSHA, final.branch == review.draft.source, final.operation == nil else { throw HostingError.accountChanged }
            let valid = await MainActor.run { hosting.binding(binding.id) == binding && hosting.account(account.id)?.identity == account.identity && !model.busy }
            guard valid else { throw HostingError.accountChanged }
          }
          await hosting.clearCaches(account: account)
        } else {
          review = try await hosting.api.prepareCreation(binding, draft: draftValue(), localHead: state.head, localBranch: state.branch,
            operationInProgress: state.operation != nil || model.busy, account: account, token: token)
        }
      } catch {
        if error as? HostingError == .creationUnknown { uncertain = true; review = nil }
        self.error = hosting.message(error); await hosting.failed(error, account: account)
      }
    }
  }
  func checkUncertain() {
    busy = true; error = nil
    requestTask = Task {
      defer { busy = false }
      do {
        let state = try await model.git().hostingCreationState(sourceBranch: source), token = try await hosting.tokens.token(for: account)
        _ = try await hosting.api.prepareCreation(binding, draft: draftValue(), localHead: state.head, localBranch: state.branch,
          operationInProgress: state.operation != nil || model.busy, account: account, token: token)
        uncertain = false // Query completed without finding a duplicate; user must review and confirm again.
      } catch { self.error = hosting.message(error) }
    }
  }
}
