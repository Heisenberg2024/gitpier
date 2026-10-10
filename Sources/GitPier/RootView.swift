import GitPierCore
import SwiftUI

struct RootView: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.colorScheme) var scheme
  @State private var sidebarVisible = true
  @State private var repositorySearch = ""
  @State private var removing: RepositoryRecord?
  @State private var creatingOrganization = false
  @State private var organizationName = ""
  @State private var collapsedGroups: Set<String> = []
  var body: some View {
    HStack(spacing: 0) {
      if sidebarVisible {
        sidebar.frame(width: 202)
        Divider()
      }
      VStack(spacing: 0) {
        if store.showDashboard || store.current == nil {
          DashboardView()
        } else if let model = store.current {
          RepositoryWorkspace(model: model)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Theme.editor(scheme))
    .toolbar {
      ToolbarItem(placement: .navigation) {
        Button {
          sidebarVisible.toggle()
        } label: {
          Image(systemName: "sidebar.left")
        }.help(store.text("Toggle Repositories", "显示 / 隐藏仓库"))
      }
      ToolbarItem(placement: .principal) {
        Text(store.showDashboard ? "GitPier" : (store.current?.title ?? "GitPier"))
          .font(repositoryFont(sizeOffset: 1, weight: .semibold)).lineLimit(1).truncationMode(
            .middle
          )
          .padding(.horizontal, 14).frame(minWidth: 110, maxWidth: 380).frame(
            height: 24, alignment: .center
          )
          .help(store.current?.title ?? "GitPier")
      }
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          store.openRepository()
        } label: {
          Image(systemName: "folder.badge.plus")
        }.help(store.text("Open Repository (⌘O)", "打开仓库 (⌘O)"))
        Button {
          store.showClone = true
        } label: {
          Image(systemName: "square.and.arrow.down")
        }.help(store.text("Clone Repository", "克隆仓库"))
        Menu {
          ForEach(
            Array(
              store.repositories.sorted { $0.lastOpened > $1.lastOpened }.prefix(
                store.settings.recentLimit))
          ) { record in Button(record.name) { store.select(record.id) } }
        } label: {
          Image(systemName: "clock")
        }.help(store.text("Recent Repositories", "最近仓库"))
        Menu {
          ForEach(AppearanceMode.allCases, id: \.self) { mode in
            Button(localizedUI(mode.rawValue.capitalized)) {
              var settings = store.settings
              settings.appearance = mode
              store.updateSettings(settings)
            }
          }
        } label: {
          Image(systemName: "circle.lefthalf.filled")
        }.help(store.text("Appearance", "外观"))
      }
    }
    .sheet(isPresented: $store.showOrganizations) {
      OrganizationsView().environmentObject(store).frame(width: 760, height: 510)
    }
    .alert(store.text("Create Organization", "创建组织"), isPresented: $creatingOrganization) {
      TextField(store.text("Name", "名称"), text: $organizationName)
      Button(store.text("Create", "创建")) {
        do { _ = try store.createOrganization(organizationName) } catch {
          store.error = error.localizedDescription
        }
      }
      Button(store.text("Cancel", "取消"), role: .cancel) {}
    }
    .sheet(isPresented: $store.showClone) { CloneSheet().environmentObject(store) }
    .sheet(isPresented: $store.showCredentials) {
      CredentialsView().environmentObject(store).frame(width: 750, height: 540)
    }
    .sheet(isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } }))
    {
      ErrorSheet(title: store.text("GitPier", "GitPier"), detail: store.error ?? "") {
        store.error = nil
      }
    }
    .alert(
      store.text("Remove from workspace?", "从工作空间移除？"),
      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    ) {
      Button(store.text("Remove", "移除"), role: .destructive) {
        if let removing { store.remove(removing.id) }
        removing = nil
      }
      Button(store.text("Cancel", "取消"), role: .cancel) { removing = nil }
    } message: {
      Text(
        store.text(
          "The repository on disk is preserved. Associated terminal sessions will stop.",
          "磁盘上的仓库将保留，关联终端会话将停止。"))
    }
    .background(WindowLifecycle())
  }
  var sidebar: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        if let image = AppResources.applicationIcon {
          Image(nsImage: image).resizable().frame(width: 26, height: 26)
        }
        Text(localizedUI("GitPier")).font(uiFont(size: 16, weight: .semibold))
        Spacer()
      }.padding(14)
      sidebarButton(
        store.text("Workspace", "工作空间"), icon: "square.grid.2x2", active: store.showDashboard
      ) {
        store.dashboardOrganization = nil
        store.showDashboard = true
      }
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField(store.text("Find repository", "搜索仓库"), text: $repositorySearch).textFieldStyle(
          .plain)
      }.font(uiFont(size: 11)).padding(8).background(Color.primary.opacity(0.04)).clipShape(
        RoundedRectangle(cornerRadius: 5)
      ).padding(10)
      ScrollView {
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text(store.text("ORGANIZATIONS", "组织 / 项目合集")).font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.secondary)
            Spacer()
            IconButton("folder.badge.plus", help: store.text("New Organization", "创建组织")) {
              organizationName = ""
              creatingOrganization = true
            }
            IconButton("gearshape", help: store.text("Manage Organizations / Groups", "管理组织 / 分组"))
            { store.showOrganizations = true }
          }.padding(.horizontal, 12).padding(.top, 6)
          ForEach(groupNames, id: \.self) { group in
            HStack(spacing: 3) {
              IconButton(
                collapsedGroups.contains(group) ? "chevron.right" : "chevron.down",
                help: store.text("Expand / Collapse", "展开 / 收起")
              ) {
                if collapsedGroups.contains(group) {
                  collapsedGroups.remove(group)
                } else {
                  collapsedGroups.insert(group)
                }
              }
              Button {
                store.dashboardOrganization = group
                store.showDashboard = true
              } label: {
                HStack {
                  Image(systemName: group.isEmpty ? "tray" : "folder")
                  Text(group.isEmpty ? store.text("Ungrouped", "未分组") : group).lineLimit(1)
                  Spacer()
                  Text("\(store.repositories.filter { $0.group == group }.count)").foregroundStyle(
                    .secondary)
                }
                .font(.system(size: 11, weight: .medium)).frame(
                  maxWidth: .infinity, alignment: .leading
                ).padding(.vertical, 6).contentShape(Rectangle())
              }.buttonStyle(.workspace)
            }.padding(.horizontal, 9).padding(.top, 7)
              .contextMenu {
                Button(store.text("Manage Organization…", "管理组织…")) {
                  store.showOrganizations = true
                }
                Button(store.text("Open Repository…", "打开仓库…")) { store.openRepository() }
              }
            if !collapsedGroups.contains(group) {
              ForEach(
                store.repositories.filter {
                  $0.group == group
                    && (repositorySearch.isEmpty
                      || $0.name.localizedCaseInsensitiveContains(repositorySearch)
                      || $0.path.localizedCaseInsensitiveContains(repositorySearch))
                }.sorted {
                  $0.favorite != $1.favorite ? $0.favorite : $0.lastOpened > $1.lastOpened
                }
              ) { record in
                sidebarButton(
                  record.name, icon: record.favorite ? "star.fill" : "shippingbox",
                  active: !store.showDashboard && store.selectedID == record.id
                ) { store.select(record.id) }
                .contextMenu {
                  Button(
                    record.favorite
                      ? store.text("Unfavorite", "取消收藏") : store.text("Favorite", "收藏")
                  ) {
                    if let model = store.models[record.id] {
                      model.record.favorite.toggle()
                      store.update(model.record)
                    }
                  }
                  Button(store.text("Reveal in Finder", "在 Finder 中显示")) {
                    store.models[record.id]?.reveal()
                  }
                  Button(store.text("Copy Path", "复制路径")) { copyText(record.path) }
                  Button(store.text("Open in Editor", "在编辑器中打开")) {
                    store.models[record.id]?.openEditor()
                  }
                  Menu(store.text("Move to Organization", "移动到组织")) {
                    Button(store.text("Ungrouped", "未分组")) {
                      try? store.moveRepositories([record.id], to: nil)
                    }
                    ForEach(store.organizations) { organization in
                      Button(organization.name) {
                        do { try store.moveRepositories([record.id], to: organization.id) } catch {
                          store.error = error.localizedDescription
                        }
                      }
                    }
                  }
                  Divider()
                  Button(store.text("Remove from workspace…", "从工作空间移除…"), role: .destructive) {
                    removing = record
                  }
                }
              }
            }
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 14)
      }
      Spacer(minLength: 0)
      Divider()
      sidebarButton(store.text("Credentials", "凭证"), icon: "key", active: false) {
        store.showCredentials = true
      }
      SettingsLink {
        Label(store.text("Settings", "设置"), systemImage: "gearshape").font(uiFont(size: 12)).frame(
          maxWidth: .infinity, alignment: .leading
        ).padding(10)
      }.buttonStyle(.workspace).padding(.horizontal, 6)
      Text(localizedUI("Native Git Client for macOS")).font(uiFont(size: 9)).foregroundStyle(
        .tertiary
      )
      .padding(
        .bottom, 12)
    }.background(Theme.sidebar(scheme)).contentShape(Rectangle()).contextMenu {
      Button(store.text("Open Repository…", "打开仓库…")) { store.openRepository() }
      Button(store.text("Clone Repository…", "克隆仓库…")) { store.showClone = true }
      Divider()
      Button(store.text("Create Organization…", "创建组织…")) {
        organizationName = ""
        creatingOrganization = true
      }
      Button(store.text("Manage Organizations / Groups…", "管理组织 / 分组…")) {
        store.showOrganizations = true
      }
      Divider()
      Button(store.text("Refresh Repositories", "刷新仓库")) { Task { await store.refreshDashboard() } }
    }
  }
  var groupNames: [String] { [""] + store.organizations.map(\.name) }
  func sidebarButton(_ title: String, icon: String, active: Bool, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      HStack(spacing: 9) {
        Image(systemName: icon).frame(width: 15).foregroundStyle(
          active ? Color.accentColor : .secondary)
        Text(title).lineLimit(1)
        Spacer()
      }.font(repositoryFont()).frame(maxWidth: .infinity, alignment: .leading).padding(
        .horizontal, 10
      ).padding(.vertical, 9).contentShape(Rectangle()).background(
        active ? Color.accentColor.opacity(0.14) : Color.clear
      ).clipShape(RoundedRectangle(cornerRadius: 5))
    }.buttonStyle(.workspace).padding(.horizontal, 6)
  }
}

struct DashboardView: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.colorScheme) var scheme
  @State private var search = ""
  @State private var sort = "recent"
  var filtered: [RepositoryRecord] {
    store.repositories.filter {
      (store.dashboardOrganization == nil || $0.group == store.dashboardOrganization)
        && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
          || $0.path.localizedCaseInsensitiveContains(search)
          || $0.group.localizedCaseInsensitiveContains(search))
    }.sorted {
      if sort == "name" { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      if sort == "path" { return $0.path.localizedStandardCompare($1.path) == .orderedAscending }
      return $0.lastOpened > $1.lastOpened
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 5) {
          Text(
            store.dashboardOrganization.map { $0.isEmpty ? store.text("Ungrouped", "未分组") : $0 }
              ?? store.text("Workspace", "工作空间")
          ).font(uiFont(size: 27, weight: .semibold))
          Text(localizedUI("All Your Repositories. One Workspace.")).font(uiFont(size: 13))
            .foregroundStyle(
              .secondary)
        }
        Spacer()
        Button(store.text("Organizations…", "组织管理…")) { store.showOrganizations = true }
        Button(store.text("Refresh", "刷新")) { Task { await store.refreshDashboard() } }
        Button(store.text("Clone…", "克隆…")) { store.showClone = true }
        Button(store.text("Open Repository…", "打开仓库…")) { store.openRepository() }.buttonStyle(
          .borderedProminent)
      }.padding(28)
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField(store.text("Search by name, path or group", "搜索名称、路径或分组"), text: $search)
          .textFieldStyle(.plain)
        Spacer()
        Picker(store.text("Sort", "排序"), selection: $sort) {
          Text(store.text("Recent", "最近使用")).tag("recent")
          Text(store.text("Name", "名称")).tag("name")
          Text(store.text("Path", "路径")).tag("path")
        }.frame(width: 150)
      }.padding(.horizontal, 28).padding(.bottom, 18)
      Divider()
      if filtered.isEmpty {
        EmptyState(
          symbol: "shippingbox", title: store.text("Your repositories, together", "汇聚你的代码仓库"),
          detail: store.text(
            "Open an existing Git repository or clone a remote to start reviewing and committing real changes.",
            "打开已有 Git 仓库或克隆远程仓库，开始审查和提交真实变更。"))
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(filtered) { record in
              if let model = store.models[record.id] {
                Button {
                  store.select(record.id)
                } label: {
                  RepositoryRow(model: model).frame(maxWidth: .infinity).contentShape(Rectangle())
                }.buttonStyle(.workspace)
                Divider().padding(.leading, 28)
              }
            }
          }
        }
      }
      HStack {
        Text(
          store.text("\(store.repositories.count) repositories", "\(store.repositories.count) 个仓库"))
        Spacer()
        OperationProgressView(progress: store.cloneActivity) { store.cloneTask?.cancel() }
        Text(localizedUI("GitPier 1.0.0"))
      }.font(uiFont(size: 11)).foregroundStyle(.secondary).padding(12).background(
        Theme.panel(scheme))
    }.task { for model in store.models.values where !model.available { await model.activate() } }
  }
}

struct RepositoryRow: View {
  @ObservedObject var model: RepositoryModel
  @EnvironmentObject var store: AppStore
  var body: some View {
    HStack(spacing: 16) {
      Image(systemName: "shippingbox").font(uiFont(size: 22, weight: .light)).foregroundStyle(
        .secondary
      ).frame(width: 36)
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(model.title).font(repositoryFont(sizeOffset: 3, weight: .semibold))
          if model.record.favorite {
            Image(systemName: "star.fill").font(uiFont(size: 9)).foregroundStyle(.yellow)
          }
          if !model.record.group.isEmpty { Badge(text: model.record.group) }
        }
        Text(model.record.path).font(uiFont(size: 11, design: .monospaced)).foregroundStyle(
          .secondary
        ).lineLimit(1)
      }
      Spacer()
      if !model.available {
        Badge(text: store.text("Unavailable", "不可用"), color: .orange)
      } else {
        Label(model.status.branch, systemImage: "arrow.triangle.branch").font(uiFont(size: 11))
          .foregroundStyle(.secondary)
        VStack(alignment: .trailing, spacing: 5) {
          Text(
            store.text(
              "\(model.trackedCount) tracked · \(model.untrackedCount) untracked",
              "\(model.trackedCount) 已跟踪 · \(model.untrackedCount) 未跟踪")
          ).font(uiFont(size: 11))
          HStack {
            Badge(text: "\(model.stagedCount) staged", color: .mint)
            if model.status.ahead + model.status.behind > 0 {
              Badge(text: "↑\(model.status.ahead) ↓\(model.status.behind)")
            }
            if model.status.files.contains(where: \.isConflicted) {
              Badge(text: "Conflict", color: .red)
            }
          }
        }
      }
      Image(systemName: "chevron.right").font(uiFont(size: 10)).foregroundStyle(.tertiary)
    }.padding(.horizontal, 28).padding(.vertical, 22).contentShape(Rectangle())
  }
}

struct CloneSheet: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @State private var url = ""
  @State private var destination = ""
  @State private var credential: UUID?
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(store.text("Clone Repository", "克隆仓库")).font(.title2.weight(.semibold))
      Text(
        store.text(
          "HTTPS or SSH. Credentials are stored separately in Keychain.",
          "支持 HTTPS 和 SSH，凭证单独保存于 Keychain。 ")
      ).font(.callout).foregroundStyle(.secondary)
      TextField(store.text("Repository URL", "仓库 URL"), text: $url)
      HStack {
        TextField(store.text("Destination (new directory)", "目标目录（新目录）"), text: $destination)
        Button(store.text("Choose…", "选择…")) {
          let panel = NSSavePanel()
          panel.nameFieldStringValue =
            URL(string: url)?.deletingPathExtension().lastPathComponent ?? "repository"
          panel.canCreateDirectories = true
          if panel.runModal() == .OK { destination = panel.url?.path ?? "" }
        }
      }
      Picker(store.text("Authentication", "认证"), selection: $credential) {
        Text(store.text("System Git / SSH", "系统 Git / SSH")).tag(nil as UUID?)
        ForEach(store.configuration.credentials) { Text($0.name).tag(Optional($0.id)) }
      }
      if store.cloning {
        HStack {
          ProgressView().controlSize(.small)
          Text(store.text("Cloning…", "克隆中…"))
          Spacer()
          Button(store.text("Cancel Clone", "取消克隆")) { store.cloneTask?.cancel() }
        }
      }
      HStack {
        Spacer()
        Button(store.text("Close", "关闭")) { dismiss() }.disabled(store.cloning)
        Button(store.text("Clone", "克隆")) {
          store.clone(
            url: url, destination: URL(fileURLWithPath: destination), credential: credential)
        }.buttonStyle(.borderedProminent).disabled(
          url.isEmpty || destination.isEmpty || store.cloning)
      }
    }.textFieldStyle(.roundedBorder).padding(28).frame(width: 560).interactiveDismissDisabled(
      store.cloning)
  }
}

struct ErrorSheet: View {
  let title: String
  let detail: String
  var dismiss: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label(title, systemImage: "exclamationmark.triangle").font(.title3.weight(.semibold))
      ScrollView {
        Text(detail).font(uiFont(size: 12, design: .monospaced)).textSelection(.enabled).frame(
          maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Button(localizedUI("Copy Details")) { copyText(detail) }
        Spacer()
        Button(localizedUI("Close"), action: dismiss).keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 640, height: 380)
  }
}
