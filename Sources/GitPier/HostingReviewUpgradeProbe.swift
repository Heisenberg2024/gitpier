import AppKit
import CryptoKit
import Darwin
import Foundation
import GitPierCore

/// Foundation normalizes the system /private/tmp alias to /tmp on this macOS.
/// Normalize only that alias, then require exact resolution to reject other links.
enum HostingReviewUpgradeProbePathGate {
  static func privatePath(_ path: String) -> String {
    path == "/tmp" || path.hasPrefix("/tmp/") ? "/private" + path : path
  }
  static func accepts(workspace: URL, configuredPath: String, markerPath: String? = nil) -> Bool {
    guard configuredPath.hasPrefix("/private/tmp/GitPier-update-acceptance-"),
      workspace.lastPathComponent == "workspace.json",
      privatePath(workspace.standardizedFileURL.path) == configuredPath,
      privatePath(workspace.resolvingSymlinksInPath().path) == configuredPath
    else { return false }
    if let markerPath {
      guard markerPath.hasPrefix("/private/tmp/GitPier-update-acceptance-"), markerPath == configuredPath else { return false }
    }
    return true
  }
}

/// Explicit local acceptance only. The disk marker survives Sparkle's relaunch;
/// the production identity can never select this path, including via environment.
@MainActor enum HostingReviewUpgradeProbe {
  private struct Request: Decodable {
    let version: Int
    let bundleIdentifier: String
    let workspacePath: String
    let localAccountID: UUID
    let expectedAccessTokenSHA256: String
    let expectedRefreshTokenSHA256: String
    let keychainAccountID: UUID
    let disconnectedAccountID: UUID
    let repositoryID: UUID
    let confirmationID: UUID
    let operationID: UUID
  }
  private struct Result: Encodable {
    let passed: Bool
    let actualApplicationProcess: Bool
    let applicationVersion: String
    let applicationBuild: String
    let accountIDs: [UUID]
    let checks: [String: Bool]
  }
  private static let localID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  private static let keychainID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
  private static let disconnectedID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
  private static let repositoryID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
  private static let confirmationID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
  private static let operationID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
  private static func hash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  private static func privateFile(_ url: URL) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
    return attributes[.type] as? FileAttributeType == .typeRegular
      && (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
      && (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
      && (attributes[.referenceCount] as? NSNumber)?.intValue == 1
  }
  static func runIfRequested(store: AppStore) async {
    let info = Bundle.main
    guard info.object(forInfoDictionaryKey: "GitPierTestingUpdates") as? Bool == true,
      let identity = info.bundleIdentifier, identity.hasPrefix("com.heisenberg2024.gitpier.update-test."),
      let version = info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
      let build = info.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
      ["1.6.1:28", "1.7.0:29"].contains(version + ":" + build),
      let configuredPath = info.object(forInfoDictionaryKey: "GitPierTestWorkspacePath") as? String
    else { return }
    let workspace = store.persistence.url
    let runtime = URL(fileURLWithPath: configuredPath).deletingLastPathComponent()
    let runtimePath = HostingReviewUpgradeProbePathGate.privatePath(runtime.path)
    guard HostingReviewUpgradeProbePathGate.accepts(workspace: workspace, configuredPath: configuredPath),
      let attributes = try? FileManager.default.attributesOfItem(atPath: runtime.path),
      attributes[.type] as? FileAttributeType == .typeDirectory,
      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
      (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700
    else { return }
    let requestFile = runtime.appendingPathComponent("review-upgrade-probe-request.json")
    guard privateFile(requestFile), let bytes = try? Data(contentsOf: requestFile), bytes.count <= 8192,
      let request = try? JSONDecoder().decode(Request.self, from: bytes), request.version == 1,
      request.bundleIdentifier == identity,
      HostingReviewUpgradeProbePathGate.accepts(workspace: workspace, configuredPath: configuredPath, markerPath: request.workspacePath),
      request.localAccountID == localID, request.keychainAccountID == keychainID,
      request.disconnectedAccountID == disconnectedID, request.repositoryID == repositoryID,
      request.confirmationID == confirmationID, request.operationID == operationID,
      request.expectedAccessTokenSHA256 == hash("synthetic-upgrade-local-access"),
      request.expectedRefreshTokenSHA256 == hash("synthetic-upgrade-local-refresh")
    else { return }
    let resultFile = runtime.appendingPathComponent("review-upgrade-app-result.json")
    guard !FileManager.default.fileExists(atPath: resultFile.path) || privateFile(resultFile) else { return }
    var checks: [String: Bool] = [
      "workspaceAndSettings": false, "metadataAndBinding": false, "localVaultDecryptedByApplication": false,
      "keychainMetadataRemainsLocked": false, "disconnectionIntentApplied": false,
      "reviewJournalRecoveredAsUnknown": false, "unknownTargetBlocked": false,
      "operationCenterReflectsJournal": false, "ordinaryTasksNotRestored": false,
    ]
    let hosting = store.hosting
    checks["workspaceAndSettings"] = store.configuration.selectedRepository == repositoryID
      && store.configuration.repositories.contains { $0.id == repositoryID && $0.group == "Upgrade Group"
        && $0.draft == "Synthetic unsent Git commit draft"
        && HostingReviewUpgradeProbePathGate.privatePath($0.path).hasPrefix(runtimePath + "/") }
      && store.settings.language == .english && !store.settings.automaticFetch && store.settings.diffFontSize == 15
    guard let local = hosting.account(localID), let keychain = hosting.account(keychainID),
      local.instance.provider == .gitlab, local.instance.baseURL.absoluteString == "https://upgrade.example.invalid",
      local.user.stableID == "42", local.user.login == "upgrade-local", local.kind == .pat,
      local.storageMode == .localVault, keychain.storageMode == .keychain,
      keychain.instance == local.instance, keychain.user.stableID == "84"
    else {
      writeResult(checks, resultFile); return
    }
    checks["metadataAndBinding"] = hosting.metadata.accounts.count == 2
      && hosting.binding(repositoryID)?.accountID == localID
      && hosting.binding(repositoryID)?.repository == "upgrade/fixture"
    let keychainHasSession = await hosting.tokens.hasSession(keychain)
    checks["keychainMetadataRemainsLocked"] = hosting.states[keychainID] == .credentialsLocked && !keychainHasSession
    checks["disconnectionIntentApplied"] = hosting.account(disconnectedID) == nil
      && hosting.metadata.disconnectedAccounts.contains { $0.id == disconnectedID && $0.remainingStorage == [.localVault] }
    do {
      // The guarded identity is synthetic and Local Vault only. No Keychain unlock,
      // provider API request, Git command or write is part of this acceptance path.
      let token = try await hosting.tokens.token(for: local)
      checks["localVaultDecryptedByApplication"] = hash(token.accessToken) == request.expectedAccessTokenSHA256
        && token.refreshToken.map(hash) == request.expectedRefreshTokenSHA256
      await store.reviewSessions.refreshRecovery()
      checks["reviewJournalRecoveredAsUnknown"] = store.reviewSessions.recoveryError == nil
        && store.reviewSessions.recoveredOperations.contains { $0.id == operationID && $0.confirmationID == confirmationID
          && $0.identity.accountID == localID && $0.state == .resultUnknown }
      let target = HostingReviewTarget(instance: local.instance, accountID: local.id, userID: local.user.stableID,
        repository: "upgrade/fixture", repositoryID: "88", requestNumber: 7, requestID: "99")
      checks["unknownTargetBlocked"] = await store.reviewSessions.coordinator.isBlocked(target)
      checks["operationCenterReflectsJournal"] = store.operations.records.contains {
        $0.id == confirmationID && $0.kind == .review && $0.state == .resultUnknown && $0.recovery == .reviewJournal
      }
      checks["ordinaryTasksNotRestored"] = store.operations.records.allSatisfy { $0.kind == .review }
    } catch { /* Keep failed checks explicit without writing errors or credential data. */ }
    writeResult(checks, resultFile)
  }
  private static func writeResult(_ checks: [String: Bool], _ url: URL) {
    let result = Result(passed: checks.values.allSatisfy { $0 }, actualApplicationProcess: true,
      applicationVersion: AppResources.version, applicationBuild: AppResources.build, accountIDs: [localID, keychainID, disconnectedID], checks: checks)
    guard let data = try? JSONEncoder().encode(result) else { return }
    do {
      try data.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch { /* Missing result is an acceptance failure; never fall back to a user path. */ }
  }
}
