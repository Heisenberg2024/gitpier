import CryptoKit
import Darwin
import XCTest
@testable import GitPierCore

actor HostingMigrationFixture {
  var value: HostingAccount
  var failCommit = false
  var gate: CheckedContinuation<Void, Never>?
  var hold = false
  init(_ account: HostingAccount) { value = account }
  func begin(_ mode: HostingStorageMode) async {
    value.pendingMigration = mode
    if hold { await withCheckedContinuation { gate = $0 } }
  }
  func commit(_ account: HostingAccount) throws {
    if failCommit { throw HostingError.storageFailure }
    value = account
  }
  func setFail() { failCommit = true }
  func setHold() { hold = true }
  func blocked() -> Bool { gate != nil }
  func release() { gate?.resume(); gate = nil }
  func account() -> HostingAccount { value }
}

@MainActor final class HostingCredentialTests: XCTestCase {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-dual-vault-" + UUID().uuidString)
  deinit { try? FileManager.default.removeItem(at: root) }
  let token = HostingToken(accessToken: "synthetic-private-access", refreshToken: "synthetic-private-refresh", scopes: ["read_api"])
  func account(_ mode: HostingStorageMode = .localVault, provider: HostingProvider = .gitlab, user: String = "42", id: UUID = UUID(), kind: HostingAuthenticationKind = .oauth) throws -> HostingAccount {
    let instance = try HostingInstance(provider: provider, url: provider == .github ? "https://github.com" : "https://forge.example.invalid:443/git")
    return HostingAccount(id: id, instance: instance, user: HostingUser(stableID: user, login: "fixture"), kind: kind, scopes: [],
      oauth: OAuthConfiguration(instance: instance, clientID: "fixture", redirect: provider == .gitea ? .loopback(port: 0) : .application), storageMode: mode)
  }
  func files(_ directory: String) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
  }
  func record(_ a: HostingAccount) throws -> LocalEncryptedCredentialStore.Record {
    try JSONDecoder().decode(LocalEncryptedCredentialStore.Record.self, from: Data(contentsOf: root.appendingPathComponent("vault/" + a.id.uuidString + ".json")))
  }
  func key(_ a: HostingAccount) throws -> URL { root.appendingPathComponent("keys/" + a.id.uuidString + "." + (try record(a)).key.uuidString + ".key") }
  func cipher(_ a: HostingAccount) throws -> URL { root.appendingPathComponent("vault/" + a.id.uuidString + "." + (try record(a)).generation.uuidString + ".sealed") }
  func expect(_ expected: HostingError, _ work: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await work(); XCTFail("Expected failure", file: file, line: line) }
    catch { XCTAssertEqual(error as? HostingError, expected, file: file, line: line) }
  }
  func testRoundTripCompletePairAndRestart() async throws {
    let a = try account(); try await LocalEncryptedCredentialStore(root: root).save(token, account: a)
    let restored = try await LocalEncryptedCredentialStore(root: root).read(account: a); XCTAssertEqual(restored, token)
  }
  func testPermissionsAndNoPlaintextInAnyFile() async throws {
    let a = try account(), vault = LocalEncryptedCredentialStore(root: root); try await vault.save(token, account: a)
    for dir in [root, root.appendingPathComponent("keys"), root.appendingPathComponent("vault")] {
      let permissions = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
      XCTAssertEqual(permissions, 0o700)
    }
    for url in try files("keys") + files("vault") {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
      XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(token.accessToken))
      XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(token.refreshToken!))
    }
    XCTAssertEqual(try Data(contentsOf: key(a)).count, 32)
  }
  func testAccountsGetIndependentRandomKeys() async throws {
    let a = try account(), b = try account(user: "43"), vault = LocalEncryptedCredentialStore(root: root)
    try await vault.save(token, account: a); try await vault.save(token, account: b)
    XCTAssertNotEqual(try Data(contentsOf: key(a)), try Data(contentsOf: key(b)))
  }
  func testRefreshReusesKeyAndChangesNonceAndOnlyOneActivePairRemains() async throws {
    let a = try account(), vault = LocalEncryptedCredentialStore(root: root)
    try await vault.save(token, account: a)
    let originalKey = try Data(contentsOf: key(a)), originalRecord = try record(a)
    var nonces: Set<Data> = []
    for _ in 0..<32 {
      try await vault.save(token, account: a)
      let nonce = try Data(contentsOf: cipher(a)).prefix(12)
      XCTAssertTrue(nonces.insert(Data(nonce)).inserted)
    }
    XCTAssertEqual(try Data(contentsOf: key(a)), originalKey); XCTAssertEqual(try record(a).key, originalRecord.key)
    XCTAssertEqual(try files("keys").count, 1); XCTAssertEqual(try files("vault").count, 2)
  }
  func testReauthorizationRotatesKeyAndRemovesOldPair() async throws {
    let a = try account(), vault = LocalEncryptedCredentialStore(root: root)
    try await vault.save(token, account: a); let oldKey = try key(a), bytes = try Data(contentsOf: oldKey), oldCipher = try cipher(a)
    try await vault.replace(token, account: a)
    XCTAssertNotEqual(try Data(contentsOf: key(a)), bytes)
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldKey.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: oldCipher.path))
  }
  func testAuthenticationTagTamperingIsRejected() async throws {
    let a = try account(), vault = LocalEncryptedCredentialStore(root: root); try await vault.save(token, account: a)
    let url = try cipher(a); var bytes = try Data(contentsOf: url); bytes[bytes.count - 1] ^= 1; try bytes.write(to: url)
    await expect(.vaultCorrupt) { _ = try await vault.read(account: a) }
  }
  func testWrongKeyIsRejected() async throws {
    let a = try account(), vault = LocalEncryptedCredentialStore(root: root); try await vault.save(token, account: a)
    try Data(repeating: 0, count: 32).write(to: key(a))
    await expect(.vaultCorrupt) { _ = try await vault.read(account: a) }
  }
  func testAssociatedDataRejectsSameUUIDDifferentUserInstanceAndProvider() async throws {
    let a = try account(), vault = LocalEncryptedCredentialStore(root: root); try await vault.save(token, account: a)
    let others = [try account(user: "43", id: a.id), try account(provider: .gitea, id: a.id),
      HostingAccount(id: a.id, instance: try HostingInstance(provider: .gitlab, url: "https://different.invalid"), user: a.user, kind: .oauth, scopes: [])]
    for other in others { await expect(.vaultCorrupt) { _ = try await vault.read(account: other) } }
  }
  func testCopyingPairAndPointerToAnotherUUIDCannotDecrypt() async throws {
    let a = try account(), b = try account(user: "43"), vault = LocalEncryptedCredentialStore(root: root); try await vault.save(token, account: a)
    let r = try record(a)
    for (source, destination) in [(try key(a), root.appendingPathComponent("keys/\(b.id).\(r.key).key")),
      (try cipher(a), root.appendingPathComponent("vault/\(b.id).\(r.generation).sealed")),
      (root.appendingPathComponent("vault/\(a.id).json"), root.appendingPathComponent("vault/\(b.id).json"))] {
      try FileManager.default.copyItem(at: source, to: destination)
    }
    await expect(.vaultCorrupt) { _ = try await vault.read(account: b) }
  }
  func testMissingKeyAndCorruptedPointerAreRecoverableByReauthorization() async throws {
    let a = try account(), vault = LocalEncryptedCredentialStore(root: root); try await vault.save(token, account: a)
    try FileManager.default.removeItem(at: key(a)); await expect(.vaultCorrupt) { _ = try await vault.read(account: a) }
    try await vault.replace(token, account: a)
    try Data("broken".utf8).write(to: root.appendingPathComponent("vault/\(a.id).json"))
    await expect(.vaultCorrupt) { _ = try await vault.read(account: a) }
    try await vault.replace(token, account: a); let restored = try await vault.read(account: a); XCTAssertEqual(restored, token)
    XCTAssertEqual(try files("keys").count, 1)
  }
  func testInterruptedKeyAndCipherWritesKeepOriginalPairAndRecoverOrphans() async throws {
    for stage in ["key", "cipher"] {
      let a = try account(), vault = LocalEncryptedCredentialStore(root: root)
      try await vault.save(token, account: a); let old = try record(a)
      let failing = LocalEncryptedCredentialStore(root: root, checkpoint: { if $0 == stage { throw HostingError.storageFailure } })
      await expect(.storageFailure) { try await failing.replace(HostingToken(accessToken: "replacement"), account: a) }
      XCTAssertEqual(try record(a).generation, old.generation)
      let restored = try await LocalEncryptedCredentialStore(root: root).read(account: a); XCTAssertEqual(restored, token)
      try await vault.replace(token, account: a)
      try await vault.delete(account: a)
      XCTAssertTrue(try files("keys").isEmpty); XCTAssertTrue(try files("vault").isEmpty)
    }
  }
  func testFailedCipherSaveKeepsOriginalPairAndKey() async throws {
    let a = try account(), vault = LocalEncryptedCredentialStore(root: root); try await vault.save(token, account: a)
    let oldKey = try Data(contentsOf: key(a))
    let failing = LocalEncryptedCredentialStore(root: root, checkpoint: { if $0 == "cipher" { throw HostingError.storageFailure } })
    await expect(.storageFailure) { try await failing.save(HostingToken(accessToken: "next"), account: a) }
    let original = try await vault.read(account: a); XCTAssertEqual(original, token); XCTAssertEqual(try Data(contentsOf: key(a)), oldKey)
  }
  func testRootDirectorySymlinkIsRejectedWithoutTouchingTarget() async throws {
    let target = root.appendingPathExtension("outside")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: target) }
    try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)
    await expect(.vaultUnavailable) { try await LocalEncryptedCredentialStore(root: root).save(token, account: account()) }
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
  }
  func testKeySymlinkAndHardlinkNeverReadOrOverwriteTarget() async throws {
    let a = try account(), vault = LocalEncryptedCredentialStore(root: root); try await vault.save(token, account: a)
    let path = try key(a), outside = root.appendingPathComponent("outside")
    let sentinel = Data(repeating: 7, count: 32); try sentinel.write(to: outside)
    try FileManager.default.removeItem(at: path); try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
    await expect(.vaultUnavailable) { _ = try await vault.read(account: a) }
    try FileManager.default.removeItem(at: path); try FileManager.default.linkItem(at: outside, to: path)
    await expect(.vaultUnavailable) { _ = try await vault.read(account: a) }
    XCTAssertEqual(try Data(contentsOf: outside), sentinel)
  }
  func testCipherDirectorySymlinkIsRejected() async throws {
    let a = try account(), vault = LocalEncryptedCredentialStore(root: root); try await vault.save(token, account: a)
    try FileManager.default.moveItem(at: root.appendingPathComponent("vault"), to: root.appendingPathComponent("original"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("vault"), withDestinationURL: root.appendingPathComponent("original"))
    await expect(.vaultUnavailable) { _ = try await vault.read(account: a) }
  }
  func testUnsafeKeyPermissionsFailClosed() async throws {
    let a = try account(), vault = LocalEncryptedCredentialStore(root: root); try await vault.save(token, account: a)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: key(a).path)
    await expect(.vaultUnavailable) { _ = try await vault.read(account: a) }
  }
  func testAdvisoryAccountLockBlocksConcurrentStoreButNotOtherAccounts() async throws {
    let a = try account(), b = try account(user: "43"), vault = LocalEncryptedCredentialStore(root: root)
    try await vault.save(token, account: a)
    let dir = try HostingPrivateDirectory(root); defer { dir.closeDirectory() }
    let lock = try dir.lock(a.id.uuidString + ".lock"); defer { close(lock) }
    await expect(.operationInProgress) { try await vault.save(token, account: a) }
    try await vault.save(token, account: b)
  }
  func testDeletingOneAccountKeepsOtherAccountAndAllowsMissingDelete() async throws {
    let a = try account(), b = try account(user: "43"), vault = LocalEncryptedCredentialStore(root: root)
    try await vault.save(token, account: a); try await vault.save(token, account: b); try await vault.delete(account: a); try await vault.delete(account: a)
    let first = try await vault.read(account: a), second = try await vault.read(account: b)
    XCTAssertNil(first); XCTAssertEqual(second, token)
  }
  func testNewDefaultAndLegacyMetadataRemainIndependentWithoutCredentialReads() throws {
    var m = HostingMetadata(); let old = try account(.keychain); m.accounts = [old]
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as! [String: Any]
    json["version"] = 1; json.removeValue(forKey: "defaultStorageMode")
    var accounts = json["accounts"] as! [[String: Any]]; accounts[0].removeValue(forKey: "storageMode"); json["accounts"] = accounts
    let legacy = try JSONDecoder().decode(HostingMetadata.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertEqual(legacy.defaultStorageMode, .localVault); XCTAssertEqual(legacy.accounts[0].storageMode, .keychain)
    var changed = legacy; changed.defaultStorageMode = .keychain
    XCTAssertEqual(changed.accounts, legacy.accounts); XCTAssertEqual(try account().storageMode, .localVault)
    accounts[0]["storageMode"] = "unrecognized"; json["accounts"] = accounts
    XCTAssertThrowsError(try JSONDecoder().decode(HostingMetadata.self, from: JSONSerialization.data(withJSONObject: json)))
  }
  func testLocalRestorationIsSingleFlightAndNeverAccessesKeychain() async throws {
    let local = HostingFixtureVault(), keychain = HostingFixtureVault(), a = try account()
    try await local.save(token, account: a)
    let manager = OAuthTokenManager(vault: HostingCredentialRouter(local: local, keychain: keychain))
    try await withThrowingTaskGroup(of: HostingToken.self) { group in
      for _ in 0..<32 { group.addTask { try await manager.token(for: a) } }
      for try await value in group { XCTAssertEqual(value, token) }
    }
    let lc = await local.counts(), kc = await keychain.counts()
    XCTAssertEqual(lc.0, 1); XCTAssertEqual(kc.0, 0); XCTAssertEqual(kc.1, 0)
  }
  func testKeychainInstallAndRequestsNeverRereadAndRestartRequiresVerify() async throws {
    let keychain = HostingFixtureVault(), local = HostingFixtureVault(), a = try account(.keychain)
    let router = HostingCredentialRouter(local: local, keychain: keychain), manager = OAuthTokenManager(vault: router)
    try await manager.install(token, account: a)
    for _ in 0..<8 { _ = try await manager.token(for: a) }
    let initial = await keychain.counts(); XCTAssertEqual(initial.0, 0)
    let restarted = OAuthTokenManager(vault: router)
    await expect(.credentialsLocked) { _ = try await restarted.token(for: a) }
    try await restarted.unlock(a); try await restarted.unlock(a); _ = try await restarted.token(for: a)
    let counts = await keychain.counts(), localCounts = await local.counts(); XCTAssertEqual(counts.0, 1); XCTAssertEqual(localCounts.1, 0)
  }
  func testFailedInstallKeepsMemorySessionAndReportsSessionOnly() async throws {
    let vault = HostingFixtureVault(), manager = OAuthTokenManager(vault: vault), a = try account()
    await vault.setReject(true)
    await expect(.sessionOnly) { try await manager.install(token, account: a) }
    let active = try await manager.token(for: a), transient = await manager.isSessionOnly(a.id)
    XCTAssertEqual(active, token); XCTAssertTrue(transient)
  }
  func testPATWithExpiryNeverRefreshesEvenWithMisleadingRefreshFields() async throws {
    let a = try account(kind: .pat), transport = HostingFixtureTransport(), vault = HostingFixtureVault()
    let manager = OAuthTokenManager(vault: vault, oauth: OAuthAuthorizationCoordinator(http: HostingHTTPClient(transport: transport)))
    try await manager.install(HostingToken(accessToken: "fixture", refreshToken: "ignored", expiresAt: .distantPast), account: a)
    await expect(.expired) { _ = try await manager.token(for: a) }; let requests = await transport.captured(); XCTAssertTrue(requests.isEmpty)
  }
  func testBidirectionalMigrationAndRestartWithExplicitSourceCleanup() async throws {
    let local = LocalEncryptedCredentialStore(root: root), keychain = HostingFixtureVault(), a = try account(.keychain)
    let router = HostingCredentialRouter(local: local, keychain: keychain), manager = OAuthTokenManager(vault: router)
    try await manager.install(token, account: a)
    let journal = HostingMigrationFixture(a)
    let changed = try await manager.migrate(a, to: .localVault, beforeWrite: { await journal.begin(.localVault) }, commit: { try await journal.commit($0) })
    XCTAssertEqual(changed.pendingCleanup, [.keychain]); XCTAssertEqual(changed.storageMode, .localVault)
    let counts = await keychain.counts(); XCTAssertEqual(counts.0, 0)
    let restarted = OAuthTokenManager(vault: router), restored = try await restarted.token(for: changed); XCTAssertEqual(restored, token)
    let source = try await keychain.read(account: a); XCTAssertEqual(source, token)
    try await manager.cleanup(changed, mode: .keychain)
    let deleted = try await keychain.read(account: a); XCTAssertNil(deleted)
    let back = try await manager.migrate(changed, to: .keychain, commit: { try await journal.commit($0) })
    XCTAssertEqual(back.storageMode, .keychain)
    try await manager.cleanup(back, mode: .localVault)
    let gone = try await local.read(account: a); XCTAssertNil(gone)
  }
  func testDestinationFailurePreservesSourceAndMode() async throws {
    let local = HostingFixtureVault(), keychain = HostingFixtureVault(), a = try account()
    let manager = OAuthTokenManager(vault: HostingCredentialRouter(local: local, keychain: keychain)), journal = HostingMigrationFixture(a)
    try await manager.install(token, account: a); await keychain.setReject(true)
    await expect(.keychainDenied) { _ = try await manager.migrate(a, to: .keychain, beforeWrite: { await journal.begin(.keychain) }, commit: { try await journal.commit($0) }) }
    let source = try await local.read(account: a), metadata = await journal.account(), active = try await manager.token(for: a)
    XCTAssertEqual(source, token); XCTAssertEqual(metadata.storageMode, .localVault); XCTAssertEqual(metadata.pendingMigration, .keychain); XCTAssertEqual(active, token)
  }
  func testMetadataCommitFailureRetainsSourceAndDestinationForExplicitRecovery() async throws {
    let local = HostingFixtureVault(), keychain = HostingFixtureVault(), a = try account(.keychain)
    let manager = OAuthTokenManager(vault: HostingCredentialRouter(local: local, keychain: keychain)), journal = HostingMigrationFixture(a)
    try await manager.install(token, account: a); await journal.setFail()
    await expect(.storageFailure) { _ = try await manager.migrate(a, to: .localVault, beforeWrite: { await journal.begin(.localVault) }, commit: { try await journal.commit($0) }) }
    let metadata = await journal.account(), original = try await keychain.read(account: a), active = try await manager.token(for: a), destination = try await local.read(account: a)
    XCTAssertEqual(metadata.storageMode, .keychain); XCTAssertEqual(original, token); XCTAssertEqual(active, token); XCTAssertEqual(destination, token)
    try await manager.cleanup(metadata, mode: .localVault)
    let removed = try await local.read(account: a); XCTAssertNil(removed)
  }
  func testMigrationCannotSilentlyReadLockedKeychain() async throws {
    let keychain = HostingFixtureVault(), local = HostingFixtureVault(), a = try account(.keychain)
    try await keychain.save(token, account: a)
    let manager = OAuthTokenManager(vault: HostingCredentialRouter(local: local, keychain: keychain))
    await expect(.credentialsLocked) { _ = try await manager.migrate(a, to: .localVault, commit: { _ in }) }
    let before = await keychain.counts(); XCTAssertEqual(before.0, 0)
    let changed = try await manager.migrate(a, to: .localVault, allowStoredRead: true, commit: { _ in })
    XCTAssertEqual(changed.storageMode, .localVault); let after = await keychain.counts(); XCTAssertEqual(after.0, 1)
  }
  func testReauthorizeMigrationDoesNotReadOldKeychainAndNeverDeletesItImplicitly() async throws {
    let keychain = HostingFixtureVault(), local = HostingFixtureVault(), a = try account(.keychain)
    let manager = OAuthTokenManager(vault: HostingCredentialRouter(local: local, keychain: keychain))
    let changed = try await manager.migrate(a, to: .localVault, replacement: token, commit: { _ in })
    let counts = await keychain.counts(), active = try await manager.token(for: changed)
    XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0); XCTAssertEqual(active, token)
  }
  func testMigrationFreezesSameAccountAcrossWindowsButAllowsOtherAccount() async throws {
    let a = try account(), b = try account(user: "43"), local = HostingFixtureVault(), keychain = HostingFixtureVault()
    let manager = OAuthTokenManager(vault: HostingCredentialRouter(local: local, keychain: keychain)), journal = HostingMigrationFixture(a)
    try await manager.install(token, account: a); try await manager.install(token, account: b); await journal.setHold()
    let task = Task { try await manager.migrate(a, to: .keychain, beforeWrite: { await journal.begin(.keychain) }, commit: { try await journal.commit($0) }) }
    while !(await journal.blocked()) { await Task.yield() }
    await expect(.operationInProgress) { _ = try await manager.migrate(a, to: .keychain, commit: { _ in }) }
    await expect(.operationInProgress) { _ = try await manager.token(for: a) }
    let other = try await manager.token(for: b); XCTAssertEqual(other, token)
    await journal.release(); let changed = try await task.value
    await expect(.accountChanged) { _ = try await manager.token(for: a) }
    let current = try await manager.token(for: changed); XCTAssertEqual(current, token)
  }
  func testCancelledMigrationKeepsSourceAndDoesNotCommitDestination() async throws {
    let a = try account(), local = HostingFixtureVault(), keychain = HostingFixtureVault()
    let manager = OAuthTokenManager(vault: HostingCredentialRouter(local: local, keychain: keychain)), journal = HostingMigrationFixture(a)
    try await manager.install(token, account: a); await journal.setHold()
    let task = Task { try await manager.migrate(a, to: .keychain, beforeWrite: { await journal.begin(.keychain) }, commit: { try await journal.commit($0) }) }
    while !(await journal.blocked()) { await Task.yield() }
    task.cancel(); await journal.release()
    do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
    let metadata = await journal.account(), active = try await manager.token(for: a)
    XCTAssertEqual(metadata.storageMode, .localVault); XCTAssertEqual(active, token)
  }
  func testForgottenAccountCannotBeResurrectedByStaleWindow() async throws {
    let a = try account(), manager = OAuthTokenManager(vault: HostingFixtureVault())
    try await manager.install(token, account: a); try await manager.forget(a)
    await expect(.accountChanged) { try await manager.unlock(a) }
    await expect(.accountChanged) { _ = try await manager.token(for: a) }
  }
  func testRefreshOnEveryProviderAndStoragePreservesCompleteRotatedPair() async throws {
    for provider in HostingProvider.allCases {
      for mode in HostingStorageMode.allCases {
        let a = try account(mode, provider: provider), local = LocalEncryptedCredentialStore(root: root), keychain = HostingFixtureVault()
        let router = HostingCredentialRouter(local: local, keychain: keychain)
        let response = HostingHTTPResponse(data: Data("{\"access_token\":\"fresh\",\"refresh_token\":\"rotated\",\"expires_in\":3600}".utf8))
        let transport = HostingFixtureTransport([response]), manager = OAuthTokenManager(vault: router, oauth: OAuthAuthorizationCoordinator(http: HostingHTTPClient(transport: transport)))
        try await manager.install(HostingToken(accessToken: "old", refreshToken: "old-refresh", expiresAt: .distantPast), account: a)
        let beforeKey = mode == .localVault ? try Data(contentsOf: key(a)) : nil
        let fresh = try await manager.token(for: a), saved = try await router.read(account: a), requests = await transport.captured()
        XCTAssertEqual(fresh.refreshToken, "rotated"); XCTAssertEqual(saved, fresh); XCTAssertEqual(requests.count, 1)
        if mode == .localVault { XCTAssertEqual(try Data(contentsOf: key(a)), beforeKey) }
        let restart = OAuthTokenManager(vault: router)
        if mode == .keychain { try await restart.unlock(a) }
        let restored = try await restart.token(for: a); XCTAssertEqual(restored, fresh)
      }
    }
  }
  func testRecoveryMarkerPreventsRestartFromLoadingKnownStalePair() async throws {
    var a = try account(); let vault = HostingFixtureVault()
    try await vault.save(token, account: a); a.credentialRecoveryRequired = true
    let restarted = OAuthTokenManager(vault: vault)
    await expect(.unauthorized) { _ = try await restarted.token(for: a) }
    let counts = await vault.counts(); XCTAssertEqual(counts.0, 0)
    var clean = a; clean.credentialRecoveryRequired = false
    try await restarted.install(token, account: clean)
    let current = try await restarted.token(for: clean); XCTAssertEqual(current, token)
  }
  func testMigrationRefusesActiveRefreshInsteadOfMovingAnObsoletePair() async throws {
    let a = try account(), vault = HostingRotationGateVault()
    let transport = HostingFixtureTransport([HostingHTTPResponse(data: Data("{\"access_token\":\"fresh\",\"refresh_token\":\"rotated\"}".utf8))])
    let manager = OAuthTokenManager(vault: vault, oauth: OAuthAuthorizationCoordinator(http: HostingHTTPClient(transport: transport)))
    try await manager.install(HostingToken(accessToken: "old", refreshToken: "old-refresh", expiresAt: .distantPast), account: a)
    let refreshing = Task { try await manager.token(for: a) }
    while !(await vault.blocked()) { await Task.yield() }
    await expect(.operationInProgress) { _ = try await manager.migrate(a, to: .keychain, commit: { _ in }) }
    await vault.release(); let current = try await refreshing.value; XCTAssertEqual(current.refreshToken, "rotated")
  }

  func testReauthorizationMigrationCommitsNewClientAndScopesAtomically() async throws {
    let a = try account(.keychain), local = HostingFixtureVault(), keychain = HostingFixtureVault()
    var updated = a; updated.oauth?.clientID = "replacement-client"; updated.scopes = ["api"]
    let manager = OAuthTokenManager(vault: HostingCredentialRouter(local: local, keychain: keychain)), journal = HostingMigrationFixture(a)
    let changed = try await manager.migrate(a, to: .localVault, replacement: token, authorizedAccount: updated, commit: { try await journal.commit($0) })
    let committed = await journal.account()
    XCTAssertEqual(changed.oauth?.clientID, "replacement-client"); XCTAssertEqual(committed.scopes, ["api"])
  }
  func testFailedReauthorizationMigrationRetainsFreshSessionWithoutOverwritingSource() async throws {
    let a = try account(.keychain), local = HostingFixtureVault(), keychain = HostingFixtureVault()
    let manager = OAuthTokenManager(vault: HostingCredentialRouter(local: local, keychain: keychain))
    let original = HostingToken(accessToken: "old-pair")
    try await manager.install(original, account: a); await local.setReject(true)
    await expect(.sessionOnly) { _ = try await manager.migrate(a, to: .localVault, replacement: token, commit: { _ in }) }
    let active = try await manager.token(for: a), source = try await keychain.read(account: a)
    XCTAssertEqual(active, token); XCTAssertEqual(source, original)
  }

  func testStaleReauthorizationConfigurationCannotRefreshNewSession() async throws {
    let old = try account(), vault = HostingFixtureVault(), manager = OAuthTokenManager(vault: vault)
    try await manager.install(token, account: old)
    var updated = old; updated.oauth?.clientID = "new-client"
    try await manager.install(token, account: updated)
    await expect(.accountChanged) { _ = try await manager.token(for: old) }
    let current = try await manager.token(for: updated); XCTAssertEqual(current, token)
  }
  func testPersistenceFailureEmitsAccountOnlyRecoveryEventBeforeReturning() async throws {
    let a = try account(), vault = HostingFixtureVault(), events = HostingMigrationFixture(a)
    let manager = OAuthTokenManager(vault: vault, persistenceFailed: { account in
      var recovery = account; recovery.credentialRecoveryRequired = true; try? await events.commit(recovery)
    })
    await vault.setReject(true)
    await expect(.sessionOnly) { try await manager.install(token, account: a) }
    let recovery = await events.account(); XCTAssertTrue(recovery.credentialRecoveryRequired)
  }

  func testForeignOAuthRefreshInstanceIsRejectedBeforeStorageOrNetwork() async throws {
    var a = try account()
    a.oauth = OAuthConfiguration(instance: try HostingInstance(provider: .gitlab, url: "https://foreign.invalid"), clientID: "fixture")
    let vault = HostingFixtureVault(), transport = HostingFixtureTransport()
    let manager = OAuthTokenManager(vault: vault, oauth: OAuthAuthorizationCoordinator(http: HostingHTTPClient(transport: transport)))
    await expect(.accountChanged) { try await manager.install(token, account: a) }
    await expect(.accountChanged) { _ = try await manager.token(for: a) }
    let counts = await vault.counts(), requests = await transport.captured()
    XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0); XCTAssertTrue(requests.isEmpty)
    let store = HostingMetadataStore(url: root.appendingPathComponent("hosting.json")); var metadata = HostingMetadata(); metadata.accounts = [a]
    try store.save(metadata); XCTAssertThrowsError(try store.load())
  }

  func testDeniedOldKeychainCleanupDoesNotBlockNewLocalStorage() async throws {
    let a = try account(.keychain), local = LocalEncryptedCredentialStore(root: root), keychain = HostingFixtureVault()
    let router = HostingCredentialRouter(local: local, keychain: keychain), manager = OAuthTokenManager(vault: router)
    try await manager.install(token, account: a)
    let changed = try await manager.migrate(a, to: .localVault, commit: { _ in })
    await keychain.setReject(true)
    await expect(.keychainDenied) { try await manager.cleanup(changed, mode: .keychain) }
    let restarted = OAuthTokenManager(vault: router), restored = try await restarted.token(for: changed)
    XCTAssertEqual(restored, token); XCTAssertEqual(changed.storageMode, .localVault)
    await keychain.setReject(false); let original = try await keychain.read(account: a); XCTAssertEqual(original, token)
  }

  func testFreshProcessRestoresBothBackendsAndMigratedAccount() async throws {
    let probe = "GITPIER_HOSTING_RESTART_FIXTURE", serviceKey = "GITPIER_HOSTING_RESTART_SERVICE"
    if let path = ProcessInfo.processInfo.environment[probe] {
      let fixture = URL(fileURLWithPath: path)
      guard fixture.lastPathComponent.hasPrefix("GitPier-dual-vault-"),
        let service = ProcessInfo.processInfo.environment[serviceKey], service.hasPrefix("GitPier.hosting.synthetic.restart.") else { throw HostingError.configurationUnreadable }
      let metadata = try HostingMetadataStore(url: fixture.appendingPathComponent("hosting.json")).load()
      let manager = OAuthTokenManager(vault: HostingCredentialRouter(root: fixture.appendingPathComponent("credentials"), keychain: HostingKeychainStore(service: service)))
      XCTAssertEqual(metadata.accounts.count, 3)
      for account in metadata.accounts {
        if account.storageMode == .keychain { try await manager.unlock(account) }
        let restored = try await manager.token(for: account); XCTAssertEqual(restored, token)
      }
      print("HOSTING_FRESH_PROCESS_RESTORED")
      return
    }
    let service = "GitPier.hosting.synthetic.restart." + UUID().uuidString
    let keychain = HostingKeychainStore(service: service)
    let a = try account(), b = try account(.keychain, user: "43"), c = try account(.keychain, provider: .gitea, user: "44")
    let manager = OAuthTokenManager(vault: HostingCredentialRouter(root: root.appendingPathComponent("credentials"), keychain: keychain))
    do {
      for account in [a, b, c] { try await manager.install(token, account: account) }
      let migrated = try await manager.migrate(b, to: .localVault, commit: { _ in })
      var metadata = HostingMetadata(); metadata.accounts = [a, migrated, c]
      try HostingMetadataStore(url: root.appendingPathComponent("hosting.json")).save(metadata)
      let result = try await ProcessRunner().run(executable: "/usr/bin/xcrun", arguments: ["xctest", "-XCTest",
        "GitPierCoreTests.HostingCredentialTests/testFreshProcessRestoresBothBackendsAndMigratedAccount",
        Bundle(for: HostingCredentialTests.self).bundleURL.path], directory: nil,
        environment: [probe: root.path, serviceKey: service], timeout: 30)
      XCTAssertEqual(result.code, 0, result.errorText + result.text)
      XCTAssertTrue(result.text.contains("HOSTING_FRESH_PROCESS_RESTORED"), result.errorText + result.text)
    } catch {
      try? await keychain.delete(account: b); try? await keychain.delete(account: c); throw error
    }
    try await keychain.delete(account: b); try await keychain.delete(account: c)
    let first = try await keychain.read(account: b), second = try await keychain.read(account: c)
    XCTAssertNil(first); XCTAssertNil(second)
  }

  func testReauthorizationJournalFailureKeepsFreshSessionAndSource() async throws {
    let a = try account(.keychain), local = HostingFixtureVault(), keychain = HostingFixtureVault()
    let manager = OAuthTokenManager(vault: HostingCredentialRouter(local: local, keychain: keychain))
    let original = HostingToken(accessToken: "old-pair")
    try await manager.install(original, account: a)
    await expect(.sessionOnly) {
      _ = try await manager.migrate(a, to: .localVault, replacement: token, beforeWrite: { throw HostingError.storageFailure }, commit: { _ in throw HostingError.invalidResponse })
    }
    let active = try await manager.token(for: a), persisted = try await keychain.read(account: a), targetCounts = await local.counts()
    XCTAssertEqual(active, token); XCTAssertEqual(persisted, original); XCTAssertEqual(targetCounts.1, 0)
  }
  func testCancelledReauthorizationMigrationDoesNotReplaceOriginalSession() async throws {
    let a = try account(.keychain), local = HostingFixtureVault(), keychain = HostingFixtureVault()
    let manager = OAuthTokenManager(vault: HostingCredentialRouter(local: local, keychain: keychain))
    let original = HostingToken(accessToken: "old-pair")
    try await manager.install(original, account: a)
    do {
      _ = try await manager.migrate(a, to: .localVault, replacement: token, beforeWrite: { throw CancellationError() }, commit: { _ in })
      XCTFail("Expected cancellation")
    } catch is CancellationError {} catch { XCTFail("Unexpected error") }
    let active = try await manager.token(for: a), targetCounts = await local.counts(), transient = await manager.isSessionOnly(a.id)
    XCTAssertEqual(active, original); XCTAssertEqual(targetCounts.1, 0); XCTAssertFalse(transient)
  }

}
