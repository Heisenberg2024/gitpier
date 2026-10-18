import AppKit
import Combine
import GitPierCore
import SwiftUI

struct QuickOpenView: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @State private var query = ""
  @State private var selection = 0
  @State private var mode = "recent"
  @State private var contextRevision = 0
  @FocusState private var focused: Bool
  var records: [RepositoryRecord] {
    let entries = store.repositories.map { store.workspace.entries[$0.id] ?? WorkspaceEntry(record: $0) }
    let ids = Set(WorkspaceSearchService.metadata(entries, query: query).map(\.repositoryID))
    return store.repositories.filter { ids.contains($0.id) && (mode != "favorites" || $0.favorite) }
      .sorted { $0.lastOpened > $1.lastOpened }
  }
  var commands: [WorkspaceCommand] {
    _ = contextRevision
    let source = mode == "recent" ? store.recentCommands : mode == "commands" ? WorkspaceCommand.allCases : []
    return source.filter { query.isEmpty || $0.title(store).localizedCaseInsensitiveContains(query) || $0.rawValue.localizedCaseInsensitiveContains(query) }
  }
  var resultCount: Int { commands.count + (mode == "commands" ? 0 : records.count) }
  private func activateSelection() {
    if selection < commands.count { execute(commands[selection]) }
    else if mode != "commands", records.indices.contains(selection - commands.count) { open(records[selection - commands.count]) }
  }
  private func execute(_ command: WorkspaceCommand) {
    guard command.unavailable(store) == nil else { return }
    dismiss()
    // Let the palette sheet dismiss before opening the existing workflow's panel.
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(180))
      command.execute(store)
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(store.text("Quick Open", "快速打开")).font(.title2.weight(.semibold))
      Text(store.showDashboard ? store.text("Dashboard", "仓库总览") : store.current?.title ?? store.text("No repository selected", "未选择仓库")).font(.caption).foregroundStyle(.secondary).id(contextRevision)
      TextField(store.text("Search repositories and commands", "搜索仓库和命令"), text: $query)
        .textFieldStyle(.roundedBorder).focused($focused)
      Picker(store.text("Show", "显示"), selection: $mode) {
        Text(store.text("Repositories", "仓库")).tag("repositories")
        Text(store.text("Commands", "命令")).tag("commands")
        Text(store.text("Recent", "最近使用")).tag("recent")
        Text(store.text("Favorites", "收藏" )).tag("favorites")
      }.pickerStyle(.segmented)
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(spacing: 3) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
              Button { execute(command) } label: {
                HStack {
                  VStack(alignment: .leading, spacing: 3) {
                    Text(command.title(store))
                    if let reason = command.unavailable(store) { Text(reason).font(.caption).foregroundStyle(.secondary) }
                  }
                  Spacer()
                  if command.unavailable(store) != nil { Image(systemName: "lock") }
                }.padding(10).frame(maxWidth: .infinity).contentShape(Rectangle())
                  .background(index == selection ? Color.accentColor.opacity(0.15) : Color.clear)
              }.buttonStyle(.workspace).disabled(command.unavailable(store) != nil).id("command-" + command.id)
            }
            ForEach(Array((mode == "commands" ? [] : records).enumerated()), id: \.element.id) { index, record in
              Button { open(record) } label: {
                VStack(alignment: .leading, spacing: 3) {
                  HStack { Text(record.name).fontWeight(.medium); if record.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }; Spacer(); Text(record.group).foregroundStyle(.secondary) }
                  Text(record.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }.padding(10).frame(maxWidth: .infinity).contentShape(Rectangle())
                  .background(index + commands.count == selection ? Color.accentColor.opacity(0.15) : Color.clear)
                  .clipShape(RoundedRectangle(cornerRadius: 6))
              }.buttonStyle(.workspace).id(record.id)
            }
            if resultCount == 0 { Text(store.text("No matching repositories", "没有匹配的仓库")).foregroundStyle(.secondary).padding() }
          }
        }.onChange(of: selection) { _, index in if index < commands.count { reader.scrollTo("command-" + commands[index].id) } else if records.indices.contains(index - commands.count) { reader.scrollTo(records[index - commands.count].id) } }
      }
      HStack { Text(store.text("↑ ↓ Choose · Return Open · Esc Close", "↑ ↓ 选择 · 回车打开 · Esc 关闭")).font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Button(store.text("Close", "关闭")) { dismiss() } }
    }.padding(22).frame(width: 590, height: 440)
      .background(Theme.editor(store.resolvedColorScheme))
      .onAppear { focused = true }
      .onReceive(store.workspace.objectWillChange.receive(on: DispatchQueue.main)) { _ in contextRevision &+= 1 }
      .onReceive(store.hosting.objectWillChange.receive(on: DispatchQueue.main)) { _ in contextRevision &+= 1 }
      .onReceive((store.current?.objectWillChange.eraseToAnyPublisher() ?? Empty<Void, Never>().eraseToAnyPublisher()).receive(on: DispatchQueue.main)) { _ in contextRevision &+= 1 }
      .onChange(of: query) { _, _ in selection = 0 }.onChange(of: mode) { _, _ in selection = 0 }
      .background(QuickOpenKeys { key in
        switch key {
        case 125: selection = min(max(0, resultCount - 1), selection + 1)
        case 126: selection = max(0, selection - 1)
        case 36, 76: activateSelection()
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
