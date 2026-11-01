#if DEBUG
import AppKit
import GitPierCore
import SwiftUI

private struct BranchHealthContrastProbe: View {
  @Environment(\.colorSchemeContrast) private var contrast
  let report: (ColorSchemeContrast) -> Void
  var body: some View {
    Color.clear.frame(width: 0, height: 0)
      .onAppear { report(contrast) }.onChange(of: contrast) { _, value in report(value) }
  }
}

@MainActor extension UIAcceptance {
  static func verifyBranchHealthVisualization(root: URL, output: URL) async throws {
    guard root.deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui.") else {
      throw GitPierError.invalidInput("Health acceptance requires disposable repositories")
    }
    let directory = root.deletingLastPathComponent().appendingPathComponent("health")
    let repo = directory.appendingPathComponent("repository")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    let git = await GitServiceRegistry.shared.service(for: repo)
    func raw(_ args: [String]) async throws { _ = try await git.read(args) }
    func head() async throws -> String { try await git.status(localOnly: true).head! }
    try await raw(["init", "-b", "master"])
    try await raw(["config", "user.name", "Health Acceptance"])
    try await raw(["config", "user.email", "health@example.invalid"])
    try await raw(["config", "commit.gpgsign", "false"])
    try Data("base\n".utf8).write(to: repo.appendingPathComponent("base.txt"))
    try await raw(["add", "."]); try await raw(["commit", "-m", "base"])
    let base = try await head()
    try await raw(["switch", "-c", "incoming"])
    var incoming: [String] = []
    for index in 1...4 {
      try await raw(["commit", "--allow-empty", "-m", "Incoming \(index)"]); incoming.append(try await head())
    }
    try await raw(["switch", "-c", "ahead-3", base])
    var local: [String] = []
    for index in 1...3 {
      try await raw(["commit", "--allow-empty", "-m", "Local \(index)"]); local.append(try await head())
    }
    let diverged = "feature/diverged-with-a-very-long-name-that-must-truncate-without-hiding-status"
    let unbound = "feature/no-upstream-with-another-long-descriptive-branch-name"
    try await raw(["branch", "behind-2", base]); try await raw(["branch", diverged, local[1]])
    try await raw(["branch", unbound, base]); try await raw(["branch", "missing-upstream", base])
    try await raw(["switch", diverged]); try await raw(["branch", "-D", "incoming"])
    // The remote path is local and isolated. No fixture can contact a real server.
    try await raw(["remote", "add", "origin", repo.path])
    for (name, tip) in [("master", base), ("ahead-3", base), ("behind-2", incoming[1]), (diverged, incoming[3])] {
      try await raw(["update-ref", "refs/remotes/origin/" + name, tip])
    }
    for name in ["master", "ahead-3", "behind-2", diverged, "missing-upstream"] {
      try await raw(["config", "branch." + name + ".remote", "origin"])
      try await raw(["config", "branch." + name + ".merge", "refs/heads/" + name])
    }
    try await raw(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/master"])
    let scenarios: [(String, BranchSyncState)] = [(diverged, .diverged(ahead: 2, behind: 4)),
      ("master", .synced), ("ahead-3", .ahead(3)), ("behind-2", .behind(2)), (unbound, .noUpstream), ("missing-upstream", .unknown)]
    var records = [RepositoryRecord(path: repo.path, name: "Diverged 2 / 4")]
    for (index, item) in scenarios.dropFirst().enumerated() {
      let path = directory.appendingPathComponent("worktree-\(index)")
      try await raw(["worktree", "add", path.path, item.0])
      records.append(RepositoryRecord(path: path.path, name: item.0))
    }
    var config = WorkspaceConfiguration(); config.repositories = records
    config.settings.automaticFetch = false; config.settings.automaticRefresh = false
    config.settings.completionNotifications = false
    let persistence = ConfigurationStore(url: directory.appendingPathComponent("workspace.json"))
    try persistence.save(config)
    let store = AppStore(persistence: persistence); defer { store.shutdown() }
    store.select(records[0].id)
    guard let model = store.current else { throw GitPierError.indexChanged }
    await model.activate(refresh: true); model.setPage("branches")
    await store.workspace.refresh()
    let indexBefore = try Data(contentsOf: repo.appendingPathComponent(".git/index"))
    let increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    let contrastSuffix = increasedContrast ? "-contrast" : ""
    var observedContrast: ColorSchemeContrast?
    func appearanceRoot<V: View>(_ content: V) -> AnyView {
      return AnyView(content.environmentObject(store).modifier(AppAppearance(store: store))
        .background(BranchHealthContrastProbe { observedContrast = $0 }))
    }
    let host = NSHostingView(rootView: appearanceRoot(RootView()))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
      styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
    window.title = "GitPier Branch Health · Disposable Fixture"; window.isReleasedWhenClosed = false
    window.contentView = host; NSApp.setActivationPolicy(.regular)
    window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    defer { host.rootView = AnyView(EmptyView()); window.close() }
    try await settle()
    try await waitFor { !model.refreshing && !model.busy }
    var checks: [String] = []
    func require(_ result: Bool, _ name: String) throws {
      guard result else {
        let details = assistantElements(host).map {
          assistantString($0, "accessibilityIdentifier") + " | " + assistantString($0, "accessibilityLabel")
            + " | " + assistantString($0, "accessibilityValue")
        }.joined(separator: "\n")
        try? details.write(to: output.appendingPathComponent("health-failure-accessibility.txt"), atomically: true, encoding: .utf8)
        try? capture(host, to: output.appendingPathComponent("health-failure-render.png"))
        throw GitPierError.invalidInput("Health acceptance: " + name)
      }
      checks.append(name)
      try checks.joined(separator: "\n").write(to: output.appendingPathComponent("health-results.txt"), atomically: true, encoding: .utf8)
    }
    if let expected = ProcessInfo.processInfo.environment["GITPIER_UI_ACCEPTANCE_HEALTH_CONTRAST"] {
      try require(increasedContrast == (expected == "increased"), "Actual system contrast matches requested acceptance mode " + expected)
    }
    func checkContrast() throws {
      try require(observedContrast == (increasedContrast ? .increased : .standard),
        "SwiftUI observes actual system contrast" + contrastSuffix + " (" + String(describing: observedContrast) + ")")
    }
    let syncSymbols: [(BranchSyncState, String, Color)] = [(.synced, "checkmark.circle", .green),
      (.ahead(3), "arrow.up.circle", .primary), (.behind(2), "arrow.down.circle", .blue),
      (.diverged(ahead: 2, behind: 4), "arrow.triangle.branch", .orange),
      (.noUpstream, "link.badge.plus", .secondary), (.unknown, "questionmark.circle", .secondary)]
    for (state, symbol, color) in syncSymbols {
      let display = BranchSyncPresentation(state: state, store: store)
      try require(display.symbol == symbol, "Shared sync symbol " + symbol)
      try require(display.color == color, "Shared semantic color " + symbol)
      try require(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "System symbol available " + symbol)
    }
    for (merged, target, symbol, color) in [(true, "refs/heads/master", "arrow.triangle.merge", Color.green),
      (false, "refs/heads/master", "arrow.triangle.branch", Color.secondary),
      (nil, "refs/heads/master", "questionmark.circle", Color.secondary),
      (true, nil, "circle.dashed", Color.secondary)] as [(Bool?, String?, String, Color)] {
      let display = BranchMergePresentation(merged: merged, targetReference: target, store: store)
      try require(display.symbol == symbol && display.color == color, "Independent merge appearance " + symbol)
      try require(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "Merge symbol available " + symbol)
    }
    try require(BranchSyncPresentation(state: .behind(2), store: store).incomingColor == .blue,
      "Incoming action uses the shared behind color")
    try require(BranchSyncPresentation(state: .ahead(3), store: store).outgoingColor == .primary,
      "Outgoing action uses adaptive primary text")
    try require(BranchSyncPresentation(state: .synced, store: store).incomingColor == .primary,
      "An idle network action does not claim sync success")
    func text(_ view: NSView) -> String {
      assistantElements(view).map { assistantString($0, "accessibilityLabel") + " " + assistantString($0, "accessibilityValue") }.joined(separator: "\n")
    }
    func visibleCapture(_ label: String) async throws {
      try await settle()
      try capture(host, to: output.appendingPathComponent(label + "-render.png"))
      let result = try await ProcessRunner().run(executable: "/usr/sbin/screencapture",
        arguments: ["-x", "-o", "-l", String(window.windowNumber), output.appendingPathComponent(label + ".png").path], directory: repo)
      try require(result.code == 0, "Visible capture " + label)
      try text(host).write(to: output.appendingPathComponent(label + "-accessibility.txt"), atomically: true, encoding: .utf8)
    }
    func checkBadgeBounds(_ label: String) throws {
      let statusLabels = Set(syncSymbols.map { BranchSyncPresentation(state: $0.0, store: store).accessibleText })
      let badges = assistantElements(host).filter { statusLabels.contains(assistantString($0, "accessibilityLabel")) }
      try require(!badges.isEmpty, "Visible sync badges " + label)
      for badge in badges {
        guard let frame = (badge.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue else {
          throw GitPierError.invalidInput("Missing native badge frame " + label)
        }
        try require(frame.width > 0 && frame.height > 0 && window.frame.insetBy(dx: -1, dy: -1).contains(frame),
          "Sync badge fits viewport " + label + " " + assistantString(badge, "accessibilityLabel"))
      }
    }
    func checkDashboardRows(_ label: String) throws {
      // Dashboard intentionally exposes each Open button as one accessible row,
      // including the sync fact in its value, rather than separate badge children.
      for (index, item) in scenarios.enumerated() {
        let rowLabel = store.text("Open", "打开") + " " + records[index].name
        guard let row = assistantElements(host).first(where: { assistantString($0, "accessibilityLabel") == rowLabel }),
          let frame = (row.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue else {
          throw GitPierError.invalidInput("Missing native Dashboard row " + rowLabel)
        }
        let display = BranchSyncPresentation(state: item.1, store: store)
        try require(assistantString(row, "accessibilityValue").contains(display.accessibleText),
          "Dashboard accessible status " + label + " " + display.accessibleText)
        try require(frame.width > 0 && frame.height > 0 && window.frame.insetBy(dx: -1, dy: -1).contains(frame),
          "Dashboard row fits viewport " + label + " " + records[index].name)
      }
    }
    func contextCaptures(_ variant: String) async throws {
      for (index, item) in scenarios.enumerated() {
        store.select(records[index].id)
        guard let context = store.current else { throw GitPierError.indexChanged }
        await context.activate(refresh: true)
        host.rootView = appearanceRoot(ContextWorkflowView(model: context, workspace: store.workspace))
        window.setContentSize(NSSize(width: 440, height: 560)); window.center(); try await settle()
        try checkContrast()
        let display = BranchSyncPresentation(state: item.1, store: store)
        if item.1 == .noUpstream {
          // Context's existing local-only guidance has no upstream-comparison badge.
          try require(!assistantElements(host).contains { assistantString($0, "accessibilityLabel") == display.accessibleText },
            "Local-only workflow keeps its existing guidance " + variant)
        } else {
          guard let badge = assistantElements(host).first(where: { assistantString($0, "accessibilityLabel") == display.accessibleText }) else {
            throw GitPierError.invalidInput("Missing context sync badge " + display.symbol + " " + variant)
          }
          try require(assistantString(badge, "accessibilityLabel") == display.accessibleText,
            "Context semantic status " + display.symbol + " " + variant)
          try checkBadgeBounds("context-" + variant)
        }
        try await visibleCapture("context-\(variant)-\(index)")
      }
      store.select(records[0].id); await model.activate(refresh: true); model.setPage("branches")
    }
    func selectTarget(_ title: String) async throws {
      guard let picker = assistantFind(host, id: "health.target") else { throw GitPierError.invalidInput("Missing local target picker") }
      let titles = [store.text("Choose a local branch…", "请选择本地分支…")] + model.branches.filter { !$0.remote }.map(\.name)
      guard let current = titles.firstIndex(of: assistantString(picker, "accessibilityValue")),
        let desired = titles.firstIndex(of: title) else { throw GitPierError.invalidInput("Target picker contains an unexpected reference") }
      // SwiftUI's AXPopUpButton is not an NSPopUpButton. Feed native menu
      // navigation events to this window, then activate its accessible Press.
      let down = desired > current
      var keys = Array(repeating: (down ? "\u{f701}" : "\u{f700}", UInt16(down ? 125 : 126)), count: abs(desired - current))
      keys.append(("\r", 36))
      for (characters, code) in keys {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
          if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
            NSApp.postEvent(event, atStart: false)
          }
        }
      }
      try assistantPress(picker)
      try await waitFor { assistantString(picker, "accessibilityValue") == title }
      try await settle()
    }
    let reader = BranchHealthReader()
    reader.load(model, target: "", force: true)
    try await waitFor { !reader.request.loading }
    try require(reader.snapshot?.suggestedTargetReference == "refs/heads/master", "Remote HEAD selects existing master without guessing main; reader=" + (reader.request.problem ?? "none") + "; snapshot=" + (reader.snapshot?.suggestedTargetReference ?? "nil"))
    for (name, expected) in scenarios {
      try require(reader.byReference["refs/heads/" + name]?.syncState == expected, "Branch row facts " + name)
    }
    for (index, item) in scenarios.enumerated() {
      let snapshot = store.workspace.entries[records[index].id]?.usable
      try require(snapshot?.syncState == item.1, "Dashboard facts " + item.0)
    }
    try require(model.workflowInput().status.syncState == .diverged(ahead: 2, behind: 4), "Context uses same current branch counts")
    try require(ContextWorkflowAdvice.evaluate(model.workflowInput()).actions == [.reviewFetch], "Unverified remote requires reviewed Fetch before writes")
    // Invalidate an in-flight request by navigating away and back to the same model.
    reader.load(model, target: "refs/heads/master", force: true)
    store.showDashboard = true; store.showDashboard = false
    try await waitFor { !reader.request.loading }
    try require(reader.snapshot == nil, "Late same-repository selection result rejected")
    reader.load(model, target: "refs/heads/master")
    try await waitFor { !reader.request.loading }
    try require(reader.snapshot?.targetReference == "refs/heads/master", "Retry after navigation is not suppressed by cache")
    reader.cancelAnalysis()
    try require(reader.analyzedTarget == nil, "Changing target immediately clears merged presentation")
    reader.load(model, target: "refs/heads/missing", force: true)
    try await waitFor { !reader.request.loading }
    try require(reader.request.problem != nil && reader.snapshot == nil, "Nonexistent target is a visible error, never unmerged")
    reader.load(model, target: "", force: true)
    try await waitFor { !reader.request.loading }
    try require(reader.snapshot != nil, "Sync remains available after an invalid merge target")
    reader.invalidate()
    try await waitFor { assistantFind(host, id: "health.analyze")?.value(forKey: "accessibilityEnabled") as? Bool == true }
    try require(text(host).contains("Merge not analyzed"), "Opening Branches distinguishes unexamined merge ancestry")
    try await selectTarget("ahead-3")
    try assistantPress(assistantFind(host, id: "health.analyze")!)
    try await waitFor { text(host).contains("Merged into ahead-3") }
    try await selectTarget("master")
    try require(text(host).contains("Merge not analyzed"), "Changing native picker hides the previous target's analysis")
    for language in AppLanguage.allCases {
      for appearance in [AppearanceMode.light, .dark] {
        var settings = store.settings; settings.language = language; settings.appearance = appearance
        store.updateSettings(settings); store.notice = nil
        store.showDashboard = false; model.setPage("branches")
        try await waitFor { assistantFind(host, id: "health.analyze")?.value(forKey: "accessibilityEnabled") as? Bool == true }
        try assistantPress(assistantFind(host, id: "health.analyze")!)
        try await waitFor { text(host).contains(store.text("Not merged into master", "未合并至 master")) }
        for width in [1440, 960] {
          window.setContentSize(NSSize(width: width, height: 900)); window.center(); try await settle()
          try await waitFor { assistantFind(host, id: "health.analyze")?.value(forKey: "accessibilityEnabled") as? Bool == true }
          try assistantPress(assistantFind(host, id: "health.analyze")!)
          try await waitFor { text(host).contains(store.text("Not merged into master", "未合并至 master")) }
          let content = text(host)
          for label in [store.text("Synced", "已同步"), store.text("Ahead by 3 commits", "领先 3 个提交"),
            store.text("Behind by 2 commits", "落后 2 个提交"), store.text("Diverged, 2 ahead and 4 behind", "已分叉，领先 2、落后 4 个提交"),
            store.text("No upstream", "未设置上游"), store.text("Unknown", "状态未知")] {
            try require(content.contains(label), "Accessible branch status " + label)
          }
          try require(assistantFind(host, id: "health.merge.arrow.triangle.merge") != nil, "Merged has a distinct native merge icon")
          try require(assistantFind(host, id: "health.merge.arrow.triangle.branch") != nil, "Unmerged ancestry remains independently identified")
          try checkBadgeBounds("branches-\(language.rawValue)-\(appearance.rawValue)-\(width)")
          try checkContrast()
          try await visibleCapture("branches-\(language.rawValue)-\(appearance.rawValue)-\(width)\(contrastSuffix)")
          store.showDashboard = true; try await settle()
          try require(text(host).contains(store.text("Diverged, 2 ahead and 4 behind", "已分叉，领先 2、落后 4 个提交")), "Dashboard semantic badge survives resize")
          try checkDashboardRows("dashboard-\(language.rawValue)-\(appearance.rawValue)-\(width)")
          try await visibleCapture("dashboard-\(language.rawValue)-\(appearance.rawValue)-\(width)\(contrastSuffix)")
          store.showDashboard = false; try await settle()
        }
        try await contextCaptures("\(language.rawValue)-\(appearance.rawValue)\(contrastSuffix)")
        host.rootView = appearanceRoot(RootView())
        window.setContentSize(NSSize(width: 1440, height: 900)); window.center(); try await settle()
      }
    }
    // Local tracking changes and an actual local-path Fetch must refresh the reader.
    reader.load(model, target: "refs/heads/master", force: true)
    store.select(records[1].id)
    try await waitFor { !reader.request.loading }
    try require(reader.snapshot == nil, "Late result cannot cross repositories")
    guard let other = store.current else { throw GitPierError.indexChanged }
    await other.activate(refresh: true)
    reader.load(other, target: "", force: true); try await waitFor { !reader.request.loading }
    try require(reader.snapshot?.currentBranch == "master" && reader.byReference["refs/heads/master"]?.syncState == .synced,
      "Same reader binds to the newly selected repository")
    store.select(records[0].id); await model.activate(refresh: true)
    try await raw(["switch", "-c", "health-switch-check"])
    await model.activate(refresh: true)
    reader.load(model, target: "", force: true); try await waitFor { !reader.request.loading }
    try require(reader.snapshot?.currentBranch == "health-switch-check" && reader.byReference["refs/heads/health-switch-check"]?.syncState == .noUpstream,
      "Branch switch replaces the current branch and upstream state")
    try await raw(["switch", diverged]); await model.activate(refresh: true)
    try await raw(["update-ref", "refs/remotes/origin/" + diverged, local[1]])
    await model.activate(refresh: true)
    reader.load(model, target: "", force: true); try await waitFor { !reader.request.loading }
    try require(reader.byReference["refs/heads/" + diverged]?.syncState == .synced, "Local ref update replaces divergence")
    let beforeFetch = reader.snapshot!.collectedAt
    model.network("fetch")
    try await waitFor { !model.busy && !model.networkFetching && !model.refreshing }
    await model.activate(refresh: true)
    reader.load(model, target: "", force: true); try await waitFor { !reader.request.loading }
    try require(reader.snapshot!.collectedAt > beforeFetch, "Fetch refresh collects a new observation")
    await store.workspace.refresh([model.record.id])
    try require(store.workspace.remoteCheck(model.record.id).lastSuccess != nil, "Actual local-path Fetch records its success time")
    try require(reader.snapshot?.fetchTargetID == store.workspace.entries[model.record.id]?.usable?.remoteTarget?.id,
      "Fetch time remains bound to the complete current target identity")
    try require(try Data(contentsOf: repo.appendingPathComponent(".git/index")) == indexBefore, "All health analysis preserves Index bytes")
    try checks.joined(separator: "\n").write(to: output.appendingPathComponent("health-results.txt"), atomically: true, encoding: .utf8)
  }
}
#endif
