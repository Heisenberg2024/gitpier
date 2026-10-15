import AppKit
import GitPierCore
import SwiftUI

extension UIAcceptance {
  /// All visible data is read from these disposable Git repositories, never user repositories.
  static func verifyDashboardRedesign(root source: URL, output: URL) async throws {
    guard source.resolvingSymlinksInPath().deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui.") else {
      throw GitPierError.invalidInput("Dashboard acceptance requires the isolated UI fixture")
    }
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-dashboard-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    func clone(_ name: String) async throws -> GitService {
      let path = fixture.appendingPathComponent(name)
      try await GitService(root: source).perform(["clone", "--no-hardlinks", "--", source.path, path.path])
      let git = await GitServiceRegistry.shared.service(for: path)
      try await git.perform(["config", "user.name", "Dashboard Fixture"])
      try await git.perform(["config", "user.email", "fixture@example.invalid"])
      try await git.perform(["config", "commit.gpgsign", "false"])
      return git
    }
    let app = try await clone("atlas-app")
    let appPath = fixture.appendingPathComponent("atlas-app")
    try Data("ahead fixture\n".utf8).write(to: appPath.appendingPathComponent("ahead.txt"))
    try await app.perform(["add", "--", "ahead.txt"]); try await app.perform(["commit", "-m", "feat: add workspace overview"])
    try Data("local modifications\n".utf8).write(to: appPath.appendingPathComponent("draft.txt"))
    let featurePath = fixture.appendingPathComponent("atlas-search")
    let releasePath = fixture.appendingPathComponent("atlas-release")
    _ = try await app.createWorktree(destination: featurePath, branch: "feature/workspace-search", newBranch: true)
    _ = try await app.createWorktree(destination: releasePath, branch: "release/1.4", newBranch: true)
    let api = try await clone("harbor-api")
    // Point its local tracking reference at a real commit from the controlled app repository.
    try await api.perform(["fetch", "--no-write-fetch-head", "--", appPath.path, "main:refs/remotes/origin/main"])
    let docs = try await clone("pier-docs")
    let docsPath = fixture.appendingPathComponent("pier-docs")
    try Data("staged documentation\n".utf8).write(to: docsPath.appendingPathComponent("guide.md"))
    try await docs.perform(["add", "--", "guide.md"])
    let design = try await clone("design-system"); try await design.perform(["remote", "remove", "origin"])
    let conflict = try await clone("bridge-service")
    let conflictPath = fixture.appendingPathComponent("bridge-service")
    try await conflict.perform(["switch", "-c", "feature/bridge"])
    try Data("incoming fixture\n".utf8).write(to: conflictPath.appendingPathComponent("README.md"))
    try await conflict.perform(["add", "--", "README.md"]); try await conflict.perform(["commit", "-m", "incoming bridge"])
    try await conflict.perform(["switch", "main"])
    try Data("current fixture\n".utf8).write(to: conflictPath.appendingPathComponent("README.md"))
    try await conflict.perform(["add", "--", "README.md"]); try await conflict.perform(["commit", "-m", "current bridge"])
    _ = try await conflict.read(["merge", "feature/bridge"], allowFailure: true)
    let names = ["atlas-app", "atlas-search", "atlas-release", "harbor-api", "pier-docs", "design-system", "bridge-service", "archived-tools"]
    var records = names.map { name in RepositoryRecord(path: fixture.appendingPathComponent(name).path, name: name) }
    for index in records.indices { records[index].group = index < 4 ? "Engineering" : "Tools" }
    records[0].favorite = true; records[0].draft = "Keep primary draft"
    records[1].draft = "Keep linked draft"
    var config = WorkspaceConfiguration(); config.repositories = records
    config.settings.launchPage = "dashboard"; config.settings.appearance = .light; config.settings.language = .english
    config.settings.completionNotifications = false
    let persistence = ConfigurationStore(url: fixture.appendingPathComponent("workspace.json")); try persistence.save(config)
    let store = AppStore(persistence: persistence); defer { store.shutdown() }
    let host = NSHostingView(rootView: AnyView(RootView().environmentObject(store).modifier(AppAppearance(store: store))))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
      styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.title = "GitPier Dashboard · Disposable Fixture"
    NSApp.setActivationPolicy(.regular); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    defer { host.rootView = AnyView(EmptyView()); window.close() }
    try await waitFor { WorkspaceSummary(Array(store.workspace.entries.values)).scanned == 8 }
    let summary = WorkspaceSummary(Array(store.workspace.entries.values))
    guard summary.counts[.conflicts] == 1, summary.counts[.behind] == 1,
      summary.counts[.unavailable] == 1, summary.physicalRepositories == 5,
      store.models.values.allSatisfy({ $0.refreshCount == 0 }) else {
      throw GitPierError.invalidInput("Dashboard fixture summary or lightweight collection is incorrect")
    }
    // Capture real visible windows at every requested size in both languages and appearances.
    for language in AppLanguage.allCases {
      for appearance in [AppearanceMode.light, .dark] {
        var settings = store.settings; settings.language = language; settings.appearance = appearance; store.updateSettings(settings); store.notice = nil
        for size in [NSSize(width: 960, height: 640), NSSize(width: 1200, height: 800), NSSize(width: 1440, height: 900),
                     NSSize(width: 1600, height: 1000), NSSize(width: 1920, height: 1080)] {
          window.setContentSize(size); window.center(); try await settle()
          let label = "dashboard-\(language.rawValue)-\(appearance.rawValue)-\(Int(size.width))x\(Int(size.height))"
          try capture(host, to: output.appendingPathComponent(label + ".png"))
          guard accessibleButton(host, title: store.text("Refresh Local Status", "刷新本地状态"), enabled: true) != nil,
            accessibleButton(host, title: store.text("Select Matches", "选择匹配项"), enabled: true) != nil else {
            throw GitPierError.invalidInput("Dashboard actions clipped or inaccessible at " + label)
          }
        }
      }
    }
    window.setContentSize(NSSize(width: 1440, height: 900)); window.center()
    var settings = store.settings; settings.language = .english; settings.appearance = .light; store.updateSettings(settings); store.notice = nil
    try await settle()
    let modified = summary.counts[.modified] ?? 0
    try pressNativeButton(host, title: "Modified \(modified)")
    try await waitFor { store.workspace.filters == [.modified] }
    try pressNativeButton(host, title: "Conflicts 1")
    try await waitFor { store.workspace.filters == [.modified, .conflicts] }
    try pressNativeButton(host, title: "Select Matches")
    try await waitFor { store.workspace.selected == [records[6].id] }
    try pressNativeButton(host, title: "All"); try await waitFor { store.workspace.filters.isEmpty }
    try pressNativeButton(host, title: "Clear Selection")
    try await waitFor { store.workspace.selected.isEmpty }
    guard let checkbox = dashboardElement(host, label: "Select atlas-app", role: "AXCheckBox") else {
      throw GitPierError.invalidInput("Missing independent repository checkbox")
    }
    try dashboardPress(checkbox)
    try await waitFor { store.workspace.selected == [records[0].id] }
    guard store.showDashboard else { throw GitPierError.invalidInput("Checkbox opened a repository") }
    try pressNativeButton(host, title: "Clear Selection")
    // Native text input must combine with AND filters while preserving selection.
    guard let field = descendants(host).compactMap({ $0 as? NSTextField }).first(where: {
      $0.placeholderString?.hasPrefix("Search repositories") == true
    }) else { throw GitPierError.invalidInput("Dashboard search field is not native/editable") }
    window.makeFirstResponder(field)
    field.stringValue = "harbor"
    NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
    try await settle()
    try pressNativeButton(host, title: "Behind 1")
    try pressNativeButton(host, title: "Select Matches")
    try await waitFor { store.workspace.selected == [records[3].id] }
    try pressNativeButton(host, title: "Clear search")
    try pressNativeButton(host, title: "All")
    try pressNativeButton(host, title: "Clear Selection")
    let disclosure = "Expand / collapse related worktrees atlas-app"
    try pressNativeButton(host, title: disclosure); try await settle()
    try capture(host, to: output.appendingPathComponent("dashboard-worktrees-collapsed.png"))
    try pressNativeButton(host, title: "Select Matches")
    try await waitFor { store.workspace.selected.count == 8 }
    guard store.showDashboard else { throw GitPierError.invalidInput("Disclosure or selection opened a repository") }
    try capture(host, to: output.appendingPathComponent("dashboard-selection.png"))
    try pressNativeButton(host, title: disclosure); try await settle()
    try capture(host, to: output.appendingPathComponent("dashboard-worktrees-expanded.png"))
    try pressNativeButton(host, title: "Fetch Selected…")
    try await waitFor { window.attachedSheet != nil && !store.workspace.preparingFetch }
    guard store.workspace.fetchTargets.contains(where: { $0.repositoryIDs.count == 3 }), store.workspace.fetchJobs.isEmpty else {
      throw GitPierError.invalidInput("Dashboard Fetch bypassed review or lost worktree deduplication")
    }
    try capture(window.attachedSheet!.contentView!, to: output.appendingPathComponent("dashboard-fetch-review.png"))
    try pressNativeButton(window.attachedSheet!.contentView!, title: "Cancel")
    try await waitFor { window.attachedSheet == nil }
    window.setContentSize(NSSize(width: 960, height: 640)); window.center(); try await settle()
    try capture(host, to: output.appendingPathComponent("dashboard-selection-small.png"))
    guard accessibleButton(host, title: "Fetch Selected…", enabled: true) != nil,
      accessibleButton(host, title: "Clear Selection", enabled: true) != nil else {
      throw GitPierError.invalidInput("Small-window selection actions disappeared")
    }
    window.setContentSize(NSSize(width: 1440, height: 900)); window.center()
    try pressNativeButton(host, title: "Clear Selection")
    store.workspace.filters = [.conflicts]; try await settle()
    try capture(host, to: output.appendingPathComponent("dashboard-conflicts.png"))
    store.workspace.filters = [.unavailable]; try await settle()
    try capture(host, to: output.appendingPathComponent("dashboard-unavailable.png"))
    try pressNativeButton(host, title: "Error details archived-tools"); try await settle()
    try capture(host, to: output.appendingPathComponent("dashboard-error-details.png"))
    // Dismiss the popover using an actual escape event.
    try sendWorkspaceKey(53, window: window); try await settle()
    store.workspace.filters.removeAll(); try await settle()
    for _ in 0..<5 {
      try pressNativeButton(host, title: "Conflicts 1"); try await waitFor { store.workspace.filters == [.conflicts] }
      try pressNativeButton(host, title: "Conflicts 1"); try await waitFor { store.workspace.filters.isEmpty }
    }
    store.workspace.filters = [.conflicts, .behind]; try await settle()
    try capture(host, to: output.appendingPathComponent("dashboard-empty-results.png"))
    try pressNativeButton(host, title: "Reset search and filters"); try await waitFor { store.workspace.filters.isEmpty }
    let before = Date()
    await store.workspace.refresh()
    try await waitFor { (store.workspace.entries[records[0].id]?.snapshot?.collectedAt ?? .distantPast) > before }
    guard store.repositories.map(\.id) == records.map(\.id), store.workspace.selected.isEmpty,
      store.models.values.allSatisfy({ $0.refreshCount == 0 }), store.models[records[0].id]?.record.draft == "Keep primary draft",
      store.models[records[1].id]?.record.draft == "Keep linked draft" else {
      throw GitPierError.invalidInput("Dashboard refresh reordered entries or changed repository sessions")
    }
    // A real in-progress scan: enumerate enough untracked fixture files to observe collection.
    let many = appPath.appendingPathComponent("scan-fixture"); try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
    for index in 0..<6000 { try Data("fixture\n".utf8).write(to: many.appendingPathComponent("\(index).txt")) }
    let refresh = Task { await store.workspace.refresh() }
    try await waitFor { store.workspace.entries.values.contains { $0.state == .collecting } }
    try capture(host, to: output.appendingPathComponent("dashboard-scanning.png"))
    await refresh.value
    try await waitFor { store.workspace.entries.values.allSatisfy { $0.state == .fresh || $0.state == .failed } }
    settings.appearance = .system; store.updateSettings(settings); try await settle()
    guard window.appearance == nil, host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) else {
      throw GitPierError.invalidInput("Dashboard System appearance did not follow the application")
    }
    if ProcessInfo.processInfo.environment["GITPIER_DASHBOARD_INTERACTIVE"] == "1" {
      settings.appearance = .light; store.updateSettings(settings)
      window.setContentSize(NSSize(width: 1200, height: 800)); window.center(); try await settle()
      try "visible fixture ready\n".write(to: output.appendingPathComponent("gui-ready"), atomically: true, encoding: .utf8)
      while !FileManager.default.fileExists(atPath: output.appendingPathComponent("finish-gui").path) { try await Task.sleep(for: .milliseconds(250)) }
    }
    try "Real 8-entry fixture; 20 visible language/theme/size layouts; KPI AND filters; native Select Matches/Clear; collapse preserves all 8 selected entries; Fetch review and cancellation/deduplication; errors; rapid filters; empty recovery; local refresh/manual identity/drafts; real scanning; System appearance passed.\n"
      .write(to: output.appendingPathComponent("dashboard-results.txt"), atomically: true, encoding: .utf8)
  }

  static func dashboardPress(_ element: NSObject) throws {
    let selector = NSSelectorFromString("accessibilityPerformPress")
    typealias Press = @convention(c) (AnyObject, Selector) -> Bool
    guard element.responds(to: selector), unsafeBitCast(element.method(for: selector), to: Press.self)(element, selector) else {
      throw GitPierError.invalidInput("Dashboard native accessibility press failed")
    }
  }
  static func dashboardElement(_ host: NSView, label: String, role: String) -> NSObject? {
    var visited = Set<ObjectIdentifier>()
    func walk(_ value: Any) -> NSObject? {
      guard let object = value as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
      func get(_ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
      }
      if get("accessibilityRole") as? String == role, get("accessibilityLabel") as? String == label { return object }
      for child in get("accessibilityChildren") as? [Any] ?? [] { if let result = walk(child) { return result } }
      if let view = object as? NSView { for child in view.subviews { if let result = walk(child) { return result } } }
      return nil
    }
    return walk(host)
  }
}
