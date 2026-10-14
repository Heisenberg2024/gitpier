import AppKit
import GitPierCore

/// The gutter selects changes; the code's NSTextView retains native text selection/copy.
@MainActor final class LineSelectableDiffTable: NSTableView {
  var gutterWidth: CGFloat = 46
  var selectLine: ((Int, NSEvent.ModifierFlags) -> Void)?
  var clearLines: (() -> Void)?
  var lineAction: (() -> Void)?
  var actionMenu: ((Int) -> NSMenu?)?
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
                          comparison == .staged ? "取消暂存选中行" : "暂存选中行")) { git in
      let review = try await git.reviewSelectiveStaging(file: file, comparison: comparison,
                                                       expectedPatch: document.raw, expectedIndex: index)
      try await git.applySelectedLines(selected, expected: review)
    }
  }
}
