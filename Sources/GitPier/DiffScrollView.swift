import AppKit

/// Diff keeps its native clip view and synchronized scrolling, sharing the application's overlays.
@MainActor final class DiffScrollView: NSScrollView {
  private var installedOverlay: OverlayScrollbars?
  private var overlay: OverlayScrollbars {
    if let installedOverlay { return installedOverlay }
    let value = OverlayScrollbars.install(on: self)
    installedOverlay = value
    return value
  }
  var verticalThumb: OverlayScrollThumb { overlay.verticalThumb }
  var horizontalThumb: OverlayScrollThumb { overlay.horizontalThumb }
  var verticalThumbOnLeft = false {
    didSet { overlay.verticalThumbOnLeft = verticalThumbOnLeft }
  }
  override init(frame: NSRect) {
    super.init(frame: frame)
    hasVerticalScroller = false
    hasHorizontalScroller = false
    borderType = .noBorder
    wantsLayer = true
    layer?.masksToBounds = true
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
    if clipView === contentView { updateThumbs() }
  }
  func updateThumbs() { overlay.refresh() }
}
