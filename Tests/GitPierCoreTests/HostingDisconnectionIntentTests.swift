import Darwin
import XCTest
@testable import GitPierCore

final class HostingDisconnectionIntentTests: XCTestCase, @unchecked Sendable {
  private var root: URL!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-disconnection-intent-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
  private var store: HostingMetadataStore { HostingMetadataStore(url: root.appendingPathComponent("hosting.json")) }
  private var journal: URL { root.appendingPathComponent("hosting.json.disconnects") }
  private func intentURL(_ id: UUID) -> URL { journal.appendingPathComponent(id.uuidString + ".json") }
  private func account(_ mode: HostingStorageMode = .localVault, id: UUID = UUID(), user: String = "42") throws -> HostingAccount {
    HostingAccount(id: id, instance: try HostingInstance(provider: .github, url: "https://github.com"),
      user: HostingUser(stableID: user, login: "fixture-" + user), kind: .pat, scopes: [], storageMode: mode)
  }
  private func active(_ accounts: [HostingAccount]) throws -> HostingMetadata {
    var value = HostingMetadata(); value.accounts = accounts
    value.bindings = try accounts.map { try RepositoryHostingBinding(repositoryID: UUID(), accountID: $0.id, remote: "origin", repository: "example/fixture") }
    try store.save(value); return value
  }
  private func writeIntentObject(_ object: [String: Any], at url: URL) throws {
    try JSONSerialization.data(withJSONObject: object).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  private func object(_ id: UUID) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: intentURL(id))) as? [String: Any])
  }

  func testIntentSuppressesStaleActiveAccountAndItsBindingOnly() throws {
    let removed = try account(), other = try account(user: "77"), value = try active([removed, other])
    try store.recordDisconnection(HostingDisconnectedAccount(account: removed))
    let restored = try HostingMetadataStore(url: store.url).load()
    XCTAssertEqual(restored.accounts, [other])
    XCTAssertEqual(restored.bindings, value.bindings.filter { $0.accountID == other.id })
    XCTAssertEqual(restored.disconnectedAccounts.map(\.id), [removed.id])
    // The independent journal recovers a crash before the main metadata replacement.
    XCTAssertEqual(try JSONDecoder().decode(HostingMetadata.self, from: Data(contentsOf: store.url)).accounts.count, 2)
  }

  func testIntentRestoresExplicitCleanupWhenMainMetadataIsMissing() throws {
    let removed = try account(.keychain)
    try store.recordDisconnection(HostingDisconnectedAccount(account: removed))
    let restored = try store.load()
    XCTAssertTrue(restored.accounts.isEmpty)
    XCTAssertEqual(restored.disconnectedAccounts, [HostingDisconnectedAccount(account: removed)])
  }

  func testFailedMainReplacementCannotResurrectOldMetadataAfterRecovery() throws {
    let removed = try account(), old = try active([removed])
    let oldBytes = try Data(contentsOf: store.url)
    try store.recordDisconnection(HostingDisconnectedAccount(account: removed))
    try FileManager.default.removeItem(at: store.url)
    try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
    var disconnected = old; disconnected.accounts = []; disconnected.bindings = []
    disconnected.disconnectedAccounts = [HostingDisconnectedAccount(account: removed)]
    XCTAssertThrowsError(try store.save(disconnected))
    try FileManager.default.removeItem(at: store.url)
    try oldBytes.write(to: store.url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path)
    XCTAssertTrue(try store.load().accounts.isEmpty)
    XCTAssertEqual(try store.load().disconnectedAccounts.map(\.id), [removed.id])
  }

  func testNewerMainCleanupCheckpointIsNotExpandedByOlderIntent() throws {
    var removed = try account(); removed.pendingCleanup = [.keychain]
    try store.recordDisconnection(HostingDisconnectedAccount(account: removed))
    var record = HostingDisconnectedAccount(account: removed); record.remainingStorage = [.keychain]
    var value = HostingMetadata(); value.disconnectedAccounts = [record]; try store.save(value)
    XCTAssertEqual(try store.load().disconnectedAccounts.first?.remainingStorage, [.keychain])
  }

  func testNewerIntentCleanupCheckpointIsNotExpandedByOlderMainMetadata() throws {
    var removed = try account(); removed.pendingCleanup = [.keychain]
    var record = HostingDisconnectedAccount(account: removed)
    var value = HostingMetadata(); value.disconnectedAccounts = [record]; try store.save(value)
    record.remainingStorage = [.keychain]; try store.recordDisconnection(record)
    XCTAssertEqual(try store.load().disconnectedAccounts.first?.remainingStorage, [.keychain])
  }

  func testCompletedIntentRemainsAnExplicitRetryRowUntilFinalRemovalIsSaved() throws {
    let removed = try account(); _ = try active([removed])
    var record = HostingDisconnectedAccount(account: removed); record.remainingStorage = []
    try store.recordDisconnection(record)
    let restored = try store.load()
    XCTAssertTrue(restored.accounts.isEmpty)
    XCTAssertEqual(restored.disconnectedAccounts, [record])
  }

  func testFinalIntentRemovalLeavesOtherAccountJournalUntouched() throws {
    let first = try account(), second = try account(user: "77")
    try store.recordDisconnection(HostingDisconnectedAccount(account: first))
    try store.recordDisconnection(HostingDisconnectedAccount(account: second))
    try store.save(HostingMetadata())
    let otherBytes = try Data(contentsOf: intentURL(second.id))
    try store.removeDisconnectionIntent(first.id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: intentURL(first.id).path))
    XCTAssertEqual(try Data(contentsOf: intentURL(second.id)), otherBytes)
    XCTAssertEqual(try store.load().disconnectedAccounts.map(\.id), [second.id])
  }

  func testFreshConnectionForSameIdentityUsesItsNewUUID() throws {
    let removed = try account(.keychain), fresh = try account(user: removed.user.stableID)
    _ = try active([fresh])
    try store.recordDisconnection(HostingDisconnectedAccount(account: removed))
    XCTAssertEqual(try store.load().accounts, [fresh])
    XCTAssertEqual(try store.load().disconnectedAccounts.map(\.id), [removed.id])
  }

  func testStaleMetadataWriterCannotBypassAnExistingIntent() throws {
    let removed = try account(), stale = try active([removed])
    try store.recordDisconnection(HostingDisconnectedAccount(account: removed))
    try store.save(stale)
    XCTAssertTrue(try store.load().accounts.isEmpty)
  }

  func testCorruptIntentFailsClosedAndPreservesOriginalBytes() throws {
    let removed = try account(); _ = try active([removed])
    try store.recordDisconnection(HostingDisconnectedAccount(account: removed))
    let damaged = Data("{incomplete".utf8); try damaged.write(to: intentURL(removed.id))
    XCTAssertThrowsError(try store.load())
    XCTAssertEqual(try Data(contentsOf: intentURL(removed.id)), damaged)
  }

  func testMismatchedIntentFilenameFailsClosed() throws {
    let removed = try account(); _ = try active([removed])
    try store.recordDisconnection(HostingDisconnectedAccount(account: removed))
    try FileManager.default.moveItem(at: intentURL(removed.id), to: intentURL(UUID()))
    XCTAssertThrowsError(try store.load())
  }

  func testUnknownIntentVersionFailsClosed() throws {
    let removed = try account(); _ = try active([removed])
    try store.recordDisconnection(HostingDisconnectedAccount(account: removed))
    var value = try object(removed.id); value["version"] = 100
    try writeIntentObject(value, at: intentURL(removed.id))
    XCTAssertThrowsError(try store.load())
  }

  func testIntentCannotRevokeDifferentIdentityWithSameUUID() throws {
    let removed = try account(), other = try account(id: removed.id, user: "77")
    _ = try active([other]); try store.recordDisconnection(HostingDisconnectedAccount(account: removed))
    XCTAssertThrowsError(try store.load())
  }

  func testDuplicateStorageModesAreRejectedBeforeJournalWrite() throws {
    let removed = try account(); var record = HostingDisconnectedAccount(account: removed)
    record.remainingStorage = [.localVault, .localVault]
    XCTAssertThrowsError(try store.recordDisconnection(record))
    XCTAssertFalse(FileManager.default.fileExists(atPath: intentURL(removed.id).path))
  }

  func testUnrelatedStorageModeIsNotAddedToCleanup() throws {
    let removed = try account(); var record = HostingDisconnectedAccount(account: removed)
    record.remainingStorage = [.keychain]
    XCTAssertThrowsError(try store.recordDisconnection(record))
  }

  func testJournalDirectorySymlinkIsRejectedWithoutWritingOutside() throws {
    let removed = try account(); _ = try active([removed])
    _ = try store.load()
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.removeItem(at: journal)
    try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: outside)
    XCTAssertThrowsError(try store.recordDisconnection(HostingDisconnectedAccount(account: removed)))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    XCTAssertThrowsError(try store.load())
  }

  func testJournalFileSymlinkIsRejectedForLoadWriteAndRemoval() throws {
    let removed = try account(); try store.recordDisconnection(HostingDisconnectedAccount(account: removed))
    let outside = root.appendingPathComponent("outside.json")
    try FileManager.default.moveItem(at: intentURL(removed.id), to: outside)
    let original = try Data(contentsOf: outside)
    try FileManager.default.createSymbolicLink(at: intentURL(removed.id), withDestinationURL: outside)
    XCTAssertThrowsError(try store.load())
    XCTAssertThrowsError(try store.recordDisconnection(HostingDisconnectedAccount(account: removed)))
    XCTAssertThrowsError(try store.removeDisconnectionIntent(removed.id))
    XCTAssertEqual(try Data(contentsOf: outside), original)
  }

  func testJournalFileHardlinkIsRejectedAndPreserved() throws {
    let removed = try account(); try store.recordDisconnection(HostingDisconnectedAccount(account: removed))
    let duplicate = root.appendingPathComponent("duplicate.json")
    try FileManager.default.linkItem(at: intentURL(removed.id), to: duplicate)
    XCTAssertThrowsError(try store.load())
    XCTAssertThrowsError(try store.removeDisconnectionIntent(removed.id))
    XCTAssertTrue(FileManager.default.fileExists(atPath: duplicate.path))
  }

  func testJournalPermissionsArePrivateAndContainNoCredentialMaterial() throws {
    let removed = try account(); try store.recordDisconnection(HostingDisconnectedAccount(account: removed))
    let folder = try FileManager.default.attributesOfItem(atPath: journal.path)
    let file = try FileManager.default.attributesOfItem(atPath: intentURL(removed.id).path)
    XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    let bytes = String(decoding: try Data(contentsOf: intentURL(removed.id)), as: UTF8.self)
    XCTAssertFalse(bytes.contains("accessToken")); XCTAssertFalse(bytes.contains("refreshToken"))
    XCTAssertFalse(bytes.contains("clientSecret"))
  }

  func testFailedPersistenceNeverReenablesRevokedSessionOrAffectsAnotherAccount() async throws {
    let removed = try account(), other = try account(user: "77"), vault = HostingFixtureVault()
    let manager = OAuthTokenManager(vault: vault), secret = HostingToken(accessToken: "synthetic-intent-only")
    try await manager.install(secret, account: removed); try await manager.install(secret, account: other)
    _ = try active([removed, other]); _ = try store.load()
    try FileManager.default.removeItem(at: journal)
    try Data("blocked".utf8).write(to: journal)
    XCTAssertThrowsError(try store.recordDisconnection(HostingDisconnectedAccount(account: removed)))
    try await manager.stopSession(removed)
    do { _ = try await manager.token(for: removed); XCTFail("Revoked session was restored") }
    catch { XCTAssertEqual(error as? HostingError, .accountChanged) }
    do { try await manager.install(secret, account: removed); XCTFail("Revoked UUID was installed") }
    catch { XCTAssertEqual(error as? HostingError, .accountChanged) }
    let retained = try await manager.token(for: other); XCTAssertEqual(retained, secret)
    let credential = try await vault.read(account: removed); XCTAssertEqual(credential, secret)
    // Explicit retry after disk recovery commits intent; no credential read is needed.
    try FileManager.default.removeItem(at: journal)
    try store.recordDisconnection(HostingDisconnectedAccount(account: removed))
    XCTAssertEqual(try store.load().accounts, [other])
    do { try await manager.unlock(removed); XCTFail("Retry resurrected the old session") }
    catch { XCTAssertEqual(error as? HostingError, .accountChanged) }
  }

  func testFreshProcessAppliesIntentBeforeRestoringAnyCredential() async throws {
    let probe = "GITPIER_DISCONNECTION_INTENT_PROCESS_FIXTURE"
    let secret = HostingToken(accessToken: "synthetic-fresh-process-intent")
    if let path = ProcessInfo.processInfo.environment[probe] {
      let fixture = URL(fileURLWithPath: path)
      guard fixture.lastPathComponent.hasPrefix("GitPier-disconnection-intent-") else { throw HostingError.configurationUnreadable }
      let recovered = try HostingMetadataStore(url: fixture.appendingPathComponent("hosting.json")).load()
      XCTAssertEqual(recovered.accounts.count, 1); XCTAssertEqual(recovered.disconnectedAccounts.count, 1)
      XCTAssertEqual(recovered.accounts.first?.storageMode, .localVault)
      let keychain = HostingFixtureVault(), local = LocalEncryptedCredentialStore(root: fixture.appendingPathComponent("credentials"))
      await keychain.setReject(true)
      let manager = OAuthTokenManager(vault: HostingCredentialRouter(local: local, keychain: keychain))
      for account in recovered.accounts {
        let restored = try await manager.token(for: account); XCTAssertEqual(restored, secret)
      }
      let counts = await keychain.counts(); XCTAssertEqual(counts.0, 0)
      print("DISCONNECTION_INTENT_FRESH_PROCESS_NO_RESTORE")
      return
    }
    let removed = try account(.keychain), other = try account(user: "77")
    _ = try active([removed, other])
    let local = LocalEncryptedCredentialStore(root: root.appendingPathComponent("credentials"))
    try await local.save(secret, account: other)
    try store.recordDisconnection(HostingDisconnectedAccount(account: removed))
    let result = try await ProcessRunner().run(executable: "/usr/bin/xcrun", arguments: ["xctest", "-XCTest",
      "GitPierCoreTests.HostingDisconnectionIntentTests/testFreshProcessAppliesIntentBeforeRestoringAnyCredential",
      Bundle(for: HostingDisconnectionIntentTests.self).bundleURL.path], directory: nil, environment: [probe: root.path], timeout: 30)
    XCTAssertEqual(result.code, 0, result.errorText + result.text)
    XCTAssertTrue(result.text.contains("DISCONNECTION_INTENT_FRESH_PROCESS_NO_RESTORE"), result.errorText + result.text)
  }
}
