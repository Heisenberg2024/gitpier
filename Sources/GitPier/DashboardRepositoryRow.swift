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
          Button(action: disclose) { Image(systemName: collapsed ? "chevron.right" : "chevron.down").frame(width: 18, height: 28) }
            .buttonStyle(.workspace).help(store.text("Expand / collapse related worktrees", "展开 / 收起关联工作树"))
            .accessibilityLabel(store.text("Expand / collapse related worktrees", "展开 / 收起关联工作树") + " " + entry.record.name)
        } else {
          Image(systemName: row.isChild ? "arrow.turn.down.right" : "shippingbox")
            .foregroundStyle(.tertiary).frame(width: 18)
        }
      }.font(uiFont(size: 11))
      Button { store.select(entry.record.id) } label: {
        HStack(spacing: 14) {
          identity.frame(width: columns.identity, alignment: .leading)
          if !columns.compact { branch.frame(width: columns.branch, alignment: .leading) }
          changes.frame(width: columns.changes, alignment: .leading)
          sync.frame(width: columns.sync, alignment: .leading)
          if columns.showsUpdated { collection.font(uiFont(size: 11)).foregroundStyle(.secondary).frame(width: columns.updated, alignment: .leading) }
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
      .nativeContextMenu { repositoryContextMenu(entry.record, store: store) }
  }
  private var identity: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        Text(entry.record.name).font(repositoryFont(sizeOffset: 2, weight: .semibold)).lineLimit(1)
        if entry.record.favorite { Image(systemName: "star.fill").font(uiFont(size: 10)).foregroundStyle(.secondary) }
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
    VStack(alignment: .leading, spacing: 4) {
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
    VStack(alignment: .leading, spacing: 4) {
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
      } else { collection }
      if entry.usable != nil && !columns.showsUpdated && entry.state != .fresh { collection }
    }.font(uiFont(size: 12)).monospacedDigit().lineLimit(1)
  }
  private var accessibleStatus: String {
    guard let value = entry.usable else { return entry.failure?.summary ?? store.text("Not scanned", "尚未采集") }
    return value.branch + ", " + store.text("\(value.tracked + value.untracked) modified, \(value.staged) staged, \(value.conflicts) conflicts, \(value.ahead) ahead, \(value.behind) behind",
      "\(value.tracked + value.untracked) 项修改，\(value.staged) 项暂存，\(value.conflicts) 个冲突，领先 \(value.ahead)，落后 \(value.behind)")
  }
  private var sync: some View {
    RepositorySyncStatus(entry: entry, workspace: store.workspace)
  }
  @ViewBuilder private var collection: some View {
    switch entry.state {
    case .collecting: Label(store.text("Scanning", "正在采集"), systemImage: "ellipsis.circle")
    case .queued: Text(store.text("Queued", "等待采集"))
    case .unscanned: Text(store.text("Not scanned", "尚未采集"))
    case .stale: Text(store.text("Needs refresh", "需要刷新")).foregroundStyle(.orange)
    case .failed: Text(store.text("Unavailable", "不可用")).foregroundStyle(.orange).help(entry.failure?.summary ?? "")
    case .fresh:
      if let date = entry.snapshot?.collectedAt {
        Text(date, style: .relative).environment(\.locale, Locale(identifier: store.settings.language == .english ? "en" : "zh_CN")).help(date.formatted(date: .abbreviated, time: .standard))
      }
    }
  }
}
