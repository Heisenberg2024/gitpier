import AppKit
import GitPierCore
import SwiftUI

/// Synthetic hosting stores only. This fixture never queries a production Keychain service.
private actor HostingDisconnectAcceptanceVault: HostingCredentialStore {
  private var values: [UUID: HostingToken] = [:]
  private var denied = false
  private var reads = 0
  func deny(_ value: Bool) { denied = value }
  func readCount() -> Int { reads }
  func read(account: HostingAccount) throws -> HostingToken? {
    reads += 1; if denied { throw HostingError.keychainDenied }; return values[account.id]
  }
  func save(_ token: HostingToken, account: HostingAccount) throws {
    if denied { throw HostingError.keychainDenied }; values[account.id] = token
  }
  func delete(account: HostingAccount) throws {
    if denied { throw HostingError.keychainDenied }; values[account.id] = nil
  }
}

private actor HostingDisconnectAcceptanceTransport: HostingTransport {
  let base = HostingAcceptanceTransport(sha: String(repeating: "a", count: 40))
  var holdUser = false
  var holdOther = false
  var userGate: CheckedContinuation<Void, Never>?
  var waitingOther = 0
  var cancelledOther = 0
  func hold() { holdUser = true; holdOther = true }
  func blocked() -> Bool { userGate != nil && waitingOther >= 2 }
  func release() { holdUser = false; holdOther = false; userGate?.resume(); userGate = nil }
  func cancellations() -> Int { cancelledOther }
  func send(_ request: URLRequest, limit: Int) async throws -> HostingHTTPResponse {
    if request.url?.path.hasSuffix("/user") == true, holdUser {
      // Deliberately ignore cancellation to prove a late platform response cannot restore login.
      await withCheckedContinuation { userGate = $0 }
    } else if holdOther {
      waitingOther += 1
      do { try await Task.sleep(for: .seconds(60)) }
      catch { cancelledOther += 1; throw error }
    }
    return try await base.send(request, limit: limit)
  }
}

extension UIAcceptance {
  static func verifyHostingDisconnect(root: URL, output: URL) async throws {
    guard root.resolvingSymlinksInPath().deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui.") else { throw HostingError.invalidInstance }
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-hosting-disconnect-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let configurationStore = ConfigurationStore(url: fixture.appendingPathComponent("workspace.json"))
    var workspace = WorkspaceConfiguration(); workspace.settings.completionNotifications = false; try configurationStore.save(workspace)
    let store = AppStore(persistence: configurationStore); defer { store.shutdown() }
    let transport = HostingDisconnectAcceptanceTransport(), keychain = HostingDisconnectAcceptanceVault()
    let http = HostingHTTPClient(transport: transport)
    let local = LocalEncryptedCredentialStore(root: fixture.appendingPathComponent("HostingCredentials"))
    let router = HostingCredentialRouter(local: local, keychain: keychain)
    let instance = try HostingInstance(provider: .gitlab, url: "https://gitlab.example.invalid")
    let original = HostingAccount(instance: instance, user: HostingUser(stableID: "51", login: "disconnected-fixture"), kind: .pat, scopes: [], storageMode: .keychain)
    let other = HostingAccount(instance: try HostingInstance(provider: .github, url: "https://github.com"), user: HostingUser(stableID: "42", login: "local-fixture"), kind: .pat, scopes: [], storageMode: .localVault)
    let secret = HostingToken(accessToken: "synthetic-disconnect-token")
    try await keychain.save(secret, account: original); try await local.save(secret, account: other)
    let binding = try RepositoryHostingBinding(repositoryID: UUID(), accountID: original.id, remote: "origin", repository: "example/fixture")
    var metadata = HostingMetadata(); metadata.accounts = [original, other]; metadata.bindings = [binding]
    let metadataStore = HostingMetadataStore(url: fixture.appendingPathComponent("workspace.hosting.json")); try metadataStore.save(metadata)
    let hosting = HostingModel(store: store, http: http, vault: router, openExternalURL: { _ in true }); store.hosting = hosting
    try await hosting.tokens.unlock(original)
    try await hosting.changeStorage(original, to: .localVault, allowStoredRead: false, cleanup: false)
    guard let migrated = hosting.account(original.id), migrated.pendingCleanup == [.keychain] else { throw HostingError.accountChanged }
    let item = try await hosting.api.request(binding, number: 17, account: migrated, token: secret)
    await keychain.deny(true); await transport.hold()
    hosting.verify(migrated)
    let list = Task { try await hosting.requests(binding, account: migrated, filter: .open, page: 1, refresh: true) }
    let signals = Task { try await hosting.signals(item, binding: binding, account: migrated) }
    for _ in 0..<100 {
      if await transport.blocked() { break }; try await Task.sleep(for: .milliseconds(20))
    }
    guard await transport.blocked() else { throw GitPierError.invalidInput("Disconnect fixture requests did not start") }
    try await hosting.disconnect(migrated)
    await transport.release()
    do { _ = try await list.value; throw GitPierError.invalidInput("Disconnected list request succeeded") } catch is CancellationError {} catch let e as HostingError where e == .accountChanged {}
    do { _ = try await signals.value; throw GitPierError.invalidInput("Disconnected signal request succeeded") } catch is CancellationError {} catch let e as HostingError where e == .accountChanged {}
    try await settle()
    guard hosting.account(migrated.id) == nil, hosting.states[migrated.id] == nil, hosting.binding(binding.id) == nil,
      hosting.metadata.disconnectedAccounts.first?.remainingStorage == [.keychain],
      try await local.read(account: migrated) == nil, await transport.cancellations() >= 2 else { throw HostingError.accountChanged }
    do { _ = try await hosting.tokens.token(for: migrated); throw HostingError.invalidResponse } catch HostingError.accountChanged {}
    hosting.shutdown()
    let readsBeforeRestart = await keychain.readCount()
    let restarted = HostingModel(store: store, http: http, vault: router, openExternalURL: { _ in true }); store.hosting = restarted
    guard restarted.account(migrated.id) == nil, restarted.metadata.disconnectedAccounts.count == 1,
      try await restarted.tokens.token(for: other) == secret,
      await keychain.readCount() == readsBeforeRestart else { throw HostingError.accountChanged }

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 1100), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.title = "GitPier Disconnect Acceptance — Synthetic"
    let host = NSHostingView(rootView: AnyView(EmptyView())); host.sizingOptions = []; host.autoresizingMask = [.width, .height]; window.contentView = host
    NSApp.setActivationPolicy(.regular); window.center(); window.makeKeyAndOrderFront(nil)
    defer { host.rootView = AnyView(EmptyView()); window.close() }
    for language in [AppLanguage.english, .simplifiedChinese] {
      for appearance in [AppearanceMode.light, .dark] {
        var settings = store.settings; settings.language = language; settings.appearance = appearance; store.updateSettings(settings)
        let name = "hosting-disconnected-pending-\(language.rawValue)-\(appearance.rawValue)"
        host.rootView = AnyView(HostingSettingsView(hosting: restarted).environmentObject(store).modifier(AppAppearance(store: store)).id(name))
        try await settle(); try await captureHostingWindow(window, to: output.appendingPathComponent(name + ".png"))
      }
    }
    await restarted.cleanupDisconnected(migrated.id)
    guard restarted.account(migrated.id) == nil, restarted.metadata.disconnectedAccounts.first?.remainingStorage == [.keychain],
      try await restarted.tokens.token(for: other) == secret else { throw HostingError.accountChanged }
    await keychain.deny(false); await restarted.cleanupDisconnected(migrated.id)
    guard restarted.metadata.disconnectedAccounts.isEmpty, try await keychain.read(account: original) == nil,
      try await restarted.tokens.token(for: other) == secret else { throw HostingError.storageFailure }

    // A failed metadata write still disconnects memory and removes the current Local credential.
    let localAccount = try XCTHostingUnwrap(restarted.account(other.id))
    try FileManager.default.removeItem(at: metadataStore.url)
    try FileManager.default.createDirectory(at: metadataStore.url, withIntermediateDirectories: false)
    try await restarted.disconnect(localAccount)
    guard restarted.account(other.id) == nil, try await local.read(account: other) == nil,
      restarted.error?.contains(store.settings.language == .english ? "restart" : "重启") == true else { throw HostingError.storageFailure }
    do { _ = try await restarted.tokens.token(for: other); throw HostingError.invalidResponse } catch HostingError.accountChanged {}
    restarted.shutdown()
    try await verifyHostingDisconnectionPersistence(root: root, output: output)
    try JSONSerialization.data(withJSONObject: ["syntheticOnly": true, "realOAuthVerified": false,
      "migrationOldKeychainDeletionDenied": true, "currentLocalDeletedBeforeHistoricalCleanup": true,
      "disconnectedRecordSurvivesModelRestart": true, "localAccountRestoresWithoutKeychain": true,
      "explicitRetryAfterDenial": true, "lateVerifyCannotRestore": true,
      "listAndSignalsTransportCancelled": true, "metadataFailureStopsMemorySessionAndWarns": true,
      "screenshots": 4, "gitCredentialsTouched": false], options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("hosting-disconnect-results.json"))
  }
}
