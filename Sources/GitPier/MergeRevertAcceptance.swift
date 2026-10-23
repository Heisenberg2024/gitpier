import AppKit
import GitPierCore
import SwiftUI

@MainActor extension UIAcceptance {
  static func verifyMergeRevert(root: URL, output: URL) async throws {
    guard root.deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui.") else {
      throw GitPierError.invalidInput("Merge revert acceptance requires a disposable repository")
    }
    let fixture = root.deletingLastPathComponent().appendingPathComponent("merge-revert")
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    let raw = GitService(root: fixture)
    func command(_ args: [String]) async throws { _ = try await raw.perform(args) }
    func write(_ name: String, _ value: String) throws {
      try value.write(to: fixture.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    try await command(["init", "-b", "main"])
    try await command(["config", "user.name", "Merge Revert Acceptance"])
    try await command(["config", "user.email", "revert@example.invalid"])
    try await command(["config", "commit.gpgsign", "false"])
    try await command(["config", "core.hooksPath", fixture.appendingPathComponent(".git/hooks").path])
    try write("base.txt", "base\n"); try await command(["add", "base.txt"])
    try await command(["commit", "-m", "base"])
    try await command(["switch", "-c", "topic"])
    try write("topic.txt", "topic\n"); try await command(["add", "topic.txt"])
    try await command(["commit", "-m", "topic parent"])
    try await command(["switch", "main"])
    try write("main.txt", "main\n"); try await command(["add", "main.txt"])
    try await command(["commit", "-m", "main parent"])
    try await command(["merge", "--no-ff", "--no-edit", "topic"])
    let mergeHash = try await raw.status().head!
    let commit = try await raw.commitDetail(mergeHash)
    let store = AppStore(persistence: ConfigurationStore(url: root.deletingLastPathComponent().appendingPathComponent("merge-revert.json")))
    defer { store.shutdown() }
    await store.addRepository(fixture); await store.current?.activate(refresh: true)
    guard let model = store.current else { throw GitPierError.invalidInput("Missing merge revert model") }
    model.setPage("history")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: RootView().environmentObject(store).modifier(AppAppearance(store: store)))
    window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    defer { window.close() }
    var checks: [String] = []
    var phase = "starting"
    defer {
      var diagnostic = checks.joined(separator: "\n")
      diagnostic += "\nPhase: \(phase)"
      diagnostic += "\nBusy: \(model.busy), refreshing: \(model.refreshing), sheet: \(window.attachedSheet != nil)"
      diagnostic += "\nConfirmation: \(model.confirmation?.title ?? "none"), ready: \(model.confirmation?.canConfirm ?? false)"
      diagnostic += "\nError: \(model.error ?? "none")"
      try? diagnostic.write(to: output.appendingPathComponent("merge-revert-diagnostics.txt"), atomically: true, encoding: .utf8)
    }
    func require(_ value: Bool, _ name: String) throws {
      guard value else { throw GitPierError.invalidInput("Merge revert: " + name) }; checks.append(name)
    }
    func control(_ id: String) throws -> NSObject {
      guard let content = window.attachedSheet?.contentView, let value = assistantFind(content, id: id) else {
        throw GitPierError.invalidInput("Missing merge revert control: " + id)
      }
      return value
    }
    func openReview() async throws {
      phase = "waiting for idle before opening"
      try await waitFor { !model.busy && !model.refreshing }
      model.revert(commit)
      phase = "waiting for prepared confirmation"
      try await waitFor { model.confirmation?.canConfirm == true && window.attachedSheet != nil }
      try await settle()
      let confirm = try control("gitpier.workflow.review.confirm")
      try require((confirm.value(forKey: "accessibilityEnabled") as? Bool) == false, "Merge revert requires an explicit mainline choice")
    }
    func closeReview() async throws {
      phase = "pressing cancel"
      try assistantPress(control("gitpier.workflow.review.cancel"))
      phase = "waiting for sheet dismissal"
      try await waitFor { window.attachedSheet == nil }
      phase = "cancelled"
    }
    let indexURL = fixture.appendingPathComponent(".git/index")
    let index = try Data(contentsOf: indexURL)
    for language in [AppLanguage.english, .simplifiedChinese] {
      for appearance in [AppearanceMode.light, .dark] {
        var settings = store.settings; settings.language = language; settings.appearance = appearance
        store.updateSettings(settings)
        try await openReview()
        try require(window.attachedSheet!.frame.height <= 440, "Mainline review remains bounded")
        guard let content = window.attachedSheet?.contentView,
          let scroll = descendants(content).compactMap({ $0 as? NSScrollView }).first,
          let overlay = scroll.subviews.compactMap({ $0 as? OverlayScrollbars }).first else {
          throw GitPierError.invalidInput("Merge revert did not reuse shared scrollbars")
        }
        try require(!scroll.hasVerticalScroller && !scroll.hasHorizontalScroller && overlay.verticalThumb.knobRect.width == 6,
          "Mainline choice uses the shared overlay without native scrollbar gutters")
        guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -250, wheel2: 0, wheel3: 0),
          let wheelEvent = NSEvent(cgEvent: wheel) else { throw GitPierError.invalidInput("Cannot construct mainline wheel event") }
        let origin = scroll.contentView.bounds.origin
        scroll.scrollWheel(with: wheelEvent); try await settle()
        try require(scroll.contentView.bounds.origin != origin, "Native wheel scrolls the mainline review")
        try dragThumb(overlay.verticalThumb, in: window.attachedSheet!)
        try require(overlay.verticalThumb.fraction > 0.98, "Dragging reaches the last mainline parent")
        try require(overlay.hitTest(NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)) == nil, "Overlay preserves text selection pass-through")
        overlay.verticalThumb.changed?(0)
        try require(overlay.verticalThumb.fraction < 0.01, "Mainline review returns to its first line")
        window.setContentSize(NSSize(width: 1200, height: 800)); try await settle()
        try require(window.attachedSheet!.frame.height <= 440, "Resizing preserves the bounded mainline sheet")
        window.setContentSize(NSSize(width: 1000, height: 700))
        _ = try control("gitpier.revert.parent.1"); _ = try control("gitpier.revert.parent.2")
        try assistantPress(control("gitpier.revert.parent.2")); try await settle()
        try require((try control("gitpier.workflow.review.confirm")).value(forKey: "accessibilityEnabled") as? Bool == true, "Selecting a parent enables confirmation")
        let parentText = assistantElements(window.attachedSheet!.contentView!).map { assistantString($0, "accessibilityLabel") + assistantString($0, "accessibilityValue") }.joined(separator: "\n")
        try require(commit.parents.allSatisfy { parentText.contains($0) }, "Review identifies parents with full hashes")
        if language == .english, let content = window.attachedSheet?.contentView {
          try capture(content, to: output.appendingPathComponent("merge-revert-\(appearance.rawValue).png"))
          if ProcessInfo.processInfo.environment["GITPIER_MERGE_REVERT_CAPTURE"] == "1", let sheet = window.attachedSheet {
            let capture = try await ProcessRunner().run(executable: "/usr/sbin/screencapture",
              arguments: ["-x", "-o", "-l", String(sheet.windowNumber), output.appendingPathComponent("merge-revert-composited-\(appearance.rawValue).png").path], directory: fixture)
            try require(capture.code == 0, "Composited native sheet capture succeeded")
          }
        }
        try await closeReview()
      }
    }
    let beforeWrite = try await raw.status()
    try require(beforeWrite.head == mergeHash && (try Data(contentsOf: indexURL)) == index, "Review cancellation preserves HEAD and exact Index")
    for parent in [2, 1] {
      try await openReview()
      try assistantPress(control("gitpier.revert.parent.\(parent)"))
      try await settle()
      try assistantPress(control("gitpier.workflow.review.confirm"))
      try await waitFor { !model.busy && (window.attachedSheet == nil || model.error != nil) }
      try require(model.error == nil, "Revert action succeeded: " + (model.error ?? "no error"))
      let state = try await raw.status()
      try require(state.head != mergeHash && state.files.isEmpty && state.operation == nil, "Native confirmation creates a clean revert commit")
      try require(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("main.txt").path) == (parent == 1), "Parent \(parent) retains the intended main version")
      try require(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("topic.txt").path) == (parent == 2), "Parent \(parent) retains the intended topic version")
      try await command(["reset", "--hard", mergeHash]); await model.refresh()
    }
    try await openReview()
    model.setPage("branches")
    try await waitFor { window.attachedSheet == nil }
    try require(model.confirmation == nil, "Changing pages cancels a prepared mainline review")
    model.setPage("history")
    model.revert(commit); model.setPage("branches"); model.setPage("history")
    phase = "waiting for late preparation rejection"
    try await waitFor { model.confirmation == nil || model.confirmation?.canConfirm == true }
    try require(model.confirmation == nil, "Switching away and back rejects late preparation")
    try await openReview()
    try assistantPress(control("gitpier.revert.parent.1")); try await settle()
    try await command(["commit", "--allow-empty", "-m", "external commit"])
    let externalHead = try await raw.status().head
    try assistantPress(control("gitpier.workflow.review.confirm"))
    try await waitFor { !model.busy && model.error != nil }
    let afterStale = try await raw.status().head
    try require(afterStale == externalHead, "A changed HEAD blocks the captured native confirmation")
    model.error = nil
    try await waitFor { window.attachedSheet == nil }
    try await command(["reset", "--hard", mergeHash]); await model.refresh()
    // Cancellation happens before the asynchronous review gets a chance to publish.
    model.revert(commit); model.confirmation = nil
    try await settle()
    try require(model.confirmation == nil && !model.busy, "Cancelled preparation cannot recreate the confirmation")
    let ordinary = try await raw.commitDetail(commit.parents[0])
    model.revert(ordinary)
    try await waitFor { model.confirmation?.canConfirm == true && window.attachedSheet != nil }
    try await settle()
    try require((try control("gitpier.workflow.review.confirm")).value(forKey: "accessibilityEnabled") as? Bool == true, "Ordinary revert keeps its existing confirmation without a parent choice")
    try await closeReview()
    try checks.joined(separator: "\n").write(to: output.appendingPathComponent("merge-revert-results.txt"), atomically: true, encoding: .utf8)
  }
}
