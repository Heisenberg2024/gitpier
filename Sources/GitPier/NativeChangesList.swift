import AppKit
import GitPierCore
import SwiftUI

enum ChangesListRow: Equatable {
  case group(tracked: Bool, title: String, files: [FileChange], expanded: Bool)
  case directory(path: String, depth: Int, expanded: Bool)
  case file(FileChange, depth: Int)
  case empty(String)
}

/// Reuse a viewport of native cells instead of constructing SwiftUI row graphs
/// as a fast scroll reveals new files. RepositoryModel still owns every action.
struct NativeChangesList: NSViewRepresentable {
  @ObservedObject var model: RepositoryModel
  @ObservedObject var panels: WorkspacePanels
  @EnvironmentObject var store: AppStore
  let rows: [ChangesListRow]
  let menu: (FileChange) -> NSMenu
  let move: (Int, NSEvent.ModifierFlags) -> String?

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
    let table = ChangesTableView()
    table.autoresizingMask = [.width]
    table.headerView = nil; table.backgroundColor = .clear
    table.selectionHighlightStyle = .none; table.focusRingType = .none
    table.style = .plain
    table.intercellSpacing = .zero
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("changes"))
    column.resizingMask = .autoresizingMask; column.minWidth = 0
    table.addTableColumn(column)
    table.dataSource = context.coordinator; table.delegate = context.coordinator
    table.move = { [weak coordinator = context.coordinator] delta, modifiers in
      coordinator?.moveSelection(delta, modifiers: modifiers)
    }
    scroll.documentView = table
    context.coordinator.table = table
    DispatchQueue.main.async { [weak coordinator = context.coordinator] in
      guard let coordinator, let table = coordinator.table else { return }
      coordinator.memory.attach(table,
        key: "files-" + coordinator.parent.model.record.id.uuidString, containsNestedScrollViews: false)
    }
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(self) }

  @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var parent: NativeChangesList
    weak var table: ChangesTableView?
    let memory = ScrollMemory.Coordinator()
    private var rows: [ChangesListRow] = []
    private var compact = false
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    init(_ parent: NativeChangesList) {
      self.parent = parent
      super.init()
      observer = NotificationCenter.default.addObserver(forName: .gitpierRevealSelected, object: nil, queue: .main) {
        [weak self] event in
        let allRepositories = event.object == nil
        let repositoryID = event.object as? UUID
        MainActor.assumeIsolated {
          guard let self, allRepositories || repositoryID == self.parent.model.record.id else { return }
          self.parent.panels.trackedExpanded = true; self.parent.panels.untrackedExpanded = true
          if let path = self.parent.model.selectedPath {
            let parts = path.split(separator: "/").dropLast()
            self.parent.model.expandedDirectories.formUnion(parts.indices.map { parts[...$0].joined(separator: "/") })
            DispatchQueue.main.async { [weak self] in self?.reveal(path) }
          }
        }
      }
    }
    func update(_ parent: NativeChangesList) {
      let reload = rows != parent.rows || compact != parent.store.settings.compactUI
      self.parent = parent; rows = parent.rows; compact = parent.store.settings.compactUI
      guard let table else { return }
      if reload { table.reloadData() }
      else {
        let range = table.rows(in: table.visibleRect)
        if range.location != NSNotFound {
          for index in range.location..<min(rows.count, NSMaxRange(range)) {
            if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ChangesListCell {
              configure(cell, at: index)
            }
          }
        }
      }
      let memoryKey = "files-" + parent.model.record.id.uuidString
      if !memory.key.isEmpty, memory.key != memoryKey {
        memory.attach(table, key: memoryKey, containsNestedScrollViews: false)
      }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
      switch rows[row] {
      case .group: 28
      case .directory: 23
      case .file: compact ? 24 : 30
      case .empty: 50
      }
    }
    func selectionShouldChange(in tableView: NSTableView) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
      let identifier = NSUserInterfaceItemIdentifier("changes-cell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ChangesListCell ?? ChangesListCell()
      cell.identifier = identifier; configure(cell, at: row)
      return cell
    }
    private func configure(_ cell: ChangesListCell, at index: Int) {
      let row = rows[index], model = parent.model
      cell.configure(row, model: model, coloredIcons: parent.store.settings.coloredFileIcons, tree: model.treeMode)
      cell.toggle = { [weak self] in
        guard let self else { return }
        switch row {
        case .group(_, _, let files, _): self.parent.model.toggleIncluded(files)
        case .file(let file, _): self.parent.model.toggleIncluded([file])
        default: break
        }
      }
      cell.disclose = { [weak self] in
        guard let self else { return }
        switch row {
        case .group(let tracked, _, _, _):
          if tracked { self.parent.panels.trackedExpanded.toggle() } else { self.parent.panels.untrackedExpanded.toggle() }
        case .directory(let path, _, _):
          if self.parent.model.expandedDirectories.contains(path) { self.parent.model.expandedDirectories.remove(path) }
          else { self.parent.model.expandedDirectories.insert(path) }
        default: break
        }
      }
      if case .file(let file, _) = row {
        cell.hit.action = { [weak model] count, modifiers in
          guard let model else { return }
          if count > 1 {
            if model.selectedPath != file.path { model.select(file) }
            model.promoteTab(file.path)
          } else { model.select(file, extend: modifiers.contains(.shift), toggle: modifiers.contains(.command)) }
        }
        cell.hit.move = { [weak self] delta, modifiers in self?.moveSelection(delta, modifiers: modifiers) }
        cell.context.makeMenu = { [weak self] in self?.parent.menu(file) ?? NSMenu() }
      } else {
        cell.hit.action = nil; cell.hit.move = nil; cell.context.makeMenu = nil
      }
    }
    @discardableResult func moveSelection(_ delta: Int, modifiers: NSEvent.ModifierFlags) -> String? {
      guard let path = parent.move(delta, modifiers) else { return nil }
      reveal(path)
      // NSTableView can receive the arrow itself and claim first responder
      // while exposing a row. Restore focus after both native and SwiftUI work.
      DispatchQueue.main.async { [weak self] in self?.reveal(path, focus: true) }
      return path
    }
    private func reveal(_ path: String, focus: Bool = false) {
      guard let table, let index = rows.firstIndex(where: {
        if case .file(let file, _) = $0 { return file.path == path }; return false
      }) else { return }
      table.scrollRowToVisible(index)
      if focus, parent.model.selectedPath == path, let window = table.window,
        window.firstResponder is ChangesTableView || window.firstResponder is FileMouseDownView,
        let cell = table.view(atColumn: 0, row: index, makeIfNecessary: true) as? ChangesListCell,
        !cell.hit.isHidden {
        window.makeFirstResponder(cell.hit)
      }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
  }
}

@MainActor final class ChangesTableView: NSTableView {
  var move: ((Int, NSEvent.ModifierFlags) -> String?)?
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 125 || event.keyCode == 126 { _ = move?(event.keyCode == 125 ? 1 : -1, event.modifierFlags) }
    else { super.keyDown(with: event) }
  }
}

@MainActor final class ChangesListCell: NSTableCellView {
  let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
  let disclosure = NSButton()
  let icon = NSImageView()
  let name = NSTextField(labelWithString: "")
  let parentPath = NSTextField(labelWithString: "")
  let badge = NSTextField(labelWithString: "±")
  let hit = FileMouseDownView()
  let context = NativeContextView()
  var toggle: (() -> Void)?
  var disclose: (() -> Void)?
  private var row: ChangesListRow = .empty("")
  private var selected = false
  private var preferredNameWidth: CGFloat = 0
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    check.target = self; check.action = #selector(toggleCheck)
    check.allowsMixedState = true; check.controlSize = .small
    check.setAccessibilityLabel("Include changes in commit")
    disclosure.target = self; disclosure.action = #selector(toggleDisclosure)
    disclosure.isBordered = false; disclosure.imagePosition = .imageOnly
    for field in [name, parentPath, badge] { field.usesSingleLineMode = true; field.isSelectable = false }
    name.font = .systemFont(ofSize: 11); name.lineBreakMode = .byTruncatingTail
    parentPath.font = .systemFont(ofSize: 10); parentPath.textColor = .tertiaryLabelColor
    parentPath.lineBreakMode = .byTruncatingMiddle
    badge.font = .systemFont(ofSize: 10, weight: .semibold); badge.textColor = .systemOrange
    hit.setAccessibilityElement(false); context.setAccessibilityElement(false)
    for view in [context, disclosure, check, icon, name, parentPath, badge, hit] { addSubview(view) }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() { layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor }
  @objc private func toggleCheck() { toggle?() }
  @objc private func toggleDisclosure() { disclose?() }
  override func mouseDown(with event: NSEvent) {
    if case .directory = row { disclose?() } else { super.mouseDown(with: event) }
  }
  func configure(_ row: ChangesListRow, model: RepositoryModel, coloredIcons: Bool, tree: Bool) {
    self.row = row
    for view in [check, disclosure, icon, parentPath, badge, hit] { view.isHidden = true }
    hit.path = ""; hit.selected = false
    selected = false; toolTip = nil; check.toolTip = nil
    name.font = .systemFont(ofSize: 11); name.textColor = .labelColor
    switch row {
    case .group(_, let title, let files, let expanded):
      check.isHidden = false; disclosure.isHidden = false; parentPath.isHidden = false
      let included = files.reduce(0) { $0 + (model.includedPaths.contains($1.path) ? 1 : 0) }
      check.state = included == 0 ? .off : included == files.count ? .on : .mixed
      check.isEnabled = !model.busy && !files.isEmpty
      name.stringValue = title; name.font = .systemFont(ofSize: 11, weight: .semibold)
      parentPath.stringValue = String(files.count); parentPath.textColor = .secondaryLabelColor
      setDisclosure(expanded)
    case .directory(let path, _, let expanded):
      disclosure.isHidden = false; icon.isHidden = false
      name.stringValue = (path as NSString).lastPathComponent
      icon.image = symbol("folder", size: 11); icon.contentTintColor = .secondaryLabelColor
      setDisclosure(expanded)
    case .file(let file, _):
      check.isHidden = false; icon.isHidden = false; hit.isHidden = false
      parentPath.isHidden = tree; badge.isHidden = !file.isPartial
      check.state = model.includedPaths.contains(file.path) ? .on : .off
      check.isEnabled = !model.busy && model.available && !file.isConflicted
      check.toolTip = file.isPartial
        ? model.store.text("Commit the staged portion. Use Stage to include the remaining edits.", "提交已暂存部分；使用“暂存”操作可包含其余修改。")
        : model.store.text("Include in commit; does not stage this file.", "选入提交，不会立即暂存文件。")
      let color: NSColor = file.isConflicted ? .systemOrange : file.kind == .deleted ? .systemRed
        : file.isUntracked || file.kind == .added ? .systemMint : .controlAccentColor
      name.stringValue = (file.path as NSString).lastPathComponent; name.textColor = color
      parentPath.stringValue = (file.path as NSString).deletingLastPathComponent
      parentPath.textColor = .tertiaryLabelColor
      icon.image = symbol(file.isConflicted ? "exclamationmark.triangle.fill" : file.submodule.hasPrefix("S")
        ? "shippingbox" : file.kind == .deleted ? "doc.badge.minus" : "doc.text", size: 11)
      icon.contentTintColor = coloredIcons ? color : .secondaryLabelColor
      selected = model.selectedPaths.contains(file.path)
      hit.path = file.path; hit.selected = selected
      toolTip = file.originalPath.map { "\($0) → \(file.path)" } ?? file.path
    case .empty(let title): name.stringValue = title; name.textColor = .secondaryLabelColor
    }
    // NSTableView can reuse a label whose intrinsic width came from an older
    // row. Measure its current text so short names/group titles never truncate.
    preferredNameWidth = ceil((name.stringValue as NSString).size(withAttributes: [.font: name.font!]).width) + 4
    needsLayout = true; needsDisplay = true
  }
  private func symbol(_ name: String, size: CGFloat) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .regular))
  }
  private func setDisclosure(_ expanded: Bool) {
    disclosure.image = symbol(expanded ? "chevron.down" : "chevron.right", size: 9)
    disclosure.setAccessibilityLabel(localizedUI("Expand / Collapse"))
  }
  override func layout() {
    super.layout()
    context.frame = bounds
    let center = bounds.midY
    func box(_ x: CGFloat, _ width: CGFloat, _ height: CGFloat = 16) -> NSRect {
      NSRect(x: x, y: center - height / 2, width: max(0, width), height: height)
    }
    switch row {
    case .group:
      disclosure.frame = box(10, 12); check.frame = box(29, 14)
      let width = min(preferredNameWidth, max(0, bounds.width - 85))
      name.frame = box(50, width); parentPath.frame = box(57 + width, bounds.width - width - 65)
    case .directory(_, let depth, _):
      let x = 35 + CGFloat(depth) * 13
      disclosure.frame = box(x, 12); icon.frame = box(x + 18, 13)
      name.frame = box(x + 37, bounds.width - x - 47)
    case .file(_, let depth):
      let x = 32 + CGFloat(depth) * 13
      check.frame = box(x, 14); icon.frame = box(x + 21, 13)
      let badgeWidth: CGFloat = badge.isHidden ? 0 : 18
      let available = max(0, bounds.width - x - 51 - badgeWidth)
      let nameWidth = parentPath.isHidden || parentPath.stringValue.isEmpty ? available
        : min(preferredNameWidth, available)
      name.frame = box(x + 41, nameWidth)
      parentPath.frame = box(x + 48 + nameWidth, available - nameWidth - 7)
      badge.frame = box(bounds.width - 24, 14)
      hit.frame = NSRect(x: x + 21, y: 0, width: max(0, bounds.width - x - 21), height: bounds.height)
    case .empty: name.frame = box(18, bounds.width - 36)
    }
  }
}
