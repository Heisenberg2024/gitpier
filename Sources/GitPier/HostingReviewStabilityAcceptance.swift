import AppKit
import GitPierCore
import SwiftUI

/// Synthetic transport deliberately returns a completed receipt after cancellation.
/// This exercises the real session/model/coordinator boundary without contacting a service.
private actor ReviewStabilityTransport: HostingTransport {
  let sha = String(repeating: "a", count: 40)
  private var gate: CheckedContinuation<Void, Never>?
  private var writes = 0
  private var saved = ""
  func held() -> Bool { gate != nil }
  func count() -> Int { writes }
  func release() { gate?.resume(); gate = nil }
  func send(_ request: URLRequest, limit: Int) async throws -> HostingHTTPResponse {
    guard request.url?.host == "api.github.com" else { throw HostingError.invalidInstance }
    let path = request.url!.path
    func response(_ object: Any) throws -> HostingHTTPResponse { HostingHTTPResponse(data: try JSONSerialization.data(withJSONObject: object)) }
    if request.httpMethod == "POST" {
      guard path.hasSuffix("/issues/17/comments") else { throw HostingError.invalidResponse }
      writes += 1
      saved = (try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["body"] as? String ?? ""
      await withCheckedContinuation { gate = $0 }
      return try response(["id": 7001, "body": saved, "user": ["id": 42], "created_at": "2026-10-18T00:00:00Z"])
    }
    if path.hasSuffix("/example/stability") { return try response(["id": 100, "private": false]) }
    if path.hasSuffix("/pulls/17") {
      return try response(["id": 200, "number": 17, "title": "Review stability fixture", "state": "open", "user": ["id": 99],
        "head": ["sha": sha, "ref": "fixture", "repo": ["full_name": "example/stability"]],
        "base": ["sha": String(repeating: "b", count: 40), "ref": "main", "repo": ["id": 100]],
        "html_url": "https://github.com/example/stability/pull/17"])
    }
    if path.hasSuffix("/issues/comments/7001") { return try response(["id": 7001, "body": saved, "user": ["id": 42]]) }
    if path.hasSuffix("/reviews") || path.hasSuffix("/comments") || path.hasSuffix("/files") { return try response([]) }
    throw HostingError.notFound
  }
}

private actor ReviewStabilityBatch {
  private var calls = 0
  func send(userID: String) throws -> HostingReviewReceipt {
    calls += 1
    if calls == 3 { throw HostingError.networkFailure }
    return HostingReviewReceipt(id: String(8000 + calls), authorID: userID)
  }
  func count() -> Int { calls }
}

extension UIAcceptance {
  static func verifyHostingReviewStability(root: URL, output: URL) async throws {
    guard root.resolvingSymlinksInPath().deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui.") else { throw HostingError.invalidInstance }
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-review-stability-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let persistence = ConfigurationStore(url: fixture.appendingPathComponent("workspace.json"))
    var config = WorkspaceConfiguration(); config.settings.completionNotifications = false; try persistence.save(config)
    let store = AppStore(persistence: persistence), transport = ReviewStabilityTransport(), vault = HostingAcceptanceVault()
    defer { store.shutdown() }
    let instance = try HostingInstance(provider: .github, url: "https://github.com")
    let account = HostingAccount(instance: instance, user: HostingUser(stableID: "42", login: "stability-a"), kind: .pat, scopes: ["public_repo"], storageMode: .localVault)
    let other = HostingAccount(instance: instance, user: HostingUser(stableID: "43", login: "stability-b"), kind: .pat, scopes: ["public_repo"], storageMode: .localVault)
    let binding = try RepositoryHostingBinding(repositoryID: UUID(), accountID: account.id, remote: "origin", repository: "example/stability")
    let otherBinding = try RepositoryHostingBinding(repositoryID: UUID(), accountID: other.id, remote: "origin", repository: "example/stability")
    var metadata = HostingMetadata(); metadata.accounts = [account, other]; metadata.bindings = [binding, otherBinding]
    try HostingMetadataStore(url: fixture.appendingPathComponent("workspace.hosting.json")).save(metadata)
    let token = HostingToken(accessToken: "synthetic-stability-only", scopes: ["public_repo"])
    try await vault.save(token, account: account); try await vault.save(token, account: other)
    let hosting = HostingModel(store: store, http: HostingHTTPClient(transport: transport), vault: vault, openExternalURL: { _ in false }); store.hosting = hosting
    let request = try await hosting.api.request(binding, number: 17, account: account, token: token)
    let session = store.reviewSessions.session(hosting: hosting, binding: binding, account: account, request: request)
    let otherSession = store.reviewSessions.session(hosting: hosting, binding: otherBinding, account: other, request: request)
    session.start(loadTimeline: false); otherSession.start(loadTimeline: false)
    try await waitFor { session.context != nil && otherSession.context != nil }
    func require(_ value: Bool, _ message: String) throws { guard value else { throw GitPierError.invalidInput(message) } }
    // Five independent writes: two verified, one ambiguous and two unsent, never an atomic batch.
    let original = try XCTHostingUnwrap(session.context)
    let target = HostingReviewTarget(instance: instance, accountID: account.id, userID: "42", repository: "example/stability", repositoryID: "100", requestNumber: 18, requestID: "201")
    let context = HostingReviewContext(target: target, revision: original.revision, capabilities: [.generalComment], state: "open", authorID: "99")
    let partial = try HostingReviewConfirmation(context: context, items: (1...5).map { HostingReviewSubmissionItem(mutation: .comment(body: "Synthetic partial \($0)")) })
    let batch = ReviewStabilityBatch()
    let partialReport = try await store.reviewSessions.coordinator.submit(partial, current: { context }, validate: {}, validateAnchor: { _ in },
      send: { _, _ in try await batch.send(userID: "42") }, readback: { receipt, _, _ in receipt })
    let batchCalls = await batch.count()
    try require(partialReport.submittedCount == 2 && partialReport.hasUnknown && batchCalls == 3, "Partial submission did not stop after the uncertain item")

    var windows: [NSWindow] = []
    func show<V: View>(_ view: V, size: NSSize = NSSize(width: 960, height: 640)) -> NSWindow {
      let host = NSHostingView(rootView: view); host.sizingOptions = []; host.autoresizingMask = [.width, .height]
      let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); windows.append(window)
      return window
    }
    defer { for window in windows { window.close() } }
    let a = show(HostingReviewView(session: session).environmentObject(store).padding())
    let b = show(HostingReviewView(session: session).environmentObject(store).padding())
    try require(store.reviewSessions.session(hosting: hosting, binding: binding, account: account, request: request) === session, "Two windows did not share one review session")
    otherSession.begin(.comment); otherSession.composerBody = "Other account draft survives"
    session.begin(.comment); session.composerBody = "Synthetic body must not enter the journal"
    session.prepareComposer()
    let snapshot = try XCTHostingUnwrap(session.confirmation)
    session.submit(snapshot)
    let sendDeadline = Date().addingTimeInterval(10)
    while !(await transport.held()), Date() < sendDeadline { try await Task.sleep(for: .milliseconds(30)) }
    try require(await transport.held(), "Synthetic POST did not reach the transport")
    do { try await hosting.disconnect(account); throw GitPierError.invalidInput("Disconnect silently discarded active review work") }
    catch HostingError.operationInProgress {}
    try require(session.hasPrivateDraftContent && hosting.account(account.id) != nil, "Cancelled disconnect lost its draft/account")
    try await captureHostingWindow(a, to: output.appendingPathComponent("stability-two-windows-sending.png"))
    try await hosting.disconnect(account, discardReviewWork: true)
    try require(!session.hasPrivateDraftContent && session.disconnected && !session.identityValid && !session.canCompose,
      "Confirmed disconnect did not clear and revoke all shared review state")
    try require(otherSession.composerBody == "Other account draft survives" && otherSession.identityValid, "Disconnect affected the other account")
    await transport.release()
    try await waitFor { !session.submitting }
    await store.reviewSessions.refreshRecovery()
    let disconnectedUnknown = try XCTHostingUnwrap(store.reviewSessions.recoveredOperations.first(where: { $0.isUnresolved && $0.identity.requestID == "200" }))
    try require(disconnectedUnknown.receipt?.id == "7001" && !session.hasPrivateDraftContent && session.report == nil,
      "Late completed receipt was lost or repopulated a disconnected session")
    let retainedAttempt = await store.reviewSessions.coordinator.report(snapshot.id)
    let retainedPartial = await store.reviewSessions.coordinator.report(partial.id)
    try require(retainedAttempt == nil && retainedPartial == nil,
      "The coordinator retained or restored private report payloads after disconnect")
    try require(await transport.count() == 1, "Disconnect/recovery repeated the POST")
    try await captureHostingWindow(b, to: output.appendingPathComponent("stability-disconnected-late-result.png"))

    a.close(); b.close(); store.shutdown()

    // Reconnection keeps the remote user but gets a new local UUID. Seed only
    // synthetic connection metadata; no OAuth grant or real account is involved.
    let reconnected = HostingAccount(instance: instance, user: account.user, kind: .pat, scopes: ["public_repo"], storageMode: .localVault)
    let reconnectedBinding = try RepositoryHostingBinding(repositoryID: UUID(), accountID: reconnected.id, remote: "origin", repository: "example/stability")
    let metadataStore = HostingMetadataStore(url: fixture.appendingPathComponent("workspace.hosting.json"))
    var reconnectedMetadata = try metadataStore.load()
    reconnectedMetadata.accounts.append(reconnected); reconnectedMetadata.bindings.append(reconnectedBinding)
    try metadataStore.save(reconnectedMetadata); try await vault.save(token, account: reconnected)
    let restarted = AppStore(persistence: persistence); defer { restarted.shutdown() }
    let restartedHosting = HostingModel(store: restarted, http: HostingHTTPClient(transport: transport), vault: vault, openExternalURL: { _ in false }); restarted.hosting = restartedHosting
    await restarted.reviewSessions.refreshRecovery()
    try await waitFor { restarted.reviewSessions.recoveredOperations.count == 6 || restarted.reviewSessions.recoveryError != nil }
    try require(restarted.reviewSessions.unresolvedOperations.count == 2 && restarted.reviewSessions.sessions.isEmpty,
      "Restart did not recover minimal unknowns or invented restored drafts")
    try require(restartedHosting.account(account.id) == nil && restartedHosting.account(other.id) != nil, "Restart resurrected the disconnected account")
    let reconnectedSession = restarted.reviewSessions.session(hosting: restartedHosting, binding: reconnectedBinding, account: reconnected, request: request)
    reconnectedSession.start(loadTimeline: false)
    try await waitFor { reconnectedSession.context != nil && reconnectedSession.targetBlocked }
    try require(!reconnectedSession.canCompose && !reconnectedSession.hasPrivateDraftContent,
      "A new local UUID bypassed the same remote user's unresolved write or restored a draft")
    let reconnectWindow = show(HostingReviewView(session: reconnectedSession).environmentObject(restarted).padding())
    try await captureHostingWindow(reconnectWindow, to: output.appendingPathComponent("stability-reconnected-unknown-block.png"))
    let rows = restarted.reviewSessions.recoveredOperations.filter { $0.confirmationID == partial.id }
    try require(rows.map(\.state) == [.submittedAndVerified, .submittedAndVerified, .resultUnknown, .notSent, .notSent], "Restart lost per-item partial outcomes")
    let panel = show(HostingReviewRecoveryView(registry: restarted.reviewSessions, hosting: restartedHosting).environmentObject(restarted))
    var screenshots = 3
    for language in [AppLanguage.english, .simplifiedChinese] {
      for appearance in [AppearanceMode.light, .dark] {
        var settings = restarted.settings; settings.language = language; settings.appearance = appearance; restarted.updateSettings(settings)
        panel.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        for size in [NSSize(width: 960, height: 640), NSSize(width: 1440, height: 900), NSSize(width: 1800, height: 1100)] {
          panel.setContentSize(size); try await settle()
          try await captureHostingWindow(panel, to: output.appendingPathComponent("stability-restart-\(language.rawValue)-\(appearance.rawValue)-\(Int(size.width)).png")); screenshots += 1
        }
      }
    }
    var english = restarted.settings; english.language = .english; restarted.updateSettings(english)
    panel.setContentSize(NSSize(width: 960, height: 640)); try await settle()
    func press(_ title: String, sheet: Bool = false) async throws {
      guard let target = sheet ? panel.sheets.last : panel, let content = target.contentView else {
        throw GitPierError.invalidInput("Recovery confirmation window missing: " + title)
      }
      NSApp.activate(ignoringOtherApps: true); target.makeKeyAndOrderFront(nil); try await settle()
      let deadline = Date().addingTimeInterval(8)
      var found: NSObject?
      while Date() < deadline {
        content.layoutSubtreeIfNeeded()
        found = accessibleButton(content, title: title, enabled: true)
        if found != nil { break }
        try await Task.sleep(for: .milliseconds(50))
      }
      guard let button = found else {
        try await captureHostingWindow(target, to: output.appendingPathComponent("stability-control-failure.png"))
        let buttons = descendants(content).compactMap { $0 as? NSButton }.map(\.title)
        try JSONSerialization.data(withJSONObject: ["requestedControl": title, "sheet": sheet, "nativeButtons": buttons], options: [.prettyPrinted]).write(to: output.appendingPathComponent("stability-control-failure.json"))
        throw GitPierError.invalidInput("Recovery acceptance control unavailable: " + title + " (sheet: \(sheet))")
      }
      let selector = NSSelectorFromString("accessibilityPerformPress")
      typealias Press = @convention(c) (AnyObject, Selector) -> Bool
      _ = unsafeBitCast(button.method(for: selector), to: Press.self)(button, selector)
    }
    // Cancellation of the second confirmation leaves the journal and barrier intact.
    try await press("I Checked the Platform…")
    try await waitFor { !panel.sheets.isEmpty }
    try await press("Cancel", sheet: true)
    try await waitFor { panel.sheets.isEmpty }
    try require(restarted.reviewSessions.unresolvedOperations.count == 2, "Cancelling manual acknowledgement changed the journal")
    try await press("I Checked the Platform…")
    try await waitFor { !panel.sheets.isEmpty }
    try await press("I Checked the Platform", sheet: true)
    try await waitFor { panel.sheets.isEmpty && restarted.reviewSessions.unresolvedOperations.count == 1 }
    try require(await transport.count() == 1, "Manual acknowledgement resent a write")
    let bad = restarted.reviewSessions.journalURL.appendingPathComponent("unexpected-file.json")
    let badData = Data("preserve corrupt fixture".utf8); try badData.write(to: bad)
    await restarted.reviewSessions.refreshRecovery()
    try require(restarted.reviewSessions.recoveryError != nil && (try Data(contentsOf: bad)) == badData, "Corrupt journal was hidden or overwritten")
    try await captureHostingWindow(panel, to: output.appendingPathComponent("stability-corrupt-journal.png")); screenshots += 1
    try FileManager.default.removeItem(at: bad)
    await restarted.reviewSessions.refreshRecovery()
    try require(restarted.reviewSessions.recoveryError == nil, "Repairing the isolated journal did not allow reloading")
    let result: [String: Any] = ["synthetic_http_only": true, "real_service_verified": false, "screenshots": screenshots,
      "shared_multiwindow_session": true, "disconnect_cancel_preserved_draft": true, "disconnect_other_account_preserved": true,
      "late_receipt_retained": true, "late_private_state_rejected": true, "coordinator_private_reports_discarded": true,
      "reconnected_same_remote_user_blocked": true, "restart_unknowns": 2,
      "partial_states": rows.map { $0.state.rawValue }, "manual_ack_cancel_preserved": true, "manual_ack_did_not_retry": true,
      "corrupt_original_preserved": true, "synthetic_transport_writes": await transport.count()]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("stability-results.json"))
  }
}
