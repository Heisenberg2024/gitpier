import XCTest
import Security
@testable import GitPierCore

final class BackgroundCredentialTests: XCTestCase {
  private let probeKey = "GITPIER_BACKGROUND_KEYCHAIN_TEST"
  private func isolatedProbe(_ name: String) async throws {
    let result = try await ProcessRunner().run(executable: "/usr/bin/xcrun", arguments: [
      "xctest", "-XCTest", "GitPierCoreTests.BackgroundCredentialTests/" + name,
      Bundle(for: BackgroundCredentialTests.self).bundleURL.path,
    ], directory: nil, environment: [probeKey: name], timeout: 20)
    XCTAssertEqual(result.code, 0, result.errorText + result.text)
    guard result.code == 0 else { return }
    if result.text.contains("KEYCHAIN_PROBE_UNAVAILABLE") { throw XCTSkip("Synthetic Keychain fixture unavailable in child.") }
    XCTAssertTrue(result.text.contains("KEYCHAIN_PROBE_COMPLETED"), result.errorText + result.text)
  }
  private func requireFixture(_ status: OSStatus) throws {
    if status == errSecInteractionNotAllowed || status == errSecNotAvailable || status == errSecAuthFailed {
      print("KEYCHAIN_PROBE_UNAVAILABLE")
      throw XCTSkip("Synthetic Keychain fixture unavailable (\(status)).")
    }
    XCTAssertEqual(status, errSecSuccess)
  }
  func testBackgroundKeychainOnlyReadsGitCredentialTypeAndExactPort() async throws {
    let name = "testBackgroundKeychainOnlyReadsGitCredentialTypeAndExactPort"
    guard ProcessInfo.processInfo.environment[probeKey] == name else { try await isolatedProbe(name); return }
    // The legacy UI policy is process-wide, so never change it in the parent XCTest/GUI process.
    try KeychainStore.prepareBackgroundHelper()
    let host = "gitpier-synthetic-" + UUID().uuidString.lowercased() + ".invalid"
    let base: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
      kSecAttrServer as String: host, kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
      kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    defer { SecItemDelete(base as CFDictionary) }
    func add(_ auth: CFString, port: Int, user: String, secret: String) throws {
      var query = base
      query[kSecAttrAuthenticationType as String] = auth; query[kSecAttrPort as String] = port
      query[kSecAttrAccount as String] = user; query[kSecValueData as String] = Data(secret.utf8)
      try requireFixture(SecItemAdd(query as CFDictionary, nil))
    }
    try add(kSecAttrAuthenticationTypeHTMLForm, port: 0, user: "browser", secret: "synthetic-browser-password")
    try add(kSecAttrAuthenticationTypeDefault, port: 8443, user: "port-user", secret: "synthetic-port-token")
    XCTAssertNil(KeychainStore.internetResponse(request: "protocol=https\nhost=\(host)\n\n"))
    try add(kSecAttrAuthenticationTypeDefault, port: 0, user: "git", secret: "synthetic-git-token")
    XCTAssertEqual(KeychainStore.internetResponse(request: "protocol=https\nhost=\(host)\n\n"), "username=git\npassword=synthetic-git-token\n\n")
    XCTAssertEqual(KeychainStore.internetResponse(request: "protocol=https\nhost=\(host):8443\n\n"), "username=port-user\npassword=synthetic-port-token\n\n")
    XCTAssertNil(KeychainStore.internetResponse(request: "protocol=http\nhost=\(host)\n\n"))
    XCTAssertNil(KeychainStore.internetResponse(request: "protocol=https\nhost=another-\(host)\n\n"))
    print("KEYCHAIN_PROBE_COMPLETED")
  }
  func testUnpreparedBackgroundReadFailsBeforeQueryingKeychain() async throws {
    let name = "testUnpreparedBackgroundReadFailsBeforeQueryingKeychain"
    guard ProcessInfo.processInfo.environment[probeKey] == name else { try await isolatedProbe(name); return }
    XCTAssertEqual(SecKeychainSetUserInteractionAllowed(true), errSecSuccess)
    let store = KeychainStore(service: "GitPier.synthetic." + UUID().uuidString)
    XCTAssertThrowsError(try store.read(id: UUID(), allowInteraction: false)) { error in
      XCTAssertTrue(error.localizedDescription.contains("background helper was not prepared"))
    }
    XCTAssertNil(KeychainStore.internetResponse(request: "protocol=https\nhost=unprepared.invalid\n\n"))
    var allowed: DarwinBoolean = false
    XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
    XCTAssertTrue(allowed.boolValue, "A read must not toggle the GUI process's interaction policy")
    try KeychainStore.prepareBackgroundHelper()
    XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
    XCTAssertFalse(allowed.boolValue)
    print("KEYCHAIN_PROBE_COMPLETED")
  }
  func testLegacyACLRefusesBackgroundSecretWithoutAuthorizationUI() async throws {
    let name = "testLegacyACLRefusesBackgroundSecretWithoutAuthorizationUI"
    guard ProcessInfo.processInfo.environment[probeKey] == name else { try await isolatedProbe(name); return }
    try KeychainStore.prepareBackgroundHelper()
    var access: SecAccess?
    // Empty trusted list requires approval for every secret read, unlike the old fixture,
    // which always trusted its creator and could not detect legacy authorization prompts.
    XCTAssertEqual(SecAccessCreate("GitPier synthetic blocked credential" as CFString, [] as CFArray, &access), errSecSuccess)
    guard let access else { return }
    let host = "gitpier-blocked-" + UUID().uuidString.lowercased() + ".invalid"
    let internet: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
      kSecAttrServer as String: host, kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
      kSecAttrAuthenticationType as String: kSecAttrAuthenticationTypeDefault,
      kSecAttrPort as String: 0, kSecAttrAccount as String: "synthetic"]
    let id = UUID(), service = "GitPier.synthetic." + UUID().uuidString
    let generic: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    var created: [[String: Any]] = []
    defer { for query in created { XCTAssertEqual(SecItemDelete(query as CFDictionary), errSecSuccess) } }
    for query in [internet, generic] {
      var add = query; add[kSecAttrAccess as String] = access
      add[kSecValueData as String] = Data("synthetic-blocked-secret".utf8)
      try requireFixture(SecItemAdd(add as CFDictionary, nil))
      created.append(query)
    }
    for _ in 0..<4 {
      XCTAssertNil(KeychainStore.internetResponse(request: "protocol=https\nhost=\(host)\n\n"))
      XCTAssertThrowsError(try KeychainStore(service: service).read(id: id, allowInteraction: false)) { error in
        XCTAssertEqual(RemoteCheckPhase.forFailure(error), .authenticationRequired)
      }
    }
    var query = internet; query[kSecReturnData as String] = true
    var secret: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &secret)
    XCTAssertTrue([errSecInteractionNotAllowed, errSecAuthFailed].contains(status), "Expected an ACL refusal, got \(status)")
    XCTAssertNil(secret)
    print("KEYCHAIN_PROBE_COMPLETED")
  }
  func testExecutableBackgroundHelpersCannotFallThroughToAskpass() async throws {
    let name = "testExecutableBackgroundHelpersCannotFallThroughToAskpass"
    guard ProcessInfo.processInfo.environment[probeKey] == name else { try await isolatedProbe(name); return }
    let executable = Bundle(for: BackgroundCredentialTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("GitPier")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      XCTFail("The existing SwiftPM application executable is required for credential CLI acceptance"); return
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-credential-cli-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = ConfigurationStore(url: directory.appendingPathComponent("workspace.json"))
    try persistence.save(WorkspaceConfiguration())
    let environment = ["GITPIER_CONFIGURATION": persistence.url.path]
    let background = environment.merging(["GITPIER_BACKGROUND": "1"]) { _, value in value }
    let request = Data("protocol=https\nhost=gitpier-nonexistent-\(UUID().uuidString).invalid\n\n".utf8)
    let runner = ProcessRunner()
    for (arguments, env) in [
      (["--background-keychain-helper", "get"], environment),
      (["--credential-helper", UUID().uuidString, "get"], background),
      (["--credential-helper", UUID().uuidString, "get"], environment),
    ] {
      let result = try await runner.run(executable: executable.path, arguments: arguments,
        directory: nil, environment: env, input: request, timeout: 5)
      XCTAssertEqual(result.code, 0, result.errorText); XCTAssertTrue(result.stdout.isEmpty)
    }
    let refused = try await runner.run(executable: executable.path, arguments: ["Password for synthetic.invalid:"],
      directory: nil, environment: background.merging(["GITPIER_ASKPASS": "1"]) { _, value in value }, timeout: 5)
    XCTAssertEqual(refused.code, 1); XCTAssertTrue(refused.stdout.isEmpty)
    print("KEYCHAIN_PROBE_COMPLETED")
  }
}
