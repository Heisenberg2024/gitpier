import GitPierCore

/// Navigation commands for the existing Quick Open sheet.
enum WorkspaceCommand: String, CaseIterable, Identifiable {
  case open, dashboard, refresh, commit, history, branches, worktrees, compare, terminal, review, operations, conflicts, rebase, upstream, fetch, pull
  var id: String { rawValue }
  @MainActor func title(_ store: AppStore) -> String {
    switch self {
    case .open: return store.text("Open Repository…", "打开仓库…")
    case .dashboard: return store.text("Open Dashboard", "打开仓库总览")
    case .refresh: return store.text("Refresh Local Status", "刷新本地状态")
    case .commit: return store.text("View Changes / Stage / Commit", "查看修改 / 暂存 / 提交")
    case .history: return store.text("Open History", "打开历史")
    case .branches: return store.text("Open Branches", "打开分支")
    case .worktrees: return store.text("Open Worktrees", "打开工作树")
    case .compare: return store.text("View Comparison", "查看比较")
    case .terminal: return store.text("Open Terminal", "打开终端")
    case .review: return store.text("Open Review / Browser / CI", "打开审查 / 浏览器 / CI")
    case .operations: return store.text("Open Operations Center", "打开操作中心")
    case .conflicts: return store.text("Open Conflict Editor", "打开冲突编辑器")
    case .rebase: return store.text("Open Rebase Recovery", "打开变基恢复")
    case .upstream: return store.text("Open Branch Upstream Settings", "打开分支 Upstream 设置")
    case .fetch: return store.text("Review Fetch…", "审查获取…")
    case .pull: return store.text("Open Pull Workflow", "打开拉取工作流")
    }
  }
  @MainActor func unavailable(_ store: AppStore) -> String? {
    if [.open, .dashboard, .operations].contains(self) { return nil }
    guard let model = store.current, !store.showDashboard else { return store.text("Select a repository", "请先选择仓库") }
    guard model.available else { return store.text("Repository unavailable", "仓库不可用") }
    if model.busy { return store.text("Wait for the current operation", "请等待当前操作完成") }
    if self == .conflicts && !model.status.files.contains(where: \.isConflicted) { return store.text("No conflicts", "没有冲突") }
    if self == .rebase && model.status.operation != .rebase { return store.text("No rebase in progress", "没有进行中的变基") }
    if self == .review {
      guard let binding = store.hosting.binding(model.record.id), store.hosting.account(binding.accountID) != nil else {
        return store.text("Connect a hosting account and repository", "请连接托管账号和仓库")
      }
    }
    return nil
  }
  @MainActor func execute(_ store: AppStore) {
    guard unavailable(store) == nil else { return }
    store.recentCommands.removeAll { $0 == self }; store.recentCommands.insert(self, at: 0)
    store.recentCommands = Array(store.recentCommands.prefix(20))
    let model = store.current
    switch self {
    case .open: store.openRepository()
    case .dashboard: store.showDashboard = true
    case .operations: store.showOperationsCenter = true
    case .refresh: Task { await store.refreshVisibleRepositories() }
    case .commit, .history, .branches, .worktrees, .compare: model?.setPage(rawValue)
    case .conflicts: model?.openConflicts()
    case .rebase: model?.showRebaseRecovery = true
    case .upstream: model?.setPage("branches")
    case .review: model?.setPage("hosting")
    case .fetch: if let model { store.workspace.prepareFetch([model.record.id]) }
    case .pull:
      model?.setPage("commit")
      store.notice = store.text("Choose Pull in the repository toolbar after reviewing local changes and Fetch snapshots.", "审查本地修改和 Fetch 快照后，请在仓库工具栏选择 Pull。")
    case .terminal:
      guard let model else { return }
      var layout = model.panels.layout; layout.terminalVisible = true; model.editLayout(layout)
      if model.terminal.sessions.isEmpty { model.terminal.add(settings: store.settings) }
    }
  }
}
