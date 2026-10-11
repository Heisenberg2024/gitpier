import AppKit

/// Native scrolling with quiet overlay thumbs, independent of the system's scrollbar preference.
@MainActor final class DiffScrollView: NSScrollView {
  let verticalThumb = DiffScrollThumb(horizontal: false)
  let horizontalThumb = DiffScrollThumb(horizontal: true)
  private let overlay = DiffScrollOverlay()
  var verticalThumbOnLeft = false {
    didSet { if oldValue != verticalThumbOnLeft { updateThumbs() } }
  }
  private var lastOrigin = NSPoint.zero
  override init(frame: NSRect) {
    super.init(frame: frame)
    hasVerticalScroller = false
    hasHorizontalScroller = false
    borderType = .noBorder
    wantsLayer = true
    layer?.masksToBounds = true
    overlay.wantsLayer = true
    overlay.layer?.masksToBounds = true
    overlay.addSubview(verticalThumb)
    overlay.addSubview(horizontalThumb)
    addSubview(overlay)
    verticalThumb.changed = { [weak self] fraction in self?.scroll(to: fraction, horizontal: false)
    }
    horizontalThumb.changed = { [weak self] fraction in self?.scroll(to: fraction, horizontal: true)
    }
  }
  convenience init() { self.init(frame: .zero) }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func tile() {
    super.tile()
    updateThumbs()
  }
  override func layout() {
    super.layout()
    updateThumbs()
  }
  override func reflectScrolledClipView(_ clipView: NSClipView) {
    super.reflectScrolledClipView(clipView)
    guard clipView === contentView else { return }
    let origin = clipView.bounds.origin
    if origin != lastOrigin {
      verticalThumb.markActive()
      horizontalThumb.markActive()
      lastOrigin = origin
    }
    updateThumbs()
  }
  func updateThumbs() {
    guard let documentView else { return }
    let visible = contentView.bounds
    let document = documentView.bounds
    // Clip-view frames can belong to an AppKit wrapper, and header tiling can finish after tile().
    // Convert the final visible region, exclude the table header, and clip every overlay to it.
    var viewport = convert(contentView.bounds, from: contentView).intersection(bounds)
    if let header = (documentView as? NSTableView)?.headerView,
      let headerClip = header.superview, headerClip.isDescendant(of: self)
    {
      let headerRect = convert(headerClip.bounds, from: headerClip).intersection(bounds)
      if viewport.intersection(headerRect).height > 0 {
        if isFlipped {
          let top = max(viewport.minY, headerRect.maxY)
          viewport = NSRect(
            x: viewport.minX, y: top, width: viewport.width,
            height: max(0, viewport.maxY - top))
        } else {
          viewport.size.height = max(0, min(viewport.maxY, headerRect.minY) - viewport.minY)
        }
      }
    }
    overlay.frame = viewport.isEmpty ? .zero : viewport
    overlay.isHidden = viewport.width < 12 || viewport.height < 12
    verticalThumb.isHidden = document.height <= visible.height + 0.5
    horizontalThumb.isHidden = document.width <= visible.width + 0.5
    let lane: CGFloat = 12
    verticalThumb.frame = NSRect(
      x: verticalThumbOnLeft ? 0 : max(0, viewport.width - lane),
      y: 0, width: lane,
      height: max(0, viewport.height - (horizontalThumb.isHidden ? 0 : lane)))
    horizontalThumb.frame = NSRect(
      x: verticalThumbOnLeft && !verticalThumb.isHidden ? lane : 0,
      y: max(0, viewport.height - lane),
      width: max(0, viewport.width - (verticalThumb.isHidden ? 0 : lane)), height: lane)
    verticalThumb.update(
      fraction: (visible.minY - document.minY) / max(1, document.height - visible.height))
    horizontalThumb.update(
      fraction: (visible.minX - document.minX) / max(1, document.width - visible.width))
  }
  private func scroll(to fraction: CGFloat, horizontal: Bool) {
    guard let documentView else { return }
    var point = contentView.bounds.origin
    if horizontal {
      point.x =
        documentView.bounds.minX
        + fraction * max(0, documentView.bounds.width - contentView.bounds.width)
    } else {
      point.y =
        documentView.bounds.minY
        + fraction * max(0, documentView.bounds.height - contentView.bounds.height)
    }
    contentView.scroll(to: point)
    reflectScrolledClipView(contentView)
  }
}

/// The clear space between thumbs leaves code selection and wheel events to the native table.
@MainActor private final class DiffScrollOverlay: NSView {
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

@MainActor final class DiffScrollThumb: NSControl {
  let horizontal: Bool
  var changed: ((CGFloat) -> Void)?
  private(set) var fraction: CGFloat = 0
  private var dragStart: CGFloat?
  private var dragFraction: CGFloat = 0
  private var idleTask: Task<Void, Never>?
  private(set) var knobOpacity: CGFloat = 0.19 { didSet { needsDisplay = true } }
  override var isFlipped: Bool { true }
  init(horizontal: Bool) {
    self.horizontal = horizontal
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = true
    setAccessibilityRole(.scrollBar)
    setAccessibilityLabel(horizontal ? "Horizontal Diff scroll" : "Vertical Diff scroll")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  var knobRect: NSRect {
    let length = horizontal ? bounds.width : bounds.height
    let track = max(0, length - 6)
    let knob = min(horizontal ? 56 : 150, max(0, track - min(24, track / 2)))
    let position = 3 + max(0, track - knob) * fraction
    return horizontal
      ? NSRect(x: position, y: 3, width: knob, height: 6)
      : NSRect(x: 3, y: position, width: 6, height: knob)
  }
  func update(fraction: CGFloat) {
    self.fraction = min(1, max(0, fraction))
    setAccessibilityValue(Double(self.fraction))
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.labelColor.withAlphaComponent(knobOpacity).setFill()
    NSBezierPath(roundedRect: knobRect, xRadius: 3, yRadius: 3).fill()
  }
  func markActive() {
    idleTask?.cancel()
    knobOpacity = 0.42
    idleTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
      guard let self, self.dragStart == nil else { return }
      for step in 1...8 {
        do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
        self.knobOpacity = 0.42 - 0.23 * CGFloat(step) / 8
      }
    }
  }
  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    markActive()
    if !knobRect.contains(point) {
      let length = horizontal ? bounds.width : bounds.height
      let knobLength = horizontal ? knobRect.width : knobRect.height
      let coordinate = horizontal ? point.x : point.y
      changed?(min(1, max(0, (coordinate - 3 - knobLength / 2) / max(1, length - 6 - knobLength))))
    }
    dragStart = horizontal ? point.x : point.y
    dragFraction = fraction
  }
  override func mouseDragged(with event: NSEvent) {
    guard let dragStart else { return }
    let point = convert(event.locationInWindow, from: nil)
    let coordinate = horizontal ? point.x : point.y
    let travel =
      horizontal ? bounds.width - 6 - knobRect.width : bounds.height - 6 - knobRect.height
    changed?(min(1, max(0, dragFraction + (coordinate - dragStart) / max(1, travel))))
    markActive()
  }
  override func mouseUp(with event: NSEvent) {
    dragStart = nil
    markActive()
  }
  override func accessibilityPerformIncrement() -> Bool {
    changed?(min(1, fraction + 0.1))
    markActive()
    return true
  }
  override func accessibilityPerformDecrement() -> Bool {
    changed?(max(0, fraction - 0.1))
    markActive()
    return true
  }
}
