import AppKit
import GitPierCore
import SwiftUI

@MainActor extension UIAcceptance {
  static func verifyConfirmations(root: URL, output: URL) async throws {
    guard root.deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui.") else {
      throw GitPierError.invalidInput("Confirmation acceptance requires a disposable repository")
    }
    var checks: [String] = []
    func require(_ value: Bool, _ name: String) throws {
      guard value else { throw GitPierError.invalidInput("Confirmation: " + name) }
      checks.append(name)
    }
    let store = AppStore(persistence: ConfigurationStore(url: root.deletingLastPathComponent().appendingPathComponent("confirmations.json")))
    defer { store.shutdown() }
    for index in 1...201 {
      try Data("Synthetic change \(index)\n".utf8).write(to: root.appendingPathComponent(String(format: "change-%03d.txt", index)))
    }
    await store.addRepository(root); await store.current?.activate(refresh: true)
    guard let model = store.current else { throw GitPierError.invalidInput("Missing confirmation fixture") }
    let git = await model.git()
    let before = try await git.snapshot()
    let indexURL = root.appendingPathComponent(".git/index")
    let indexBytes = try Data(contentsOf: indexURL)
    model.toggleIncluded(model.status.files.filter { !model.includedPaths.contains($0.path) })
    model.editDraft("test: review a large selection without committing")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640), styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: RootView().environmentObject(store).modifier(AppAppearance(store: store)))
    window.contentView = host
    window.setContentSize(NSSize(width: 960, height: 640))
    window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    defer { window.close() }
    func sheet() async throws -> (NSWindow, NSView) {
      try await waitFor { window.attachedSheet != nil }
      try await settle()
      guard let sheet = window.attachedSheet, let rootView = sheet.contentView else {
        throw GitPierError.invalidInput("Missing confirmation sheet")
      }
      try require(sheet.frame.height <= 440 && sheet.frame.width <= 620, "Confirmation stays bounded with more than 201 files")
      let content = descendants(rootView).first { String(describing: type(of: $0)).contains("NSHostingView") } ?? rootView
      return (sheet, content)
    }
    func button(_ content: NSView, _ id: String) throws -> NSObject {
      guard let value = assistantFind(content, id: "gitpier.workflow.review." + id) else {
        let controls = assistantElements(content).map { "\(type(of: $0)) " + assistantString($0, "accessibilityIdentifier") + " " + assistantString($0, "accessibilityLabel") }
        try controls.joined(separator: "\n").write(to: output.appendingPathComponent("missing-control.txt"), atomically: true, encoding: .utf8)
        throw GitPierError.invalidInput("Missing confirmation " + id)
      }
      let frame = (value.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
      try require(!frame.isEmpty && window.attachedSheet!.frame.contains(frame), "\(id) button remains inside the sheet")
      return value
    }
    for language in [AppLanguage.english, .simplifiedChinese] {
      for appearance in [AppearanceMode.light, .dark] {
        var settings = store.settings; settings.language = language; settings.appearance = appearance
        store.updateSettings(settings)
        try await settle()
        try await waitFor { !model.refreshing && !model.busy }
        model.amend = true
        try require(model.canCommit && model.snapshot != nil, "Large selection is ready for commit review (available=\(model.available), refreshing=\(model.refreshing), selected=\(model.includedPaths.count), draft=\(!model.record.draft.isEmpty))")
        model.commit(push: false)
        try require(model.confirmation != nil, "Commit opens a review before any write")
        let (review, content) = try await sheet()
        try require(model.confirmation?.detail.contains("change-201.txt") == true, "Real commit review contains the last selected path")
        _ = try button(content, "confirm")
        _ = try button(content, "cancel")
        guard let scroll = descendants(content).compactMap({ $0 as? NSScrollView }).first,
          let overlay = scroll.subviews.compactMap({ $0 as? OverlayScrollbars }).first else {
          throw GitPierError.invalidInput("Confirmation did not install shared scrollbars")
        }
        try require(!scroll.hasVerticalScroller && !scroll.hasHorizontalScroller && overlay.verticalThumb.knobRect.height == 150 && overlay.verticalThumb.knobRect.width == 6, "Review uses the shared Diff scrollbar")
        try require(overlay.verticalThumb.fraction < 0.01, "Review starts at the first file")
        if ProcessInfo.processInfo.environment["GITPIER_CONFIRMATION_GUI"] == "1", language == .english, appearance == .light {
          let ready = output.appendingPathComponent("gui-ready")
          let resume = output.appendingPathComponent("gui-continue")
          try Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: ready)
          let deadline = Date().addingTimeInterval(120)
          while !FileManager.default.fileExists(atPath: resume.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
          }
          try require(FileManager.default.fileExists(atPath: resume.path), "GUI inspection completed before fixture timeout")
          overlay.verticalThumb.changed?(0)
        }
        let origin = scroll.contentView.bounds.origin
        guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -180, wheel2: 0, wheel3: 0),
          let wheelEvent = NSEvent(cgEvent: wheel) else { throw GitPierError.invalidInput("Cannot construct native wheel event") }
        scroll.scrollWheel(with: wheelEvent)
        try await settle()
        try require(scroll.contentView.bounds.origin != origin, "Native wheel input scrolls the review details")
        let textPoint = NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)
        try require(overlay.hitTest(textPoint) == nil, "Scrollbar overlay passes text selection through to the document")
        let size = window.contentLayoutRect.size
        window.setContentSize(NSSize(width: 1200, height: 800))
        try await settle()
        _ = try button(content, "confirm"); _ = try button(content, "cancel")
        window.setContentSize(size)
        try await settle()
        try dragThumb(overlay.verticalThumb, in: review)
        try require(overlay.verticalThumb.fraction > 0.98, "Dragging reaches the last file")
        _ = try button(content, "confirm"); _ = try button(content, "cancel")
        overlay.verticalThumb.changed?(0)
        try require(overlay.verticalThumb.fraction < 0.01, "Shared scrollbar returns to the first file")
        try assistantPress(button(content, "cancel"))
        try await waitFor { window.attachedSheet == nil }
        try require(model.confirmation == nil && !model.busy, "Cancel dismisses review without committing")
      }
    }
    // A harmless action proves the real button dismisses before executing, once.
    var actions = 0
    var dismissedBeforeAction = false
    model.confirmation = PendingAction(title: "Synthetic confirmation", detail: "One short detail", destructive: false) {
      actions += 1; dismissedBeforeAction = model.confirmation == nil
    }
    let (_, shortContent) = try await sheet()
    try assistantPress(button(shortContent, "confirm"))
    try await waitFor { window.attachedSheet == nil }
    try require(actions == 1 && dismissedBeforeAction, "Confirm invokes the captured action once after clearing the request")
    model.confirmation = PendingAction(title: "Preparing review", detail: "Checking current state", destructive: false, canConfirm: false, asynchronousReview: true) { actions += 1 }
    let (_, pendingContent) = try await sheet()
    let disabled = try button(pendingContent, "confirm")
    try require((disabled.value(forKey: "accessibilityEnabled") as? Bool) == false, "Preparation disables confirmation")
    let pendingID = model.confirmation!.id
    model.confirmation = PendingAction(id: pendingID, title: "Prepared review", detail: "Updated details", destructive: false, asynchronousReview: true) { actions += 1 }
    try await settle()
    let enabled = try button(pendingContent, "confirm")
    try require((enabled.value(forKey: "accessibilityEnabled") as? Bool) == true, "Prepared review updates in place and enables confirmation")
    try assistantPress(button(pendingContent, "cancel"))
    try await waitFor { window.attachedSheet == nil }
    try require(actions == 1, "Cancelling preparation never runs its action")
    let after = try await git.snapshot()
    try require(before == after && (try Data(contentsOf: indexURL)) == indexBytes, "HEAD and exact Index bytes survive all reviews")
    try require(model.record.draft == "test: review a large selection without committing", "Review cancellation preserves the commit draft")
    try checks.joined(separator: "\n").write(to: output.appendingPathComponent("confirmation-results.txt"), atomically: true, encoding: .utf8)
  }
}
