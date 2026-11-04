#if DEBUG
import AppKit
import GitPierCore
import Sparkle
import SwiftUI
import UserNotifications

extension UIAcceptance {
  static func verifyNativeExperienceD(store: AppStore, model: RepositoryModel, window: NSWindow, output: URL) async throws {
    guard URL(fileURLWithPath: model.record.path).deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui."),
      let host = window.contentView else { throw GitPierError.invalidInput("Phase D requires the disposable acceptance workspace") }
    NSApp.setActivationPolicy(.regular)
    window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    var settings = store.settings
    settings.automaticFetch = false; settings.completionNotifications = false
    model.record.favorite = true; store.update(model.record)
    let pages = ["commit", "history", "branches", "worktrees", "conflicts", "stash", "lfs", "submodules", "hosting", "repository"]
    var captures = 0
    for (language, mode, size) in [(AppLanguage.english, AppearanceMode.light, NSSize(width: 1440, height: 900)),
      (.simplifiedChinese, .dark, NSSize(width: 960, height: 640))] {
      settings.language = language; settings.appearance = mode; store.updateSettings(settings); store.notice = nil
      window.setContentSize(size); window.center()
      store.showDashboard = true
      try await settle()
      try await captureHostingWindow(window, to: output.appendingPathComponent("\(mode.rawValue)-dashboard.png")); captures += 1
      store.showDashboard = false
      for page in pages {
        model.setPage(page)
        try await settle()
        try await captureHostingWindow(window, to: output.appendingPathComponent("\(mode.rawValue)-\(page).png")); captures += 1
      }
    }
    let nativeSidebar = descendants(host).compactMap { $0 as? NSVisualEffectView }.contains { $0.material == .sidebar }
    if #available(macOS 27, *), !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency, !nativeSidebar {
      throw GitPierError.invalidInput("The primary sidebar did not install its native material")
    }
    settings.appearance = .system; store.updateSettings(settings); try await settle()
    guard model.record.favorite && window.appearance == nil else {
      throw GitPierError.invalidInput("Following system appearance or preserved favorite failed")
    }
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      store.showDashboard = false
      model.setPage("commit")
      let ticket = model.activity.begin("Reduce Motion fixture", kind: .fetch)
      model.activity.markExecuting()
      func indicators() -> [NSProgressIndicator] {
        descendants(host).compactMap { $0 as? NSProgressIndicator }.filter {
          $0.accessibilityLabel() == localizedUI("Git operation progress")
        }
      }
      try await settle()
      guard workflowAccessibilityText(host).contains("Reduce Motion fixture"), indicators().isEmpty else {
        throw GitPierError.invalidInput("Reduce Motion did not show a static indeterminate step")
      }
      model.activity.receiver()(GitTransferProgress(phase: .receiving, fraction: 0.42))
      try await waitFor {
        indicators().contains { !$0.isIndeterminate && abs($0.doubleValue - 0.42) < 0.001 }
      }
      model.activity.finish(.succeeded, ticket: ticket)
      try Data("Reduce Motion uses a static indeterminate step and still shows determinate transfer progress.\n".utf8)
        .write(to: output.appendingPathComponent("reduce-motion-results.txt"))
    }
    try Data("\(captures) WindowServer images; dark compact ZH and light wide EN; system appearance and favorite preserved; native sidebar material: \(nativeSidebar).\n".utf8)
      .write(to: output.appendingPathComponent("phase-d-results.txt"))
  }

  static func verifyNativeExperienceC(store: AppStore, model: RepositoryModel, root: URL, window: NSWindow, output: URL) async throws {
    guard root.deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui."), let host = window.contentView else {
      throw GitPierError.invalidInput("Phase C requires the disposable acceptance workspace")
    }
    let git = await model.git()
    var settings = store.settings
    settings.language = .english; settings.automaticFetch = false; settings.completionNotifications = false
    store.updateSettings(settings)
    let before = try await git.snapshot()
    model.setPage("repository")
    NSApp.setActivationPolicy(.regular)
    window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    do {
      try await waitFor { assistantFind(host, id: "gitpier.repository.authentication.test") != nil }
      if let button = assistantFind(host, id: "gitpier.repository.authentication.test") { try assistantPress(button) }
      try await waitFor { workflowAccessibilityText(host).contains("Remote references are readable") }
    } catch {
      try workflowAccessibilityText(host).write(to: output.appendingPathComponent("accessibility-failure.txt"), atomically: true, encoding: .utf8)
      throw error
    }
    guard workflowAccessibilityText(host).contains("No GitPier credential is required") else {
      throw GitPierError.invalidInput("System credentials route did not explain that a separate profile is optional")
    }
    try capture(host, to: output.appendingPathComponent("system-connection.png"))
    model.record.credentialID = UUID()
    store.update(model.record)
    model.network("fetch")
    try await waitFor { !model.busy }
    let after = try await git.snapshot()
    guard model.error?.contains("Authentication configuration changed") == true,
      store.operations.records.first(where: { $0.kind == .fetch })?.state == .failed,
      !FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/FETCH_HEAD").path), before == after else {
      throw GitPierError.invalidInput("A missing profile must fail Fetch without falling back to an earlier or system credential")
    }
    model.error = nil
    try await settle()
    guard workflowAccessibilityText(host).contains("The selected profile is missing") else {
      throw GitPierError.invalidInput("The repository does not explain the missing credential")
    }
    try capture(host, to: output.appendingPathComponent("missing-credential.png"))
    let firstKey = root.deletingLastPathComponent().appendingPathComponent("terminal-identity-a")
    let secondKey = root.deletingLastPathComponent().appendingPathComponent("terminal-identity-b")
    try Data().write(to: firstKey)
    try Data().write(to: secondKey)
    let first = CredentialProfile(name: "First SSH profile", host: "example.invalid", kind: .ssh, identityPath: firstKey.path)
    let second = CredentialProfile(name: "Second SSH profile", host: "example.invalid", kind: .ssh, identityPath: secondKey.path)
    store.configuration.credentials = [first, second]
    model.record.credentialID = nil
    model.record.useDefaultCredential = true
    store.update(model.record)
    func verifyTerminalRebinding(_ location: String) async throws {
      settings.defaultCredentialID = first.id
      store.updateSettings(settings)
      guard await model.configure() else { throw GitPierError.invalidInput("Could not configure the first terminal identity") }
      defer {
        model.cancel()
        for session in model.terminal.sessions { model.terminal.close(session.id) }
      }
      model.terminal.add(settings: store.settings)
      guard let previous = model.terminal.sessions.last,
        previous.authentication?.environment["GITPIER_SSH_IDENTITY"] == firstKey.path else {
        throw GitPierError.invalidInput("The first terminal did not inherit the initial identity: " + location)
      }
      model.run { _ in try await Task.sleep(for: .seconds(12)) }
      settings.defaultCredentialID = second.id
      store.updateSettings(settings)
      model.terminal.add(settings: store.settings)
      guard model.busy, let next = model.terminal.sessions.last, next.id != previous.id,
        next.authentication?.environment["GITPIER_SSH_IDENTITY"] == secondKey.path,
        previous.authentication?.environment["GITPIER_SSH_IDENTITY"] == firstKey.path else {
        throw GitPierError.invalidInput("A new terminal inherited the previous SSH identity after changing the default during Git work: " + location)
      }
      let count = model.terminal.sessions.count
      settings.defaultCredentialID = UUID()
      store.updateSettings(settings)
      model.terminal.add(settings: store.settings)
      guard model.terminal.sessions.count == count else {
        throw GitPierError.invalidInput("A terminal started with a missing configured identity: " + location)
      }
      model.cancel()
      try await waitFor { !model.busy }
    }
    try await verifyTerminalRebinding("initial worktree")
    let relocated = root.deletingLastPathComponent().appendingPathComponent("relocated terminal worktree")
    try await git.perform(["worktree", "add", "--detach", relocated.path, "HEAD"])
    await model.relocateWorktree(to: relocated.path)
    try await verifyTerminalRebinding("relocated worktree")
    try Data("Phase C passed: read-only system connection, missing profile fails closed before Fetch, local state preserved, and a new terminal uses the changed default or rejects a missing profile before and after relocation.\n".utf8)
      .write(to: output.appendingPathComponent("phase-c-results.txt"))
  }

  static func verifyNativeExperienceB(store: AppStore, model: RepositoryModel, root: URL, window: NSWindow, output: URL) async throws {
    guard root.deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui."), let host = window.contentView else {
      throw GitPierError.invalidInput("Phase B requires the disposable acceptance workspace")
    }
    func check(_ passes: Bool, _ subject: String) throws {
      if !passes { throw GitPierError.invalidInput("Phase B: \(subject)") }
    }
    var settings = store.settings
    settings.automaticFetch = false
    settings.completionNotifications = false
    settings.language = .english
    store.updateSettings(settings)
    let git = await model.git()
    let previous = try await git.snapshot()
    let draft = "  fix:   polish feedback  \nThis description stays intact. "
    let formatted = "fix: polish feedback\n\nThis description stays intact."
    let file = root.appendingPathComponent("phase-b.txt")
    try Data("a local test commit\n".utf8).write(to: file)
    await model.refresh()
    if !model.includedPaths.contains("phase-b.txt") {
      model.toggleIncluded(model.status.files.filter { $0.path == "phase-b.txt" })
    }
    model.editDraft(draft)
    model.commit(push: true)
    try check(model.confirmation?.messageReview?.proposed == formatted && model.confirmation?.messageReview?.useOriginal != nil,
      "review shows proposed text and offers original")
    try await settle()
    if let sheet = window.attachedSheet?.contentView { try capture(sheet, to: output.appendingPathComponent("format-review.png")) }
    model.confirmation = nil
    let afterCancel = try await git.snapshot()
    try check(model.record.draft == draft && afterCancel == previous, "cancelling formatting review preserves draft and repository")
    try await settle()
    model.commit(push: true)
    let reviewed = model.confirmation
    model.confirmation = nil
    reviewed?.performConfirmedAction()
    try check(model.busy && !model.canCommit && model.activity.state?.workflow.current == .prepare,
      "preparation is visible immediately and blocks duplicate submissions")
    let operationID = model.activity.ticket.id
    model.commit(push: true)
    try await waitFor { !model.busy }
    guard let result = store.operations.records.first(where: { $0.id == operationID }), let head = result.localCommit else {
      throw GitPierError.invalidInput("Phase B: expected saved commit result")
    }
    let actual = try await git.history(count: 1).first
    let remote = try await git.read(["ls-remote", "--", "origin", "refs/heads/main"]).text
    try check(result.state == .succeeded && result.workflow?.outcome == .succeeded
      && result.workflow?.steps.allSatisfy({ $0.state == .completed }) == true
      && result.workflow?.id == operationID && model.operationFeedbackID == operationID, "same operation owns every completed step and visible result")
    try check(actual?.hash == head && actual?.subject == "fix: polish feedback" && actual?.body.contains("This description stays intact.") == true
      && actual?.parents == [previous.head].compactMap { $0 } && remote.hasPrefix(head + "\t"),
      "Git and the remote contain exactly one reviewed commit")
    try await settle()
    try capture(host, to: output.appendingPathComponent("commit-push-success.png"))
    guard let checkpoint = result.pushCheckpoint else { throw GitPierError.invalidInput("Phase B: missing real Push checkpoint") }
    // Exercise immediate readback while the same footer is still onscreen. The real local remote
    // already contains the saved commit; no second Git write is needed to resolve the record.
    let recovery = model.activity.begin("Fixture Push", kind: .push)
    model.activity.markExecuting()
    model.activity.recordLocalCommit(head)
    model.activity.recordPushCheckpoint(checkpoint)
    model.activity.finish(.resultUnknown, ticket: recovery)
    guard let unverified = store.operations.records.first(where: { $0.id == recovery.id }) else {
      throw GitPierError.invalidInput("Phase B: missing unknown result for readback")
    }
    await store.operations.verifyPush(unverified, store: store)
    let reconciled = store.operations.records.first { $0.id == recovery.id }
    try check(reconciled?.state == .succeeded && reconciled?.verifiedAt != nil, "real remote proves the saved commit")
    try check(model.activity.state?.result == .succeeded && model.activity.state?.workflow == reconciled?.workflow,
      "authoritative readback updates the matching visible footer immediately")

    for kind in [WorkflowOperationKind.push, .mergeAndPush] {
      model.run(label: "Readback fixture", kind: kind) { _ in
        model.activity.recordLocalCommit(head)
        model.activity.recordPushCheckpoint(checkpoint)
        model.output = "Push result unverified"
        model.outputResult = .resultUnknown
      }
      let ticket = model.activity.ticket
      try await waitFor { !model.busy }
      guard let operation = store.operations.records.first(where: { $0.id == ticket.id }) else {
        throw GitPierError.invalidInput("Phase B: expected an operation for the workspace readback")
      }
      await store.operations.verifyPush(operation, store: store)
      try check(store.operations.records.first(where: { $0.id == ticket.id })?.verifiedAt != nil
        && model.operationFeedbackID == ticket.id && model.activity.state?.result == .succeeded,
        "verified \(kind.rawValue) must update both the workspace banner and the footer")
    }

    try Data("saved commit before authentication failure\n".utf8).write(to: root.appendingPathComponent("phase-b-retry.txt"))
    model.record.credentialID = UUID()
    store.update(model.record)
    await model.refresh()
    if !model.includedPaths.contains("phase-b-retry.txt") {
      model.toggleIncluded(model.status.files.filter { $0.path == "phase-b-retry.txt" })
    }
    model.editDraft("test: save commit before Push preflight")
    model.commit(push: true)
    let failedID = model.activity.ticket.id
    try await waitFor { !model.busy }
    guard let preflight = store.operations.records.first(where: { $0.id == failedID }), preflight.state == .failed,
      preflight.pushCheckpoint == nil, let saved = preflight.localCommit, saved != head else {
      throw GitPierError.invalidInput("Phase B: expected a saved commit and failed authentication before the Push checkpoint")
    }
    model.record.credentialID = nil
    store.update(model.record)
    _ = await model.configure()
    _ = try await git.perform(["commit", "--amend", "--no-gpg-sign", "-m", "External fixture amendment"])
    await model.refresh()
    try check(model.status.head != saved && model.status.head != head, "fixture externally changed the saved HEAD")
    model.error = nil
    model.retryPush()
    try await waitFor { model.error != nil || model.confirmation != nil || model.busy }
    try await waitFor { !model.busy }
    let afterRetry = try await git.read(["ls-remote", "--", "origin", "refs/heads/main"]).text
    try check(model.confirmation == nil && model.error != nil && afterRetry.hasPrefix(head + "\t"),
      "uncheckpointed Retry Push cannot publish an external amendment")

    // Restore only the disposable source so the next case can isolate a destination change after review.
    try await git.perform(["reset", "--hard", saved])
    await model.refresh()
    model.error = nil
    model.retryPush()
    try await waitFor { model.confirmation != nil || model.error != nil }
    guard let approved = model.confirmation else {
      throw GitPierError.invalidInput("Phase B: exact saved commit should offer a destination review")
    }
    let originalRemote = root.deletingLastPathComponent().appendingPathComponent("remote.git")
    let alternateRemote = root.deletingLastPathComponent().appendingPathComponent("alternate push target.git")
    try await git.perform(["clone", "--bare", "--", originalRemote.path, alternateRemote.path])
    try await git.perform(["remote", "set-url", "--push", "origin", alternateRemote.path])
    model.confirmation = nil
    approved.performConfirmedAction()
    try await waitFor { !model.busy }
    let alternate = GitService(root: alternateRemote)
    let firstAttempt = try await alternate.read(["rev-parse", "refs/heads/main"]).text.trimmingCharacters(in: .newlines)
    try check(firstAttempt == head && model.error != nil, "the approved checkpoint rejects the changed Push URL")
    model.error = nil
    model.retryPush()
    try await waitFor { model.confirmation != nil || model.error != nil || model.busy || store.showOperationsCenter }
    if let second = model.confirmation {
      model.confirmation = nil
      second.performConfirmedAction()
    }
    try await waitFor { !model.busy }
    let secondAttempt = try await alternate.read(["rev-parse", "refs/heads/main"]).text.trimmingCharacters(in: .newlines)
    try check(secondAttempt == head, "a second Retry Push cannot bypass the rejected checkpoint and publish to a different repository")
    try check(approved.detail.contains(originalRemote.lastPathComponent), "the confirmation shows the effective Push endpoint and not just its alias")
    try Data("Phase B passed: format review/cancel, exact Git result, duplicate prevention, single workflow, verified Push feedback and recovery bound to the saved commit and reviewed destination across repeated attempts.\n".utf8)
      .write(to: output.appendingPathComponent("phase-b-results.txt"))
  }

  static func verifyNativeExperienceA(store: AppStore, root: URL, output: URL) async throws {
    let fixture = root.deletingLastPathComponent()
    guard fixture.lastPathComponent.hasPrefix("GitPier-ui.") else {
      throw GitPierError.invalidInput("Phase A requires the disposable acceptance workspace")
    }
    func check(_ passes: Bool, _ subject: String) throws {
      if !passes { throw GitPierError.invalidInput("Phase A: \(subject)") }
    }
    let id = UUID()
    var settings = AppSettings()
    settings.language = .english
    func request(_ result: OperationResult = .succeeded, foreground: Bool = false, kind: WorkflowOperationKind = .commitAndPush) -> UNNotificationRequest? {
      CompletionNotifications.request(id: id, kind: kind, result: result, operation: "Commit & Push",
        repository: "Test Repository", localCommit: "eaac43cd1290", settings: settings, foreground: foreground)
    }
    try check(request() == nil, "master switch off")
    settings.completionNotifications = true
    let sound = request()
    try check(sound?.content.sound == .default && sound?.identifier == id.uuidString, "default system sound and stable operation identifier")
    try check(request(foreground: true) == nil && request(kind: .automaticFetch) == nil && request(.running) == nil, "suppress foreground, automatic fetch and running notifications")
    settings.completionNotificationSound = false
    let muted = request(.resultUnknown)
    try check(muted != nil && muted?.content.sound == nil && muted?.content.subtitle.contains("Push result unknown") == true,
      "muted unknown still delivers a request with truthful partial status")
    try check(request(.failed)?.content.subtitle.contains("Push failed") == true && request(.needsAttention)?.content.body.contains("eaac43cd") == true,
      "distinct partial outcome and reviewed commit hash")

    let fm = FileManager.default
    let repo = fixture.appendingPathComponent("linked worktree #1", isDirectory: true)
    try await GitService(root: root).perform(["worktree", "add", "--detach", repo.path, "HEAD"])
    let alias = fixture.appendingPathComponent("alias to worktree")
    try fm.createSymbolicLink(at: alias, withDestinationURL: repo)
    let link = repo.appendingPathComponent("missing target link")
    try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "not-created")
    let folderLocation = try FinderLocation.repository(repo.path)
    let aliasLocation = try FinderLocation.repository(alias.path)
    let fileLocation = try FinderLocation.file("README.md", in: repo.path)
    let symlinkLocation = try FinderLocation.file(link.lastPathComponent, in: repo.path)
    try check(folderLocation == .openFolder(repo) && aliasLocation == .openFolder(URL(fileURLWithPath: alias.path, isDirectory: true)), "open the exact repository or symbolic-link directory")
    try check(fileLocation == .selectFile(repo.appendingPathComponent("README.md")) && symlinkLocation == .selectFile(link), "select the exact file or dangling link")
    try check((try? FinderLocation.repository(repo.appendingPathComponent("missing").path)) == nil
      && (try? FinderLocation.file("missing", in: repo.path)) == nil, "reject missing Finder locations")

    if ProcessInfo.processInfo.environment["GITPIER_NATIVE_FINDER_PROBE"] == "1" {
      // Manual or automation observation only. Do not read other Finder windows or change its preferences.
      func waitForMarker(_ name: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while !fm.fileExists(atPath: output.appendingPathComponent(name).path) {
          guard ContinuousClock.now < deadline else { throw GitPierError.invalidInput("Finder observation timed out") }
          try await Task.sleep(for: .milliseconds(150))
        }
      }
      folderLocation.show { error in store.error = error.localizedDescription }
      try repo.path.write(to: output.appendingPathComponent("finder-folder-ready.txt"), atomically: true, encoding: .utf8)
      try await waitForMarker("finder-folder-observed")
      try check(store.error == nil, "Launch Services accepted the folder open")
      fileLocation.show { error in store.error = error.localizedDescription }
      try repo.appendingPathComponent("README.md").path.write(to: output.appendingPathComponent("finder-file-ready.txt"), atomically: true, encoding: .utf8)
      try await waitForMarker("finder-file-observed")
    }

    if let packagedDefault = Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool {
      let sparkID = "com.heisenberg2024.gitpier.update-test.phase-a.\(id.uuidString.lowercased())"
      let app = fixture.appendingPathComponent("Preference Probe.app")
      try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
      let info: [String: Any] = ["CFBundleIdentifier": sparkID, "CFBundlePackageType": "APPL", "SUEnableAutomaticChecks": packagedDefault,
        "SUAutomaticallyUpdate": false, "SUAllowsAutomaticUpdates": false]
      try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
      guard let bundle = Bundle(url: app) else { throw GitPierError.invalidInput("Could not load Sparkle preference probe bundle") }
      defer { UserDefaults.standard.removePersistentDomain(forName: sparkID) }
      func makeUpdater() -> SPUUpdater {
        SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: SPUStandardUserDriver(hostBundle: bundle, delegate: nil), delegate: nil)
      }
      // Read the actual Sparkle setting without starting its scheduler or any network check.
      let initial = makeUpdater()
      try check(initial.automaticallyChecksForUpdates && !initial.automaticallyDownloadsUpdates, "new Sparkle domain enables checks only")
      initial.automaticallyChecksForUpdates = false
      try check(!makeUpdater().automaticallyChecksForUpdates, "explicit saved Sparkle opt-out overrides the bundle")
    }

    settings.appearance = .dark
    settings.diffFont = store.settings.diffFont
    settings.diffFontSize = 17
    store.updateSettings(settings)
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 660),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    defer { window.close() }
    for (tab, name) in [(0, "general"), (1, "appearance"), (4, "diff")] {
      host.rootView = AnyView(SettingsView(initialTab: tab).id(tab).environmentObject(store).modifier(AppAppearance(store: store)))
      try await settle()
      try capture(host, to: output.appendingPathComponent("settings-\(name).png"))
    }
    try check(store.settings.diffFontSize == 17, "opening settings does not modify the existing Diff size")
    try Data("Phase A passed. Sparkle packaged preference probe: \(Bundle.main.bundleURL.pathExtension == "app").\n".utf8)
      .write(to: output.appendingPathComponent("phase-a-results.txt"))
  }
}
#endif
