import CryptoKit
import Foundation
import XCTest
@testable import GitPierCore

/// In-memory stand-in only. These tests never construct HostingKeychainStore.
private actor UpgradeSyntheticKeychain: HostingCredentialStore {
  private var values: [UUID: HostingToken] = [:]
  private var reads = 0
  private var writes = 0
  private var denied = false
  func deny() { denied = true }
  func read(account: HostingAccount) throws -> HostingToken? {
    reads += 1
    if denied { throw HostingError.keychainDenied }
    return values[account.id]
  }
  func save(_ token: HostingToken, account: HostingAccount) throws {
    if denied { throw HostingError.keychainDenied }
    writes += 1; values[account.id] = token
  }
  func delete(account: HostingAccount) throws {
    if denied { throw HostingError.keychainDenied }
    values[account.id] = nil
  }
  func counts() -> (Int, Int) { (reads, writes) }
}

@MainActor final class HostingReviewUpgradeTests: XCTestCase {
  private let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-review-upgrade-" + UUID().uuidString)
  deinit { try? FileManager.default.removeItem(at: root) }

  private let firstID = "11111111-1111-4111-8111-111111111111"
  private let secondID = "22222222-2222-4222-8222-222222222222"
  private let repositoryID = "33333333-3333-4333-8333-333333333333"
  private var metadataStore: HostingMetadataStore { HostingMetadataStore(url: root.appendingPathComponent("workspace.hosting.json")) }
  private var vaultRoot: URL { root.appendingPathComponent("HostingCredentials") }
  private var journalRoot: URL { root.appendingPathComponent("review-operations") }

  // Fixed v1.6.0 wire shapes, deliberately not encoded from current models.
  private var firstAccountJSON: String {
    #"{"id":"11111111-1111-4111-8111-111111111111","instance":{"provider":"github","baseURL":"https://github.com"},"user":{"stableID":"42","login":"old-local-account","name":"Legacy Local"},"kind":"pat","scopes":["public_repo"],"storageMode":"localVault","pendingCleanup":[],"credentialRecoveryRequired":false}"#
  }
  private var secondAccountJSON: String {
    #"{"id":"22222222-2222-4222-8222-222222222222","instance":{"provider":"gitlab","baseURL":"https://forge.example.invalid/git"},"user":{"stableID":"84","login":"old-oauth-account","name":"Legacy OAuth"},"kind":"oauth","scopes":["api"],"oauth":{"instance":{"provider":"gitlab","baseURL":"https://forge.example.invalid/git"},"clientID":"synthetic-upgrade-client","redirect":{"application":{}}},"storageMode":"localVault","pendingCleanup":[],"credentialRecoveryRequired":false}"#
  }
  private func account(_ second: Bool = false) throws -> HostingAccount {
    try JSONDecoder().decode(HostingAccount.self, from: Data((second ? secondAccountJSON : firstAccountJSON).utf8))
  }
  private func makeDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }
  private func write(_ data: Data, to url: URL) throws {
    try makeDirectory(url.deletingLastPathComponent())
    try data.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  private func installMetadata() throws -> HostingMetadata {
    let bytes = Data("""
      {"version":2,"defaultStorageMode":"localVault","accounts":[\(firstAccountJSON),\(secondAccountJSON)],
       "disconnectedAccounts":[],"configurations":[],"bindings":[
       {"repositoryID":"\(repositoryID)","accountID":"\(firstID)","remote":"origin","repository":"owner/repo"}]}
      """.utf8)
    try write(bytes, to: metadataStore.url)
    return try metadataStore.load()
  }

  /// Construct the legacy AES-GCM envelope independently of the production writer.
  /// Keys/nonces/tokens below are public synthetic test values, never user data.
  private func installLegacyVault(second: Bool = false, expired: Bool = false) throws -> HostingToken {
    let a = try account(second)
    let keyID = second ? "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC" : "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    let generation = second ? "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD" : "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    let aad = second
      ? #"{"account":"22222222-2222-4222-8222-222222222222","generation":"DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD","instance":"https:\/\/forge.example.invalid\/git","key":"CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC","provider":"gitlab","user":"84","version":1}"#
      : #"{"account":"11111111-1111-4111-8111-111111111111","generation":"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB","instance":"https:\/\/github.com","key":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","provider":"github","user":"42","version":1}"#
    let plain = second
      ? "{\"accessToken\":\"synthetic-upgrade-oauth\",\"refreshToken\":\"synthetic-upgrade-refresh\",\"tokenType\":\"bearer\",\"scopes\":[\"api\"]" + (expired ? ",\"expiresAt\":0}" : "}")
      : #"{"accessToken":"synthetic-upgrade-local","tokenType":"bearer","scopes":["public_repo"]}"#
    let key = Data((0..<32).map { UInt8($0 + (second ? 32 : 0)) })
    let nonce = try AES.GCM.Nonce(data: Data(repeating: second ? 0x22 : 0x11, count: 12))
    let sealed = try AES.GCM.seal(Data(plain.utf8), using: SymmetricKey(data: key), nonce: nonce, authenticating: Data(aad.utf8))
    try write(key, to: vaultRoot.appendingPathComponent("keys/\(a.id.uuidString).\(keyID).key"))
    try write(XCTUnwrap(sealed.combined), to: vaultRoot.appendingPathComponent("vault/\(a.id.uuidString).\(generation).sealed"))
    try write(Data("{\"version\":1,\"key\":\"\(keyID)\",\"generation\":\"\(generation)\"}".utf8),
              to: vaultRoot.appendingPathComponent("vault/\(a.id.uuidString).json"))
    return try JSONDecoder().decode(HostingToken.self, from: Data(plain.utf8))
  }
  private func manager(_ keychain: UpgradeSyntheticKeychain) -> OAuthTokenManager {
    OAuthTokenManager(vault: HostingCredentialRouter(root: vaultRoot, keychain: keychain))
  }
  private func credentialBytes() throws -> [String: Data] {
    var result: [String: Data] = [:]
    for directory in ["keys", "vault"] {
      for file in try FileManager.default.contentsOfDirectory(at: vaultRoot.appendingPathComponent(directory), includingPropertiesForKeys: nil) {
        result[directory + "/" + file.lastPathComponent] = try Data(contentsOf: file)
      }
    }
    return result
  }

  func testV160WorkspaceSettingsSelectionAndBindingRemainReadableAndRoundTrip() throws {
    let file = root.appendingPathComponent("workspace.json")
    try write(Data("""
      {"version":2,"repositories":[{"id":"\(repositoryID)","path":"/synthetic/upgrade-repository","name":"Legacy Repo",
       "group":"Existing Group","favorite":true,"lastOpened":123456,"useDefaultCredential":true,
       "draft":"unsent Git commit draft","layout":{"changesWidth":321,"terminalVisible":true}}],
       "organizations":[{"id":"44444444-4444-4444-8444-444444444444","name":"Existing Group"}],
       "credentials":[],"selectedRepository":"\(repositoryID)","settings":{"language":"simplifiedChinese","appearance":"dark",
       "shellPath":"/bin/bash","loginShell":false,"diffFontSize":16,"automaticFetch":true,
       "remoteCheckIntervalMinutes":30,"remoteCheckScope":"current","launchPage":"dashboard","refreshPolicyVersion":1,"automaticRefresh":true}}
      """.utf8), to: file)
    let store = ConfigurationStore(url: file), before = try store.load()
    XCTAssertEqual(before.selectedRepository?.uuidString, repositoryID)
    XCTAssertEqual(before.repositories.first?.draft, "unsent Git commit draft")
    XCTAssertEqual(before.repositories.first?.layout.changesWidth, 321)
    XCTAssertEqual(before.settings.language, .simplifiedChinese)
    XCTAssertEqual(before.settings.appearance, .dark)
    XCTAssertTrue(before.settings.automaticFetch); XCTAssertTrue(before.settings.automaticRefresh)
    XCTAssertEqual(before.settings.remoteCheckIntervalMinutes, 30)
    XCTAssertEqual(before.settings.launchPage, "dashboard")
    try store.save(before)
    let after = try ConfigurationStore(url: file).load()
    XCTAssertEqual(after.repositories, before.repositories); XCTAssertEqual(after.settings, before.settings)
    XCTAssertEqual(after.organizations, before.organizations); XCTAssertEqual(after.selectedRepository, before.selectedRepository)
    let hosting = try installMetadata()
    XCTAssertEqual(hosting.bindings.first?.repositoryID, after.selectedRepository)
    XCTAssertEqual(hosting.bindings.first?.accountID.uuidString, firstID)
    XCTAssertEqual(hosting.bindings.first?.repository, "owner/repo")
  }

  func testLegacyMetadataWithoutStorageFieldKeepsKeychainAndRequiresExplicitUnlock() async throws {
    let old = #"{"version":1,"accounts":[{"id":"11111111-1111-4111-8111-111111111111","instance":{"provider":"github","baseURL":"https://github.com"},"user":{"stableID":"42","login":"old-keychain-account","name":"Legacy Keychain"},"kind":"pat","scopes":[]}],"configurations":[],"bindings":[]}"#
    try write(Data(old.utf8), to: metadataStore.url)
    let metadata = try metadataStore.load(), a = try XCTUnwrap(metadata.accounts.first)
    XCTAssertEqual(metadata.version, 2); XCTAssertEqual(a.storageMode, .keychain)
    let keychain = UpgradeSyntheticKeychain(), tokens = manager(keychain)
    let secret = HostingToken(accessToken: "synthetic-keychain-upgrade")
    try await keychain.save(secret, account: a)
    do { _ = try await tokens.token(for: a); XCTFail("Legacy Keychain must not read in the background") }
    catch { XCTAssertEqual(error as? HostingError, .credentialsLocked) }
    let before = await keychain.counts(); XCTAssertEqual(before.0, 0)
    try await tokens.unlock(a)
    let restored = try await tokens.token(for: a); XCTAssertEqual(restored, secret)
    let after = await keychain.counts(); XCTAssertEqual(after.0, 1)
  }

  func testV160IndependentAESFixturesRestoreMultipleAccountsWithoutKeychain() async throws {
    let metadata = try installMetadata(), firstToken = try installLegacyVault(), secondToken = try installLegacyVault(second: true)
    let before = try credentialBytes(), keychain = UpgradeSyntheticKeychain()
    let tokens = manager(keychain)
    let first = try await tokens.token(for: metadata.accounts[0]), second = try await tokens.token(for: metadata.accounts[1])
    XCTAssertEqual(first, firstToken); XCTAssertEqual(second, secondToken)
    let fresh = manager(keychain), restored = try await fresh.token(for: metadata.accounts[0])
    XCTAssertEqual(restored, firstToken); XCTAssertEqual(try credentialBytes(), before)
    let counts = await keychain.counts(); XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
  }

  func testV160OAuthPairRefreshesAndFreshManagerReadsRotatedTokenWithoutKeychain() async throws {
    let a = try account(true); _ = try installLegacyVault(second: true, expired: true)
    let keychain = UpgradeSyntheticKeychain()
    let response = HostingHTTPResponse(data: Data(#"{"access_token":"synthetic-refreshed-upgrade","refresh_token":"synthetic-refreshed-pair","token_type":"Bearer","expires_in":3600,"scope":"api"}"#.utf8), status: 200, headers: [:])
    let transport = HostingFixtureTransport([response])
    let tokens = OAuthTokenManager(vault: HostingCredentialRouter(root: vaultRoot, keychain: keychain),
      oauth: OAuthAuthorizationCoordinator(http: HostingHTTPClient(transport: transport)))
    let refreshed = try await tokens.token(for: a)
    XCTAssertEqual(refreshed.accessToken, "synthetic-refreshed-upgrade")
    XCTAssertEqual(refreshed.refreshToken, "synthetic-refreshed-pair")
    let restarted = manager(keychain), restored = try await restarted.token(for: a)
    XCTAssertEqual(restored, refreshed)
    let requests = await transport.captured()
    XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests.first?.httpMethod, "POST")
    XCTAssertEqual(requests.first?.url?.path, "/git/oauth/token")
    let counts = await keychain.counts(); XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
  }

  func testSyntheticKeychainDenialDoesNotLoopOrPreventOldLocalRestoration() async throws {
    let local = try account(), expected = try installLegacyVault()
    var locked = try account(true); locked.storageMode = .keychain
    let keychain = UpgradeSyntheticKeychain(); await keychain.deny()
    let tokens = manager(keychain)
    do { try await tokens.unlock(locked); XCTFail("Synthetic denial must propagate") }
    catch { XCTAssertEqual(error as? HostingError, .keychainDenied) }
    for _ in 0..<3 {
      do { _ = try await tokens.token(for: locked); XCTFail("Explicit Verify is required again") }
      catch { XCTAssertEqual(error as? HostingError, .credentialsLocked) }
    }
    let restored = try await tokens.token(for: local); XCTAssertEqual(restored, expected)
    let counts = await keychain.counts(); XCTAssertEqual(counts.0, 1)
  }

  func testOldLocalPairMigratesBothDirectionsAndOnlyExplicitCleanupDeletesSource() async throws {
    _ = try installMetadata()
    let a = try account(), expected = try installLegacyVault(), keychain = UpgradeSyntheticKeychain()
    let tokens = manager(keychain), store = metadataStore
    _ = try await tokens.token(for: a)
    let keychainAccount = try await tokens.migrate(a, to: .keychain, commit: { next in
      var metadata = try store.load(); metadata.accounts[0] = next; try store.save(metadata)
    })
    let original = try await LocalEncryptedCredentialStore(root: vaultRoot).read(account: a)
    XCTAssertEqual(original, expected)
    XCTAssertEqual(try store.load().accounts[0].storageMode, .keychain)
    try await tokens.cleanup(keychainAccount, mode: .localVault)
    let removed = try await LocalEncryptedCredentialStore(root: vaultRoot).read(account: a); XCTAssertNil(removed)
    let localAccount = try await tokens.migrate(keychainAccount, to: .localVault, commit: { next in
      var metadata = try store.load(); metadata.accounts[0] = next; try store.save(metadata)
    })
    let oldKeychain = try await keychain.read(account: keychainAccount); XCTAssertEqual(oldKeychain, expected)
    try await tokens.cleanup(localAccount, mode: .keychain)
    let deleted = try await keychain.read(account: keychainAccount); XCTAssertNil(deleted)
    let restarted = manager(keychain), restored = try await restarted.token(for: try store.load().accounts[0])
    XCTAssertEqual(restored, expected)
  }

  func testV160DisconnectionSidecarSurvivesUpgradeWithoutDeletingCredentialBytes() async throws {
    _ = try installMetadata(); _ = try installLegacyVault()
    let otherToken = try installLegacyVault(second: true), before = try credentialBytes()
    let sidecar = metadataStore.url.deletingLastPathComponent().appendingPathComponent(metadataStore.url.lastPathComponent + ".disconnects/" + firstID + ".json")
    let bytes = Data("{\"version\":1,\"record\":{\"account\":\(firstAccountJSON),\"remainingStorage\":[\"localVault\"]}}".utf8)
    try write(bytes, to: sidecar)
    let restored = try metadataStore.load()
    XCTAssertEqual(restored.accounts.map(\.id.uuidString), [secondID]); XCTAssertTrue(restored.bindings.isEmpty)
    XCTAssertEqual(restored.disconnectedAccounts.map(\.id.uuidString), [firstID])
    XCTAssertEqual(try Data(contentsOf: sidecar), bytes); XCTAssertEqual(try credentialBytes(), before)
    let other = try await LocalEncryptedCredentialStore(root: vaultRoot).read(account: restored.accounts[0])
    XCTAssertEqual(other, otherToken)
  }

  func testMissingNewJournalLeavesOldMetadataAndVaultReadable() async throws {
    _ = try installMetadata(); let expected = try installLegacyVault()
    let metadataBytes = try Data(contentsOf: metadataStore.url), credentials = try credentialBytes()
    XCTAssertTrue(try HostingReviewOperationJournal(root: journalRoot).records().isEmpty)
    let restored = try metadataStore.load(), keychain = UpgradeSyntheticKeychain()
    let token = try await manager(keychain).token(for: restored.accounts[0])
    XCTAssertEqual(token, expected); XCTAssertEqual(restored.bindings.count, 1)
    XCTAssertEqual(try Data(contentsOf: metadataStore.url), metadataBytes); XCTAssertEqual(try credentialBytes(), credentials)
    let counts = await keychain.counts(); XCTAssertEqual(counts.0, 0)
  }

  func testCorruptAndUnknownNewJournalPreserveOldMetadataAndVault() async throws {
    _ = try installMetadata(); let expected = try installLegacyVault()
    let metadataBytes = try Data(contentsOf: metadataStore.url), credentials = try credentialBytes()
    let file = journalRoot.appendingPathComponent("55555555-5555-4555-8555-555555555555.json")
    let cases: [(String, HostingReviewJournalError)] = [
      ("{broken-json", .corrupt),
      (#"{"version":999,"confirmationID":"55555555-5555-4555-8555-555555555555","records":[]}"#, .unsupportedSchema),
    ]
    for (source, expectedError) in cases {
      let bytes = Data(source.utf8); try write(bytes, to: file)
      XCTAssertThrowsError(try HostingReviewOperationJournal(root: journalRoot).records()) {
        XCTAssertEqual($0 as? HostingReviewJournalError, expectedError)
      }
      XCTAssertEqual(try Data(contentsOf: file), bytes)
      let restored = try metadataStore.load(), keychain = UpgradeSyntheticKeychain()
      let token = try await manager(keychain).token(for: restored.accounts[0]); XCTAssertEqual(token, expected)
      XCTAssertEqual(try Data(contentsOf: metadataStore.url), metadataBytes); XCTAssertEqual(try credentialBytes(), credentials)
      let counts = await keychain.counts(); XCTAssertEqual(counts.0, 0)
    }
  }

  func testPossiblySentNewJournalRecoversBesideV160DataWithoutPersistingComment() async throws {
    let metadata = try installMetadata(), a = metadata.accounts[0], expected = try installLegacyVault()
    let context = HostingReviewContext(target: HostingReviewTarget(instance: a.instance, accountID: a.id, userID: a.user.stableID,
      repository: "owner/repo", repositoryID: "88", requestNumber: 7, requestID: "99"),
      revision: HostingReviewRevision(headSHA: String(repeating: "a", count: 40)),
      capabilities: Set(HostingReviewCapability.allCases), state: "open", authorID: "7")
    let body = "synthetic-private-comment-not-for-disk"
    let confirmation = try HostingReviewConfirmation(context: context, items: [HostingReviewSubmissionItem(mutation: .comment(body: body))])
    let journal = HostingReviewOperationJournal(root: journalRoot)
    try journal.prepare(confirmation)
    try journal.update(confirmationID: confirmation.id, itemID: confirmation.items[0].id, state: .possiblySent)
    let recovered = try HostingReviewOperationJournal(root: journalRoot).records()
    XCTAssertEqual(recovered.count, 1); XCTAssertEqual(recovered.first?.state, .resultUnknown)
    XCTAssertTrue(try XCTUnwrap(recovered.first).needsManualCheck)
    let journalBytes = try Data(contentsOf: journalRoot.appendingPathComponent(confirmation.id.uuidString + ".json"))
    XCTAssertFalse(String(decoding: journalBytes, as: UTF8.self).contains(body))
    XCTAssertEqual(try metadataStore.load().accounts, metadata.accounts)
    let token = try await LocalEncryptedCredentialStore(root: vaultRoot).read(account: a); XCTAssertEqual(token, expected)
  }
}
