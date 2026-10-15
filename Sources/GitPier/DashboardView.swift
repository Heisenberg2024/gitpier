import GitPierCore
import SwiftUI

struct DashboardView: View {
  @EnvironmentObject var store: AppStore
  var body: some View { WorkspaceDashboard(workspace: store.workspace) }
}

private struct WorkspaceDashboard: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.colorScheme) var scheme
  @ObservedObject var workspace: WorkspaceModel
  @State private var search = ""
  @State private var sort = "manual"
  @State private var collapsed: Set<String> = []
  var scoped: [WorkspaceEntry] {
    store.repositories.filter { store.dashboardOrganization == nil || $0.group == store.dashboardOrganization }
      .map { workspace.entries[$0.id] ?? WorkspaceEntry(record: $0) }
  }
  var filtered: [WorkspaceEntry] {
    let values = scoped.filter { entry in
      let record = entry.record
      let metadata = [record.name, record.path, record.group, entry.usable?.branch ?? ""] + (entry.usable?.remoteNames ?? [])
      return (search.isEmpty || metadata.contains { $0.localizedCaseInsensitiveContains(search) })
        && workspace.filters.allSatisfy { $0.matches(entry) }
    }
    guard sort != "manual" else { return values }
    return values.sorted {
      if sort == "name" { return $0.record.name.localizedStandardCompare($1.record.name) == .orderedAscending }
      if sort == "path" { return $0.record.path.localizedStandardCompare($1.record.path) == .orderedAscending }
      return $0.record.lastOpened > $1.record.lastOpened
    }
  }
  var families: [String: [WorkspaceEntry]] { Dictionary(grouping: filtered.filter { $0.usable != nil }) { $0.usable!.commonDirectory } }
  func leader(_ family: [WorkspaceEntry]) -> UUID? { (family.first { $0.usable?.isWorktree == false } ?? family.first)?.record.id }
  var displayed: [WorkspaceEntry] {
    filtered.filter { entry in
      guard let key = entry.usable?.commonDirectory, collapsed.contains(key), let family = families[key] else { return true }
      return leader(family) == entry.record.id
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      summary
      controls
      if !workspace.fetchJobs.isEmpty { WorkspaceFetchTray(workspace: workspace) }
      Divider()
      if filtered.isEmpty {
        EmptyState(symbol: "shippingbox", title: store.text("No matching repositories", "没有匹配的仓库"),
          detail: store.text("Open a repository, or adjust your search and filters.", "打开仓库，或调整搜索与筛选。"))
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(displayed, id: \.record.id) { entry in
              row(entry).repositoryReordering(entry.record) { sort = "manual" }
                .onAppear { workspace.visible(entry.record.id) }
              Divider().padding(.leading, 24)
            }
          }
        }
      }
      HStack {
        Text(store.text("\(filtered.count) matching · \(workspace.selected.count) selected", "\(filtered.count) 个匹配 · 已选 \(workspace.selected.count) 个"))
        Spacer()
        OperationProgressView(progress: store.cloneActivity) { store.cloneTask?.cancel() }
        Text("GitPier " + AppResources.version)
      }.font(uiFont(size: 11)).foregroundStyle(.secondary).padding(12).background(Theme.panel(scheme))
    }
  }
  private var header: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(store.dashboardOrganization.map { $0.isEmpty ? store.text("Ungrouped", "未分组") : $0 }
            ?? store.text("Workspace", "工作空间")).font(uiFont(size: 27, weight: .semibold))
          Text(localizedUI("All Your Repositories. One Workspace.")).font(uiFont(size: 13)).foregroundStyle(.secondary)
        }
        Spacer()
        Button { store.showWorkspaceSearch = true } label: { Label(store.text("Workspace Search", "工作空间搜索"), systemImage: "magnifyingglass") }
      }
      ViewThatFits(in: .horizontal) {
        HStack { actions; Spacer() }
        VStack(alignment: .leading) { HStack { primaryActions }; HStack { secondaryActions } }
      }
    }.padding(24)
  }
  @ViewBuilder private var actions: some View { primaryActions; secondaryActions }
  @ViewBuilder private var primaryActions: some View {
    Button(store.text("Refresh Local Status", "刷新本地状态")) { Task { await workspace.refresh() } }
    Button(store.text("Fetch Selected…", "获取已选仓库…")) { workspace.prepareFetch() }
      .disabled(workspace.selected.isEmpty)
  }
  @ViewBuilder private var secondaryActions: some View {
    Button(store.text("Open Repository…", "打开仓库…")) { store.openRepository(in: store.dashboardOrganization) }
    Button(store.text("Clone…", "克隆…")) { store.showClone = true }
    Button(store.text("Organizations…", "组织管理…")) { store.showOrganizations = true }
  }
  private var summary: some View {
    let value = WorkspaceSummary(scoped)
    return VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 16) {
        Text(store.text("\(value.total) workspace entries", "\(value.total) 个工作空间条目")).fontWeight(.medium)
        Text(store.text("\(value.scanned)/\(value.total) scanned · \(value.fresh) current", "已扫描 \(value.scanned)/\(value.total) · \(value.fresh) 个有效状态"))
        Spacer()
      }
      HStack(spacing: 12) {
        Text(store.text("\(value.physicalRepositories) known physical repositories", "\(value.physicalRepositories) 个已识别物理仓库"))
        if value.unknownPhysical > 0 { Text(store.text("\(value.unknownPhysical) unresolved", "\(value.unknownPhysical) 个尚未识别")) }
      }.foregroundStyle(.secondary)
      Text(store.text("Ahead/behind uses local tracking refs. Refresh is local; Fetch contacts remotes.", "领先 / 落后依据本地跟踪引用。刷新只读本地；获取才连接远程。"))
        .foregroundStyle(.secondary)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 102))], alignment: .leading) {
        ForEach([WorkspaceFilter.modified, .ahead, .behind, .conflicts, .unavailable], id: \.self) { filter in
          Text(filterName(filter) + " \(value.counts[filter] ?? 0)").fontWeight(.medium)
        }
      }
    }.font(uiFont(size: 11)).padding(.horizontal, 24).padding(.bottom, 16)
  }
  private var controls: some View {
    let counts = WorkspaceSummary(scoped).counts
    return VStack(alignment: .leading, spacing: 12) {
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField(store.text("Name, path, organization, branch or remote", "名称、路径、组织、分支或远程"), text: $search).textFieldStyle(.plain)
        Picker(store.text("Sort", "排序"), selection: $sort) {
          Text(store.text("Manual", "手动排序")).tag("manual")
          Text(store.text("Recent", "最近使用")).tag("recent")
          Text(store.text("Name", "名称")).tag("name")
          Text(store.text("Path", "路径")).tag("path")
        }.frame(width: 145)
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 7)], alignment: .leading, spacing: 7) {
        Button(store.text("All", "全部")) { workspace.filters.removeAll() }.tint(workspace.filters.isEmpty ? .accentColor : .secondary)
        ForEach(WorkspaceFilter.allCases, id: \.self) { filter in
          let count = counts[filter] ?? 0
          Button(filterName(filter) + " \(count)") {
            if workspace.filters.contains(filter) { workspace.filters.remove(filter) } else { workspace.filters.insert(filter) }
          }.tint(workspace.filters.contains(filter) ? .accentColor : .secondary)
        }
      }.buttonStyle(.bordered)
      HStack {
        Button(store.text("Select Matches", "选择匹配项")) { workspace.selected.formUnion(filtered.map { $0.record.id }) }
        Button(store.text("Clear Selection", "清除选择")) { workspace.selected.removeAll() }.disabled(workspace.selected.isEmpty)
        Spacer()
        if workspace.filters.count > 1 { Text(store.text("Match all selected filters", "同时满足所选筛选")).foregroundStyle(.secondary) }
      }.font(uiFont(size: 11))
    }.padding(.horizontal, 24).padding(.bottom, 16)
  }
  private func filterName(_ filter: WorkspaceFilter) -> String {
    switch filter {
    case .modified: return store.text("Modified", "有修改")
    case .staged: return store.text("Staged", "已暂存")
    case .ahead: return store.text("Ahead", "领先")
    case .behind: return store.text("Behind", "落后")
    case .conflicts: return store.text("Conflicts", "冲突")
    case .unavailable: return store.text("Unavailable", "不可用")
    case .favorites: return store.text("Favorites", "收藏")
    }
  }
  private func row(_ entry: WorkspaceEntry) -> some View {
    let record = entry.record
    let family = entry.usable.flatMap { families[$0.commonDirectory] } ?? []
    return HStack(spacing: 12) {
      Toggle(store.text("Select", "选择") + " " + record.name, isOn: Binding(
        get: { workspace.selected.contains(record.id) },
        set: { if $0 { workspace.selected.insert(record.id) } else { workspace.selected.remove(record.id) } }))
        .labelsHidden().toggleStyle(.checkbox)
      if family.count > 1, leader(family) == record.id, let key = entry.usable?.commonDirectory {
        Button {
          if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
        } label: { Image(systemName: collapsed.contains(key) ? "chevron.right" : "chevron.down") }
          .buttonStyle(.plain).help(store.text("Expand / collapse related worktrees", "展开 / 收起关联工作树"))
      } else { Image(systemName: entry.usable?.isWorktree == true ? "arrow.triangle.branch" : "shippingbox").foregroundStyle(.secondary) }
      Button { store.select(record.id) } label: {
        WorkspaceRepositoryRow(entry: entry, relatedCount: family.count).frame(maxWidth: .infinity).contentShape(Rectangle())
      }.buttonStyle(.workspace)
    }.padding(.horizontal, 24).padding(.vertical, 15)
  }
}

private struct WorkspaceRepositoryRow: View {
  @EnvironmentObject var store: AppStore
  let entry: WorkspaceEntry
  let relatedCount: Int
  var body: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text(entry.record.name).font(repositoryFont(sizeOffset: 2, weight: .semibold)).lineLimit(1)
          if entry.record.favorite { Image(systemName: "star.fill").font(uiFont(size: 9)).foregroundStyle(.yellow) }
          if !entry.record.group.isEmpty { Badge(text: entry.record.group) }
          if let value = entry.snapshot, value.isWorktree { Badge(text: store.text("Worktree", "工作树")) }
          if relatedCount > 1 { Badge(text: store.text("\(relatedCount) related", "\(relatedCount) 个关联")) }
        }
        Text(entry.record.path).font(uiFont(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        if let failure = entry.failure, entry.state == .failed {
          Text(failureLabel(failure.kind) + ": " + failure.summary).foregroundStyle(.orange).lineLimit(2).help(failure.summary)
        }
      }
      Spacer(minLength: 4)
      VStack(alignment: .trailing, spacing: 5) {
        if let value = entry.snapshot {
          HStack {
            if value.conflicts > 0 { Badge(text: store.text("\(value.conflicts) conflicts", "\(value.conflicts) 个冲突"), color: .red) }
            if let operation = value.operation { Badge(text: localizedUI(operation.rawValue.capitalized), color: .orange) }
            Label(value.detached ? store.text("Detached HEAD", "分离 HEAD") : value.branch, systemImage: "arrow.triangle.branch").lineLimit(1)
          }
          HStack {
            Text(store.text("\(value.tracked + value.untracked) modified", "\(value.tracked + value.untracked) 项修改"))
            Badge(text: store.text("\(value.staged) staged", "\(value.staged) 项暂存"), color: .mint)
            if value.upstream != nil { Text("↑\(value.ahead) ↓\(value.behind)").help(store.text("Local remote-tracking references; use Fetch to update.", "本地远程跟踪引用，使用获取更新。")) }
            else { Text(store.text("No upstream", "无上游")).foregroundStyle(.secondary) }
          }
          HStack {
            collectionLabel
            Text(value.collectedAt, style: .relative).foregroundStyle(.secondary)
          }
        } else { collectionLabel }
      }.font(uiFont(size: 11)).frame(maxWidth: 260, alignment: .trailing)
    }
  }
  @ViewBuilder private var collectionLabel: some View {
    switch entry.state {
    case .collecting: HStack(spacing: 4) { ProgressView().controlSize(.mini); Text(store.text("Scanning", "正在采集")) }
    case .queued: Text(store.text("Queued", "等待采集")).foregroundStyle(.secondary)
    case .unscanned: Text(store.text("Not scanned", "尚未采集")).foregroundStyle(.secondary)
    case .stale: Text(store.text("Needs refresh", "需要刷新")).foregroundStyle(.orange)
    case .failed: Text(store.text("Unavailable", "不可用")).foregroundStyle(.orange)
    case .fresh: EmptyView()
    }
  }
  private func failureLabel(_ kind: WorkspaceFailureKind) -> String {
    switch kind {
    case .missingDirectory: return store.text("Directory missing", "目录不存在")
    case .invalidRepository: return store.text("Invalid repository", "无效仓库")
    case .permissionDenied: return store.text("Permission denied", "权限不足")
    case .gitQuery: return store.text("Git query failed", "Git 查询失败")
    }
  }
}
