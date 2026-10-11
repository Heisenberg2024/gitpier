import AppKit
import SwiftUI

/// Build context menus before AppKit begins tracking, preserving native submenu tracking and application icons.
struct NativeContextMenu: NSViewRepresentable {
  let makeMenu: () -> NSMenu
  func makeNSView(context: Context) -> NativeContextView {
    let view = NativeContextView()
    view.makeMenu = makeMenu
    view.setAccessibilityElement(false)
    return view
  }
  func updateNSView(_ view: NativeContextView, context: Context) { view.makeMenu = makeMenu }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeContextView, context: Context)
    -> CGSize?
  {
    CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
  }
}
extension View {
  func nativeContextMenu(_ makeMenu: @escaping () -> NSMenu) -> some View {
    background(NativeContextMenu(makeMenu: makeMenu))
  }
}
@MainActor final class NativeContextView: NSView {
  var makeMenu: (() -> NSMenu)?
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      NativeContextMonitor.shared.remove(self)
    } else {
      NativeContextMonitor.shared.add(self)
    }
  }
  func present(_ event: NSEvent) {
    guard let menu = makeMenu?() else { return }
    NSMenu.popUpContextMenu(menu, with: event, for: self)
  }
}

@MainActor private final class NativeContextMonitor {
  static let shared = NativeContextMonitor()
  private let targets = NSHashTable<NativeContextView>.weakObjects()
  private var monitor: Any?
  func add(_ view: NativeContextView) {
    targets.add(view)
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) {
      [weak self] event in
      guard event.type == .rightMouseDown || event.modifierFlags.contains(.control),
        self?.present(event) == true
      else { return event }
      return nil
    }
  }
  func remove(_ view: NativeContextView) {
    targets.remove(view)
    if targets.allObjects.isEmpty, let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
  }
  private func present(_ event: NSEvent) -> Bool {
    guard let window = event.window else { return false }
    for view in targets.allObjects where view.window === window && !view.isHiddenOrHasHiddenAncestor
    {
      let point = view.convert(event.locationInWindow, from: nil)
      guard view.bounds.contains(point), view.visibleRect.contains(point) else { continue }
      view.present(event)
      return true
    }
    return false
  }
}

@MainActor enum NativeMenuItems {
  static func menu(_ items: [NSMenuItem]) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    items.forEach(menu.addItem)
    return menu
  }
  static func action(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void)
    -> NSMenuItem
  {
    let target = MenuAction(action)
    let item = NSMenuItem(
      title: title, action: #selector(MenuAction.invokeAction(_:)), keyEquivalent: "")
    item.target = target
    item.representedObject = target
    item.isEnabled = enabled
    return item
  }
  static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.submenu = menu(items)
    return item
  }
  static func editor(model: RepositoryModel, path: String? = nil) -> NSMenuItem {
    let choices = ExternalEditors.available(settings: model.store.settings).map { editor in
      let choice = action(editor.name) { [weak model] in
        model?.openEditor(path, application: editor.url)
      }
      ExternalEditors.setIcon(editor, on: choice)
      return choice
    }
    let item = submenu(model.store.text("Open in Editor", "在编辑器中打开"), choices)
    item.isEnabled = !choices.isEmpty
    return item
  }
}
@MainActor private final class MenuAction: NSObject {
  let action: () -> Void
  init(_ action: @escaping () -> Void) { self.action = action }
  @objc func invokeAction(_ sender: NSMenuItem) { action() }
}
