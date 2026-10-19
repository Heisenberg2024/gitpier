import AppKit
import SwiftUI

/// Installs overlays on SwiftUI's native scroll views without replacing their documents or proxies.
struct UnifiedScrollbars: NSViewRepresentable {
  func makeNSView(context: Context) -> ScrollbarAnchor { ScrollbarAnchor() }
  func updateNSView(_ view: ScrollbarAnchor, context: Context) { view.scheduleInstall() }
}

@MainActor final class ScrollbarAnchor: NSView {
  nonisolated(unsafe) private var observer: CFRunLoopObserver?
  private var scheduled = false
  override func layout() {
    super.layout()
    scheduleInstall()
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
    observer = nil
    guard window != nil else { return }
    // SwiftUI can insert scroll views after window updates and while an offscreen window isn't drawn.
    // Discover them after layout at the end of each UI event cycle, without timers or method swizzling.
    observer = CFRunLoopObserverCreateWithHandler(
      nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0
    ) { [weak self] _, _ in
      MainActor.assumeIsolated {
        guard let self, let window = self.window else { return }
        self.install(in: window)
      }
    }
    if let observer { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
    scheduleInstall()
  }
  func scheduleInstall() {
    guard !scheduled else { return }
    scheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.scheduled = false
      if let window = self.window { self.install(in: window) }
    }
  }
  private func includes(_ candidate: NSWindow) -> Bool {
    // Keep operating-system file choosers under AppKit's control.
    guard !(candidate is NSSavePanel), let window else { return false }
    var current: NSWindow? = candidate
    while let value = current {
      if value === window { return true }
      current = value.sheetParent
    }
    return false
  }
  private func install(in window: NSWindow) {
    func visit(_ view: NSView) {
      guard !view.isHidden else { return }
      if let scroll = view as? NSScrollView {
        OverlayScrollbars.install(on: scroll).refresh()
        // SwiftUI scroll documents can contain other scroll views or editors.
        // Inspect their materialized native views, but skip Diff cells and text
        // document leaves; neither contains another scrolling container.
        if !(scroll is DiffScrollView), let document = scroll.documentView,
          !(document is NSTextView) { visit(document) }
        return
      }
      if view is SafeTerminalView { return }
      for child in view.subviews { visit(child) }
    }
    if let content = window.contentView { visit(content) }
    for sheet in window.sheets where includes(sheet) { install(in: sheet) }
  }
  deinit {
    if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
  }
}

/// The overlay is retained by its scroll view; observers and callbacks only retain it weakly.
@MainActor final class OverlayScrollbars: NSView {
  let verticalThumb = OverlayScrollThumb(horizontal: false)
  let horizontalThumb = OverlayScrollThumb(horizontal: true)
  weak var scrollView: NSScrollView?
  private weak var observedClip: NSClipView?
  private weak var observedDocument: NSView?
  nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
  private var lastOrigin: NSPoint?
  var verticalThumbOnLeft = false {
    didSet { if oldValue != verticalThumbOnLeft { refresh() } }
  }
  override var isFlipped: Bool { true }

  @discardableResult static func install(on scroll: NSScrollView) -> OverlayScrollbars {
    if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
    if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
    if let overlay = scroll.subviews.compactMap({ $0 as? OverlayScrollbars }).first {
      return overlay
    }
    let overlay = OverlayScrollbars(frame: .zero)
    overlay.scrollView = scroll
    scroll.addSubview(overlay, positioned: .above, relativeTo: nil)
    overlay.refresh()
    return overlay
  }
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    addSubview(verticalThumb)
    addSubview(horizontalThumb)
    verticalThumb.changed = { [weak self] in self?.scroll(to: $0, horizontal: false) }
    horizontalThumb.changed = { [weak self] in self?.scroll(to: $0, horizontal: true) }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
  private func observe(_ scroll: NSScrollView, document: NSView) {
    guard observedClip !== scroll.contentView || observedDocument !== document else { return }
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
    observedClip = scroll.contentView
    observedDocument = document
    lastOrigin = nil
    for view in [scroll, scroll.contentView, document] {
      view.postsFrameChangedNotifications = true
      view.postsBoundsChangedNotifications = true
      for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
        observers.append(NotificationCenter.default.addObserver(
          forName: name, object: view, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } })
      }
    }
  }
  func refresh() {
    guard let scroll = scrollView, let document = scroll.documentView else {
      isHidden = true
      return
    }
    observe(scroll, document: document)
    let visible = scroll.contentView.bounds
    let extent = document.bounds
    if let lastOrigin, lastOrigin != visible.origin {
      verticalThumb.markActive()
      horizontalThumb.markActive()
    }
    lastOrigin = visible.origin
    // Final clip geometry can be inside an AppKit wrapper. Exclude table headers after tiling.
    var viewport = scroll.convert(visible, from: scroll.contentView).intersection(scroll.bounds)
    if let header = (document as? NSTableView)?.headerView,
      let headerClip = header.superview, headerClip.isDescendant(of: scroll)
    {
      let headerRect = scroll.convert(headerClip.bounds, from: headerClip).intersection(scroll.bounds)
      if viewport.intersection(headerRect).height > 0 {
        if scroll.isFlipped {
          let top = max(viewport.minY, headerRect.maxY)
          viewport = NSRect(x: viewport.minX, y: top, width: viewport.width,
            height: max(0, viewport.maxY - top))
        } else {
          viewport.size.height = max(0, min(viewport.maxY, headerRect.minY) - viewport.minY)
        }
      }
    }
    let target = viewport.isEmpty ? NSRect.zero : viewport
    if frame != target { frame = target }
    isHidden = viewport.width < 12 || viewport.height < 12
    verticalThumb.isHidden = extent.height <= visible.height + 0.5
    horizontalThumb.isHidden = extent.width <= visible.width + 0.5
    let lane: CGFloat = 12
    let verticalFrame = NSRect(
      x: verticalThumbOnLeft ? 0 : max(0, viewport.width - lane), y: 0, width: lane,
      height: max(0, viewport.height - (horizontalThumb.isHidden ? 0 : lane)))
    let horizontalFrame = NSRect(
      x: verticalThumbOnLeft && !verticalThumb.isHidden ? lane : 0,
      y: max(0, viewport.height - lane),
      width: max(0, viewport.width - (verticalThumb.isHidden ? 0 : lane)), height: lane)
    if verticalThumb.frame != verticalFrame { verticalThumb.frame = verticalFrame }
    if horizontalThumb.frame != horizontalFrame { horizontalThumb.frame = horizontalFrame }
    verticalThumb.update(fraction:
      (document.isFlipped ? visible.minY - extent.minY : extent.maxY - visible.maxY)
        / max(1, extent.height - visible.height))
    horizontalThumb.update(fraction: (visible.minX - extent.minX) / max(1, extent.width - visible.width))
  }
  private func scroll(to fraction: CGFloat, horizontal: Bool) {
    guard let scroll = scrollView, let document = scroll.documentView else { return }
    let extent = document.bounds
    let visible = scroll.contentView.bounds
    var point = visible.origin
    if horizontal {
      point.x = extent.minX + fraction * max(0, extent.width - visible.width)
    } else if document.isFlipped {
      point.y = extent.minY + fraction * max(0, extent.height - visible.height)
    } else {
      point.y = extent.maxY - visible.height - fraction * max(0, extent.height - visible.height)
    }
    scroll.contentView.scroll(to: point)
    scroll.reflectScrolledClipView(scroll.contentView)
    refresh()
  }
  deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
}
