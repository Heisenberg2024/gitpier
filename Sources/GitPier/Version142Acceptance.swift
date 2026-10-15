import AppKit
import GitPierCore
import SwiftUI

extension UIAcceptance {
  static func verifyVersion142(root source: URL, output: URL) async throws {
    guard source.resolvingSymlinksInPath().deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui.") else {
      throw GitPierError.invalidInput("Remote check acceptance requires a disposable UI fixture")
    }
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-v142-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let root = fixture.appendingPathComponent("primary"), linked = fixture.appendingPathComponent("linked")
    let producerPath = fixture.appendingPathComponent("producer"), remote = fixture.appendingPathComponent("remote.git")
    let seed = GitService(root: source)
    _ = try await seed.perform(["clone", "--bare", "--", source.path, remote.path])
    _ = try await seed.perform(["clone", "--", remote.path, root.path])
    _ = try await seed.perform(["clone", "--", remote.path, producerPath.path])
    let git = GitService(root: root), producer = GitService(root: producerPath)
    for service in [git, producer] {
      _ = try await service.perform(["config", "user.name", "Remote Acceptance"])
      _ = try await service.perform(["config", "user.email", "remote@example.invalid"])
      _ = try await service.perform(["config", "commit.gpgsign", "false"])
    }
    _ = try await git.createWorktree(destination: linked, branch: "linked", newBranch: true)
    _ = try await GitService(root: linked).perform(["branch", "--set-upstream-to", "origin/main"])
    var primary = RepositoryRecord(path: root.path), secondary = RepositoryRecord(path: linked.path)
    primary.draft = "Keep remote check draft"; secondary.draft = "Keep linked draft"
    let invalid = RepositoryRecord(path: fixture.appendingPathComponent("missing").path)
    let trace = fixture.appendingPathComponent("fetch-trace"), wrapper = fixture.appendingPathComponent("git-trace")
    let wrapperText = "#!/bin/sh\nfor task_arg in \"$@\"; do\n if [ \"$task_arg\" = fetch ]; then printf 'fetch\\n' >> "
      + InputValidation.shellQuote(trace.path) + "; sleep 1; break; fi\ndone\nexec /usr/bin/git \"$@\"\n"
    try wrapperText.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    var config = WorkspaceConfiguration(); config.repositories = [primary, secondary, invalid]
    config.selectedRepository = primary.id; config.settings.gitPath = wrapper.path
    let persistence = ConfigurationStore(url: fixture.appendingPathComponent("workspace.json")); try persistence.save(config)
    let store = AppStore(persistence: persistence); defer { store.shutdown() }
    let host = NSHostingView(rootView: AnyView(RootView().environmentObject(store).modifier(AppAppearance(store: store))))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
      styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.title = "GitPier 1.4.2 · Disposable Fixture"
    NSApp.setActivationPolicy(.regular); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    defer { host.rootView = AnyView(EmptyView()); window.close() }
    try await waitFor { store.workspace.entries.count == 3 && store.workspace.entries.values.allSatisfy { $0.state == .fresh || $0.state == .failed } }
    try await settle()
    try accessibilityLabels(host).write(to: output.appendingPathComponent("v142-initial-ax.txt"), atomically: true, encoding: .utf8)
    try capture(host, to: output.appendingPathComponent("v142-initial.png"))
    try descendants(host).compactMap { $0 as? NSButton }.map { "\(type(of: $0)) role=\($0.accessibilityRole()?.rawValue ?? "nil") label=\($0.accessibilityLabel() ?? "nil") title=\($0.title)" }.joined(separator: "\n").write(to: output.appendingPathComponent("v142-native-buttons.txt"), atomically: true, encoding: .utf8)
    func fetchCount() -> Int { ((try? String(contentsOf: trace, encoding: .utf8)) ?? "").split(separator: "\n").count }
    func matchingCheckbox() throws -> NSButton {
      guard let button = descendants(host).compactMap({ $0 as? NSButton }).first(where: {
        $0.allowsMixedState
      }) else { throw GitPierError.invalidInput("Missing native tri-state matching checkbox") }
      return button
    }
    print("v142: initial scan and default-off")
    guard fetchCount() == 0, !store.settings.automaticFetch, store.workspace.remoteCheck(primary.id).lastSuccess == nil else {
      throw GitPierError.invalidInput("Default remote checks connected without opt-in")
    }
    try pressNativeButton(host, title: "Select Matching"); try await settle()
    guard store.workspace.selected.count == 3, try matchingCheckbox().state == .on else { throw GitPierError.invalidInput("Matching select-all is incorrect") }
    store.workspace.selected.remove(secondary.id); try await settle()
    guard try matchingCheckbox().state == .mixed else { throw GitPierError.invalidInput("Partial selection is not a native mixed checkbox") }
    try pressNativeButton(host, title: "Select Matching"); try await settle()
    guard store.workspace.selected.count == 3 else { throw GitPierError.invalidInput("Clicking mixed did not select all matches") }
    try pressNativeButton(host, title: "Select Matching"); try await settle()
    guard store.workspace.selected.isEmpty, try matchingCheckbox().state == .off else { throw GitPierError.invalidInput("Select-all toggle did not deselect") }
    print("v142: tri-state selection passed")
    // Open a live repository session and leave a draft, selected Diff and non-Commit page intact.
    await store.models[primary.id]!.activate()
    let model = store.models[primary.id]!
    print("v142: session active available=\(model.available), active=\(NSApp.isActive)")
    try "working draft\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    await model.refresh()
    if let file = model.status.files.first(where: { $0.path == "README.md" }) { model.select(file, permanent: true) }
    try await waitFor { !model.diffLoading }
    print("v142: Diff ready, active=\(NSApp.isActive)")
    model.setPage("worktrees")
    let refreshes = model.refreshCount, diffReads = model.diffReadCount, path = model.selectedPath, tabs = model.tabs.map(\.path)
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    store.workspace.selected = [secondary.id]
    let interactiveForeground = ProcessInfo.processInfo.environment["GITPIER_UI_ACCEPTANCE_INTERACTIVE_FOREGROUND"] == "1"
    func awaitPhysicalActivation(_ phase: String) async throws {
      guard interactiveForeground else { return }
      window.title = "GitPier 1.4.2 · Activate disposable " + phase
      try Data("Ready for a real window click.\n".utf8).write(to: output.appendingPathComponent("ready-" + phase))
      let proceed = output.appendingPathComponent("continue-" + phase)
      let deadline = Date().addingTimeInterval(600)
      while !FileManager.default.fileExists(atPath: proceed.path) {
        guard Date() < deadline else { throw GitPierError.invalidInput("Foreground fixture timed out: " + phase) }
        try await Task.sleep(for: .milliseconds(100))
      }
    }
    try await awaitPhysicalActivation("automatic")
    // A short fixture-only focus lease avoids launch/activation races. Production still checks
    // NSApp.isActive at admission and dispatch; no foreground condition is bypassed for tests.
    let focusLease = Task { @MainActor in
      for _ in 0..<30 {
        guard !Task.isCancelled else { return }
        if !NSApp.isActive {
          window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        }
        try? await Task.sleep(for: .milliseconds(200))
      }
    }
    defer { focusLease.cancel() }
    try await waitFor { NSApp.isActive }
    try await settle()
    var settings = store.settings; settings.automaticFetch = true; settings.remoteCheckScope = "workspace"; store.updateSettings(settings)
    try await waitFor { store.workspace.entries[primary.id]?.state == .fresh && store.workspace.entries[secondary.id]?.state == .fresh }
    print("v142: auto evaluate, active=\(NSApp.isActive), busy=\(store.hasRunningGitOperations), target=\(store.workspace.entries[primary.id]?.snapshot?.remoteTarget?.remote.name ?? "nil")")
    await store.workspace.evaluateRemoteChecks()
    do { try await waitFor { store.workspace.remoteCheck(primary.id).lastSuccess != nil && !store.workspace.fetching } }
    catch { throw GitPierError.invalidInput("Automatic Fetch did not succeed: \(store.workspace.remoteCheck(primary.id)) trace=\(fetchCount())") }
    focusLease.cancel()
    try await settle()
    guard fetchCount() == 1, store.workspace.selected == [secondary.id], store.workspace.fetchJobs.isEmpty,
      !store.workspace.showFetchReview, model.record.draft == primary.draft, model.page == "worktrees",
      model.selectedPath == path, model.tabs.map(\.path) == tabs, model.refreshCount == refreshes,
      model.diffReadCount == diffReads, try Data(contentsOf: root.appendingPathComponent(".git/index")) == index else {
      throw GitPierError.invalidInput("Automatic Fetch duplicated a worktree target or changed repository UI/Index")
    }
    print("v142: auto preservation and dedup passed")
    // Native Git may update refs before cancellation (for example while a committed-ref hook
    // finishes). The same cancellation/drain path used for quitting must refresh those counts.
    let hook = root.appendingPathComponent(".git/hooks/reference-transaction")
    let committedMarker = fixture.appendingPathComponent("refs-committed")
    let hookText = "#!/bin/sh\ncat >/dev/null\nif [ \"$1\" = committed ]; then touch "
      + InputValidation.shellQuote(committedMarker.path) + "; sleep 30; fi\n"
    try hookText.write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    try "before cancellation\n".write(to: producerPath.appendingPathComponent("cancel.txt"), atomically: true, encoding: .utf8)
    _ = try await producer.perform(["add", "--", "cancel.txt"])
    _ = try await producer.perform(["commit", "-m", "remote change before cancellation"])
    _ = try await producer.network("push")
    try await awaitPhysicalActivation("cancellation")
    let cancellationFocusLease = Task { @MainActor in
      for _ in 0..<30 {
        guard !Task.isCancelled else { return }
        if !NSApp.isActive { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        try? await Task.sleep(for: .milliseconds(200))
      }
    }
    defer { cancellationFocusLease.cancel() }
    try await waitFor { NSApp.isActive }
    // Activation also starts a local scan; scheduling intentionally waits for its fresh snapshot.
    try await waitFor { store.workspace.entries[primary.id]?.state == .fresh && store.workspace.entries[secondary.id]?.state == .fresh }
    print("v142: cancellation preflight active=\(NSApp.isActive), busy=\(store.hasRunningGitOperations)")
    await store.workspace.evaluateRemoteChecks(now: Date().addingTimeInterval(1000), uptime: ProcessInfo.processInfo.systemUptime + 1000)
    do { try await waitFor { FileManager.default.fileExists(atPath: committedMarker.path) } }
    catch { throw GitPierError.invalidInput("Cancellation fixture did not reach committed refs: \(store.workspace.remoteCheck(primary.id)) trace=\(fetchCount()) active=\(NSApp.isActive)") }
    await store.workspace.stopAutomaticChecks()
    cancellationFocusLease.cancel()
    try FileManager.default.removeItem(at: hook)
    try await waitFor { store.workspace.entries[primary.id]?.snapshot?.behind == 1 && model.status.behind == 1 }
    guard store.workspace.selected == [secondary.id], fetchCount() == 2,
      model.diffReadCount == diffReads, model.refreshCount == refreshes,
      try Data(contentsOf: root.appendingPathComponent(".git/index")) == index else {
      throw GitPierError.invalidInput("Cancelled running Fetch lost ref updates, changed selection/Index, or failed to drain")
    }
    print("v142: cancellation after committed refs refreshed and drained")
    for _ in 0..<6 { store.workspace.requestRemoteEvaluation(); await store.workspace.evaluateRemoteChecks() }
    try await Task.sleep(for: .seconds(3))
    guard fetchCount() == 2 else { throw GitPierError.invalidInput("Rapid lifecycle events repeated Fetch") }
    // A new AppStore must restore successful remote metadata and remain inside its interval.
    let reopened = AppStore(persistence: persistence)
    try await waitFor { reopened.workspace.entries[primary.id]?.state == .fresh }
    guard reopened.workspace.remoteCheck(primary.id).lastSuccess == store.workspace.remoteCheck(primary.id).lastSuccess else {
      throw GitPierError.invalidInput("Remote check timestamp did not survive reopening")
    }
    try await settle(); await reopened.workspace.evaluateRemoteChecks()
    try await Task.sleep(for: .seconds(2))
    guard fetchCount() == 2 else { throw GitPierError.invalidInput("Reopening repeated a recent successful Fetch") }
    reopened.shutdown()
    settings.automaticFetch = false; store.updateSettings(settings)
    // A corrupt metadata file pauses automation and remains byte-for-byte intact.
    let corruptPersistence = ConfigurationStore(url: fixture.appendingPathComponent("corrupt-workspace.json"))
    var corruptConfig = config; corruptConfig.settings.automaticFetch = true
    try corruptPersistence.save(corruptConfig)
    let corruptMetadata = corruptPersistence.url.deletingPathExtension().appendingPathExtension("remote-checks.json")
    let corruptBytes = Data("not a remote history file".utf8); try corruptBytes.write(to: corruptMetadata)
    let corrupt = AppStore(persistence: corruptPersistence)
    try await waitFor { corrupt.workspace.entries[primary.id]?.state == .fresh }
    await corrupt.workspace.evaluateRemoteChecks(); try await Task.sleep(for: .seconds(2))
    guard corrupt.workspace.remoteMetadataError != nil, try Data(contentsOf: corruptMetadata) == corruptBytes, fetchCount() == 2 else {
      throw GitPierError.invalidInput("Corrupt remote metadata was replaced or allowed automatic networking")
    }
    corrupt.shutdown()
    print("v142: lifecycle, enabled reopen and corrupt metadata passed")
    // Cancellation retains all choices; successful admission clears only the two valid choices.
    store.showDashboard = true; store.workspace.selected = [primary.id, secondary.id, invalid.id]
    store.workspace.prepareFetch(); try await waitFor { window.attachedSheet != nil && !store.workspace.preparingFetch }
    guard store.workspace.fetchTargets.count == 1, store.workspace.fetchReviewErrors.count == 1 else { throw GitPierError.invalidInput("Review lost per-target errors or deduplication") }
    try pressNativeButton(window.attachedSheet!.contentView!, title: "Cancel"); try await waitFor { window.attachedSheet == nil }
    guard store.workspace.selected.count == 3, fetchCount() == 2 else { throw GitPierError.invalidInput("Cancel discarded selection or ran Fetch") }
    store.workspace.prepareFetch(); try await waitFor { window.attachedSheet != nil && !store.workspace.preparingFetch }
    try pressNativeButton(window.attachedSheet!.contentView!, title: "Fetch")
    try await waitFor { !store.workspace.submittingFetch && window.attachedSheet == nil && !store.workspace.fetching }
    guard store.workspace.selected == [invalid.id], fetchCount() == 3 else { throw GitPierError.invalidInput("Admission did not preserve the unsubmitted error selection") }
    print("v142: reviewed admission and cancel passed")
    let olderSnapshot = store.workspace.entries[primary.id]!.snapshot!
    // Real local commits establish behind/ahead/divergence for toolbar and Dashboard.
    try "remote\n".write(to: producerPath.appendingPathComponent("remote.txt"), atomically: true, encoding: .utf8)
    _ = try await producer.perform(["add", "--", "remote.txt"]); _ = try await producer.perform(["commit", "-m", "remote change"])
    _ = try await producer.network("push")
    store.showDashboard = false; model.setPage("commit"); try await settle()
    model.network("fetch")
    try await waitFor { store.workspace.remoteCheck(primary.id).phase == .checking }
    try await Task.sleep(for: .milliseconds(100))
    try capture(host, to: output.appendingPathComponent("v142-toolbar-checking.png"))
    try accessibilityLabels(host).write(to: output.appendingPathComponent("v142-toolbar-checking-ax.txt"), atomically: true, encoding: .utf8)
    // Disabled SwiftUI controls may be omitted from the native accessibility tree. Require no
    // enabled Fetch action while busy, with the visible spinner/disabled appearance captured.
    guard model.busy, accessibleButton(host, title: "Fetch", enabled: true) == nil else {
      throw GitPierError.invalidInput("An enabled Fetch action remained accessible during a manual Git operation")
    }
    try await waitFor { !model.busy && model.status.behind == 2 }
    model.applyRemoteSnapshot(olderSnapshot)
    guard model.status.behind == 2 else { throw GitPierError.invalidInput("Older cached workspace snapshot overwrote a newer repository read") }
    guard store.workspace.remoteCheck(primary.id).lastSuccess != nil else { throw GitPierError.invalidInput("Repository manual Fetch did not update unified time") }
    try "local\n".write(to: root.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
    _ = try await git.perform(["add", "--", "local.txt"]); _ = try await git.perform(["commit", "-m", "local change"])
    await model.refresh(); await store.workspace.refresh([primary.id, secondary.id])
    try await waitFor { model.status.ahead == 1 && model.status.behind == 2 }
    for language in AppLanguage.allCases {
      for appearance in [AppearanceMode.light, .dark] {
        settings = store.settings; settings.language = language; settings.appearance = appearance; store.updateSettings(settings); store.notice = nil
        for size in [NSSize(width: 960, height: 640), NSSize(width: 1440, height: 900)] {
          window.setContentSize(size); window.center(); store.showDashboard = true; try await settle()
          try capture(host, to: output.appendingPathComponent("v142-dashboard-\(language.rawValue)-\(appearance.rawValue)-\(Int(size.width)).png"))
          store.showDashboard = false; model.setPage("commit"); try await settle()
          guard accessibleButton(host, title: store.text("Pull", "拉取") + " ↓2", enabled: true) != nil,
            accessibleButton(host, title: store.text("Push", "推送") + " ↑1", enabled: true) != nil else {
            throw GitPierError.invalidInput("Diverged toolbar counts clipped or unavailable")
          }
          try capture(host, to: output.appendingPathComponent("v142-toolbar-\(language.rawValue)-\(appearance.rawValue)-\(Int(size.width)).png"))
        }
      }
    }
    // A real transport failure retains counts and last success while marking remote data stale.
    let success = store.workspace.remoteCheck(primary.id).lastSuccess
    let moved = fixture.appendingPathComponent("remote-offline.git")
    try FileManager.default.moveItem(at: remote, to: moved)
    model.network("fetch"); try await waitFor { !model.busy && model.error != nil }
    guard model.status.ahead == 1, model.status.behind == 2,
      store.workspace.remoteCheck(primary.id).lastSuccess == success,
      store.workspace.remoteCheck(primary.id).phase == .failed else { throw GitPierError.invalidInput("Failed Fetch erased valid tracking state: ahead=\(model.status.ahead) behind=\(model.status.behind) check=\(store.workspace.remoteCheck(primary.id)) expectedSuccess=\(String(describing: success))") }
    let failureFetchCount = fetchCount()
    settings.automaticFetch = true; store.updateSettings(settings)
    await store.workspace.evaluateRemoteChecks(); try await Task.sleep(for: .seconds(2))
    guard fetchCount() == failureFetchCount else { throw GitPierError.invalidInput("Automatic retry ignored failure backoff") }
    settings.automaticFetch = false; store.updateSettings(settings)
    // Render the real settings tab in both languages and appearances.
    for language in AppLanguage.allCases {
      for appearance in [AppearanceMode.light, .dark] {
        settings.language = language; settings.appearance = appearance; store.updateSettings(settings)
        host.rootView = AnyView(SettingsView(initialTab: 2).environmentObject(store).modifier(AppAppearance(store: store)))
        window.setContentSize(NSSize(width: 760, height: 580)); window.center(); try await settle()
        try capture(host, to: output.appendingPathComponent("v142-settings-\(language.rawValue)-\(appearance.rawValue).png"))
      }
    }
    host.rootView = AnyView(RootView().environmentObject(store).modifier(AppAppearance(store: store)))
    _ = try await git.perform(["branch", "--unset-upstream"])
    await model.refresh(); await store.workspace.refresh([primary.id])
    try await waitFor { store.workspace.entries[primary.id]?.snapshot?.upstream == nil }
    store.showDashboard = false; model.setPage("commit"); window.setContentSize(NSSize(width: 960, height: 640)); try await settle()
    try capture(host, to: output.appendingPathComponent("v142-no-upstream.png"))
    guard model.status.upstream == nil, RemoteCheckText(workspace: store.workspace, id: primary.id).title == store.text("No upstream", "无上游") else {
      throw GitPierError.invalidInput("Missing upstream was presented as synchronized")
    }
    model.network("fetch")
    try await waitFor { model.networkFetching }
    try capture(host, to: output.appendingPathComponent("v142-no-upstream-fetching.png"))
    try await waitFor { !model.busy }
    let metadata = RemoteCheckStore(url: persistence.url.deletingPathExtension().appendingPathExtension("remote-checks.json"))
    store.remove(primary.id)
    let sharedHistory = try metadata.load()
    guard sharedHistory.values.contains(where: { $0.repositoryIDs.contains(secondary.id) }),
      sharedHistory.values.allSatisfy({ !$0.repositoryIDs.contains(primary.id) }) else { throw GitPierError.invalidInput("Deleting a worktree dropped shared history or retained its removed ID") }
    store.remove(secondary.id)
    guard try metadata.load().isEmpty, FileManager.default.fileExists(atPath: root.path), FileManager.default.fileExists(atPath: linked.path) else {
      throw GitPierError.invalidInput("Removing workspace entries failed to clean metadata or changed physical repositories")
    }
    try "Native tri-state checkbox, mixed-to-all and all-to-none; opt-in automatic local-bare Fetch; common-directory deduplication; lifecycle repeat suppression; independent local/remote timestamps; no automatic Review/tray/selection changes; preserved draft/page/Diff/Index; enabled persisted reopen without repeated Fetch; corrupt metadata pause/preservation; review Cancel and partial target acceptance; manual Fetch shared time; real ahead/behind/divergence and failed transport retention/backoff; cancellation after committed refs drains and refreshes counts; checking/disabled toolbar; no upstream; shared metadata removal; English/Chinese, light/dark, 960/1440 toolbar/Dashboard and 760 settings passed.\n"
      .write(to: output.appendingPathComponent("v142-results.txt"), atomically: true, encoding: .utf8)
  }
}
