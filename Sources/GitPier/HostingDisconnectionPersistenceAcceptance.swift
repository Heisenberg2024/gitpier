import Foundation
import GitPierCore

extension UIAcceptance {
  /// Pure model acceptance with disposable files and an injected synthetic credential backend.
  /// Called only by the existing isolated hosting acceptance entry point; it opens no windows.
  static func verifyHostingDisconnectionPersistence(root: URL, output: URL) async throws {
    guard root.resolvingSymlinksInPath().deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui.") else { throw HostingError.invalidInstance }
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-disconnection-model-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let configuration = ConfigurationStore(url: fixture.appendingPathComponent("workspace.json"))
    var workspace = WorkspaceConfiguration(); workspace.settings.completionNotifications = false; try configuration.save(workspace)
    let store = AppStore(persistence: configuration); defer { store.shutdown() }
    let metadataStore = HostingMetadataStore(url: fixture.appendingPathComponent("workspace.hosting.json"))
    let journal = fixture.appendingPathComponent("workspace.hosting.json.disconnects")
    let local = LocalEncryptedCredentialStore(root: fixture.appendingPathComponent("credentials"))
    let vault = HostingCredentialRouter(local: local, keychain: HostingAcceptanceVault())
    let http = HostingHTTPClient(transport: HostingAcceptanceTransport(sha: String(repeating: "a", count: 40)))
    let instance = try HostingInstance(provider: .github, url: "https://github.com")
    let removed = HostingAccount(instance: instance, user: HostingUser(stableID: "42", login: "disk-recovery"), kind: .pat, scopes: [])
    let other = HostingAccount(instance: instance, user: HostingUser(stableID: "77", login: "preserved-account"), kind: .pat, scopes: [])
    let secret = HostingToken(accessToken: "synthetic-disconnection-model-only")
    try await local.save(secret, account: removed); try await local.save(secret, account: other)
    var metadata = HostingMetadata(); metadata.accounts = [removed, other]; try metadataStore.save(metadata)
    let originalBytes = try Data(contentsOf: metadataStore.url)
    let hosting = HostingModel(store: store, http: http, vault: vault, openExternalURL: { _ in false }); store.hosting = hosting

    // Fail only the main metadata replacement. The independent intent must survive a restart
    // that sees the last valid (still-active) metadata snapshot.
    try FileManager.default.removeItem(at: metadataStore.url)
    try FileManager.default.createDirectory(at: metadataStore.url, withIntermediateDirectories: false)
    try await hosting.disconnect(removed)
    guard hosting.account(removed.id) == nil,
      hosting.metadata.disconnectedAccounts.first?.remainingStorage.isEmpty == true,
      try await local.read(account: removed) == nil else { throw HostingError.storageFailure }
    do { _ = try await hosting.tokens.token(for: removed); throw HostingError.invalidResponse } catch HostingError.accountChanged {}
    hosting.shutdown()
    try FileManager.default.removeItem(at: metadataStore.url)
    try originalBytes.write(to: metadataStore.url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataStore.url.path)
    let recovered = HostingModel(store: store, http: http, vault: vault, openExternalURL: { _ in false }); store.hosting = recovered
    guard recovered.account(removed.id) == nil, recovered.metadata.disconnectedAccounts.first?.remainingStorage.isEmpty == true,
      try await recovered.tokens.token(for: other) == secret else { throw HostingError.accountChanged }
    await recovered.cleanupDisconnected(removed.id)
    guard recovered.metadata.disconnectedAccounts.isEmpty, try metadataStore.load().accounts == [other] else { throw HostingError.storageFailure }
    recovered.shutdown()

    // Fail both independent writes. Memory must still revoke immediately, credentials stay
    // available only for explicit cleanup, and the retry row must survive until disk recovery.
    let blocked = HostingAccount(instance: instance, user: HostingUser(stableID: "88", login: "blocked-disk"), kind: .pat, scopes: [])
    try await local.save(secret, account: blocked)
    metadata.accounts = [blocked, other]; try metadataStore.save(metadata)
    let beforeFailure = try Data(contentsOf: metadataStore.url)
    let failed = HostingModel(store: store, http: http, vault: vault, openExternalURL: { _ in false }); store.hosting = failed
    try FileManager.default.removeItem(at: metadataStore.url)
    try FileManager.default.createDirectory(at: metadataStore.url, withIntermediateDirectories: false)
    try FileManager.default.removeItem(at: journal); try Data("blocked".utf8).write(to: journal)
    try await failed.disconnect(blocked)
    guard failed.account(blocked.id) == nil, failed.metadata.disconnectedAccounts.first?.remainingStorage == [.localVault],
      failed.error?.contains("Restart") == true, try await local.read(account: blocked) == secret,
      try await failed.tokens.token(for: other) == secret else { throw HostingError.storageFailure }
    do { try await failed.tokens.install(secret, account: blocked); throw HostingError.invalidResponse } catch HostingError.accountChanged {}
    try FileManager.default.removeItem(at: metadataStore.url)
    try beforeFailure.write(to: metadataStore.url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataStore.url.path)
    try FileManager.default.removeItem(at: journal)
    await failed.cleanupDisconnected(blocked.id)
    guard failed.error == nil, failed.account(blocked.id) == nil, failed.metadata.disconnectedAccounts.isEmpty,
      try await local.read(account: blocked) == nil, try await failed.tokens.token(for: other) == secret,
      try metadataStore.load().accounts == [other] else { throw HostingError.storageFailure }
    do { try await failed.tokens.unlock(blocked); throw HostingError.invalidResponse } catch HostingError.accountChanged {}
    failed.shutdown()
    try JSONSerialization.data(withJSONObject: ["syntheticOnly": true, "mainMetadataFailureRecoveredFromIndependentIntent": true,
      "bothWritesFailedSessionStillRevoked": true, "diskRecoveryExplicitRetry": true,
      "completedCleanupRetainsRetryRow": true, "otherAccountPreserved": true,
      "realKeychainTouched": false, "realNetworkRequests": false], options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("hosting-disconnection-persistence-results.json"))
  }
}
