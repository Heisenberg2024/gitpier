import XCTest
@testable import GitPierCore

private actor HostingDisconnectJournal {
  let store: HostingMetadataStore
  var metadata: HostingMetadata
  init(store: HostingMetadataStore, metadata: HostingMetadata) { self.store = store; self.metadata = metadata }
  func begin(_ account: HostingAccount) throws {
    metadata.accounts.removeAll { $0.id == account.id }
    metadata.bindings.removeAll { $0.accountID == account.id }
    metadata.disconnectedAccounts.append(HostingDisconnectedAccount(account: account))
    try store.save(metadata)
  }
  func deleted(_ mode: HostingStorageMode, id: UUID) throws {
    if let i = metadata.disconnectedAccounts.firstIndex(where: { $0.id == id }) {
      metadata.disconnectedAccounts[i].remainingStorage.removeAll { $0 == mode }
      if metadata.disconnectedAccounts[i].remainingStorage.isEmpty { metadata.disconnectedAccounts.remove(at: i) }
    }
    try store.save(metadata)
  }
}

extension HostingCredentialTests {
  func testFreshProcessRetainsDisconnectedTombstoneAndRetriesDeniedHistoricalCopy() async throws {
    let probe = "GITPIER_HOSTING_DISCONNECT_RESTART_FIXTURE"
    if let path = ProcessInfo.processInfo.environment[probe] {
      let fixture = URL(fileURLWithPath: path)
      guard fixture.lastPathComponent.hasPrefix("GitPier-dual-vault-") else { throw HostingError.configurationUnreadable }
      let store = HostingMetadataStore(url: fixture.appendingPathComponent("hosting.json"))
      let metadata = try store.load(), pending = try XCTUnwrap(metadata.disconnectedAccounts.first)
      XCTAssertEqual(metadata.accounts.count, 1); XCTAssertEqual(metadata.disconnectedAccounts.count, 1)
      XCTAssertFalse(metadata.accounts.contains { $0.id == pending.id }); XCTAssertTrue(metadata.bindings.isEmpty)
      XCTAssertEqual(pending.remainingStorage, [.keychain])
      // Rebuild the denied fake backend in this genuinely new process. No macOS Keychain item
      // or authorization policy is used; only Local Vault files and metadata cross the boundary.
      let keychain = HostingFixtureVault(), local = LocalEncryptedCredentialStore(root: fixture.appendingPathComponent("credentials"))
      var historical = pending.account; historical.storageMode = .keychain
      try await keychain.save(token, account: historical); await keychain.setReject(true)
      let manager = OAuthTokenManager(vault: HostingCredentialRouter(local: local, keychain: keychain))
      for active in metadata.accounts {
        XCTAssertEqual(active.storageMode, .localVault)
        let restored = try await manager.token(for: active); XCTAssertEqual(restored, token)
      }
      let oldLocal = try await local.read(account: pending.account); XCTAssertNil(oldLocal)
      await expect(.unauthorized) { _ = try await manager.token(for: pending.account) }
      let beforeCleanup = await keychain.counts(); XCTAssertEqual(beforeCleanup.0, 0)
      let journal = HostingDisconnectJournal(store: store, metadata: metadata)
      await expect(.keychainDenied) {
        try await manager.forget(pending.account, modes: pending.remainingStorage) { mode in try? await journal.deleted(mode, id: pending.id) }
      }
      XCTAssertEqual(try store.load().disconnectedAccounts.first?.remainingStorage, [.keychain])
      await expect(.accountChanged) { _ = try await manager.token(for: pending.account) }
      await keychain.setReject(false)
      try await manager.forget(pending.account, modes: pending.remainingStorage) { mode in try? await journal.deleted(mode, id: pending.id) }
      XCTAssertTrue(try store.load().disconnectedAccounts.isEmpty)
      XCTAssertEqual(try store.load().accounts.map(\.id), metadata.accounts.map(\.id))
      let remaining = try await manager.token(for: metadata.accounts[0]), counts = await keychain.counts()
      XCTAssertEqual(remaining, token); XCTAssertEqual(counts.0, 0)
      print("HOSTING_DISCONNECTED_FRESH_PROCESS_RESTORED_AND_CLEANED_SYNTHETIC")
      return
    }
    let original = try account(.keychain), other = try account(user: "other-local")
    let local = LocalEncryptedCredentialStore(root: root.appendingPathComponent("credentials")), keychain = HostingFixtureVault()
    let manager = OAuthTokenManager(vault: HostingCredentialRouter(local: local, keychain: keychain))
    try await manager.install(token, account: original); try await manager.install(token, account: other)
    let migrated = try await manager.migrate(original, to: .localVault, commit: { _ in })
    var metadata = HostingMetadata(); metadata.accounts = [migrated, other]
    metadata.bindings = [try RepositoryHostingBinding(repositoryID: UUID(), accountID: migrated.id, remote: "origin", repository: "owner/repo")]
    let store = HostingMetadataStore(url: root.appendingPathComponent("hosting.json")), journal = HostingDisconnectJournal(store: store, metadata: metadata)
    await keychain.setReject(true); try await manager.stopSession(migrated); try await journal.begin(migrated)
    await expect(.keychainDenied) {
      try await manager.forget(migrated) { mode in try? await journal.deleted(mode, id: migrated.id) }
    }
    XCTAssertEqual(try store.load().disconnectedAccounts.first?.remainingStorage, [.keychain])
    let result = try await ProcessRunner().run(executable: "/usr/bin/xcrun", arguments: ["xctest", "-XCTest",
      "GitPierCoreTests.HostingCredentialTests/testFreshProcessRetainsDisconnectedTombstoneAndRetriesDeniedHistoricalCopy",
      Bundle(for: HostingCredentialTests.self).bundleURL.path], directory: nil, environment: [probe: root.path], timeout: 30)
    XCTAssertEqual(result.code, 0, result.errorText + result.text)
    XCTAssertTrue(result.text.contains("HOSTING_DISCONNECTED_FRESH_PROCESS_RESTORED_AND_CLEANED_SYNTHETIC"), result.errorText + result.text)
    XCTAssertTrue(try store.load().disconnectedAccounts.isEmpty)
  }

  func testMigratedDeniedKeychainDisconnectDeletesActiveLocalAndJournalsOnlyOldCopyAcrossRestart() async throws {
    let old = try account(.keychain), other = try account(user: "43")
    let local = LocalEncryptedCredentialStore(root: root.appendingPathComponent("credentials")), keychain = HostingFixtureVault()
    let router = HostingCredentialRouter(local: local, keychain: keychain), manager = OAuthTokenManager(vault: router)
    try await manager.install(token, account: old); try await manager.install(token, account: other)
    let migrated = try await manager.migrate(old, to: .localVault, commit: { _ in })
    var metadata = HostingMetadata(); metadata.accounts = [migrated, other]
    let binding = try RepositoryHostingBinding(repositoryID: UUID(), accountID: migrated.id, remote: "origin", repository: "owner/repo")
    metadata.bindings = [binding]
    let store = HostingMetadataStore(url: root.appendingPathComponent("hosting.json")), journal = HostingDisconnectJournal(store: store, metadata: metadata)
    await keychain.setReject(true)
    try await manager.stopSession(migrated); try await journal.begin(migrated)
    await expect(.keychainDenied) {
      try await manager.forget(migrated) { mode in try? await journal.deleted(mode, id: migrated.id) }
    }
    let deletedLocal = try await local.read(account: migrated); XCTAssertNil(deletedLocal)
    await expect(.accountChanged) { _ = try await manager.token(for: migrated) }
    await expect(.accountChanged) { try await manager.install(token, account: migrated) }
    let restoredMetadata = try store.load()
    XCTAssertEqual(restoredMetadata.accounts.map(\.id), [other.id]); XCTAssertTrue(restoredMetadata.bindings.isEmpty)
    XCTAssertEqual(restoredMetadata.disconnectedAccounts.first?.remainingStorage, [.keychain])
    let restarted = OAuthTokenManager(vault: router)
    let restored = try await restarted.token(for: restoredMetadata.accounts[0]); XCTAssertEqual(restored, token)
    let counts = await keychain.counts(); XCTAssertEqual(counts.0, 0, "Local restoration must not query old OAuth Keychain")
    let pending = try XCTUnwrap(restoredMetadata.disconnectedAccounts.first)
    await keychain.setReject(false)
    try await restarted.forget(pending.account, modes: pending.remainingStorage) { mode in try? await journal.deleted(mode, id: pending.id) }
    XCTAssertTrue(try store.load().disconnectedAccounts.isEmpty)
    let deletedOld = try await keychain.read(account: old), remainingOther = try await restarted.token(for: other)
    XCTAssertNil(deletedOld); XCTAssertEqual(remainingOther, token)
  }

  func testDeniedCurrentKeychainStopsSessionAndStillCleansInterruptedLocalDestination() async throws {
    var current = try account(.keychain); current.pendingMigration = .localVault
    let local = HostingFixtureVault(), keychain = HostingFixtureVault()
    let router = HostingCredentialRouter(local: local, keychain: keychain), manager = OAuthTokenManager(vault: router)
    try await manager.install(token, account: current)
    var destination = current; destination.storageMode = .localVault; try await local.save(token, account: destination)
    await keychain.setReject(true)
    await expect(.keychainDenied) { try await manager.forget(current) }
    await expect(.accountChanged) { try await manager.unlock(current) }
    await expect(.accountChanged) { _ = try await manager.token(for: current) }
    let deletedDestination = try await local.read(account: destination); XCTAssertNil(deletedDestination)
    await keychain.setReject(false)
    let retained = try await keychain.read(account: current); XCTAssertEqual(retained, token)
    try await manager.forget(current, modes: [.keychain])
    let deleted = try await keychain.read(account: current); XCTAssertNil(deleted)
  }

  func testRepeatedDeniedCleanupNeverReenablesLocalOrTouchesAnotherAccount() async throws {
    var disconnected = try account(); disconnected.pendingCleanup = [.keychain]
    let other = try account(user: "other"), local = HostingFixtureVault(), keychain = HostingFixtureVault()
    let manager = OAuthTokenManager(vault: HostingCredentialRouter(local: local, keychain: keychain))
    try await manager.install(token, account: disconnected); try await manager.install(token, account: other)
    var old = disconnected; old.storageMode = .keychain; try await keychain.save(token, account: old)
    await keychain.setReject(true)
    for _ in 0..<3 {
      await expect(.keychainDenied) { try await manager.forget(disconnected) }
      await expect(.accountChanged) { _ = try await manager.token(for: disconnected) }
      let otherToken = try await manager.token(for: other); XCTAssertEqual(otherToken, token)
    }
    let deleted = try await local.read(account: disconnected); XCTAssertNil(deleted)
    await keychain.setReject(false); try await manager.forget(disconnected, modes: [.keychain])
    let retained = try await local.read(account: other); XCTAssertEqual(retained, token)
  }

  func testDisconnectDuringUncancellableInstallWaitsForWriteThenDeletesLateCopy() async throws {
    let a = try account(), vault = HostingRotationGateVault(), manager = OAuthTokenManager(vault: vault)
    try await manager.install(token, account: a)
    let pending = Task { try await manager.install(HostingToken(accessToken: "late-synthetic"), account: a) }
    while !(await vault.blocked()) { await Task.yield() }
    try await manager.stopSession(a)
    await expect(.accountChanged) { _ = try await manager.token(for: a) }
    let disconnect = Task { try await manager.forget(a) }
    await vault.release()
    await expect(.accountChanged) { try await pending.value }
    try await disconnect.value
    let deleted = await vault.read(account: a); XCTAssertNil(deleted)
    await expect(.accountChanged) { try await manager.install(token, account: a) }
  }

  func testDisconnectDuringMigrationPreventsLateCommitAndCleansBothPossibleCopies() async throws {
    let a = try account(), local = HostingFixtureVault(), keychain = HostingFixtureVault()
    let manager = OAuthTokenManager(vault: HostingCredentialRouter(local: local, keychain: keychain)), journal = HostingMigrationFixture(a)
    try await manager.install(token, account: a); await journal.setHold()
    let migration = Task { try await manager.migrate(a, to: .keychain, beforeWrite: { await journal.begin(.keychain) }, commit: { try await journal.commit($0) }) }
    while !(await journal.blocked()) { await Task.yield() }
    var intent = a; intent.pendingMigration = .keychain
    try await manager.stopSession(intent)
    let disconnect = Task { try await manager.forget(intent) }
    await journal.release()
    await expect(.accountChanged) { _ = try await migration.value }
    try await disconnect.value
    let deletedLocal = try await local.read(account: a), deletedKeychain = try await keychain.read(account: a)
    XCTAssertNil(deletedLocal); XCTAssertNil(deletedKeychain)
    await expect(.accountChanged) { _ = try await manager.token(for: a) }
  }

  func testDisconnectionMetadataContainsNoSecretsAndRejectsActiveTombstoneAmbiguity() throws {
    let a = try account(), store = HostingMetadataStore(url: root.appendingPathComponent("hosting.json"))
    var metadata = HostingMetadata(); metadata.disconnectedAccounts = [HostingDisconnectedAccount(account: a)]
    try store.save(metadata)
    let bytes = try Data(contentsOf: store.url)
    XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(token.accessToken))
    XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(token.refreshToken!))
    XCTAssertEqual(try store.load().disconnectedAccounts, metadata.disconnectedAccounts)
    metadata.accounts = [a]; try store.save(metadata)
    XCTAssertThrowsError(try store.load())
  }

  func testFreshConnectionOfDisconnectedIdentityUsesNewUUIDWithoutDeletingRetainedOldCopy() async throws {
    let old = try account(.keychain), keychain = HostingFixtureVault(), local = HostingFixtureVault()
    let manager = OAuthTokenManager(vault: HostingCredentialRouter(local: local, keychain: keychain))
    try await manager.install(token, account: old); await keychain.setReject(true)
    await expect(.keychainDenied) { try await manager.forget(old) }
    let fresh = try account(.localVault, user: old.user.stableID)
    XCTAssertNotEqual(old.id, fresh.id); try await manager.install(token, account: fresh)
    let freshToken = try await manager.token(for: fresh); XCTAssertEqual(freshToken, token)
    await keychain.setReject(false); try await manager.forget(old, modes: [.keychain])
    let remaining = try await manager.token(for: fresh); XCTAssertEqual(remaining, token)
  }
}
