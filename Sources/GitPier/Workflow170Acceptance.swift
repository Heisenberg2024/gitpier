import AppKit
import GitPierCore
import SwiftUI

extension UIAcceptance {
  static func verifyWorkflow170(root: URL, output: URL) async throws {
    guard root.deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui.") else {
      throw GitPierError.invalidInput("Workflow acceptance requires its disposable repository")
    }
    var checks: [String] = []
    func require(_ condition: @autoclosure () -> Bool, _ name: String) throws {
      guard condition() else { throw GitPierError.invalidInput("Workflow 1.7: " + name) }; checks.append(name)
    }
    let persistence = ConfigurationStore(url: root.deletingLastPathComponent().appendingPathComponent("workflow170.json"))
    let store = AppStore(persistence: persistence)
    defer { store.shutdown() }
    await store.addRepository(root); await store.current?.activate(refresh: true)
    guard let model = store.current else { throw GitPierError.invalidInput("Missing fixture repository") }
    let center = store.operations
    try require(center.records.isEmpty, "Opening a repository produces no operation records for local scans: " + center.records.map { $0.kind.rawValue + ":" + $0.state.rawValue }.joined(separator: ","))
    model.network("fetch")
    try await waitFor { !model.busy }
    try require(center.records.filter { $0.kind == .fetch && $0.state == .succeeded }.count == 1, "Manual Fetch has one final record")
    let first = UUID(); var cancelled = 0
    center.begin(id: first, kind: .push, repositoryID: model.record.id, state: .running) { cancelled += 1 }
    center.cancel(first); center.cancel(first)
    try require(cancelled == 1 && center.records.first { $0.id == first }?.state == .running, "Repeated cancellation requests are not completion or rollback")
    center.update(first, state: .succeeded); center.cancel(first)
    try require(cancelled == 1 && center.records.first { $0.id == first }?.state == .succeeded, "Confirmed success wins after cancellation and completed records cannot cancel")
    let progress = OperationProgress(); progress.center = center; progress.repositoryID = model.record.id
    let old = progress.begin("Fixture", kind: .clone); let late = progress.receiver()
    progress.markRunning(); progress.finish(.succeeded, ticket: old)
    let new = progress.begin("Fixture", kind: .clone); progress.markRunning()
    late(GitTransferProgress(phase: .receiving, fraction: 0.5))
    try await settle()
    try require(center.records.first { $0.id == new.id }?.progress == nil, "Late progress cannot overwrite a later operation")
    let priorStage = progress.receiver()
    priorStage(GitTransferProgress(phase: .receiving, fraction: 0.5))
    try await settle()
    progress.advance("Refreshing", cancellable: false, phase: .refreshing)
    priorStage(GitTransferProgress(phase: .receiving, fraction: 0.9))
    try await settle()
    let refreshed = center.records.first { $0.id == new.id }
    try require(refreshed?.phase == .refreshing && refreshed?.transferPhase == nil && refreshed?.progress == nil, "A new phase clears transfer progress and rejects prior-stage callbacks")
    progress.finish(.cancelled, ticket: new)
    try require(WorkspaceCommand.review.unavailable(store) != nil, "Disconnected Review command has an unavailable reason")
    try require(WorkspaceCommand.conflicts.unavailable(store) != nil, "Conflict action is unavailable without conflicts")
    store.showDashboard = true
    try require(WorkspaceCommand.history.unavailable(store) != nil, "Repository commands are unavailable on Dashboard")
    store.showDashboard = false
    WorkspaceCommand.history.execute(store)
    try require(model.page == "history" && store.recentCommands.first == .history, "Commands reuse repository navigation and memory Recent")
    guard let stagedFile = model.status.files.first(where: { $0.path == "Sources/workspace.swift" }) else { throw GitPierError.invalidInput("Missing composite commit fixture") }
    model.stageGroup([stagedFile], unstage: false)
    try await waitFor { !model.busy }
    model.editDraft("test: observe a composite commit and push")
    try require(model.canCommit, "Composite fixture has a reviewed staged snapshot")
    model.commit(push: true)
    if let confirmation = model.confirmation { confirmation.action(); model.confirmation = nil }
    try await waitFor { !model.busy }
    try require(center.records.contains { $0.kind == .commitAndPush && $0.state == .succeeded }, "Commit and Push is identified as a composite result")
    let request = try NavigationRequest(directory: root, page: .compare)
    store.enqueueNavigation(request); store.enqueueNavigation(request)
    try await waitFor { !store.routingNavigation }
    try require(model.page == "compare" && store.repositories.count == 1, "Navigation queue deduplicates requests and preserves repository identity")
    // Real local Clone and conflict recovery, including an externally changed Index.
    let cloned = root.deletingLastPathComponent().appendingPathComponent("workflow-clone")
    store.clone(url: root.path, destination: cloned, credential: nil)
    try await waitFor { !store.cloning }
    guard let clonedModel = store.current, clonedModel.record.id != model.record.id else { throw GitPierError.invalidInput("Clone did not open its repository") }
    await clonedModel.activate(refresh: true)
    try require(center.records.contains { $0.kind == .clone && $0.state == .succeeded }, "Clone is observed without changing its execution workflow")
    let clonedGit = await clonedModel.git()
    try await clonedGit.perform(["config", "user.name", "Workflow Fixture"])
    try await clonedGit.perform(["config", "user.email", "workflow@example.invalid"])
    try await clonedGit.perform(["config", "commit.gpgsign", "false"])
    try await clonedGit.createBranch("workflow-conflict")
    try await clonedGit.switchBranch("workflow-conflict")
    try Data("feature version\n".utf8).write(to: cloned.appendingPathComponent("README.md"))
    try await clonedGit.perform(["add", "--", "README.md"])
    try await clonedGit.perform(["commit", "-m", "fixture feature"])
    try await clonedGit.switchBranch("main")
    try Data("main version\n".utf8).write(to: cloned.appendingPathComponent("README.md"))
    try await clonedGit.perform(["add", "--", "README.md"])
    try await clonedGit.perform(["commit", "-m", "fixture main"])
    await clonedModel.refresh()
    clonedModel.run(kind: .merge) { git in try await git.perform(["merge", "workflow-conflict"]) }
    try await waitFor { !clonedModel.busy }
    guard let conflict = center.records.first(where: { $0.kind == .merge && $0.repositoryID == clonedModel.record.id }) else { throw GitPierError.invalidInput("Missing conflict operation") }
    try require(conflict.state == .needsAttention && conflict.recovery == .conflicts, "A real merge conflict is attention with original recovery routing")
    await store.openOperation(conflict)
    try require(store.current === clonedModel && clonedModel.page == "conflicts" && store.error == nil, "Unchanged conflict recovery opens the existing editor")
    try Data("external staged change\n".utf8).write(to: cloned.appendingPathComponent("external.txt"))
    try await clonedGit.perform(["add", "--", "external.txt"])
    let indexURL = cloned.appendingPathComponent(".git/index"), beforeIndex = try Data(contentsOf: cloned.appendingPathComponent(".git/index"))
    store.error = nil
    await store.openOperation(conflict)
    let afterIndex = try Data(contentsOf: indexURL)
    try require(store.error != nil && afterIndex == beforeIndex, "Stale recovery refuses external Index changes without modifying them")
    store.error = nil
    let active = UUID(), unknown = UUID()
    var panelCancellation = 0
    center.begin(id: active, kind: .fetch, repositoryID: model.record.id, state: .running) { panelCancellation += 1 }
    center.begin(id: unknown, kind: .review, repositoryID: model.record.id, state: .running)
    center.update(unknown, state: .resultUnknown, recovery: .reviewJournal)
    try require(center.records.first { $0.id == unknown }?.state == .resultUnknown, "Synthetic Review Unknown is retained and uses original journal recovery")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: AnyView(EmptyView())); window.contentView = host
    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    defer { host.rootView = AnyView(EmptyView()); window.close() }
    // Keep the same hosted panel alive across separate publisher deliveries. Inserting
    // and finishing an operation in one run-loop turn misses stale lazy content.
    let liveCenter = OperationsCenter()
    let liveGit = await model.git()
    guard let liveTarget = try await liveGit.reviewWorkspaceFetch(model.record).first else {
      throw GitPierError.invalidInput("Missing live panel Fetch target")
    }
    var liveJob = WorkspaceFetchJob(target: liveTarget, automatic: true)
    liveJob.state = .running
    liveCenter.observe(liveJob) {}
    host.rootView = AnyView(OperationsCenterView(center: liveCenter).environmentObject(store))
    try await settle()
    try require(workflowAccessibilityText(host).contains("Running"), "Open operation panel initially shows the running automatic Fetch")
    liveJob.state = .succeeded; liveJob.completedAt = Date()
    liveCenter.observe(liveJob) {}
    try await settle()
    let completedText = workflowAccessibilityText(host)
    if !completedText.contains("Succeeded") || completedText.contains("Running") {
      try capture(host, to: output.appendingPathComponent("operations-live-update-failure.png"))
      try completedText.write(to: output.appendingPathComponent("operations-live-update-failure.txt"), atomically: true, encoding: .utf8)
    }
    try require(completedText.contains("Succeeded") && !completedText.contains("Running"), "Automatic Fetch completion updates the open panel without reopening")
    let livePush = UUID()
    liveCenter.begin(id: livePush, kind: .push, repositoryID: model.record.id, state: .running) {}
    liveCenter.update(livePush, transfer: GitTransferProgress(phase: .receiving, fraction: 0.25))
    try await settle()
    try require(workflowAccessibilityText(host).contains("Receiving 25%"), "An open operation row shows its first transfer progress")
    liveCenter.update(livePush, transfer: GitTransferProgress(phase: .receiving, fraction: 0.75))
    try await settle()
    try require(workflowAccessibilityText(host).contains("Receiving 75%") && !workflowAccessibilityText(host).contains("Receiving 25%"), "An existing active row updates progress without changing identity")
    liveCenter.cancel(livePush)
    try await settle()
    try require(workflowAccessibilityText(host).contains("Cancelling…"), "An open row updates a cancellation request immediately")
    liveCenter.update(livePush, state: .failed)
    try await settle()
    let failedText = workflowAccessibilityText(host)
    try require(failedText.contains("Failed · Open repository for details") && !failedText.contains("Cancelling…"), "A live failure moves to Attention with fresh final content")
    let presentationStore = AppStore(persistence: ConfigurationStore(url: root.deletingLastPathComponent().appendingPathComponent("presentation.json")))
    defer { presentationStore.shutdown() }
    presentationStore.presentNavigationWindow()
    try require(presentationStore.navigationPresentationPending, "Cold-start navigation defers presentation until a workspace window exists")
    let presentationWindow = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 480, height: 240), styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
    presentationWindow.isReleasedWhenClosed = false
    presentationWindow.contentView = WindowHookView(store: presentationStore)
    try await settle()
    try require(!presentationStore.navigationPresentationPending && presentationWindow.isVisible, "The real window lifecycle fulfils deferred CLI presentation")
    presentationWindow.miniaturize(nil)
    try await settle()
    try require(presentationWindow.isMiniaturized, "CLI fixture starts with a genuinely minimized workspace window")
    presentationStore.presentNavigationWindow()
    try await settle()
    try require(!presentationWindow.isMiniaturized && presentationWindow.isVisible, "CLI navigation restores the minimized workspace window")
    presentationWindow.close()
    for language in AppLanguage.allCases {
      for appearance in [AppearanceMode.light, .dark] {
        var settings = store.settings; settings.language = language; settings.appearance = appearance; store.updateSettings(settings)
        host.rootView = AnyView(OperationsCenterView(center: center).environmentObject(store).modifier(AppAppearance(store: store)))
        try await settle()
        try capture(host, to: output.appendingPathComponent("v170-operations-" + language.rawValue + "-" + appearance.rawValue + ".png"))
        host.rootView = AnyView(QuickOpenView().environmentObject(store).modifier(AppAppearance(store: store)))
        try await settle()
        try capture(host, to: output.appendingPathComponent("v170-palette-" + language.rawValue + "-" + appearance.rawValue + ".png"))
        host.rootView = AnyView(SettingsView(initialTab: 3).environmentObject(store).modifier(AppAppearance(store: store)))
        window.setContentSize(NSSize(width: 760, height: 580))
        try await settle()
        for scroll in workflowScrollViews(host) {
          if let document = scroll.documentView { document.scroll(NSPoint(x: 0, y: document.bounds.height)); scroll.reflectScrolledClipView(scroll.contentView) }
        }
        try await settle()
        let buttonTitles = [store.text("Install Command Line Tool", "安装命令行工具"),
          store.text("Uninstall Command Line Tool", "卸载命令行工具"), store.text("Choose GitPier App…", "选择 GitPier 应用…")]
        let frames = workflowButtonFrames(host, titles: Set(buttonTitles))
        if let install = frames[buttonTitles[0]], let uninstall = frames[buttonTitles[1]], let choose = frames[buttonTitles[2]] {
          try require(abs(install.midY - uninstall.midY) < 2 && abs(install.midY - choose.midY) < 2
            && install.maxX <= uninstall.minX && uninstall.maxX <= choose.minX && buttonTitles.allSatisfy { frames[$0].map(window.frame.contains) == true },
            "Terminal settings CLI buttons share a visible row in order: " + language.rawValue + "/" + appearance.rawValue)
        } else { throw GitPierError.invalidInput("Missing Terminal settings CLI controls") }
        try capture(host, to: output.appendingPathComponent("v170-cli-settings-" + language.rawValue + "-" + appearance.rawValue + ".png"))
        window.setContentSize(NSSize(width: 820, height: 620))
      }
    }
    host.rootView = AnyView(QuickOpenView().environmentObject(store).modifier(AppAppearance(store: store)))
    try await settle()
    let contextName = clonedModel.record.name
    clonedModel.record.name = "Updated CLI Context"
    try await settle()
    let contextLabels = workflowAccessibilityText(host)
    if !contextLabels.contains("Updated CLI Context") {
      try capture(host, to: output.appendingPathComponent("palette-context-failure.png"))
      try ("Dashboard: \(store.showDashboard)\nCurrent: \(store.current?.title ?? "none")\n" + contextLabels).write(to: output.appendingPathComponent("palette-context-failure.txt"), atomically: true, encoding: .utf8)
    }
    try require(contextLabels.contains("Updated CLI Context"), "Palette context updates from the repository publisher without a search change")
    clonedModel.record.name = contextName
    host.rootView = AnyView(EmptyView()); try await settle()
    try require(panelCancellation == 0 && center.records.first { $0.id == active }?.state == .running, "Closing the operation view does not cancel the execution owner")
    center.update(active, state: .succeeded)
    weak var cancellationLease: NSObject?
    do {
      let lease = NSObject(); cancellationLease = lease
      let finished = UUID()
      center.begin(id: finished, kind: .fetch, repositoryID: model.record.id, state: .running) { _ = lease.description }
      center.update(finished, state: .succeeded)
    }
    try require(cancellationLease == nil, "Completed operations release their cancellation callbacks")
    let secondHost = NSHostingView(rootView: AnyView(EmptyView()))
    let secondWindow = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 820, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    secondWindow.isReleasedWhenClosed = false; secondWindow.contentView = secondHost; secondWindow.makeKeyAndOrderFront(nil)
    defer { secondHost.rootView = AnyView(EmptyView()); secondWindow.close() }
    var performance: [[String: Any]] = []
    for count in [10, 50, 100] {
      let measured = OperationsCenter()
      let before = ProcessInfo.processInfo.systemUptime
      for _ in 0..<count {
        let id = UUID(); measured.begin(id: id, kind: .fetch, repositoryID: UUID(), state: .running)
        measured.update(id, state: .succeeded)
      }
      let eventMilliseconds = (ProcessInfo.processInfo.systemUptime - before) * 1000
      let open = ProcessInfo.processInfo.systemUptime
      host.rootView = AnyView(OperationsCenterView(center: measured).environmentObject(store))
      host.layoutSubtreeIfNeeded(); try await settle()
      let openMilliseconds = (ProcessInfo.processInfo.systemUptime - open) * 1000
      secondHost.rootView = AnyView(OperationsCenterView(center: measured).environmentObject(store))
      try await settle()
      let shared = UUID()
      let sharedStart = ProcessInfo.processInfo.systemUptime
      measured.begin(id: shared, kind: .pull, repositoryID: model.record.id, state: .running)
      measured.update(shared, state: .failed)
      let twoWindowEventMilliseconds = (ProcessInfo.processInfo.systemUptime - sharedStart) * 1000
      try await settle()
      let failedTitle = store.text("Failed · Open repository for details", "失败 · 打开仓库查看详情")
      try require(workflowAccessibilityText(host).contains(failedTitle) && workflowAccessibilityText(secondHost).contains(failedTitle), "Both native windows observe the same final operation at \(count) records")
      performance.append(["records": count, "eventMilliseconds": eventMilliseconds,
        "openAndSettleMilliseconds": openMilliseconds, "twoWindowEventMilliseconds": twoWindowEventMilliseconds])
      try require(measured.records.count == min(100, count + 1) && measured.activeCount == 0, "Operation history remains bounded for \(count) records")
    }
    let data = try JSONSerialization.data(withJSONObject: performance, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: output.appendingPathComponent("v170-operation-performance.json"))
    try checks.joined(separator: "\n").write(to: output.appendingPathComponent("v170-results.txt"), atomically: true, encoding: .utf8)
  }
  private static func workflowScrollViews(_ view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(workflowScrollViews)
  }
  private static func workflowButtonFrames(_ host: NSView, titles: Set<String>) -> [String: NSRect] {
    var visited = Set<ObjectIdentifier>(), frames: [String: NSRect] = [:]
    func walk(_ item: Any) {
      guard let object = item as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { return }
      func value(_ key: String) -> Any? {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
      }
      if let label = value("accessibilityLabel") as? String, titles.contains(label),
        let rect = value("accessibilityFrame") as? NSValue { frames[label] = rect.rectValue }
      for child in value("accessibilityChildren") as? [Any] ?? [] { walk(child) }
      if let view = object as? NSView { for child in view.subviews { walk(child) } }
    }
    walk(host); return frames
  }
  /// SwiftUI static text exposes its content as AXValue, unlike button AXLabel.
  static func workflowAccessibilityText(_ host: NSView) -> String {
    var visited = Set<ObjectIdentifier>(), text: [String] = []
    func walk(_ item: Any, depth: Int = 0) {
      guard depth < 80, let object = item as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { return }
      func value(_ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
      }
      for key in ["accessibilityLabel", "accessibilityValue"] {
        if let value = value(key) as? String { text.append(value) }
      }
      for child in value("accessibilityChildren") as? [Any] ?? [] { walk(child, depth: depth + 1) }
      if let view = object as? NSView { for child in view.subviews { walk(child, depth: depth + 1) } }
    }
    walk(host); return text.joined(separator: "\n")
  }
}
