import GitPierCore
import SwiftUI

struct DashboardView: View {
  @EnvironmentObject var store: AppStore
  var body: some View { WorkspaceDashboard(workspace: store.workspace) }
}

private struct WorkspaceDashboard: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.colorScheme) private var scheme
  @ObservedObject var workspace: WorkspaceModel
  @State private var search = ""
  @State private var sort = "manual"
  @State private var collapsed: Set<String> = []
  @State private var reviewInbox = false
  @FocusState private var searching: Bool

  var body: some View {
    let listing = WorkspaceListing(records: store.repositories, entries: workspace.entries,
      organization: store.dashboardOrganization, search: search, filters: workspace.filters,
      sort: sort, collapsed: collapsed)
    GeometryReader { geometry in
      let compact = geometry.size.width < 850
      let columns = DashboardColumns(width: min(geometry.size.width - 48, 1320))
      VStack(spacing: 14) {
        header(compact: compact)
        overview(listing)
        toolbar(listing, wide: columns.showsUpdated)
        repositoryList(listing, columns: columns)
      }
      .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)
      .frame(maxWidth: 1368, maxHeight: .infinity)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }.background(Theme.sidebar(scheme))
      .onAppear { workspace.requestRemoteEvaluation() }
      .sheet(isPresented: $reviewInbox) { HostingReviewDashboardView(hosting: store.hosting) { item in
        reviewInbox = false; store.openHostingReviewInboxItem(item)
      }.environmentObject(store) }
  }

  private func header(compact: Bool) -> some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 5) {
        Text(store.dashboardOrganization.map { $0.isEmpty ? store.text("Ungrouped", "未分组") : $0 }
          ?? store.text("Workspace", "工作空间"))
          .font(uiFont(size: 27, weight: .semibold)).lineLimit(1)
        Text(localizedUI("All Your Repositories. One Workspace."))
          .font(uiFont(size: 12)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 0)
      HStack(spacing: 8) {
        headerButton("tray", store.text("Account Review Inbox", "账号审查收件箱"), compact: true) { reviewInbox = true }
        headerButton("magnifyingglass", store.text("Workspace Search", "工作空间搜索"), compact: compact) {
          store.showWorkspaceSearch = true
        }
        headerButton("arrow.clockwise", store.text("Refresh Local Status", "刷新本地状态"), compact: true) {
          Task { await workspace.refresh() }
        }
        headerButton("folder.badge.plus", store.text("Open Repository…", "打开仓库…"), compact: compact) {
          store.openRepository(in: store.dashboardOrganization)
        }.tint(.accentColor)
        Menu {
          Button(store.text("Clone…", "克隆…")) { store.showClone = true }
          Button(store.text("Organizations…", "组织管理…")) { store.showOrganizations = true }
          Divider()
          Button(store.text("Quick Open…", "快速打开…")) { store.showQuickOpen = true }
        } label: {
          Image(systemName: "ellipsis").frame(width: 20, height: 22)
        }.menuStyle(.borderlessButton).fixedSize()
          .help(store.text("More workspace actions", "更多工作空间操作"))
          .accessibilityLabel(store.text("More workspace actions", "更多工作空间操作"))
      }.controlSize(.large)
    }
  }
  private func headerButton(_ symbol: String, _ title: String, compact: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: symbol)
        if !compact { Text(title) }
      }.font(uiFont(size: 12, weight: .medium)).frame(minWidth: 18, minHeight: 20)
    }.buttonStyle(.bordered).help(title).accessibilityLabel(title)
  }

  private func overview(_ listing: WorkspaceListing) -> some View {
    VStack(spacing: 10) {
      HStack(spacing: 10) {
        metric(store.text("Repositories", "仓库"), value: listing.summary.total, symbol: "shippingbox", filter: nil, color: .accentColor)
        metric(filterName(.modified), value: listing.summary.counts[.modified] ?? 0, symbol: "pencil.line", filter: .modified, color: .orange)
        metric(filterName(.ahead), value: listing.summary.counts[.ahead] ?? 0, symbol: "arrow.up", filter: .ahead, color: .accentColor)
        metric(filterName(.behind), value: listing.summary.counts[.behind] ?? 0, symbol: "arrow.down", filter: .behind, color: .orange)
        metric(filterName(.conflicts), value: listing.summary.counts[.conflicts] ?? 0, symbol: "exclamationmark.triangle", filter: .conflicts, color: .red)
      }
      HStack(spacing: 6) {
        if listing.scanning > 0 { ProgressView().controlSize(.mini) }
        else { Image(systemName: listing.summary.fresh == listing.summary.total ? "checkmark.circle" : "clock").foregroundStyle(.secondary) }
        Text(store.text("\(listing.summary.scanned)/\(listing.summary.total) scanned · \(listing.summary.fresh) current",
          "已扫描 \(listing.summary.scanned)/\(listing.summary.total) · \(listing.summary.fresh) 个有效状态"))
        Text("·").foregroundStyle(.tertiary)
        Text(store.text("\(listing.summary.physicalRepositories) physical", "\(listing.summary.physicalRepositories) 个物理仓库"))
        if listing.summary.unknownPhysical > 0 {
          Text(store.text("· \(listing.summary.unknownPhysical) unresolved", "· \(listing.summary.unknownPhysical) 个未识别"))
        }
        Spacer(minLength: 0)
        Image(systemName: "info.circle").help(store.text(
          "Ahead/behind uses local remote-tracking references; Fetch updates them. Refresh only reads local status.",
          "领先 / 落后基于本地远程跟踪引用，Fetch 后更新。刷新只读取本地状态。"))
          .accessibilityLabel(store.text("Local tracking references; Fetch to update", "本地跟踪引用，Fetch 后更新"))
      }.font(uiFont(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        .padding(.horizontal, 2).accessibilityIdentifier("dashboard-scan-status")
    }
  }
  private func metric(_ title: String, value: Int, symbol: String, filter: WorkspaceFilter?, color: Color) -> some View {
    DashboardMetricCard(title: title, value: value, symbol: symbol, color: color,
      selected: filter.map { workspace.filters.contains($0) } ?? workspace.filters.isEmpty) {
        if let filter { toggle(filter) } else { workspace.filters.removeAll() }
      }.accessibilityIdentifier("dashboard-metric-" + (filter?.rawValue ?? "all"))
  }

  @ViewBuilder private func toolbar(_ listing: WorkspaceListing, wide: Bool) -> some View {
    if wide {
      HStack(spacing: 12) {
        searchField.frame(width: 280)
        filterControls(listing)
        sortPicker.frame(width: 144)
      }
    } else {
      VStack(spacing: 8) {
        HStack(spacing: 12) { searchField; sortPicker.frame(width: 152) }
        filterControls(listing)
      }
    }
  }
  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField(store.text("Search repositories, paths, organizations, branches or remotes…", "搜索仓库、路径、组织、分支或远程…"), text: $search)
        .textFieldStyle(.plain).focused($searching).accessibilityIdentifier("dashboard-search")
      if !search.isEmpty {
        Button { search = ""; searching = true } label: { Image(systemName: "xmark.circle.fill") }
          .buttonStyle(.plain).foregroundStyle(.secondary)
          .help(store.text("Clear search", "清除搜索")).accessibilityLabel(store.text("Clear search", "清除搜索"))
      }
    }.font(uiFont(size: 13)).padding(.horizontal, 11).frame(height: 34)
      .background(Theme.editor(scheme), in: RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7).stroke(searching ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.09)))
  }
  private var sortPicker: some View {
    Picker(store.text("Sort", "排序"), selection: $sort) {
      Text(store.text("Manual", "手动排序")).tag("manual")
      Text(store.text("Recent", "最近使用")).tag("recent")
      Text(store.text("Name", "名称")).tag("name")
      Text(store.text("Path", "路径")).tag("path")
    }.accessibilityIdentifier("dashboard-sort")
  }
  private func filterControls(_ listing: WorkspaceListing) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 4) {
        filterChip(store.text("All", "全部"), count: nil, selected: workspace.filters.isEmpty) { workspace.filters.removeAll() }
        ForEach(WorkspaceFilter.allCases, id: \.self) { filter in
          filterChip(filterName(filter), count: listing.summary.counts[filter] ?? 0,
            selected: workspace.filters.contains(filter)) { toggle(filter) }
        }
      }.padding(2)
    }.fixedSize(horizontal: false, vertical: true)
  }
  private func filterChip(_ title: String, count: Int?, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Text(title)
        if let count { Text("\(count)").monospacedDigit().foregroundStyle(selected ? Color.accentColor : .secondary) }
      }.font(uiFont(size: 12, weight: selected ? .semibold : .regular))
        .padding(.horizontal, 8).frame(height: 28)
        .background(selected ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor.opacity(0.22) : .clear))
    }.buttonStyle(.workspace).foregroundStyle(selected ? Color.accentColor : .primary)
      .accessibilityLabel(title + (count.map { " \($0)" } ?? ""))
      .accessibilityAddTraits(selected ? [.isSelected] : [])
  }

  private func repositoryList(_ listing: WorkspaceListing, columns: DashboardColumns) -> some View {
    VStack(spacing: 0) {
      HStack {
        let count = workspace.selected.intersection(listing.matchingIDs).count
        StagingCheckbox(state: count == 0 ? .off : count == listing.matchingIDs.count ? .on : .mixed,
          enabled: !listing.matchingIDs.isEmpty, accessibilityLabel: store.text("Select Matching", "选择匹配项")) {
          toggleMatching(listing.matchingIDs)
        }.frame(width: 18).accessibilityRepresentation {
          Toggle(store.text("Select Matching", "选择匹配项"), isOn: Binding(
            get: { !listing.matchingIDs.isEmpty && listing.matchingIDs.isSubset(of: workspace.selected) },
            set: { _ in toggleMatching(listing.matchingIDs) }))
            .toggleStyle(.checkbox).disabled(listing.matchingIDs.isEmpty)
            .accessibilityValue(count == 0 ? store.text("Off", "未选")
              : count == listing.matchingIDs.count ? store.text("On", "全选") : store.text("Mixed", "部分选中"))
        }
        Button(store.text("Select Matching", "选择匹配项")) { toggleMatching(listing.matchingIDs) }
          .buttonStyle(.plain).disabled(listing.matchingIDs.isEmpty).accessibilityHidden(true)
        Text(store.text("Repositories", "仓库列表")).fontWeight(.semibold)
        Text("\(listing.matching.count)").monospacedDigit().foregroundStyle(.secondary)
        if workspace.filters.count > 1 { Text(store.text("· Match all filters", "· 同时满足所选筛选")).foregroundStyle(.secondary) }
        Spacer()
      }.font(uiFont(size: 12)).padding(.horizontal, 16).frame(height: 40)
      Divider()
      if !workspace.fetchJobs.isEmpty {
        WorkspaceFetchTray(workspace: workspace).padding(.top, 12)
        Divider()
      }
      if listing.matching.isEmpty {
        EmptyState(symbol: listing.scoped.isEmpty ? "folder.badge.plus" : "line.3.horizontal.decrease.circle",
          title: listing.scoped.isEmpty ? store.text("Your workspace starts here", "从这里开始你的工作空间") : store.text("No matching repositories", "没有匹配的仓库"),
          detail: listing.scoped.isEmpty ? store.text("Open a repository to see its local status at a glance.", "打开仓库，即可概览本地状态。") : store.text("Try another search or clear the selected filters.", "尝试其他搜索词，或清除所选筛选。"))
        if !listing.scoped.isEmpty {
          Button(store.text("Reset search and filters", "重置搜索和筛选")) { search = ""; workspace.filters.removeAll() }.padding(.bottom, 24)
        }
      } else {
        ScrollView {
          LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            Section {
              ForEach(listing.rows) { row in
              DashboardRepositoryRow(row: row, columns: columns, selected: workspace.selected.contains(row.id),
                collapsed: row.familyKey.map { collapsed.contains($0) } ?? false,
                select: { if $0 { workspace.selected.insert(row.id) } else { workspace.selected.remove(row.id) } },
                disclose: { if let key = row.familyKey { if !collapsed.insert(key).inserted { collapsed.remove(key) } } })
                .repositoryReordering(row.entry.record) { sort = "manual" }
                .onAppear { workspace.visible(row.id) }
                .padding(.horizontal, 6)
              Divider().padding(.leading, 58)
              }
            } header: {
              columnHeadings(columns)
            }
          }
        }.scrollIndicators(.hidden).contentMargins(.horizontal, 0, for: .scrollContent)
          .accessibilityIdentifier("dashboard-repositories")
      }
      Divider()
      selectionBar(listing)
    }.background(Theme.editor(scheme), in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
      .clipShape(RoundedRectangle(cornerRadius: 10))
  }
  private func toggleMatching(_ ids: Set<UUID>) {
    if ids.isSubset(of: workspace.selected) { workspace.selected.subtract(ids) }
    else { workspace.selected.formUnion(ids) }
  }
  private func columnHeadings(_ columns: DashboardColumns) -> some View {
    HStack(spacing: 14) {
      Text(store.text("REPOSITORY", "仓库")).frame(width: columns.identity, alignment: .leading)
      if !columns.compact { Text(store.text("BRANCH", "分支")).frame(width: columns.branch, alignment: .leading) }
      Text(store.text("CHANGES", "修改状态")).frame(width: columns.changes, alignment: .leading)
      Text(store.text("SYNC", "同步")).frame(width: columns.sync, alignment: .leading)
      if columns.showsUpdated { Text(store.text("UPDATED", "更新时间")).frame(width: columns.updated, alignment: .leading) }
    }.font(uiFont(size: 10, weight: .medium)).foregroundStyle(.secondary)
      .padding(.leading, 72).padding(.trailing, 44).frame(height: 26)
      .background(Theme.panel(scheme))
  }
  private func selectionBar(_ listing: WorkspaceListing) -> some View {
    let selectedMatches = workspace.selected.intersection(listing.matchingIDs).count
    return HStack(spacing: 12) {
      if !workspace.selected.isEmpty {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
        Text(store.text("\(workspace.selected.count) selected", "已选 \(workspace.selected.count) 个")).fontWeight(.medium)
        if selectedMatches < workspace.selected.count {
          Text(store.text("\(workspace.selected.count - selectedMatches) outside results", "\(workspace.selected.count - selectedMatches) 个在结果之外"))
            .foregroundStyle(.secondary).help(store.text("Selection is kept when searching or filtering.", "搜索或筛选时保留已有选择。"))
        }
        Spacer(minLength: 0)
        Button(store.text("Clear Selection", "清除选择")) { workspace.selected.removeAll() }.buttonStyle(.borderless)
        Button { workspace.prepareFetch() } label: {
          Label(store.text("Fetch Selected…", "获取已选仓库…"), systemImage: "arrow.down.circle")
        }.buttonStyle(.borderedProminent).disabled(workspace.preparingFetch)
      } else {
        Text(store.text("\(listing.matching.count) matching", "\(listing.matching.count) 个匹配"))
        if listing.hiddenCount > 0 { Text(store.text("· \(listing.hiddenCount) collapsed worktrees", "· \(listing.hiddenCount) 个折叠工作树")) }
        Spacer()
        OperationProgressView(progress: store.cloneActivity) { store.cloneTask?.cancel() }
        Text("GitPier " + AppResources.version).foregroundStyle(.tertiary)
      }
    }.font(uiFont(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 44)
      .background(workspace.selected.isEmpty ? Color.clear : Color.accentColor.opacity(0.045))
  }
  private func toggle(_ filter: WorkspaceFilter) {
    if !workspace.filters.insert(filter).inserted { workspace.filters.remove(filter) }
  }
  private func filterName(_ filter: WorkspaceFilter) -> String { dashboardFilterName(filter, store: store) }
}

/// Shared column widths; only repository identity expands.
struct DashboardColumns {
  let compact: Bool
  let showsUpdated: Bool
  let branch: CGFloat
  let changes: CGFloat = 132
  let sync: CGFloat = 92
  let updated: CGFloat = 100
  let identity: CGFloat
  init(width: CGFloat) {
    compact = width < 850; showsUpdated = width >= 1100; branch = width >= 1100 ? 164 : 140
    // 72pt leading selection/disclosure area and 44pt trailing diagnostic area.
    let fixed = 72 + 44 + changes + sync + 28
      + (compact ? 0 : branch + 14) + (showsUpdated ? updated + 14 : 0)
    identity = max(80, width - fixed)
  }
}

private struct DashboardMetricCard: View {
  @Environment(\.colorScheme) private var scheme
  @State private var hovering = false
  @FocusState private var focused: Bool
  let title: String
  let value: Int
  let symbol: String
  let color: Color
  let selected: Bool
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Image(systemName: symbol).foregroundStyle(value > 0 ? color : .secondary)
          Text(title).foregroundStyle(.secondary).lineLimit(1)
          Spacer(minLength: 0)
        }.font(uiFont(size: 12, weight: .medium))
        Text("\(value)").font(uiFont(size: 26, weight: .semibold)).monospacedDigit()
      }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Theme.panel(scheme) : Theme.editor(scheme), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(
          focused ? Color.accentColor : selected ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: focused ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 9))
    }.buttonStyle(.plain).focused($focused).onHover { hovering = $0 }
      .accessibilityLabel(title + " \(value)").accessibilityAddTraits(selected ? [.isSelected] : [])
  }
}

@MainActor private func dashboardFilterName(_ filter: WorkspaceFilter, store: AppStore) -> String {
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
