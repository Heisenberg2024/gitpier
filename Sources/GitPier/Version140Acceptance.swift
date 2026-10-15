import AppKit
import GitPierCore
import SwiftUI

extension UIAcceptance {
  static func verifyVersion140(root sourceRoot: URL, output: URL) async throws {
    guard sourceRoot.resolvingSymlinksInPath().deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui."),
      sourceRoot.resolvingSymlinksInPath().path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/") else {
      throw GitPierError.invalidInput("Workspace acceptance writes require the disposable UI fixture")
    }
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-v140-ui-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let root = fixture.appendingPathComponent("primary")
    try await GitService(root: sourceRoot).perform(["clone", "--no-hardlinks", "--", sourceRoot.path, root.path])
    let navigationFile = root.appendingPathComponent("README.md")
    try (Data(contentsOf: navigationFile) + Data("\nv140 navigation fixture\n".utf8)).write(to: navigationFile)
    let git = await GitServiceRegistry.shared.service(for: root)
    let linked = fixture.appendingPathComponent("linked")
    _ = try await git.createWorktree(destination: linked, branch: "v140-ui-" + UUID().uuidString, newBranch: true)
    var primary = RepositoryRecord(path: root.path, name: "Workspace Fixture"); primary.group = "Engineering"; primary.favorite = true
    primary.draft = "primary draft"
    var secondary = RepositoryRecord(path: linked.path, name: "Linked Fixture"); secondary.group = "Engineering"; secondary.draft = "linked draft"
    let invalidPath = fixture.appendingPathComponent("invalid"); try FileManager.default.createDirectory(at: invalidPath, withIntermediateDirectories: true)
    let invalid = RepositoryRecord(path: invalidPath.path, name: "Invalid Fixture")
    let missing = RepositoryRecord(path: fixture.appendingPathComponent("missing").path, name: "Missing Fixture")
    var configuration = WorkspaceConfiguration(); configuration.repositories = [primary, secondary, invalid, missing]
    configuration.selectedRepository = primary.id; configuration.settings.launchPage = "dashboard"
    let persistence = ConfigurationStore(url: fixture.appendingPathComponent("workspace.json"))
    try persistence.save(configuration)
    let store = AppStore(persistence: persistence)
    defer { store.shutdown() }
    guard store.showDashboard, store.models.values.allSatisfy({ $0.refreshCount == 0 }) else {
      throw GitPierError.invalidInput("Dashboard startup activated full repository sessions")
    }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
      styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: AnyView(EmptyView())); host.autoresizingMask = [.width, .height]
    window.contentView = host; window.title = "GitPier Workspace Acceptance"; window.center()
    let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let handled = MainActor.assumeIsolated { ShortcutRouter.handleKeyDown(event, store: store, window: event.window) }
      return handled ? nil : event
    }
    defer { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
    NSApp.setActivationPolicy(.regular); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    defer { host.rootView = AnyView(EmptyView()); window.close() }
    host.rootView = AnyView(RootView().environmentObject(store).modifier(AppAppearance(store: store)))
    try await waitFor { WorkspaceSummary(Array(store.workspace.entries.values)).scanned == 4 }
    let summary = WorkspaceSummary(Array(store.workspace.entries.values))
    guard summary.total == 4, summary.physicalRepositories == 1, summary.counts[.unavailable] == 2,
          store.workspace.entries[primary.id]?.snapshot?.commonDirectory == store.workspace.entries[secondary.id]?.snapshot?.commonDirectory,
          store.models.values.allSatisfy({ $0.refreshCount == 0 }) else {
      throw GitPierError.invalidInput("Workspace summaries or lightweight startup are incorrect")
    }
    var watcherSettings = store.settings; watcherSettings.automaticRefresh = true; store.updateSettings(watcherSettings)
    try await settle()
    try await waitFor { store.workspace.entries[primary.id]?.state == .fresh && store.workspace.entries[secondary.id]?.state == .fresh }
    let cachedDate = store.workspace.entries[primary.id]?.snapshot?.collectedAt
    try (Data(contentsOf: navigationFile) + Data("external watcher fixture\n".utf8)).write(to: navigationFile)
    try await waitFor { store.workspace.entries[primary.id]?.state == .stale }
    store.save(); try await settle()
    guard store.workspace.entries[primary.id]?.state == .stale,
      store.workspace.entries[primary.id]?.snapshot?.collectedAt == cachedDate else {
      throw GitPierError.invalidInput("Configuration saves changed external-watcher notification semantics: state=\(store.workspace.entries[primary.id]?.state.rawValue ?? "missing"), old=\(String(describing: cachedDate)), new=\(String(describing: store.workspace.entries[primary.id]?.snapshot?.collectedAt))")
    }
    await store.workspace.refresh([primary.id, secondary.id])
    try await waitFor { store.workspace.entries[primary.id]?.state == .fresh }
    watcherSettings.automaticRefresh = false; store.updateSettings(watcherSettings)
    for language in AppLanguage.allCases {
      for appearance in [AppearanceMode.light, .dark] {
        var settings = store.settings; settings.language = language; settings.appearance = appearance; store.updateSettings(settings)
        try await settle()
        try capture(host, to: output.appendingPathComponent("v140-dashboard-" + language.rawValue + "-" + appearance.rawValue + ".png"))
        try accessibilityLabels(host).write(to: output.appendingPathComponent("v140-dashboard-" + language.rawValue + "-" + appearance.rawValue + ".txt"), atomically: true, encoding: .utf8)
        guard accessibleButton(host, title: store.text("Refresh Local Status", "刷新本地状态"), enabled: true) != nil else {
          throw GitPierError.invalidInput("Compact dashboard controls are not accessible")
        }
      }
    }
    try pressNativeButton(host, title: store.text("Favorites", "收藏") + " 1")
    try await waitFor { store.workspace.filters == [.favorites] }
    try pressNativeButton(host, title: store.text("All", "全部")); try await waitFor { store.workspace.filters.isEmpty }
    try pressNativeButton(host, title: store.text("Select Matches", "选择匹配项")); try await waitFor { store.workspace.selected.count == 4 }
    try pressNativeButton(host, title: store.text("Fetch Selected…", "获取已选仓库…"))
    try await waitFor { window.attachedSheet != nil && !store.workspace.preparingFetch }
    guard store.workspace.fetchTargets.count == 1, store.workspace.fetchTargets[0].repositoryIDs.count == 2,
          store.workspace.fetchReviewErrors.count == 2, let sheet = window.attachedSheet?.contentView else {
      throw GitPierError.invalidInput("Fetch review did not deduplicate worktrees or isolate invalid entries")
    }
    try capture(sheet, to: output.appendingPathComponent("v140-fetch-review.png"))
    try pressNativeButton(sheet, title: store.text("Cancel", "取消")); try await waitFor { window.attachedSheet == nil }
    guard store.workspace.fetchJobs.isEmpty else { throw GitPierError.invalidInput("Cancelled Fetch review ran a network job") }
    store.workspace.prepareFetch([primary.id, secondary.id]); try await waitFor { window.attachedSheet != nil && !store.workspace.preparingFetch }
    try pressNativeButton(window.attachedSheet!.contentView!, title: store.text("Fetch", "获取"))
    try await waitFor { store.workspace.fetchJobs.count == 1 && !store.workspace.fetching && window.attachedSheet == nil }
    guard store.workspace.fetchJobs[0].state == .succeeded else { throw GitPierError.invalidInput("Local fixture Fetch failed") }
    guard store.models[primary.id]?.record.draft == "primary draft", store.models[secondary.id]?.record.draft == "linked draft" else {
      throw GitPierError.invalidInput("Worktree drafts were mixed")
    }
    // Shortcut route and real native sheet key delivery.
    let shortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
      characters: "P", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35)!
    guard ShortcutRouter.handleKeyDown(shortcut, store: store, window: window) else { throw GitPierError.invalidInput("Quick Open shortcut was not routed") }
    try await waitFor { window.attachedSheet != nil }; try await settle()
    try capture(window.attachedSheet!.contentView!, to: output.appendingPathComponent("v140-quick-open.png"))
    try sendWorkspaceKey(53, window: window.attachedSheet!)
    try await waitFor { !store.showQuickOpen && window.attachedSheet == nil }
    store.showQuickOpen = true; try await waitFor { window.attachedSheet != nil }; try await settle()
    try sendWorkspaceKey(125, window: window.attachedSheet!); try sendWorkspaceKey(126, window: window.attachedSheet!)
    try sendWorkspaceKey(36, window: window.attachedSheet!)
    try await waitFor { !store.showQuickOpen && !store.showDashboard }
    store.showDashboard = true; store.showWorkspaceSearch = true
    try await waitFor { window.attachedSheet != nil }; try await settle()
    try capture(window.attachedSheet!.contentView!, to: output.appendingPathComponent("v140-workspace-search.png"))
    try pressNativeButton(window.attachedSheet!.contentView!, title: store.text("Close", "关闭"))
    try await waitFor { window.attachedSheet == nil }
    let commit = try await git.history(count: 1)[0]
    guard await store.workspace.openSearchHit(WorkspaceSearchHit(repositoryID: primary.id, kind: .commit,
      value: commit.hash, detail: commit.subject, commit: commit)), store.current?.selectedHistoryCommit?.hash == commit.hash else {
      throw GitPierError.invalidInput("Commit search navigation did not open commit details")
    }
    let changedPath = try await git.status().files.first!.path
    guard await store.workspace.openSearchHit(WorkspaceSearchHit(repositoryID: primary.id, kind: .file, value: changedPath, detail: primary.name)),
      store.current?.selectedPath == changedPath else { throw GitPierError.invalidInput("File search navigation did not select the existing Diff") }
    let removedHit = WorkspaceSearchHit(repositoryID: missing.id, kind: .repository, value: missing.name, detail: missing.path)
    store.remove(missing.id)
    guard !(await store.workspace.openSearchHit(removedHit)) else { throw GitPierError.invalidInput("Removed repository search result remained actionable") }
    store.error = nil
    if ProcessInfo.processInfo.environment["GITPIER_UI_ACCEPTANCE_INTERACTIVE_V140"] == "1" {
      store.showDashboard = true
      let marker = output.appendingPathComponent("finish-gui")
      try "visible fixture ready\n".write(to: output.appendingPathComponent("gui-ready"), atomically: true, encoding: .utf8)
      while !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(for: .milliseconds(250)) }
    }
    try "Lightweight cached startup, unavailable classification, physical/worktree summaries, opt-in external-change notifications retained across configuration save until explicit refresh, four visible language/theme layouts at 960x640, native filter/select actions, reviewed/cancelled/confirmed deduplicated fixture Fetch, independent drafts, shortcut routing and native up/down/Return/Escape sheet events, search presentation and file/commit/removed-result navigation passed.\n"
      .write(to: output.appendingPathComponent("v140-results.txt"), atomically: true, encoding: .utf8)
  }
  static func sendWorkspaceKey(_ code: UInt16, window: NSWindow) throws {
    let characters = code == 36 ? "\r" : code == 53 ? "\u{1b}" : ""
    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
      characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { throw GitPierError.invalidInput("Cannot create native key event") }
    NSApp.postEvent(event, atStart: false)
  }
}
