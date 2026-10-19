import AppKit
import GitPierCore
import SwiftUI

@MainActor extension UIAcceptance {
  static func verifyContextAssistant(root: URL, output: URL) async throws {
    guard root.deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui.") else { throw GitPierError.invalidInput("Disposable repository required") }
    var checks: [String] = []
    func require(_ condition: Bool, _ name: String) throws {
      guard condition else { throw GitPierError.invalidInput("Context assistant: " + name) }
      checks.append(name)
      try checks.joined(separator: "\n").write(to: output.appendingPathComponent("assistant-results.txt"), atomically: true, encoding: .utf8)
    }
    let store = AppStore(persistence: ConfigurationStore(url: root.deletingLastPathComponent().appendingPathComponent("assistant-workspace.json")))
    defer { store.shutdown() }
    var settings = store.settings; settings.automaticFetch = false; settings.automaticRefresh = false; store.updateSettings(settings)
    await store.addRepository(root); await store.current?.activate(refresh: true)
    guard let model = store.current else { throw GitPierError.invalidInput("Missing repository") }
    let git = await model.git()
    try await git.perform(["config", "user.name", "Assistant Fixture"])
    try await git.perform(["config", "user.email", "assistant@example.invalid"])
    try await git.perform(["config", "commit.gpgsign", "false"])
    try await git.perform(["add", "--all"]); try await git.perform(["commit", "-m", "assistant fixture"])
    _ = try await git.network("push"); await model.refresh(); await store.workspace.refresh()
    model.network("fetch"); try await waitFor { !model.busy }
    var layout = model.panels.layout; layout.terminalVisible = false; model.editLayout(layout)
    model.output = nil; model.setPage("commit")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640), styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: AnyView(RootView().environmentObject(store).modifier(AppAppearance(store: store))))
    host.sizingOptions = []; host.autoresizingMask = [.width, .height]; window.contentView = host
    NSApp.setActivationPolicy(.regular)
    window.setContentSize(NSSize(width: 960, height: 640)); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    defer { window.close() }
    try await settle(); try await waitFor { !model.refreshing }
    func popup() -> NSWindow? {
      NSApp.windows.first { $0 !== window && $0.isVisible && $0.contentView.map { assistantFind($0, id: "gitpier.workflow.guidance") != nil } == true }
    }
    func open() async throws -> NSWindow {
      window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
      try await waitFor { NSApp.isActive && window.isKeyWindow }
      // Language changes can insert the existing restart notice above the
      // toolbar. Wait for that layout before reading AX screen coordinates.
      try await settle()
      host.layoutSubtreeIfNeeded()
      // Replacing the selected repository can finish the old popover's native
      // key-window teardown during layout. Reactivate the surviving window.
      window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
      try await waitFor { NSApp.isActive && window.isKeyWindow }
      guard let button = assistantFind(host, id: "gitpier.workflow.open") else { throw GitPierError.invalidInput("Missing toolbar button") }
      // Exercise the real mouse route after native activation, rather than an
      // AX Press racing AppKit's previous key-window/focus teardown.
      let frame = assistantFrame(button)
      assistantClick(window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY)), window: window)
      try await settle()
      guard let popover = popup() else { throw GitPierError.invalidInput("Native popover did not open (active=\(NSApp.isActive), key=\(window.isKeyWindow), frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"), anchor=\(frame))") }
      return popover
    }
    func close(_ popover: NSWindow) async throws {
      assistantKey("\u{1b}", code: 53, window: popover)
      try await settle(); try require(popup() == nil, "Escape closes the native popover")
    }
    guard let toolbar = assistantFind(host, id: "gitpier.repository.toolbar"),
      let button = assistantFind(host, id: "gitpier.workflow.open"), let branch = assistantFind(host, id: "gitpier.repository.branch") else { throw GitPierError.invalidInput("Missing toolbar accessibility anchors") }
    let toolbarFrame = assistantFrame(toolbar), buttonFrame = assistantFrame(button), branchFrame = assistantFrame(branch)
    try require(abs(toolbarFrame.height - 43) < 1 && buttonFrame.width == 30 && buttonFrame.height == 23, "Toolbar remains 43pt and assistant reserves one stable 30×23pt status slot")
    try require(buttonFrame.maxX < branchFrame.minX && abs(buttonFrame.midY - branchFrame.midY) < 3, "Assistant is immediately left of the existing branch control")
    guard let changes = assistantElements(host).first(where: { assistantString($0, "accessibilityValue") == "Changes" || assistantString($0, "accessibilityLabel") == "Changes" }) else { throw GitPierError.invalidInput("Missing Changes heading") }
    let reclaimed = toolbarFrame.minY - assistantFrame(changes).maxY
    try require(reclaimed >= 0 && reclaimed < 35, "Main content starts directly below toolbar, with no banner or reserved gap: \(reclaimed)")
    try require(popup() == nil && assistantFind(host, id: "gitpier.workflow.guidance") == nil, "No popover or suggestion region is present by default")
    try require(assistantString(button, "accessibilityValue").contains("No priority"), "Clean aligned target uses normal accessible state")
    let empty = try await open()
    try require(String(describing: type(of: empty)).contains("Popover"), "SwiftUI presents an AppKit native popover: " + String(describing: type(of: empty)))
    try require(empty.contentView.map { assistantText($0).contains("No priority suggestions") } == true, "Clean snapshot has a concise empty suggestion state")
    try require(empty.contentView.flatMap { assistantFind($0, id: "gitpier.workflow.reviewPush") } == nil, "Empty state does not invent Push")
    try await close(empty)
    assistantKey("\u{1b}", code: 53, window: window); try await settle()
    try require(popup() == nil, "Escape on the closed anchor does not create pending presentation")
    assistantKey(" ", code: 49, window: window); try await settle()
    try require(popup() != nil, "Keyboard focus returns to the anchor and Space opens it (active=\(NSApp.isActive), mainKey=\(window.isKeyWindow), key=\(String(describing: NSApp.keyWindow)))")
    if let current = popup() { try await close(current) }
    _ = try await open()
    try assistantPress(button); try await settle()
    try require(popup() == nil, "Activating the anchor again dismisses the current popover")
    if ProcessInfo.processInfo.environment["GITPIER_ASSISTANT_VISUAL_HOLD"] == "1" {
      // Inspect after keyboard assertions. A human returning to Codex during
      // this pause may legitimately deactivate the fixture application.
      try "closed-focus".write(to: output.appendingPathComponent("visual-ready.txt"), atomically: true, encoding: .utf8)
      try await Task.sleep(for: .seconds(45))
    }
    let outside = try await open()
    assistantClick(NSPoint(x: host.bounds.width - 15, y: 12), window: window); try await settle()
    try require(popup() == nil && !outside.isVisible, "Clicking outside dismisses without navigating")
    // A mixed partial Index is a normal review, not three separate warnings.
    try Data("staged assistant\n".utf8).write(to: root.appendingPathComponent("README.md"))
    try await git.perform(["add", "--", "README.md"])
    try Data("staged assistant\nunstaged assistant\n".utf8).write(to: root.appendingPathComponent("README.md"))
    try Data("untracked\n".utf8).write(to: root.appendingPathComponent("assistant-untracked.txt"))
    await model.refresh(); try await settle()
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    try require(popup() == nil && assistantString(button, "accessibilityValue").contains("No priority"), "Ordinary changes do not auto-open or nag on the Commit page")
    model.setPage("branches"); try await settle()
    try require(assistantString(button, "accessibilityValue").contains("Suggestion available"), "Same uncommitted state is an ordinary suggestion on another page")
    let live = try await open()
    guard let liveContent = live.contentView else { throw GitPierError.invalidInput("Missing native content") }
    try require(assistantFind(liveContent, id: "gitpier.workflow.reviewChanges") != nil, "Relevant review action appears outside the Commit page")
    model.setPage("commit"); try await settle()
    try require(popup() === live && assistantText(liveContent).contains("remain uncommitted") && assistantFind(liveContent, id: "gitpier.workflow.reviewChanges") == nil, "Open popover updates in place and lowers duplicate navigation without declaring completion")
    try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index, "Opening, closing and changing advice never stage or alter partial Index content")
    try await close(live)
    try await settle(); _ = ProcessTrace.take()
    for _ in 0..<3 { let popover = try await open(); try await close(popover) }
    let renderCommands = ProcessTrace.take()
    try require(ProcessTrace.enabled && renderCommands.isEmpty, "Repeated toolbar/popover rendering launches zero Git processes (enabled=\(ProcessTrace.enabled), commands=\(renderCommands.map(\.command)))")
    // Same-branch changes refresh in place; a different target closes the native popover.
    let changing = try await open()
    try await git.perform(["stash", "push", "--include-untracked", "-m", "assistant changes"]); await model.refresh(); try await settle()
    try require(popup() === changing && changing.contentView.map { assistantText($0).contains("No priority suggestions") } == true, "Stash completion updates open analysis without closing or reopening")
    try await git.perform(["stash", "pop"]); await model.refresh(); try await settle()
    try require(popup() === changing && changing.contentView.map { assistantText($0).contains("remain uncommitted") } == true, "Restoring changes updates the same popover")
    try await git.perform(["reset", "--hard", "HEAD"]); try? FileManager.default.removeItem(at: root.appendingPathComponent("assistant-untracked.txt")); await model.refresh()
    try await git.perform(["switch", "--detach", "HEAD"]); await model.refresh(); try await settle()
    try require(popup() == nil && assistantString(button, "accessibilityValue").contains("Warning"), "Changing branch closes stale presentation and detached HEAD has a warning label")
    let detached = try await open(); try require(detached.contentView.map { assistantText($0).contains("detached") } == true, "Detached explanation names the actual HEAD state")
    try await close(detached)
    try await git.perform(["switch", "main"]); await model.refresh(); await store.workspace.refresh(); try await settle()
    let linked = root.deletingLastPathComponent().appendingPathComponent("assistant-linked")
    try await git.perform(["worktree", "add", "-b", "assistant-linked", linked.path])
    let selected = try await open(); await store.addRepository(linked); await store.current?.activate(refresh: true); try await settle()
    try require(popup() == nil && !selected.isVisible && store.current?.record.path == linked.resolvingSymlinksInPath().path, "Switching repositories/Worktrees closes the old presentation")
    let linkedPopover = try await open()
    try require(linkedPopover.contentView.map { assistantText($0).contains("assistant-linked") && !assistantText($0).contains("origin/main ·") } == true, "New Worktree shows its own branch and upstream context")
    try await close(linkedPopover)
    store.select(model.record.id); await model.activate(refresh: true); try await settle()
    // Late local analysis cannot create a confirmation for an already changed branch/page.
    try await git.perform(["commit", "--allow-empty", "-m", "outgoing review"]); await model.refresh(); try await settle()
    let displayed = model.workflowInput()
    try require(ContextWorkflowAdvice.evaluate(displayed).actions.contains(.reviewPush), "Late-result fixture has a real actionable outgoing commit")
    let pending = Task { await model.prepareWorkflow(.reviewPush, displayed: displayed) }
    try await waitFor { model.workflowPreparing }
    model.setPage("branches")
    await pending.value
    try require(model.confirmation == nil && model.page == "branches", "Late analysis does not hand off after the user changes the page")
    model.setPage("commit")
    let oldBranch = model.workflowInput(), gate = AssistantHandoffGate()
    let branchReview = Task { await gate.wait(); await model.prepareWorkflow(.reviewPush, displayed: oldBranch) }
    try await git.perform(["switch", "-c", "assistant-new-target"]); await model.refresh()
    await gate.release(); await branchReview.value
    try require(model.confirmation == nil && model.status.branch == "assistant-new-target", "A delayed old-branch callback cannot create a confirmation for the new branch")
    try await git.perform(["switch", "main"]); await model.refresh()
    // Build a real conflict, then inspect the original recovery controls in the popover.
    try await git.perform(["switch", "-c", "assistant-conflict"])
    try Data("feature conflict\n".utf8).write(to: root.appendingPathComponent("README.md")); try await git.perform(["add", "README.md"]); try await git.perform(["commit", "-m", "feature conflict"])
    try await git.perform(["switch", "main"])
    try Data("main conflict\n".utf8).write(to: root.appendingPathComponent("README.md")); try await git.perform(["add", "README.md"]); try await git.perform(["commit", "-m", "main conflict"])
    do { try await git.perform(["merge", "assistant-conflict"]); throw GitPierError.invalidInput("Fixture failed to conflict") } catch let error as GitPierError { if case .command = error {} else { throw error } }
    await model.refresh(); try await settle()
    try require(assistantString(button, "accessibilityValue").contains("Conflict"), "Real unmerged paths have the highest priority even on the Commit page")
    // Presentation-only snapshots, distinct from the real conflict fixture.
    // No Git mutation or network activity is needed to exercise every visual tier.
    let conflictStatus = model.status
    var cleanStatus = conflictStatus; cleanStatus.files = []; cleanStatus.operation = nil
    cleanStatus.ahead = 0; cleanStatus.behind = 0
    var outgoingStatus = cleanStatus; outgoingStatus.ahead = 2
    var incomingStatus = cleanStatus; incomingStatus.behind = 240
    var warningStatus = incomingStatus
    warningStatus.files = [FileChange(path: "local.txt", index: ".", worktree: "M", kind: .modified)]
    for (snapshot, expected) in [(cleanStatus, "No priority"), (outgoingStatus, "Suggestion available"),
      (incomingStatus, "Needs attention"), (warningStatus, "Warning"), (conflictStatus, "Conflict")] {
      var input = model.workflowInput(); input.status = snapshot
      let advice = ContextWorkflowAdvice.evaluate(input)
      let presentation = ContextWorkflowPresentation(advice: advice, input: input, store: store)
      try require(presentation.label.contains(expected), "Synthetic snapshot maps to distinct presentation: " + expected)
      if snapshot.behind == 240 && snapshot.files.isEmpty {
        try require(presentation.summary.contains("240") && !presentation.label.contains("Conflict"),
          "240 tracking-only commits are attention, never a fabricated conflict")
      }
    }
    try require(assistantFrame(button) == buttonFrame && assistantFrame(toolbar).height == toolbarFrame.height,
      "Real normal/suggestion/warning/conflict transitions retain the entire status slot and toolbar height")
    let conflictInput = model.workflowInput()
    try require(ContextWorkflowPresentation(advice: .evaluate(conflictInput), input: conflictInput, store: store, hasNotice: true).level == .blocked,
      "A supplemental notice cannot downgrade a true conflict")
    for language in AppLanguage.allCases {
      for appearance in [AppearanceMode.light, .dark] {
        var themed = store.settings; themed.language = language; themed.appearance = appearance; store.updateSettings(themed)
        let popover = try await open(); guard let content = popover.contentView else { throw GitPierError.invalidInput("Missing popover content") }
        let frame = content.bounds
        let expectedAppearance: NSAppearance.Name = appearance == .light ? .aqua : .darkAqua
        try require(popover.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expectedAppearance,
          "Popover native material follows the selected theme: " + appearance.rawValue)
        try require(popover.alphaValue == 1,
          "Popover uses a blurred material without whole-window transparency: " + appearance.rawValue)
        let nativeRoot = content.superview ?? content
        let effects = ([nativeRoot] + descendants(nativeRoot)).compactMap { $0 as? NSVisualEffectView }
        let materialReport = effects.map { "\(type(of: $0)) material=\($0.material.rawValue) blend=\($0.blendingMode.rawValue) state=\($0.state.rawValue) opaque=\($0.isOpaque)" }.joined(separator: "\n")
        try materialReport.write(to: output.appendingPathComponent("native-material-" + language.rawValue + "-" + appearance.rawValue + ".txt"), atomically: true, encoding: .utf8)
        try require(assistantElements(content).allSatisfy { !["Close suggestions", "关闭建议"].contains(assistantString($0, "accessibilityLabel")) },
          "Popover has no close button or reserved close control")
        assistantClick(NSPoint(x: 70, y: popover.contentLayoutRect.height - 40), window: popover); try await settle()
        try require(popup() === popover, "Clicking ordinary popover content does not dismiss it")
        try assistantUnifiedScrollbars(content)
        try require(frame.width >= 400 && frame.width <= 440 && frame.height < 510, "Native popover stays compact at 960pt window: " + language.rawValue + "/" + appearance.rawValue)
        let documentHeights = descendants(content).compactMap { ($0 as? NSScrollView)?.documentView?.bounds.height }
        try require(frame.height > 300, "Native contentSize follows measured content instead of retaining the initial 240pt viewport (native=\(frame.height), documents=\(documentHeights))")
        try require(assistantFind(content, id: "gitpier.workflow.resolveConflicts") != nil && assistantFind(content, id: "gitpier.workflow.abort") != nil, "Conflict recovery reuses relevant controls: " + language.rawValue + "/" + appearance.rawValue)
        if (language == .english && appearance == .light) || (language == .simplifiedChinese && appearance == .dark),
          (["1", "themes"].contains(ProcessInfo.processInfo.environment["GITPIER_ASSISTANT_VISUAL_HOLD"] ?? "") ||
            language == .english && appearance == .light && ProcessInfo.processInfo.environment["GITPIER_ASSISTANT_VISUAL_HOLD"] == "light") {
          try (language.rawValue + "/" + appearance.rawValue).write(to: output.appendingPathComponent("visual-ready.txt"), atomically: true, encoding: .utf8)
          try await Task.sleep(for: .seconds(45))
        }
        try capture(host, to: output.appendingPathComponent("assistant-workspace-" + language.rawValue + "-" + appearance.rawValue + ".png"))
        try assistantCapture(content, to: output.appendingPathComponent("assistant-popover-" + language.rawValue + "-" + appearance.rawValue + ".png"))
        try await close(popover)
      }
    }
    var english = store.settings; english.language = .english; store.updateSettings(english)
    let originalFrame = window.frame
    window.setContentSize(NSSize(width: 720, height: 420))
    if let screen = window.screen {
      window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - window.frame.width, y: screen.visibleFrame.minY + 10))
    }
    let edge = try await open()
    if let screen = edge.screen {
      try require(screen.visibleFrame.insetBy(dx: -1, dy: -1).contains(edge.frame), "Native popover fits the available screen at a narrow window's edge")
    }
    try await close(edge); window.setFrame(originalFrame, display: true); try await settle()
    let previousAppearance = window.appearance
    host.rootView = AnyView(RootView().environmentObject(store))
    guard let requestedContrast = NSAppearance(named: .accessibilityHighContrastDarkAqua) else { throw GitPierError.invalidInput("High-contrast appearance unavailable") }
    window.appearance = requestedContrast
    host.appearance = requestedContrast
    try await settle()
    let contrast = try await open()
    try require(window.appearance == requestedContrast && assistantFind(host, id: "gitpier.workflow.open").map { assistantString($0, "accessibilityValue").contains("Conflict") } == true,
      "Requested native high-contrast appearance retains risk semantics (OS-normalized name): " + (window.appearance?.name.rawValue ?? "system"))
    if let content = contrast.contentView { try assistantCapture(content, to: output.appendingPathComponent("assistant-high-contrast.png")) }
    try await close(contrast)
    host.appearance = nil; window.appearance = previousAppearance
    host.rootView = AnyView(RootView().environmentObject(store).modifier(AppAppearance(store: store))); try await settle()
    let long = try await open()
    model.workflowMessage = String(repeating: "Review the current target before continuing. ", count: 80); try await settle()
    let scrollers = long.contentView.map { descendants($0).compactMap { $0 as? NSScrollView } } ?? []
    guard let scroller = scrollers.first(where: { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 10 }) else { throw GitPierError.invalidInput("Long analysis is not scrollable") }
    try assistantUnifiedScrollbars(long.contentView!)
    guard let overlay = scroller.subviews.compactMap({ $0 as? OverlayScrollbars }).first,
      overlay.verticalThumb.knobRect.width == 6, overlay.verticalThumb.knobRect.height == 150 else {
      throw GitPierError.invalidInput("Popover did not reuse the Diff scrollbar thumb")
    }
    let before = scroller.contentView.bounds.minY
    scroller.contentView.scroll(to: NSPoint(x: 0, y: 100)); scroller.reflectScrolledClipView(scroller.contentView)
    try require(scroller.contentView.bounds.minY != before && long.frame.height < 520, "Long explanations scroll inside a bounded native popover")
    try dragThumb(overlay.verticalThumb, in: long)
    try require(overlay.verticalThumb.fraction > 0.98, "Shared Diff thumb reaches the bottom of the popover")
    model.workflowMessage = nil; try await close(long)
    let recovery = try await open()
    guard let abort = recovery.contentView.flatMap({ assistantFind($0, id: "gitpier.workflow.abort") }) else { throw GitPierError.invalidInput("Missing original Abort") }
    try assistantPress(abort); try await waitFor { window.attachedSheet != nil }
    try require(popup() == nil && model.confirmation != nil && model.status.operation == .merge, "Recovery dismisses the popover before the original confirmation and performs no write")
    if let sheet = window.attachedSheet, let content = sheet.contentView,
      let cancel = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Cancel" }) { cancel.performClick(nil) }
    try await settle(); model.confirmation = nil
    try await git.perform(["merge", "--abort"]); await model.refresh()
    let switching = try await open()
    let otherWindow = NSWindow(contentRect: NSRect(x: 10, y: 10, width: 300, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    otherWindow.isReleasedWhenClosed = false
    otherWindow.contentView = NSHostingView(rootView: RootView().environmentObject(store).modifier(AppAppearance(store: store)))
    otherWindow.makeKeyAndOrderFront(nil); try await settle()
    try require(popup() == nil && !switching.isVisible, "Switching windows closes the old popover")
    otherWindow.close(); window.makeKeyAndOrderFront(nil)
    store.showDashboard = true; try await settle()
    try require(assistantFind(host, id: "gitpier.workflow.open") == nil && popup() == nil, "Dashboard/no active repository has no repository-specific assistant")
    try require(store.settings.automaticFetch == false, "Advice leaves the existing automatic Fetch preference unchanged")
  }
  private static func assistantUnifiedScrollbars(_ root: NSView) throws {
    let scrolls = ([root] + descendants(root)).compactMap { $0 as? NSScrollView }
    guard !scrolls.isEmpty else { throw GitPierError.invalidInput("Popover has no native scroll container") }
    for scroll in scrolls where !scroll.isHiddenOrHasHiddenAncestor {
      guard !scroll.hasVerticalScroller, !scroll.hasHorizontalScroller,
        scroll.subviews.filter({ $0 is OverlayScrollbars }).count == 1 else {
        throw GitPierError.invalidInput("Popover kept a default or duplicate scrollbar")
      }
      guard !scroll.drawsBackground || scroll.backgroundColor.alphaComponent < 1 else {
        throw GitPierError.invalidInput("Opaque scroll content hides the popover material")
      }
    }
  }
  private static func assistantCapture(_ view: NSView, to url: URL) throws {
    let hosting = descendants(view).first { String(describing: type(of: $0)).contains("NSHostingView") } ?? view
    hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw GitPierError.invalidInput("Cannot capture popover") }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    // The system material is compositor-owned. Export the actual native view
    // against its semantic window color so transparent black text stays legible.
    let rendered = NSImage(size: hosting.bounds.size)
    rendered.lockFocus()
    hosting.effectiveAppearance.performAsCurrentDrawingAppearance {
      NSColor.windowBackgroundColor.setFill(); NSRect(origin: .zero, size: hosting.bounds.size).fill()
      rep.draw(in: NSRect(origin: .zero, size: hosting.bounds.size))
    }
    rendered.unlockFocus()
    guard let tiff = rendered.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let data = bitmap.representation(using: .png, properties: [:]) else { throw GitPierError.invalidInput("Cannot encode popover capture") }
    try data.write(to: url)
  }
  static func assistantElements(_ root: Any) -> [NSObject] {
    var seen = Set<ObjectIdentifier>(), items: [NSObject] = []
    func walk(_ value: Any) {
      guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
      items.append(object)
      if object.responds(to: NSSelectorFromString("accessibilityChildren")), let children = object.value(forKey: "accessibilityChildren") as? [Any] { children.forEach(walk) }
      if let view = object as? NSView { view.subviews.forEach(walk) }
    }
    walk(root); return items
  }
  static func assistantString(_ object: NSObject, _ key: String) -> String {
    object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) as? String ?? "" : ""
  }
  static func assistantFind(_ root: Any, id: String) -> NSObject? { assistantElements(root).first { assistantString($0, "accessibilityIdentifier") == id } }
  private static func assistantText(_ root: Any) -> String { assistantElements(root).map { assistantString($0, "accessibilityLabel") + assistantString($0, "accessibilityValue") }.joined(separator: "\n") }
  private static func assistantFrame(_ object: NSObject) -> NSRect {
    guard object.responds(to: NSSelectorFromString("accessibilityFrame")) else { return .zero }
    return (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
  }
  static func assistantPress(_ object: NSObject) throws {
    let action = NSSelectorFromString("accessibilityPerformPress")
    guard object.responds(to: action) else { throw GitPierError.invalidInput("Control has no native Press action") }
    object.perform(action)
  }
  private static func assistantKey(_ characters: String, code: UInt16, window: NSWindow) {
    for kind in [NSEvent.EventType.keyDown, .keyUp] {
      if let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) { NSApp.sendEvent(event) }
    }
  }
  private static func assistantClick(_ location: NSPoint, window: NSWindow) {
    for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      if let event = NSEvent.mouseEvent(with: kind, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(event, atStart: false) }
    }
  }
}

private actor AssistantHandoffGate {
  private var released = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if released { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func release() {
    released = true
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }
}
