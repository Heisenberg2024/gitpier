import GitPierCore
import SwiftUI

struct OrganizationsView: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @State private var selectedID: UUID?
  @State private var selection: Set<UUID> = []
  @State private var destinationID: UUID?
  @State private var creating = false
  @State private var renaming = false
  @State private var deleting = false
  @State private var name = ""
  @State private var problem: String?
  var current: RepositoryOrganization? { store.organizations.first { $0.id == selectedID } }
  var members: [RepositoryRecord] {
    store.repositories.filter { $0.group == (current?.name ?? "") }.sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label(
          store.text("Organizations / Project Collections", "组织 / 项目合集"),
          systemImage: "folder.badge.gearshape"
        ).font(.title3.weight(.semibold))
        Spacer()
        Button(store.text("New Organization…", "创建组织…")) {
          name = ""
          creating = true
        }
        Button(store.text("Close", "关闭")) { dismiss() }
      }.padding(16)
      Divider()
      HSplitView {
        VStack(spacing: 0) {
          List(selection: $selectedID) {
            Label(store.text("Ungrouped", "未分组"), systemImage: "tray").tag(nil as UUID?)
            ForEach(store.organizations) { organization in
              HStack {
                Label(organization.name, systemImage: "folder")
                Spacer()
                Text("\(store.repositories.filter { $0.group == organization.name }.count)")
                  .foregroundStyle(.secondary)
              }.tag(Optional(organization.id))
            }
          }.listStyle(.sidebar)
          HStack {
            Button(store.text("Rename…", "重命名…")) {
              name = current?.name ?? ""
              renaming = true
            }.disabled(current == nil)
            Button(store.text("Remove…", "移除…"), role: .destructive) { deleting = true }.disabled(
              current == nil)
          }.controlSize(.small).padding(10)
        }.frame(minWidth: 200, idealWidth: 230, maxWidth: 280)
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text(current?.name ?? store.text("Ungrouped", "未分组")).font(.headline)
            Spacer()
            Text(store.text("\(members.count) repositories", "\(members.count) 个仓库"))
              .foregroundStyle(.secondary)
          }
          Text(
            store.text(
              "Select repositories to move them together. Removing an organization keeps every repository, draft and credential binding.",
              "选择仓库可以批量移动。移除组织会保留所有仓库、提交草稿和凭证绑定。")
          ).font(.caption).foregroundStyle(.secondary)
          List(members, selection: $selection) { record in
            VStack(alignment: .leading, spacing: 4) {
              Text(record.name).font(repositoryFont())
              Text(record.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(
                .secondary
              ).lineLimit(1)
            }.padding(.vertical, 4).tag(record.id)
          }.listStyle(.inset)
          HStack {
            Picker(store.text("Move to", "移动到"), selection: $destinationID) {
              Text(store.text("Ungrouped", "未分组")).tag(nil as UUID?)
              ForEach(store.organizations) { Text($0.name).tag(Optional($0.id)) }
            }
            Button(store.text("Move Selected", "移动选中仓库")) {
              perform {
                try store.moveRepositories(selection, to: destinationID)
                selection = []
              }
            }.disabled(selection.isEmpty)
          }
        }.padding(18).frame(minWidth: 390)
      }
    }.frame(minWidth: 680, minHeight: 430).buttonStyle(.bordered)
      .onChange(of: selectedID) { selection = [] }
      .alert(store.text("Create Organization", "创建组织"), isPresented: $creating) {
        TextField(store.text("Name", "名称"), text: $name)
        Button(store.text("Create", "创建")) {
          perform { selectedID = try store.createOrganization(name).id }
        }
        Button(store.text("Cancel", "取消"), role: .cancel) {}
      }
      .alert(store.text("Rename Organization", "重命名组织"), isPresented: $renaming) {
        TextField(store.text("Name", "名称"), text: $name)
        Button(store.text("Save", "保存")) {
          perform { if let selectedID { try store.renameOrganization(selectedID, name: name) } }
        }
        Button(store.text("Cancel", "取消"), role: .cancel) {}
      }
      .alert(store.text("Remove Organization?", "移除组织？"), isPresented: $deleting) {
        Button(store.text("Remove", "移除"), role: .destructive) {
          if let selectedID { store.removeOrganization(selectedID) }
          selectedID = nil
          selection = []
        }
        Button(store.text("Cancel", "取消"), role: .cancel) {}
      } message: {
        Text(
          store.text(
            "Its repositories move to Ungrouped. No repository directory is deleted.",
            "组织内的仓库会移到未分组，不会删除磁盘目录。"))
      }
      .alert(
        store.text("Organization", "组织"),
        isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
      ) {
        Button(store.text("Close", "关闭")) { problem = nil }
      } message: {
        Text(problem ?? "")
      }
  }
  func perform(_ action: () throws -> Void) {
    do { try action() } catch { problem = error.localizedDescription }
  }
}
