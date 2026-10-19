import AppKit
import GitPierCore
import SwiftUI

@MainActor extension UIAcceptance {
  static func verifyContextWorkflow(root: URL, output: URL) async throws {
    guard root.deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui.") else { throw GitPierError.invalidInput("Disposable repository required") }
    var checks: [String] = []
    func require(_ value: Bool, _ name: String) throws {
      guard value else { throw GitPierError.invalidInput("Context workflow: " + name) }; checks.append(name)
    }
    let persistence = ConfigurationStore(url: root.deletingLastPathComponent().appendingPathComponent("context-workspace.json"))
    let store = AppStore(persistence: persistence)
    defer { store.shutdown() }
    await store.addRepository(root); await store.current?.activate(refresh: true)
    guard let model = store.current else { throw GitPierError.invalidInput("Missing fixture") }
    let git = await model.git()
    try await git.perform(["config", "user.name", "Context Fixture"])
    try await git.perform(["config", "user.email", "context@example.invalid"])
    try await git.perform(["config", "commit.gpgsign", "false"])
    try await git.perform(["add", "--all"])
    try await git.perform(["commit", "-m", "fixture clean state"])
    _ = try await git.network("push")
    await model.refresh(); await store.workspace.refresh()
    try await waitFor { store.workspace.entries[model.record.id]?.usable?.head == model.status.head }
    model.network("fetch"); try await waitFor { !model.busy }
    try await settle()
    let initial = model.workflowInput()
    try require(ContextWorkflowAdvice.evaluate(initial).kind == .aligned, "Actual clean tracked branch is aligned after Fetch: " + ContextWorkflowAdvice.evaluate(initial).kind.rawValue + "/" + initial.remotePhase.rawValue + "/fresh=\(initial.remoteFresh)")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640), styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: AnyView(EmptyView())); host.sizingOptions = []
    host.autoresizingMask = [.width, .height]; window.contentView = host
    window.setContentSize(NSSize(width: 960, height: 640))
    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    defer { host.rootView = AnyView(EmptyView()); window.close() }
    func panel() {
      host.rootView = AnyView(VStack(spacing: 0) { ContextWorkflowView(model: model, workspace: store.workspace); Spacer() }
        .frame(width: 680, height: 640, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .environmentObject(store).modifier(AppAppearance(store: store)))
      window.setContentSize(NSSize(width: 680, height: 640))
    }
    model.setPage("history")
    panel(); try await settle()
    try require(contextText(host).contains("No priority suggestions"), "Aligned panel has an explanation")
    try require(!contextText(host).contains("Review Push…"), "Aligned panel has no irrelevant synchronization action")
    let file = root.appendingPathComponent("README.md")
    try Data("staged context work\n".utf8).write(to: file)
    try await git.perform(["add", "--", "README.md"])
    try Data("staged context work\nunstaged context work\n".utf8).write(to: file)
    await model.refresh(); try await settle()
    let partial = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    try require(contextText(host).contains("Review the Index before committing"), "Same visible panel updates to staged guidance without reopening")
    try require(contextText(host).contains("1 staged and 1 unstaged"), "Partial staging reason uses actual counts")
    await model.prepareWorkflow(.reviewChanges, displayed: model.workflowInput())
    try require(model.page == "commit" && model.comparison == .staged && model.selectedPath == "README.md", "Review action selects existing staged Diff")
    try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == partial, "Advice navigation preserves Index bytes and partial staging")
    try await git.perform(["commit", "-m", "outgoing context fixture"])
    try await git.perform(["restore", "--", "README.md"])
    await model.refresh(); await store.workspace.refresh(); try await settle()
    try require(ContextWorkflowAdvice.evaluate(model.workflowInput()).kind == .outgoing, "Real local commit produces outgoing advice")
    let outgoing = model.workflowInput()
    await model.prepareWorkflow(.compareOutgoing, displayed: outgoing)
    guard let comparison = model.workflowComparison else { throw GitPierError.invalidInput("Missing fixed comparison") }
    try require(model.page == "compare" && comparison.right == model.status.head && comparison.targets.count == 2, "Comparison opens immediately with typed commit and configured-upstream targets")
    host.rootView = AnyView(BranchComparisonView(model: model).environmentObject(store)); try await settle()
    try await waitFor { contextText(host).contains("Left ahead / behind: 0 / 1") }
    try require(model.workflowComparison == nil && !contextText(host).contains("Select a local or remote-tracking branch"), "Comparison displays actual exclusive commits and file differences without a selector error")
    let tracking = try await git.resolveCommit("refs/remotes/origin/main")
    let older = try await git.resolveCommit("HEAD~2")
    try await git.perform(["update-ref", "refs/remotes/origin/main", older]); await model.refresh()
    await model.prepareWorkflow(.compareOutgoing, displayed: model.workflowInput())
    try await waitFor { contextText(host).contains("Left ahead / behind: 0 / 2") }
    try require(contextText(host).contains("Left ahead / behind: 0 / 2"), "Repeating the same comparison target reloads changed upstream tips even when HEAD and mode are unchanged")
    try await git.perform(["update-ref", "refs/remotes/origin/main", tracking]); await model.refresh()
    model.setPage("commit"); panel(); try await settle()
    let linked = root.deletingLastPathComponent().appendingPathComponent("context-linked")
    try await git.perform(["worktree", "add", "-b", "context-linked", linked.path])
    await store.addRepository(linked)
    guard let linkedModel = store.current else { throw GitPierError.invalidInput("Missing linked fixture") }
    store.selectedID = model.record.id; store.showDashboard = false
    let beforeSwitch = model.workflowInput()
    let preparing = Task { await model.prepareWorkflow(.reviewPush, displayed: beforeSwitch) }
    try await waitFor { model.workflowPreparing }
    store.selectedID = linkedModel.record.id
    await preparing.value
    try require(model.confirmation == nil && store.current === linkedModel, "Late review cannot act after switching to a different Worktree")
    store.selectedID = model.record.id
    await model.prepareWorkflow(.reviewPush, displayed: model.workflowInput())
    guard let push = model.confirmation else { throw GitPierError.invalidInput("Missing Push review") }
    try require(push.detail.contains(root.resolvingSymlinksInPath().path) && push.detail.contains("refs/heads/main") && push.detail.contains("Fetch"), "Original confirmation includes worktree, branch, destination and snapshot provenance")
    let remoteBefore = try await git.resolveCommit("refs/remotes/origin/main")
    try require(try await git.resolveCommit("HEAD") == comparison.right && remoteBefore != comparison.right, "Reviewing Push performs no remote write")
    try Data("external Index edit\n".utf8).write(to: root.appendingPathComponent("external-context.txt"))
    try await git.perform(["add", "--", "external-context.txt"])
    let externalIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    model.confirmation = nil; push.action(); try await waitFor { !model.busy }
    try require(model.error != nil, "External Index changes invalidate confirmed Push inside original queue")
    try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == externalIndex, "Rejected stale review preserves external Index bytes")
    try require(try await git.resolveCommit("refs/remotes/origin/main") == remoteBefore, "Stale Push does not update tracking tip")
    try await git.perform(["reset", "--hard", "HEAD"])
    try? FileManager.default.removeItem(at: root.appendingPathComponent("external-context.txt"))
    model.error = nil; await model.refresh()
    let wrongSelection = model.workflowInput()
    store.showDashboard = true
    await model.prepareWorkflow(.reviewPush, displayed: wrongSelection)
    try require(model.confirmation == nil, "Repository advice cannot run while Dashboard owns selection")
    store.showDashboard = false
    // Native rendering uses real divergence metadata below; it never executes the offered operations.
    try await git.perform(["branch", "incoming-context", remoteBefore])
    try await git.perform(["switch", "incoming-context"])
    try Data("incoming branch\n".utf8).write(to: root.appendingPathComponent("incoming-context.txt"))
    try await git.perform(["add", "--", "incoming-context.txt"]); try await git.perform(["commit", "-m", "incoming"])
    let incoming = try await git.resolveCommit("HEAD")
    try await git.perform(["switch", "main"])
    try await git.perform(["update-ref", "refs/remotes/origin/main", incoming])
    await model.refresh()
    try require(ContextWorkflowAdvice.evaluate(model.workflowInput()).kind == .diverged, "Diverged branch offers comparison and explicit strategy")
    for language in AppLanguage.allCases {
      for appearance in [AppearanceMode.light, .dark] {
        var settings = store.settings; settings.language = language; settings.appearance = appearance; store.updateSettings(settings)
        panel(); try await settle()
        let titles = language == .english ? ["Compare incoming commits", "Review Merge…", "Review Rebase…"] : ["比较传入提交", "审查合并…", "审查变基…"]
        let frames = contextButtonFrames(host, titles: Set(titles))
        try require(frames.count == 3 && frames.values.allSatisfy { $0.width > 20 && $0.minX >= window.frame.minX && $0.maxX <= window.frame.maxX }, "All divergence controls visible at minimum width: " + language.rawValue + "/" + appearance.rawValue)
        try require(contextText(host).contains(language == .english ? "local-only" : "本地独有"), "Localized reason explains divergence: " + language.rawValue + "/" + appearance.rawValue)
        try capture(host, to: output.appendingPathComponent("context-" + language.rawValue + "-" + appearance.rawValue + ".png"))
      }
    }
    var english = store.settings; english.language = .english; store.updateSettings(english)
    await model.prepareWorkflow(.mergeUpstream, displayed: model.workflowInput())
    try await waitFor { model.confirmation != nil || model.error != nil }
    try require(model.confirmation?.detail.contains(incoming.prefix(12)) == true, "Merge uses existing confirmation with fixed reviewed upstream")
    model.confirmation = nil
    try await git.perform(["branch", "--unset-upstream", "main"]); await model.refresh(); await store.workspace.refresh(); try await settle()
    await model.prepareWorkflow(.setUpstream, displayed: model.workflowInput())
    try require(model.workflowBranchRequest?.intent == .upstream && model.page == "branches", "Missing upstream hands off to existing branch setup without publishing")
    host.rootView = AnyView(BranchesView(model: model).environmentObject(store))
    try await settle()
    guard let upstreamSheet = window.attachedSheet, let upstreamContent = upstreamSheet.contentView else { throw GitPierError.invalidInput("Original upstream alert was not presented") }
    try require(contextText(upstreamContent).contains("Set Branch Upstream"), "Advice opens the original native upstream form")
    try captureContextForm(upstreamContent, to: output.appendingPathComponent("context-upstream-form.png"))
    guard let upstreamCancel = descendants(upstreamContent).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Cancel" }) else { throw GitPierError.invalidInput("Missing upstream Cancel") }
    upstreamCancel.performClick(nil); try await settle()
    let fetchBefore = store.operations.records.filter { $0.kind == .fetch }.count
    await model.prepareWorkflow(.reviewFetch, displayed: model.workflowInput())
    try await waitFor { !store.workspace.preparingFetch }
    try require(store.workspace.showFetchReview && !store.workspace.fetchTargets.isEmpty, "Fetch advice opens the existing target review")
    try require(store.operations.records.filter { $0.kind == .fetch }.count == fetchBefore, "Preparing Fetch does not execute it")
    store.workspace.cancelFetchReview()
    try await git.perform(["switch", "--detach", "HEAD"]); await model.refresh()
    await model.prepareWorkflow(.chooseBranch, displayed: model.workflowInput())
    try require(model.workflowBranchRequest?.intent == .retainingCommit, "Detached HEAD already retained by a branch is not told to create a duplicate: " + ContextWorkflowAdvice.evaluate(model.workflowInput()).kind.rawValue + "/" + (model.workflowMessage ?? ""))
    model.workflowBranchRequest = nil
    try await git.perform(["commit", "--allow-empty", "-m", "detached fixture"]); await model.refresh()
    let detached = model.status.head!
    await model.prepareWorkflow(.createBranch, displayed: model.workflowInput())
    host.rootView = AnyView(EmptyView()); try await settle()
    host.rootView = AnyView(BranchesView(model: model).environmentObject(store)); try await settle()
    guard let branchContent = window.attachedSheet?.contentView else { throw GitPierError.invalidInput("Original branch alert missing") }
    try require(descendants(branchContent).compactMap { $0 as? NSTextField }.contains { $0.stringValue == detached }, "Retaining branch form uses the fixed reviewed HEAD")
    try captureContextForm(branchContent, to: output.appendingPathComponent("context-branch-form.png"))
    guard let branchCancel = descendants(branchContent).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Cancel" }) else { throw GitPierError.invalidInput("Missing branch Cancel") }
    branchCancel.performClick(nil); try await settle()
    try await git.perform(["switch", "main"]); try await git.perform(["remote", "remove", "origin"]); await model.refresh()
    await model.prepareWorkflow(.addRemote, displayed: model.workflowInput())
    host.rootView = AnyView(RemotesView(model: model).environmentObject(store)); try await settle()
    guard let remoteContent = window.attachedSheet?.contentView else { throw GitPierError.invalidInput("Original remote sheet missing") }
    try require(contextText(remoteContent).contains("Add Remote"), "Local-only advice opens the existing Add Remote sheet")
    try captureContextForm(remoteContent, to: output.appendingPathComponent("context-remote-form.png"))
    guard let remoteCancel = assistantElements(remoteContent).first(where: {
      assistantString($0, "accessibilityLabel") == "Cancel" && $0.responds(to: NSSelectorFromString("accessibilityPerformPress"))
    }) else { throw GitPierError.invalidInput("Missing Remote Cancel") }
    try assistantPress(remoteCancel)
    try await waitFor { window.attachedSheet == nil }; try await settle()
    try require(window.attachedSheet == nil, "Remote form closes through its original Cancel binding before replacing the hosting view")
    let indexBeforeRender = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    let beforeRender = try await git.resolveCommit("HEAD")
    panel(); try await settle(); model.workflowMessage = "render-only fixture"; try await settle()
    let afterRender = try await git.resolveCommit("HEAD")
    try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == indexBeforeRender && afterRender == beforeRender, "Repeated native rendering never changes HEAD or Index")
    try checks.joined(separator: "\n").write(to: output.appendingPathComponent("context-results.txt"), atomically: true, encoding: .utf8)
  }
  /// Explicit acceptance-only entry. The external repository is read, never
  /// configured, fetched, checked out, staged, committed or otherwise written.
  static func verifyContextReadOnlyRepository(_ root: URL, output: URL) async throws {
    var checks: [String] = []
    func require(_ value: Bool, _ name: String) throws {
      guard value else { throw GitPierError.invalidInput("Read-only context: " + name) }
      checks.append(name)
      try checks.joined(separator: "\n").write(to: output.appendingPathComponent("readonly-results.txt"), atomically: true, encoding: .utf8)
    }
    let persistence = ConfigurationStore(url: output.appendingPathComponent("readonly-workspace.json"))
    let record = RepositoryRecord(path: root.resolvingSymlinksInPath().path)
    var configuration = WorkspaceConfiguration()
    configuration.repositories = [record]
    configuration.settings.automaticFetch = false; configuration.settings.automaticRefresh = false; configuration.settings.language = .english
    try persistence.save(configuration)
    // Only the disposable workspace is seeded. This exercises the owner's
    // local tracking snapshot without pretending a real Fetch was performed.
    let bootstrap = GitService(root: root)
    guard let target = try await bootstrap.workspaceSnapshot(record).remoteTarget else { throw GitPierError.invalidInput("Read-only fixture has no configured upstream target") }
    var freshness = RemoteCheckRecord()
    freshness.repositoryIDs = [record.id]; freshness.phase = .upToDate; freshness.lastSuccess = Date(); freshness.lastAttempt = freshness.lastSuccess
    try RemoteCheckStore(url: persistence.url.deletingPathExtension().appendingPathExtension("remote-checks.json")).save([RemoteCheckStore.key(target): freshness])
    let store = AppStore(persistence: persistence)
    defer { store.shutdown() }
    var settings = store.settings
    settings.automaticFetch = false; settings.automaticRefresh = false; settings.language = .english
    store.updateSettings(settings)
    await store.addRepository(root); await store.current?.activate(refresh: true)
    guard let model = store.current, let head = model.status.head, let upstream = model.status.upstream else { throw GitPierError.invalidInput("Read-only fixture requires a tracked branch") }
    await store.workspace.refresh([model.record.id])
    try await waitFor { store.workspace.entries[model.record.id]?.usable?.head == head }
    let git = await model.git()
    let indexURL = try await git.metadataDirectories()[0].appendingPathComponent("index")
    let index = try Data(contentsOf: indexURL)
    var layout = model.panels.layout; layout.terminalVisible = false; model.editLayout(layout)
    model.setPage("commit")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: RootView().environmentObject(store).modifier(AppAppearance(store: store)))
    host.sizingOptions = []; window.contentView = host
    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    defer { window.close() }
    try await settle(); try await waitFor { !model.refreshing }
    if ProcessInfo.processInfo.environment["GITPIER_CONTEXT_READONLY_VISUAL_HOLD"] == "1" {
      var light = store.settings; light.appearance = .light; store.updateSettings(light)
      try "light".write(to: output.appendingPathComponent("readonly-visual-ready.txt"), atomically: true, encoding: .utf8)
      try await Task.sleep(for: .seconds(60))
    }
    let input = model.workflowInput()
    try require(ContextWorkflowAdvice.evaluate(input).actions.contains(.compareIncoming) && ContextWorkflowAdvice.evaluate(input).actions.contains(.reviewPull), "Real local tracking snapshot offers incoming comparison and Pull review (isolated simulated freshness)")
    _ = ProcessTrace.take()
    let began = ProcessInfo.processInfo.systemUptime
    await model.prepareWorkflow(.compareIncoming, displayed: input)
    let handoff = (ProcessInfo.processInfo.systemUptime - began) * 1000
    try require(model.page == "compare" && handoff < 100, "Comparison page opens before Git reads: \(handoff) ms")
    try await waitFor { contextText(host).contains("Left ahead / behind: \(input.status.ahead) / \(input.status.behind)") }
    try require(!contextText(host).contains("Select a local or remote-tracking branch"), "Real comparison has counts and no branch-selector error")
    let trace = ProcessTrace.take()
    try require(!trace.contains { $0.command.contains("status") || $0.command.contains("ls-files") }, "Comparison performs no status or Index scan")
    let expected = try await git.compareBranchTargets(left: .commit(head), right: .upstream(branch: input.status.branch, head: head, name: upstream))
    try require(!expected.files.isEmpty && !expected.rightOnly.isEmpty && contextText(host).contains(expected.rightHash.prefix(8)), "Configured upstream produces actual incoming commits and file differences")
    try capture(host, to: output.appendingPathComponent("readonly-comparison.png"))
    model.setPage("commit"); try await settle()
    guard let advice = assistantFind(host, id: "gitpier.workflow.open") else { throw GitPierError.invalidInput("Missing assistant control") }
    try assistantPress(advice); try await settle()
    guard let popover = NSApp.windows.first(where: { $0.isVisible && $0.contentView.map { assistantFind($0, id: "gitpier.workflow.guidance") != nil } == true }),
      let pullAdvice = popover.contentView.flatMap({ assistantFind($0, id: "gitpier.workflow.reviewPull") }) else { throw GitPierError.invalidInput("Missing actual Pull advice control") }
    let reviewBegan = ProcessInfo.processInfo.systemUptime
    try assistantPress(pullAdvice)
    try await waitFor { model.confirmation != nil }
    let feedback = (ProcessInfo.processInfo.systemUptime - reviewBegan) * 1000
    try require(feedback < 500, "Pull review presents before full preflight: \(feedback) ms")
    try await waitFor { window.attachedSheet != nil }
    try await waitFor { !model.workflowPreparing }
    try await waitFor {
      window.attachedSheet?.contentView.flatMap { assistantFind($0, id: "gitpier.workflow.review.confirm") }.map { $0.value(forKey: "accessibilityEnabled") as? Bool == true } == true
    }
    guard let sheet = window.attachedSheet, let content = sheet.contentView,
      let pull = assistantFind(content, id: "gitpier.workflow.review.confirm") else { throw GitPierError.invalidInput("PendingAction Pull confirmation was not presented") }
    try require(model.confirmation?.canConfirm == true && pull.value(forKey: "accessibilityEnabled") as? Bool == true && contextText(content).contains("Working tree"), "Existing PendingAction updates in place with full review data and an enabled Pull")
    try require(!popover.isVisible, "Actual advice button dismisses its popover before the review sheet")
    guard let cancel = assistantFind(content, id: "gitpier.workflow.review.cancel") else { throw GitPierError.invalidInput("Missing Pull Cancel") }
    try assistantPress(cancel); try await settle()
    let cancelled = Task { await model.prepareWorkflow(.reviewPull, displayed: model.workflowInput()) }
    try await waitFor { model.confirmation != nil }
    try require(model.confirmation?.canConfirm == false, "Immediate Pull confirmation cannot execute while preparing")
    model.confirmation = nil
    await cancelled.value; try await settle()
    try require(model.confirmation == nil, "Cancelling the loading review cannot resurrect a confirmation")
    let finalHead = try await git.resolveCommit("HEAD")
    try require(try Data(contentsOf: indexURL) == index && finalHead == head, "Read-only acceptance preserves actual HEAD and Index bytes")
  }
  // Native alerts already cache their AppKit layers; the terminal-specific layer
  // composition in the main UI capture helper would draw them a second time.
  private static func captureContextForm(_ view: NSView, to url: URL) throws {
    view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw GitPierError.invalidInput("Cannot capture original form") }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw GitPierError.invalidInput("Cannot encode original form") }
    try data.write(to: url)
  }
  private static func contextText(_ view: NSView) -> String {
    var seen = Set<ObjectIdentifier>(), result: [String] = []
    func walk(_ item: Any) {
      guard let object = item as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
      func value(_ key: String) -> Any? { object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil }
      for key in ["accessibilityLabel", "accessibilityValue"] { if let text = value(key) as? String { result.append(text) } }
      for child in value("accessibilityChildren") as? [Any] ?? [] { walk(child) }
      if let view = object as? NSView { view.subviews.forEach(walk) }
    }
    walk(view); return result.joined(separator: "\n")
  }
  private static func contextButtonFrames(_ view: NSView, titles: Set<String>) -> [String: NSRect] {
    var seen = Set<ObjectIdentifier>(), frames: [String: NSRect] = [:]
    func walk(_ item: Any) {
      guard let object = item as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
      func value(_ key: String) -> Any? { object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil }
      if let title = value("accessibilityLabel") as? String, titles.contains(title), let frame = value("accessibilityFrame") as? NSValue { frames[title] = frame.rectValue }
      for child in value("accessibilityChildren") as? [Any] ?? [] { walk(child) }
      if let view = object as? NSView { view.subviews.forEach(walk) }
    }
    walk(view); return frames
  }
}
