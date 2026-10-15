import AppKit
import GitPierCore
import SwiftUI

struct QuickOpenView: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @State private var query = ""
  @State private var selection = 0
  @State private var mode = "recent"
  @FocusState private var focused: Bool
  var records: [RepositoryRecord] {
    let entries = store.repositories.map { store.workspace.entries[$0.id] ?? WorkspaceEntry(record: $0) }
    let ids = Set(WorkspaceSearchService.metadata(entries, query: query).map(\.repositoryID))
    return store.repositories.filter { ids.contains($0.id) && (mode != "favorites" || $0.favorite) }
      .sorted { $0.lastOpened > $1.lastOpened }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(store.text("Quick Open", "快速打开")).font(.title2.weight(.semibold))
      TextField(store.text("Search repositories or organizations", "搜索仓库或组织"), text: $query)
        .textFieldStyle(.roundedBorder).focused($focused)
      Picker(store.text("Show", "显示"), selection: $mode) {
        Text(store.text("Recent", "最近使用")).tag("recent")
        Text(store.text("Favorites", "收藏" )).tag("favorites")
      }.pickerStyle(.segmented)
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(spacing: 3) {
            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
              Button { open(record) } label: {
                VStack(alignment: .leading, spacing: 3) {
                  HStack { Text(record.name).fontWeight(.medium); if record.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }; Spacer(); Text(record.group).foregroundStyle(.secondary) }
                  Text(record.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }.padding(10).frame(maxWidth: .infinity).contentShape(Rectangle())
                  .background(index == selection ? Color.accentColor.opacity(0.15) : Color.clear)
                  .clipShape(RoundedRectangle(cornerRadius: 6))
              }.buttonStyle(.workspace).id(record.id)
            }
            if records.isEmpty { Text(store.text("No matching repositories", "没有匹配的仓库")).foregroundStyle(.secondary).padding() }
          }
        }.onChange(of: selection) { _, index in if records.indices.contains(index) { reader.scrollTo(records[index].id) } }
      }
      HStack { Text(store.text("↑ ↓ Choose · Return Open · Esc Close", "↑ ↓ 选择 · 回车打开 · Esc 关闭")).font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Button(store.text("Close", "关闭")) { dismiss() } }
    }.padding(22).frame(width: 590, height: 440)
      .onAppear { focused = true }
      .onChange(of: query) { _, _ in selection = 0 }.onChange(of: mode) { _, _ in selection = 0 }
      .background(QuickOpenKeys { key in
        switch key {
        case 125: selection = min(max(0, records.count - 1), selection + 1)
        case 126: selection = max(0, selection - 1)
        case 36, 76: if records.indices.contains(selection) { open(records[selection]) }
        case 53: dismiss()
        default: break
        }
      })
  }
  private func open(_ record: RepositoryRecord) {
    guard store.repositories.contains(where: { $0.id == record.id }) else { return }
    store.select(record.id); dismiss()
  }
}

/// Native key routing limited to this sheet's window; never consumes terminal keys.
private struct QuickOpenKeys: NSViewRepresentable {
  let action: (UInt16) -> Void
  func makeNSView(context: Context) -> KeyView { let view = KeyView(); view.action = action; return view }
  func updateNSView(_ view: KeyView, context: Context) { view.action = action }
  static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.removeMonitor() }
  final class KeyView: NSView {
    var action: ((UInt16) -> Void)?
    var monitor: Any?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow(); removeMonitor()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, event.window === self.window, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              [UInt16(125), 126, 36, 76, 53].contains(event.keyCode) else { return event }
        self.action?(event.keyCode); return nil
      }
    }
    func removeMonitor() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
  }
}
