import AppKit
import GitPierCore
import SwiftUI

@MainActor private final class ScrollDiscoveryProbe: NSView {
  var reads = 0
  override var subviews: [NSView] {
    get { reads += 1; return super.subviews }
    set { super.subviews = newValue }
  }
}

@MainActor extension UIAcceptance {
  static func verifyFileScroll(store: AppStore, model: RepositoryModel, root: URL, output: URL) async throws {
    guard root.deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui.") else {
      throw GitPierError.invalidInput("File scrolling acceptance requires a disposable repository")
    }
    var settings = store.settings
    settings.automaticFetch = false; settings.automaticRefresh = false
    settings.language = .english; store.updateSettings(settings)
    let host = NSHostingView(rootView: RootView().environmentObject(store).modifier(AppAppearance(store: store)))
    let window = NSWindow(contentRect: NSRect(x: -2400, y: -2400, width: 1200, height: 800),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
    defer { window.close() }
    var results: [[String: Any]] = []
    var repeatedDiscovery = 0
    let originalCount = model.status.files.count
    var generated = 0
    let git = await model.git()
    let originalIndex = try await git.snapshot()
    for count in [226, 1000] {
      while originalCount + generated < count {
        let folder = root.appendingPathComponent("ScrollFixture/group_\(generated / 20)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("scroll fixture\n".utf8).write(to: folder.appendingPathComponent(String(format: "file_%05d.txt", generated)))
        generated += 1
      }
      await model.refresh(); try await settle()
      guard model.available, model.status.files.count == count,
        let row = descendants(host).compactMap({ $0 as? FileMouseDownView }).first,
        let scroll = row.enclosingScrollView, let document = scroll.documentView else {
        throw GitPierError.invalidInput("Missing materialized file list at \(count) files")
      }
      // Refresh schedules bounded Diff prefetch independently of scrolling.
      // Finish that real background work before measuring scroll-only reads.
      var stableReads = 0
      for _ in 0..<100 {
        let reads = model.diffReadCount
        try await Task.sleep(for: .milliseconds(50))
        stableReads = reads == model.diffReadCount && !model.diffLoading ? stableReads + 1 : 0
        if stableReads == 4 { break }
      }
      guard stableReads == 4 else { throw GitPierError.invalidInput("Diff warmup did not settle") }
      let beforeReads = model.diffReadCount
      let beforeSelection = model.selectedPaths, beforeIncluded = model.includedPaths
      let probe = ScrollDiscoveryProbe(frame: .zero)
      document.addSubview(probe)
      try await settle(); probe.reads = 0
      for _ in 0..<8 { try await Task.sleep(for: .milliseconds(10)) }
      repeatedDiscovery += probe.reads
      probe.removeFromSuperview()
      for tree in [false, true] {
        model.treeMode = tree
        model.expandedDirectories = Set(model.filteredFiles.flatMap { file in
          let parts = file.path.split(separator: "/").dropLast()
          return parts.indices.map { parts[...$0].joined(separator: "/") }
        })
        try await settle()
        var frames: [Double] = []
        for step in 0..<90 {
          let start = ContinuousClock.now
          let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
          let progress = CGFloat(step < 45 ? step : 89 - step) / 44
          scroll.contentView.scroll(to: NSPoint(x: 0, y: maximum * progress))
          scroll.reflectScrolledClipView(scroll.contentView)
          host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
          try await Task.sleep(for: .milliseconds(8))
          frames.append(PerformanceAcceptance.ms(start))
        }
        let ordered = frames.sorted()
        let rows = descendants(document).compactMap { $0 as? FileMouseDownView }.count
        results.append(["files": count, "tree": tree, "samples": frames.count,
          "medianMS": ordered[ordered.count / 2], "p95MS": ordered[Int(Double(ordered.count) * 0.95)],
          "maxMS": ordered.last!, "materializedRows": rows])
        let data = try JSONSerialization.data(withJSONObject: ["frames": results,
          "repeatedDocumentDiscovery": repeatedDiscovery], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("file-scroll-results.json"))
        let visibleBudget = Int(scroll.contentView.bounds.height / (store.settings.compactUI ? 24 : 30)) + 4
        guard rows <= visibleBudget * 2 else {
          throw GitPierError.invalidInput("File rows must be recycled within the viewport budget: \(rows) > \(visibleBudget * 2)")
        }
        guard let overlay = scroll.subviews.compactMap({ $0 as? OverlayScrollbars }).first,
          !scroll.hasVerticalScroller, overlay.verticalThumb.knobRect.height == 150,
          overlay.verticalThumb.fraction < 0.01 else {
          throw GitPierError.invalidInput("File list must retain shared overlay thumbs and scroll back to the top")
        }
        try capture(host, to: output.appendingPathComponent("files-\(count)-\(tree ? "tree" : "list").png"))
      }
      guard model.diffReadCount == beforeReads, model.selectedPaths == beforeSelection,
        model.includedPaths == beforeIncluded else {
        throw GitPierError.invalidInput("Scrolling changed reads \(beforeReads)→\(model.diffReadCount), selection \(beforeSelection)→\(model.selectedPaths), inclusion \(beforeIncluded.count)→\(model.includedPaths.count)")
      }
    }
    try await verifyNativeFileListControls(store: store, model: model, host: host, window: window, output: output)
    let finalIndex = try await git.snapshot()
    guard finalIndex.identity == originalIndex.identity else {
      throw GitPierError.invalidInput("Scrolling changed the Index or HEAD")
    }
    guard repeatedDiscovery == 0 else {
      throw GitPierError.invalidInput("File list discovery repeatedly traversed known leaf content: \(repeatedDiscovery)")
    }
  }

  private static func verifyNativeFileListControls(store: AppStore, model: RepositoryModel,
    host: NSView, window: NSWindow, output: URL) async throws {
    var checks: [String] = []
    func require(_ condition: Bool, _ message: String) throws {
      guard condition else { throw GitPierError.invalidInput("Native file list: " + message) }
      checks.append(message)
      try checks.joined(separator: "\n").write(to: output.appendingPathComponent("file-controls.txt"), atomically: true, encoding: .utf8)
    }
    guard let table = descendants(host).compactMap({ $0 as? ChangesTableView }).first,
      let scroll = table.enclosingScrollView else { throw GitPierError.invalidInput("Missing native changes table") }
    func cells() -> [ChangesListCell] { descendants(table).compactMap { $0 as? ChangesListCell } }
    let rows = table.numberOfRows
    guard let header = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ChangesListCell else {
      throw GitPierError.invalidInput("Missing tracked group")
    }
    let included = model.includedPaths
    header.check.performClick(nil); try await settle()
    try require(Set(model.status.tracked.map(\.path)).isSubset(of: model.includedPaths), "Group checkbox includes every tracked file")
    header.check.performClick(nil); try await settle()
    try require(model.includedPaths == included, "Group checkbox restores inclusion without staging")
    header.disclosure.performClick(nil); try await settle()
    try require(table.numberOfRows < rows, "Group disclosure collapses its native rows")
    guard let collapsedHeader = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ChangesListCell else {
      throw GitPierError.invalidInput("Missing collapsed group")
    }
    collapsedHeader.disclosure.performClick(nil); try await settle()
    try require(table.numberOfRows == rows, "Group disclosure restores its native rows")
    guard let file = cells().first(where: { !$0.hit.isHidden && !$0.hit.path.isEmpty }) else {
      throw GitPierError.invalidInput("Missing visible file checkbox")
    }
    let path = file.hit.path
    file.check.performClick(nil); try await settle()
    try require(model.includedPaths == included.symmetricDifference([path]) && model.canCommit,
      "File checkbox changes only inclusion and enables the reviewed commit")
    file.check.performClick(nil); try await settle()
    try require(model.includedPaths == included, "File checkbox restores inclusion")
    if let directory = cells().first(where: { !$0.disclosure.isHidden && $0.check.isHidden && !$0.icon.isHidden }) {
      let title = directory.name.stringValue
      directory.disclosure.performClick(nil); try await settle()
      try require(table.numberOfRows < rows, "Directory disclosure collapses descendants")
      guard let collapsed = cells().first(where: { !$0.disclosure.isHidden && $0.check.isHidden && $0.name.stringValue == title }) else {
        throw GitPierError.invalidInput("Missing collapsed directory")
      }
      collapsed.disclosure.performClick(nil); try await settle()
      try require(table.numberOfRows == rows, "Directory disclosure restores descendants")
    } else { throw GitPierError.invalidInput("Missing directory disclosure") }
    model.query = "file_00990"; try await settle()
    try require(model.filteredFiles.count == 1 && table.numberOfRows <= 6,
      "Search replaces the rows with the matching hierarchy")
    model.query = ""; try await settle()
    try require(table.numberOfRows == rows && model.includedPaths == included, "Clearing search restores rows and inclusion")
    guard let last = model.filteredFiles.last else { throw GitPierError.invalidInput("Missing last fixture file") }
    model.select(last)
    NotificationCenter.default.post(name: .gitpierRevealSelected, object: model.record.id)
    try await waitFor {
      cells().contains { $0.hit.path == last.path && !$0.hit.isHiddenOrHasHiddenAncestor && !$0.hit.visibleRect.isEmpty }
    }
    try require(model.selectedPath == last.path, "Reveal materializes a selected file beyond the old viewport")
    let position = scroll.contentView.bounds.origin
    model.setPage("history"); try await settle(); model.setPage("commit"); try await settle()
    try require(abs(scroll.contentView.bounds.origin.y - position.y) < 1, "Page switching retains repository scroll position")
    for language in [AppLanguage.english, .simplifiedChinese] {
      for appearance in [AppearanceMode.light, .dark] {
        var settings = store.settings; settings.language = language; settings.appearance = appearance
        store.updateSettings(settings)
        window.setContentSize(NSSize(width: 960, height: 640)); try await settle()
        try require(abs(table.bounds.width - scroll.contentSize.width) < 1,
          "Resizing keeps the native column inside its viewport (\(language), \(appearance))")
        try capture(host, to: output.appendingPathComponent("files-\(language)-\(appearance)-compact.png"))
      }
    }
  }
}
