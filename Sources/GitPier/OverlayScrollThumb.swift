import AppKit

/// Shared fixed-length overlay thumb for native scroll views and terminal scrollback.
@MainActor final class OverlayScrollThumb: NSControl {
  let horizontal: Bool
  var accessibilityName: String
  var tintColor: NSColor = .labelColor { didSet { if oldValue != tintColor { needsDisplay = true } } }
  var changed: ((CGFloat) -> Void)?
  private(set) var fraction: CGFloat = 0
  private var dragStart: CGFloat?
  private var dragFraction: CGFloat = 0
  private var idleTask: Task<Void, Never>?
  private(set) var knobOpacity: CGFloat = 0.19 { didSet { needsDisplay = true } }
  override var isFlipped: Bool { true }
  init(horizontal: Bool) {
    self.horizontal = horizontal
    accessibilityName = horizontal ? "Horizontal scroll" : "Vertical scroll"
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = true
    setAccessibilityRole(.scrollBar)
    setAccessibilityLabel(localizedUI(accessibilityName))
    setAccessibilityValue(0.0)
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
    let label = localizedUI(accessibilityName)
    if accessibilityLabel() != label { setAccessibilityLabel(label) }
    let value = min(1, max(0, fraction))
    guard value != self.fraction else { return }
    self.fraction = value
    setAccessibilityValue(Double(value))
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    tintColor.withAlphaComponent(knobOpacity).setFill()
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
