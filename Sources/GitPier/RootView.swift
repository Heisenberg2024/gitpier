import AppKit
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
    VStack(spacing: 0) {
      if let notice = store.notice {
        HStack(spacing: 10) {
          Text(notice).font(uiFont(size: 11)).textSelection(.enabled)
          Spacer()
          IconButton("xmark", help: localizedUI("Dismiss")) { store.notice = nil }
        }.padding(10).background(Color.accentColor.opacity(0.05))
        Divider()
      }
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
    .sheet(isPresented: $store.showWorkspaceSearch) { WorkspaceSearchView().environmentObject(store) }
    .sheet(isPresented: $store.showQuickOpen) { QuickOpenView().environmentObject(store) }
    .modifier(WorkspaceFetchPresentation(workspace: store.workspace))
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
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 4) {
            Text(store.text("Organizations", "组织 / 项目合集")).font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            IconButton(
              allOrganizationsCollapsed
                ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
              help: allOrganizationsCollapsed
                ? store.text("Expand All Organizations", "展开全部组织")
                : store.text("Collapse All Organizations", "收起全部组织")
            ) {
              if allOrganizationsCollapsed {
                collapsedGroups.removeAll()
              } else {
                collapsedGroups = Set(groupNames)
              }
            }
            IconButton("folder.badge.plus", help: store.text("New Organization", "创建组织")) {
              organizationName = ""
              creatingOrganization = true
            }
            IconButton("gearshape", help: store.text("Manage Organizations / Groups", "管理组织 / 分组"))
            { store.showOrganizations = true }
          }.padding(.horizontal, 12).padding(.top, 6)
          ForEach(groupNames, id: \.self) { group in
            VStack(alignment: .leading, spacing: 4) {
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
                    Image(systemName: group.isEmpty ? "tray.fill" : "folder.fill")
                      .foregroundStyle(Color.accentColor).frame(width: 16)
                    Text(group.isEmpty ? store.text("Ungrouped", "未分组") : group).lineLimit(1)
                    Spacer()
                    Text("\(store.repositories.filter { $0.group == group }.count)")
                      .font(.system(size: 10, weight: .medium)).monospacedDigit()
                      .foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 2)
                      .background(Color.primary.opacity(0.06), in: Capsule())
                  }
                  .font(.system(size: 12, weight: .semibold)).frame(
                    maxWidth: .infinity, alignment: .leading
                  ).padding(.vertical, 6).contentShape(Rectangle())
                }.buttonStyle(.workspace)
              }.padding(.horizontal, 6).padding(.vertical, 3)
                .background(
                  store.showDashboard && store.dashboardOrganization == group
                    ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.045),
                  in: RoundedRectangle(cornerRadius: 7)
                )
                .contextMenu {
                  Button(store.text("Manage Organization…", "管理组织…")) {
                    store.showOrganizations = true
                  }
                  Button(store.text("Open Repository…", "打开仓库…")) {
                    store.openRepository(in: group)
                  }
                }
              if !collapsedGroups.contains(group) {
                VStack(alignment: .leading, spacing: 1) {
                  ForEach(
                    store.repositories.filter {
                      $0.group == group
                        && (repositorySearch.isEmpty
                          || $0.name.localizedCaseInsensitiveContains(repositorySearch)
                          || $0.path.localizedCaseInsensitiveContains(repositorySearch))
                    }
                  ) { record in
                    sidebarButton(
                      record.name, icon: record.favorite ? "star.fill" : "shippingbox",
                      active: !store.showDashboard && store.selectedID == record.id
                    ) { store.select(record.id) }
                    .padding(.leading, 22)
                    .repositoryReordering(record)
                    .nativeContextMenu { repositoryMenu(record) }
                  }
                }.overlay(alignment: .leading) {
                  Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1)
                    .padding(.leading, 21).padding(.vertical, 4)
                    .allowsHitTesting(false)
                }
              }
            }.padding(.horizontal, 8).padding(.top, 4)
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
  func repositoryMenu(_ record: RepositoryRecord) -> NSMenu {
    repositoryContextMenu(record, store: store) { removing = record }
  }
  var groupNames: [String] { [""] + store.organizations.map(\.name) }
  var allOrganizationsCollapsed: Bool { Set(groupNames).isSubset(of: collapsedGroups) }
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

/// Dashboard and sidebar share the native editor / organization actions.
@MainActor func repositoryContextMenu(_ record: RepositoryRecord, store: AppStore, remove: (() -> Void)? = nil) -> NSMenu {
    var items = [
      NativeMenuItems.action(
        record.favorite ? store.text("Unfavorite", "取消收藏") : store.text("Favorite", "收藏")
      ) {
        if let model = store.models[record.id] {
          model.record.favorite.toggle()
          store.update(model.record)
        }
      },
      NativeMenuItems.action(store.text("Reveal in Finder", "在 Finder 中显示")) {
        store.models[record.id]?.reveal()
      },
      NativeMenuItems.action(store.text("Copy Path", "复制路径")) { copyText(record.path) },
    ]
    if let model = store.models[record.id] {
      items.append(NativeMenuItems.editor(model: model))
    }
    var groups = [
      NativeMenuItems.action(store.text("Ungrouped", "未分组")) {
        try? store.moveRepositories([record.id], to: nil)
      }
    ]
    groups += store.organizations.map { organization in
      NativeMenuItems.action(organization.name) {
        do { try store.moveRepositories([record.id], to: organization.id) } catch {
          store.error = error.localizedDescription
        }
      }
    }
    items.append(NativeMenuItems.submenu(store.text("Move to Organization", "移动到组织"), groups))
    if let remove {
      items.append(.separator())
      items.append(NativeMenuItems.action(store.text("Remove from workspace…", "从工作空间移除…"), remove))
    }
    return NativeMenuItems.menu(items)
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
