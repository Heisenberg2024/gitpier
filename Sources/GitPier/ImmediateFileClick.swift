import AppKit
import SwiftUI

/// File selection must not wait for a competing double-click recognizer to fail.
struct ImmediateFileClick: NSViewRepresentable {
  let path: String
  var selected = false
  let action: (Int, NSEvent.ModifierFlags) -> Void
  let move: (Int, NSEvent.ModifierFlags) -> String?
  func makeNSView(context: Context) -> FileMouseDownView {
    let view = FileMouseDownView()
    view.setAccessibilityElement(false)
    view.path = path
    view.selected = selected
    view.action = action
    view.move = move
    return view
  }
  func updateNSView(_ view: FileMouseDownView, context: Context) {
    view.path = path
    view.selected = selected
    view.action = action
    view.move = move
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: FileMouseDownView, context: Context)
    -> CGSize?
  {
    CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
  }
}

final class FileMouseDownView: NSView {
  var path = ""
  var selected = false
  var action: ((Int, NSEvent.ModifierFlags) -> Void)?
  var move: ((Int, NSEvent.ModifierFlags) -> String?)?
  private(set) var lastDispatchDuration: TimeInterval = 0
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard super.hitTest(point) != nil else { return nil }
    if let type = NSApp.currentEvent?.type,
      type != .leftMouseDown && type != .leftMouseUp && type != .leftMouseDragged
    {
      return nil
    }
    if NSApp.currentEvent?.modifierFlags.contains(.control) == true { return nil }
    return self
  }
  override func mouseDown(with event: NSEvent) {
    lastDispatchDuration = ProcessInfo.processInfo.systemUptime - event.timestamp
    let focused = ContinuousClock.now
    window?.makeFirstResponder(self)
    PerformanceAcceptance.component("file-focus", start: focused)
    let selected = ContinuousClock.now
    action?(event.clickCount, event.modifierFlags)
    PerformanceAcceptance.component("file-selection", start: selected)
  }
  override func mouseUp(with event: NSEvent) {}
  override func keyDown(with event: NSEvent) {
    guard event.keyCode == 125 || event.keyCode == 126 else {
      super.keyDown(with: event)
      return
    }
    guard let path = move?(event.keyCode == 125 ? 1 : -1, event.modifierFlags), let window else {
      return
    }
    // SwiftUI materializes the next row after scrolling; keep keyboard focus on that row.
    DispatchQueue.main.async { [weak window] in
      guard let window, !(window.firstResponder is NSTextView),
        !(window.firstResponder is NSControl),
        let root = window.contentView, let target = Self.fileView(in: root, path: path)
      else { return }
      window.makeFirstResponder(target)
    }
  }
  private static func fileView(in root: NSView, path: String) -> FileMouseDownView? {
    if let view = root as? FileMouseDownView, view.path == path { return view }
    for child in root.subviews {
      if let found = fileView(in: child, path: path) { return found }
    }
    return nil
  }
}

/// Observe the entire row before AppKit dispatches its context-menu event, without consuming it.
struct ImmediateFileContext: NSViewRepresentable {
  let action: () -> Void
  func makeNSView(context: Context) -> FileContextTarget {
    let view = FileContextTarget()
    view.setAccessibilityElement(false)
    view.action = action
    return view
  }
  func updateNSView(_ view: FileContextTarget, context: Context) { view.action = action }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: FileContextTarget, context: Context)
    -> CGSize?
  {
    CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
  }
}

final class FileContextTarget: NSView {
  var action: (() -> Void)?
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      FileContextMonitor.shared.remove(self)
    } else {
      FileContextMonitor.shared.add(self)
    }
  }
}

@MainActor private final class FileContextMonitor {
  static let shared = FileContextMonitor()
  private let targets = NSHashTable<FileContextTarget>.weakObjects()
  private var monitor: Any?
  func add(_ view: FileContextTarget) {
    targets.add(view)
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) {
      [weak self] event in
      // Control-click is macOS's other context-menu gesture. Modifiers never toggle selection here.
      if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
        self?.selectTarget(for: event)
      }
      return event
    }
  }
  func remove(_ view: FileContextTarget) {
    targets.remove(view)
    if targets.allObjects.isEmpty, let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
  }
  private func selectTarget(for event: NSEvent) {
    guard let window = event.window else { return }
    for view in targets.allObjects where view.window === window && !view.isHiddenOrHasHiddenAncestor
    {
      let point = view.convert(event.locationInWindow, from: nil)
      // SwiftUI background hosts can report a visibleRect larger than the row's own bounds.
      guard view.bounds.contains(point), view.visibleRect.contains(point) else { continue }
      view.action?()
      return
    }
  }
}
