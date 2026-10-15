import XCTest
import Security
@testable import GitPierCore

final class BackgroundCredentialTests: XCTestCase {
  func testBackgroundKeychainOnlyReadsGitCredentialTypeAndExactPort() throws {
    let host = "gitpier-synthetic-" + UUID().uuidString.lowercased() + ".invalid"
    let base: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
      kSecAttrServer as String: host, kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
      kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    defer { SecItemDelete(base as CFDictionary) }
    func add(_ auth: CFString, port: Int, user: String, secret: String) throws {
      var query = base
      query[kSecAttrAuthenticationType as String] = auth; query[kSecAttrPort as String] = port
      query[kSecAttrAccount as String] = user; query[kSecValueData as String] = Data(secret.utf8)
      let status = SecItemAdd(query as CFDictionary, nil)
      if status == errSecInteractionNotAllowed || status == errSecNotAvailable || status == errSecAuthFailed {
        throw XCTSkip("Synthetic internet-password Keychain access unavailable (\(status)).")
      }
      XCTAssertEqual(status, errSecSuccess)
    }
    try add(kSecAttrAuthenticationTypeHTMLForm, port: 0, user: "browser", secret: "synthetic-browser-password")
    try add(kSecAttrAuthenticationTypeDefault, port: 8443, user: "port-user", secret: "synthetic-port-token")
    XCTAssertNil(KeychainStore.internetResponse(request: "protocol=https\nhost=\(host)\n\n"))
    try add(kSecAttrAuthenticationTypeDefault, port: 0, user: "git", secret: "synthetic-git-token")
    XCTAssertEqual(KeychainStore.internetResponse(request: "protocol=https\nhost=\(host)\n\n"), "username=git\npassword=synthetic-git-token\n\n")
    XCTAssertEqual(KeychainStore.internetResponse(request: "protocol=https\nhost=\(host):8443\n\n"), "username=port-user\npassword=synthetic-port-token\n\n")
    XCTAssertNil(KeychainStore.internetResponse(request: "protocol=http\nhost=\(host)\n\n"))
    XCTAssertNil(KeychainStore.internetResponse(request: "protocol=https\nhost=another-\(host)\n\n"))
  }
}
