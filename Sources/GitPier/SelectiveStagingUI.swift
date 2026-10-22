import AppKit
import GitPierCore

/// The gutter selects changes; the code's NSTextView retains native text selection/copy.
@MainActor final class LineSelectableDiffTable: NSTableView {
  var gutterWidth: CGFloat = 46
  var selectLine: ((Int, NSEvent.ModifierFlags) -> Void)?
  var clearLines: (() -> Void)?
  var lineAction: (() -> Void)?
  var actionMenu: ((Int) -> NSMenu?)?
  var reviewLine: ((Int) -> Void)? { didSet { if reviewLine == nil { reviewButton.isHidden = true } else { window?.acceptsMouseMovedEvents = true } } }
  var canReviewLine: ((Int) -> Bool)?
  var reviewActionTitle = "Add Review Comment" { didSet { reviewButton.toolTip = reviewActionTitle; reviewButton.setAccessibilityLabel(reviewActionTitle) } }
  private var reviewTracking: NSTrackingArea?
  private var reviewRow = -1
  private lazy var reviewButton: NSButton = {
    let button = NSButton(image: NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)!, target: self, action: #selector(addReviewComment))
    button.isBordered = false; button.bezelStyle = .inline; button.controlSize = .small
    button.toolTip = reviewActionTitle
    button.setAccessibilityLabel(reviewActionTitle)
    button.setAccessibilityIdentifier("hosting.diff.add-comment")
    button.isHidden = true
    addSubview(button)
    return button
  }()
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let reviewTracking { removeTrackingArea(reviewTracking) }
    let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(tracking); reviewTracking = tracking
  }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if reviewLine != nil { window?.acceptsMouseMovedEvents = true } }
  override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    let point = convert(event.locationInWindow, from: nil), row = row(at: convert(event.locationInWindow, from: nil))
    guard reviewLine != nil, row >= 0, canReviewLine?(row) == true, visibleRect.contains(point) else { reviewButton.isHidden = true; return }
    reviewRow = row
    let rect = rect(ofRow: row)
    reviewButton.frame = NSRect(x: visibleRect.minX + 3, y: rect.minY + max(0, (rect.height - 17) / 2), width: 17, height: 17)
    addSubview(reviewButton, positioned: .above, relativeTo: nil)
    reviewButton.isHidden = false
  }
  override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); reviewButton.isHidden = true }
  @objc private func addReviewComment() { if canReviewLine?(reviewRow) == true { reviewLine?(reviewRow) } }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let row = keyboardReviewRow
    if reviewLine != nil, event.modifierFlags.contains([.command, .shift]), event.charactersIgnoringModifiers?.lowercased() == "m", let row, canReviewLine?(row) == true {
      reviewLine?(row); return true
    }
    return super.performKeyEquivalent(with: event)
  }
  private var keyboardReviewRow: Int? {
    guard var view = window?.firstResponder as? NSView, view === self || view.isDescendant(of: self) else { return nil }
    while view !== self {
      if let cell = view as? NSTableCellView { return row(for: cell) }
      guard let parent = view.superview else { break }; view = parent
    }
    return selectedRow >= 0 ? selectedRow : nil
  }
  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let row = row(at: point)
    if let selectLine, point.x < gutterWidth, row >= 0 {
      window?.makeFirstResponder(self)
      selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      selectLine(row, event.modifierFlags); return
    }
    super.mouseDown(with: event)
  }
  override func keyDown(with event: NSEvent) {
    if reviewLine != nil, event.modifierFlags.contains([.command, .shift]), event.charactersIgnoringModifiers?.lowercased() == "m", canReviewLine?(selectedRow) == true {
      reviewLine?(selectedRow); return
    }
    guard let selectLine else { super.keyDown(with: event); return }
    if event.modifierFlags.contains([.command, .shift]), event.charactersIgnoringModifiers?.lowercased() == "s" {
      lineAction?(); return
    }
    if event.keyCode == 53 { clearLines?(); return }
    if event.keyCode == 49, selectedRow >= 0 { selectLine(selectedRow, .command); return }
    if event.keyCode == 125 || event.keyCode == 126 {
      let next = min(max(0, selectedRow + (event.keyCode == 125 ? 1 : -1)), max(0, numberOfRows - 1))
      guard numberOfRows > 0 else { return }
      selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
      selectLine(next, event.modifierFlags); scrollRowToVisible(next); return
    }
    super.keyDown(with: event)
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let point = convert(event.locationInWindow, from: nil)
    return point.x < gutterWidth ? actionMenu?(row(at: point)) : super.menu(for: event)
  }
}

@MainActor extension RepositoryModel {
  func applySelectedLines(_ selected: Set<Int>, document: DiffDocument,
                          file: FileChange, comparison: DiffComparison, index: IndexSnapshot) {
    guard !busy, !store.settings.ignoreWhitespace, !selected.isEmpty else { return }
    run(label: store.text(comparison == .staged ? "Unstaging selected lines" : "Staging selected lines",
                          comparison == .staged ? "取消暂存选中行" : "暂存选中行"), updatesCommitState: .index) { git in
      let review = try await git.reviewSelectiveStaging(file: file, comparison: comparison,
                                                       expectedPatch: document.raw, expectedIndex: index)
      try await git.applySelectedLines(selected, expected: review)
    }
  }
}
