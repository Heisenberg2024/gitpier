import AppKit
import GitPierCore
import SwiftUI

@MainActor extension UIAcceptance {
  static func verifyCommitReplay(root: URL, output: URL) async throws {
    guard root.deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui.") else { throw GitPierError.invalidInput("Replay acceptance requires a disposable repository") }
    let fixture = root.deletingLastPathComponent().appendingPathComponent("replay")
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    let git = await GitServiceRegistry.shared.service(for: fixture)
    func raw(_ args: [String]) async throws { _ = try await git.read(args) }
    func write(_ path: String, _ value: String) throws { try value.write(to: fixture.appendingPathComponent(path), atomically: true, encoding: .utf8) }
    try await raw(["init", "-b", "main"]); try await raw(["config", "user.name", "Replay Acceptance"])
    try await raw(["config", "user.email", "replay@example.invalid"]); try await raw(["config", "commit.gpgsign", "false"])
    try write("base.txt", "base\n"); try await raw(["add", "."]); try await raw(["commit", "-m", "base"])
    let base = try await git.status().head!
    try await raw(["switch", "-c", "source"])
    var commits: [String] = []
    for index in 1...2 {
      try write("\(index).txt", "\(index)\n"); try await raw(["add", "."]); try await raw(["commit", "-m", "Replay \(index)"])
      commits.append(try await git.status().head!)
    }
    try await raw(["switch", "main"])
    let store = AppStore(persistence: ConfigurationStore(url: root.deletingLastPathComponent().appendingPathComponent("replay-workspace.json")))
    defer { store.shutdown() }
    await store.addRepository(fixture); await store.current?.activate(refresh: true)
    guard let model = store.current else { throw GitPierError.invalidInput("Missing replay model") }
    model.editDraft("Preserve this draft")
    model.setPage("history")
    let host = NSHostingView(rootView: RootView().environmentObject(store).modifier(AppAppearance(store: store)))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 1000), styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    NSApp.setActivationPolicy(.regular); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    defer { window.close() }
    var checks: [String] = [], phase = "initial"
    defer {
      try? (checks.joined(separator: "\n") + "\nPhase: " + phase + "\nError: " + (model.error ?? "none")).write(to: output.appendingPathComponent("replay-diagnostics.txt"), atomically: true, encoding: .utf8)
      var active = window.attachedSheet
      while let next = active?.attachedSheet { active = next }
      if let content = active?.contentView {
        let text = assistantElements(content).map { assistantString($0, "accessibilityLabel") + " | " + assistantString($0, "accessibilityValue") }.joined(separator: "\n")
        try? text.write(to: output.appendingPathComponent("replay-final-accessibility.txt"), atomically: true, encoding: .utf8)
      }
    }
    func require(_ value: Bool, _ name: String) throws { guard value else { throw GitPierError.invalidInput("Replay acceptance: " + name) }; checks.append(name) }
    func sheet() -> NSWindow? { var value = window.attachedSheet; while let next = value?.attachedSheet { value = next }; return value }
    func control(_ id: String) throws -> NSObject {
      guard let content = sheet()?.contentView, let value = assistantFind(content, id: id) else { throw GitPierError.invalidInput("Missing replay control: " + id) }
      return value
    }
    func cancelSheet() async throws {
      guard let content = sheet()?.contentView else { throw GitPierError.indexChanged }
      try pressNativeButton(content, title: store.text("Cancel", "取消")); try await waitFor { window.attachedSheet == nil }
    }
    func openPlan(_ plan: [String]? = nil) async throws {
      try await waitFor { !model.busy && !model.refreshing }
      model.commitReplayRequest = CommitReplayRequest(commits: plan ?? commits)
      try await waitFor { sheet()?.contentView.flatMap { assistantFind($0, id: "replay.apply") } != nil }
      try await waitFor { (try? control("replay.apply").value(forKey: "accessibilityEnabled") as? Bool) == true }
      try await settle()
    }
    let index = try Data(contentsOf: fixture.appendingPathComponent(".git/index"))
    phase = "History selection"
    try await waitFor { !model.historyLoading && !model.refreshing }
    var all = HistoryQuery(); all.scope = .allReferences
    model.historyQuery = all; await model.loadHistory(reset: true)
    try await waitFor { assistantFind(host, id: "history.select." + commits[1]) != nil }
    for hash in commits {
      guard let checkbox = assistantFind(host, id: "history.select." + hash) else { throw GitPierError.indexChanged }
      try assistantPress(checkbox)
    }
    guard let selectedAction = assistantFind(host, id: "history.cherry-pick-selected") else { throw GitPierError.indexChanged }
    try assistantPress(selectedAction)
    try await waitFor { sheet()?.contentView.flatMap { assistantFind($0, id: "replay.apply") } != nil }
    try await cancelSheet()
    try require(true, "History checkboxes open a multi-commit native review")
    model.historyQuery = nil; await model.loadHistory(reset: true); try await settle()
    try require(assistantFind(host, id: "history.cherry-pick-selected")?.value(forKey: "accessibilityEnabled") as? Bool == false,
      "History cannot confirm an empty plan after selected commits leave the loaded query")
    for language in [AppLanguage.english, .simplifiedChinese] {
      for appearance in [AppearanceMode.light, .dark] {
        phase = "review \(language.rawValue) \(appearance.rawValue)"
        var settings = store.settings; settings.language = language; settings.appearance = appearance; store.updateSettings(settings)
        try await openPlan()
        guard let content = sheet()?.contentView else { throw GitPierError.indexChanged }
        let text = assistantElements(content).map { assistantString($0, "accessibilityLabel") + assistantString($0, "accessibilityValue") }.joined(separator: "\n")
        try require(commits.allSatisfy { text.contains($0) }, "Full reviewed hashes visible in \(language.rawValue)/\(appearance.rawValue)")
        let scrolls = descendants(content).compactMap { $0 as? NSScrollView }
        try require(!scrolls.isEmpty && scrolls.allSatisfy { !$0.hasVerticalScroller && !$0.hasHorizontalScroller }, "Review uses shared overlay scrollbars without native gutters")
        try assistantPress(control("replay.move.down")); try await settle()
        try require((try control("replay.move.up")).value(forKey: "accessibilityEnabled") as? Bool == true, "Native order arrows move the selected commit")
        try capture(content, to: output.appendingPathComponent("replay-\(language.rawValue)-\(appearance.rawValue).png"))
        if language == .english, let sheet = sheet() {
          let result = try await ProcessRunner().run(executable: "/usr/sbin/screencapture", arguments: ["-x", "-o", "-l", String(sheet.windowNumber), output.appendingPathComponent("replay-visible-\(appearance.rawValue).png").path], directory: fixture)
          try require(result.code == 0, "Visible native replay capture \(appearance.rawValue)")
        }
        if language == .english && appearance == .light, let currentSheet = sheet() {
          try sendWorkspaceKey(53, window: currentSheet); try await waitFor { window.attachedSheet == nil }
          try require(true, "Escape cancels replay review")
        } else { try await cancelSheet() }
      }
    }
    let before = try await git.status()
    try require(before.head == base && (try Data(contentsOf: fixture.appendingPathComponent(".git/index"))) == index, "Review and cancellation preserve HEAD and exact Index")
    phase = "long plan scrolling and Return cancellation"
    var longPlan = commits
    let tree = try await git.read(["rev-parse", base + "^{tree}"]).text.trimmingCharacters(in: .newlines)
    for index in 0..<24 {
      let hash = try await git.read(["commit-tree", tree, "-p", base], input: Data("Long review \(index)\n".utf8)).text.trimmingCharacters(in: .newlines)
      longPlan.append(hash)
    }
    try await openPlan(longPlan)
    if let content = sheet()?.contentView,
      let scroll = descendants(content).compactMap({ $0 as? NSScrollView }).max(by: {
        ($0.documentView?.bounds.height ?? 0) - $0.contentView.bounds.height < ($1.documentView?.bounds.height ?? 0) - $1.contentView.bounds.height
      }), let overlay = scroll.subviews.compactMap({ $0 as? OverlayScrollbars }).first, let currentSheet = sheet() {
      try require((scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height, "Long native plan has a real scrollable viewport")
      checks.append("Long scroll before drag: \(scroll.contentView.bounds), document \(scroll.documentView?.bounds ?? .zero), thumb \(overlay.verticalThumb.fraction)")
      try dragThumb(overlay.verticalThumb, in: currentSheet)
      checks.append("Long scroll immediately after drag: \(scroll.contentView.bounds), document \(scroll.documentView?.bounds ?? .zero), thumb \(overlay.verticalThumb.fraction)")
      try await settle()
      checks.append("Long scroll after layout: \(scroll.contentView.bounds), document \(scroll.documentView?.bounds ?? .zero), thumb \(overlay.verticalThumb.fraction)")
      try require(overlay.verticalThumb.fraction > 0.98, "Shared thumb drag reaches the last replay commit")
      overlay.verticalThumb.changed?(0)
      try require(overlay.verticalThumb.fraction < 0.01, "Replay list returns to its first commit")
    } else { throw GitPierError.invalidInput("Long replay plan did not install the shared scrollbars") }
    try assistantPress(control("replay.apply"))
    try await waitFor { sheet()?.contentView.flatMap { assistantFind($0, id: "replay.confirm") } != nil }
    if let currentSheet = sheet() { try sendWorkspaceKey(36, window: currentSheet) }
    try await waitFor { window.attachedSheet != nil && window.attachedSheet?.attachedSheet == nil }
    try require(true, "Return defaults to cancelling the final replay confirmation")
    try await cancelSheet()
    phase = "execute ordered plan and change page"
    var settings = store.settings; settings.language = .english; settings.appearance = .light; store.updateSettings(settings)
    try await openPlan(); try assistantPress(control("replay.move.down")); try assistantPress(control("replay.apply"))
    try await waitFor { sheet()?.contentView.flatMap { assistantFind($0, id: "replay.confirm") } != nil }
    try assistantPress(control("replay.confirm")); model.setPage("branches")
    try await waitFor { !model.busy && window.attachedSheet == nil }
    let history = try await git.history(count: 2)
    try require(history.map(\.subject) == ["Replay 1", "Replay 2"], "Confirmed order executes through native Git across page dismissal")
    try require(model.record.draft == "Preserve this draft", "Replay preserves commit draft")
    try require(store.operations.records.contains { $0.state == .succeeded && $0.repositoryID == model.record.id }, "Operations Center records replay success")
    phase = "ordinary revert confirmation"
    model.revert(history[0]); try await waitFor { model.confirmation?.canConfirm == true && window.attachedSheet != nil }
    try require(model.confirmation?.mainlineParents == nil && model.confirmation?.diffCommit?.hash == history[0].hash, "Ordinary Revert shares reviewed confirmation and Diff entry")
    try assistantPress(control("gitpier.workflow.review.cancel")); try await waitFor { window.attachedSheet == nil }
    phase = "Revert uses newly reviewed effective metadata"
    let oldCommit = history[0]
    let replacementTree = try await git.read(["rev-parse", oldCommit.hash + "^{tree}"]).text.trimmingCharacters(in: .newlines)
    let replacement = try await git.read(["commit-tree", replacementTree] + oldCommit.parents.flatMap { ["-p", $0] }, input: Data("Reviewed replacement subject\n".utf8)).text.trimmingCharacters(in: .newlines)
    try await raw(["replace", oldCommit.hash, replacement])
    model.revert(oldCommit); try await waitFor { model.confirmation?.canConfirm == true && window.attachedSheet != nil }
    try require(model.confirmation?.diffCommit?.subject == "Reviewed replacement subject"
      && model.confirmation?.detail.contains("Reviewed replacement subject") == true
      && model.confirmation?.replayReview != nil, "Revert confirmation and shared Diff use the effective reviewed commit rather than a cached History record")
    try assistantPress(control("gitpier.workflow.review.cancel")); try await waitFor { window.attachedSheet == nil }
    try await raw(["replace", "-d", oldCommit.hash])
    phase = "branch health"
    model.setPage("history"); model.setPage("branches")
    try await waitFor { assistantFind(host, id: "health.branch.main") != nil }
    try require(assistantFind(host, id: "health.target") != nil && assistantFind(host, id: "health.analyze") != nil, "Branches exposes read-only health with an explicit target")
    try capture(host, to: output.appendingPathComponent("branch-health.png"))
    let healthReader = BranchHealthReader()
    try await raw(["update-ref", "refs/heads/source", base])
    healthReader.load(model, target: "", force: true); try await waitFor { !healthReader.request.loading }
    try require(healthReader.snapshot == nil && healthReader.byReference.isEmpty && healthReader.request.problem?.contains("Refresh") == true,
      "External branch changes cannot combine new health badges with stale row hashes")
    try await raw(["update-ref", "refs/heads/source", commits[1]])
    phase = "conflict and native recovery"
    try await raw(["reset", "--hard", base]); try write("1.txt", "conflict\n")
    try await raw(["add", "."]); try await raw(["commit", "-m", "target conflict"]); await model.refresh()
    model.setPage("history"); try await openPlan(); try assistantPress(control("replay.apply"))
    try await waitFor { sheet()?.contentView.flatMap { assistantFind($0, id: "replay.confirm") } != nil }
    try assistantPress(control("replay.confirm"))
    try await waitFor { !model.busy && model.status.operation == .cherryPick }
    try require(model.page == "conflicts" && model.sequencer?.remaining.count == 2, "Conflict navigates to existing editor and retains current plus remaining commits")
    try require(store.operations.records.first?.state == .waitingForUser, "Incomplete native sequence waits for the user")
    model.showSequencerRecovery = true
    try await waitFor { sheet()?.contentView.flatMap { assistantFind($0, id: "replay.control.abort") } != nil }
    try await waitFor { (try? control("replay.control.abort").value(forKey: "accessibilityEnabled") as? Bool) == true }
    phase = "recovery changed todo request"
    try write(".git/sequencer/todo", "pick \(commits[0]) updated recovery subject\npick \(commits[1]) Replay 2\n")
    try assistantPress(control("replay.control.abort"))
    try await waitFor {
      sheet()?.contentView.map { content in assistantElements(content).contains {
        (assistantString($0, "accessibilityLabel") + assistantString($0, "accessibilityValue"))
          .contains(localizedUI("The sequence changed. Review the updated recovery state before choosing an action again."))
      } } == true
    }
    try require(window.attachedSheet?.attachedSheet == nil, "Changed native todo requires reviewing the updated recovery state before confirmation")
    try assistantPress(control("replay.control.abort"))
    phase = "recovery final confirmation"
    try await waitFor { sheet()?.contentView.flatMap { assistantFind($0, id: "replay.control.confirm") } != nil }
    if let content = sheet()?.contentView {
      let text = assistantElements(content).map { assistantString($0, "accessibilityLabel") + assistantString($0, "accessibilityValue") }.joined(separator: "\n")
      try require(commits.allSatisfy { text.contains($0) } && text.contains("updated recovery subject"), "Final recovery confirmation includes the fixed current commit and complete todo")
    }
    try assistantPress(control("replay.control.confirm")); model.setPage("branches")
    try await waitFor { !model.busy && window.attachedSheet == nil }
    try require(model.status.operation == nil && model.error == nil, "Confirmed Abort survives page dismissal and refreshes the original repository")
    phase = "ambiguous Unicode reference identities"
    let packed = fixture.appendingPathComponent(".git/packed-refs")
    let finalHead = try await git.status().head!
    let names = ["refs/heads/cafe\u{301}", "refs/heads/caf\u{e9}"]
    var packedBytes = Data("# pack-refs with: peeled fully-peeled sorted\n".utf8)
    for name in names { packedBytes.append(Data((finalHead + " " + name + "\n").utf8)) }
    try packedBytes.write(to: packed)
    let reader = BranchHealthReader(); reader.load(model, target: "")
    try await waitFor { !reader.request.loading }
    try require(reader.snapshot == nil && reader.byReference.isEmpty && reader.request.problem?.contains("ambiguous") == true,
      "Canonically equivalent packed ref names report unavailable instead of crashing the health dictionary")
    try FileManager.default.removeItem(at: packed)
    phase = "complete"
    try (checks.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("replay-results.txt"), atomically: true, encoding: .utf8)
  }
}
