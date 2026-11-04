import GitPierCore
import SwiftUI

struct DashboardRepositoryRow: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.colorScheme) private var scheme
  @State private var hovering = false
  @State private var showFailure = false
  @FocusState private var focused: Bool
  let row: WorkspaceListing.Row
  let columns: DashboardColumns
  let selected: Bool
  let collapsed: Bool
  let select: (Bool) -> Void
  let disclose: () -> Void
  private var entry: WorkspaceEntry { row.entry }
  var body: some View {
    HStack(spacing: 10) {
      Toggle(store.text("Select", "选择") + " " + entry.record.name, isOn: Binding(get: { selected }, set: { select($0) }))
        .labelsHidden().toggleStyle(.checkbox).frame(width: 18)
      Group {
        if row.canCollapse {
          VStack(spacing: 0) {
            Button(action: disclose) { Image(systemName: collapsed ? "chevron.right" : "chevron.down").frame(width: 18, height: 28) }
              .buttonStyle(.workspace).help(store.text("Expand / collapse related worktrees", "展开 / 收起关联工作树"))
              .accessibilityLabel(store.text("Expand / collapse related worktrees", "展开 / 收起关联工作树") + " " + entry.record.name)
            dragHandle("shippingbox")
          }
        } else {
          dragHandle(row.isChild ? "arrow.turn.down.right" : "shippingbox")
        }
      }.font(uiFont(size: 11))
      Button { store.select(entry.record.id) } label: {
        HStack(spacing: 14) {
          identity.frame(width: columns.identity, alignment: .leading)
          if !columns.compact { branch.frame(width: columns.branch, alignment: .center) }
          changes.frame(width: columns.changes, alignment: .center)
          sync.frame(width: columns.sync, alignment: .center)
        }.frame(minHeight: columns.compact ? 72 : 66).contentShape(Rectangle())
      }.buttonStyle(.plain).focused($focused).accessibilityLabel(store.text("Open", "打开") + " " + entry.record.name)
        .accessibilityValue(accessibleStatus)
      Group {
        if entry.failure != nil {
          Button { showFailure = true } label: { Image(systemName: "info.circle").frame(width: 18, height: 28) }
            .buttonStyle(.workspace).foregroundStyle(.orange)
            .accessibilityLabel(store.text("Error details", "错误详情") + " " + entry.record.name)
            .popover(isPresented: $showFailure) {
              VStack(alignment: .leading, spacing: 12) {
                Text(entry.record.name).font(.headline)
                Text(entry.failure?.summary ?? "").font(uiFont(size: 12)).textSelection(.enabled)
                Button(store.text("Refresh Local Status", "刷新本地状态")) {
                  showFailure = false; Task { await store.workspace.refresh([entry.record.id]) }
                }
              }.padding(18).frame(width: 360)
                .modifier(AppPopoverAppearance(store: store))
            }
        } else { Color.clear.frame(width: 18).allowsHitTesting(false) }
      }
    }.padding(.horizontal, 10)
      .background(selected ? Color.accentColor.opacity(0.085) : hovering ? Theme.panel(scheme).opacity(0.7) : .clear,
        in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Color.accentColor.opacity(0.75) : .clear))
      .onHover { hovering = $0 }
      .accessibilityIdentifier("dashboard-row-" + entry.record.id.uuidString)
      .accessibilityAction(named: Text(store.text("Open Repository", "打开仓库"))) {
        store.select(entry.record.id)
      }
      .nativeContextMenu { repositoryContextMenu(entry.record, store: store) }
  }
  private func dragHandle(_ symbol: String) -> some View {
    Image(systemName: symbol).foregroundStyle(.tertiary).frame(width: 18, height: 18)
      .contentShape(Rectangle())
      .help(store.text("Drag to reorder", "拖动以调整顺序"))
      .repositoryDragSource(entry.record)
  }
  private var identity: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        Text(entry.record.name).font(repositoryFont(sizeOffset: 2, weight: .semibold)).lineLimit(1)
        if entry.record.favorite { RepositoryFavoriteMark().font(uiFont(size: 10)) }
        if row.relatedCount > 1 && !row.isChild {
          Text("\(row.relatedCount)").font(uiFont(size: 10, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 2).background(Color.primary.opacity(0.055), in: Capsule())
            .help(store.text("\(row.relatedCount) related worktrees", "\(row.relatedCount) 个关联工作树"))
        }
      }
      if columns.compact { branch.font(uiFont(size: 12)) }
      Text(entry.record.path).font(uiFont(size: 11)).foregroundStyle(.secondary)
        .lineLimit(1).truncationMode(.middle).help(entry.record.path)
        .padding(.trailing, 20)
    }.padding(.leading, row.isChild ? 12 : 0)
  }
  private var branch: some View {
    VStack(alignment: columns.compact ? .leading : .center, spacing: 4) {
      Label(entry.usable.map { $0.detached ? store.text("Detached HEAD", "分离 HEAD") : $0.branch } ?? "—",
        systemImage: "arrow.triangle.branch").lineLimit(1).truncationMode(.middle)
        .help(entry.usable?.branch ?? store.text("Status unavailable", "状态不可用"))
      if !columns.compact {
        Text(entry.usable?.isWorktree == true ? store.text("Linked worktree", "关联工作树") : entry.record.group)
          .font(uiFont(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      }
      HostingDashboardBadge(hosting: store.hosting, recordID: entry.record.id, branch: entry.usable?.branch ?? "", head: entry.usable?.head, snapshotRevision: entry.usable?.collectedAt)
    }.font(uiFont(size: 12)).foregroundStyle(.secondary)
  }
  private var changes: some View {
    VStack(alignment: .center, spacing: 4) {
      if let value = entry.usable {
        if value.conflicts > 0 {
          Label(store.text("\(value.conflicts) conflicts", "\(value.conflicts) 个冲突"), systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        } else if value.modified {
          Text(store.text("\(value.tracked + value.untracked) modified", "\(value.tracked + value.untracked) 项修改")).foregroundStyle(.orange)
        } else { Text(store.text("Clean", "干净")).foregroundStyle(.secondary) }
        if value.staged > 0 {
          Text(store.text("\(value.staged) staged", "\(value.staged) 项暂存")).foregroundStyle(.green)
        }
        if let operation = value.operation {
          Text(localizedUI(operation.rawValue.capitalized)).foregroundStyle(.orange)
        }
      }
      if let collectionStatus { Text(collectionStatus).foregroundStyle(entry.state == .failed || entry.state == .stale ? Color.orange : Color.secondary) }
    }.font(uiFont(size: 12)).monospacedDigit().lineLimit(1)
  }
  private var accessibleStatus: String {
    var parts = [entry.record.favorite ? store.text("Favorite", "已收藏") : nil, collectionStatus].compactMap { $0 }
    if let value = entry.usable {
      parts += [value.branch, store.text("\(value.tracked + value.untracked) modified, \(value.staged) staged, \(value.conflicts) conflicts",
        "\(value.tracked + value.untracked) 项修改，\(value.staged) 项暂存，\(value.conflicts) 个冲突"),
        BranchSyncPresentation(state: value.syncState, store: store).accessibleText]
    }
    return parts.joined(separator: ", ")
  }
  private var sync: some View {
    RepositorySyncStatus(entry: entry, workspace: store.workspace)
  }
  private var collectionStatus: String? {
    switch entry.state {
    case .collecting: store.text("Scanning", "正在采集")
    case .queued: store.text("Queued", "等待采集")
    case .unscanned: store.text("Not scanned", "尚未采集")
    case .stale: store.text("Needs refresh", "需要刷新")
    case .failed: store.text("Unavailable", "不可用")
    case .fresh: nil
    }
  }
}
