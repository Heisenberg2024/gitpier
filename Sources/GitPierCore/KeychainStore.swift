import Foundation
import Security

public struct KeychainStore: Sendable {
  public let service: String
  public init(service: String = "GitPier.credentials") { self.service = service }
  /// Call only in a dedicated credential helper process. The legacy login keychain ignores
  /// SecItem's per-query authentication UI option; its interaction policy is process-wide.
  public static func prepareBackgroundHelper() throws {
    let status = SecKeychainSetUserInteractionAllowed(false)
    guard status == errSecSuccess, backgroundAccessPrepared else {
      throw GitPierError.configuration("Keychain lookup failed: noninteractive access is unavailable (\(status)).")
    }
  }
  private static var backgroundAccessPrepared: Bool {
    var allowed: DarwinBoolean = true
    return SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess && !allowed.boolValue
  }
  private func query(_ id: UUID) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: id.uuidString,
    ]
  }
  public func save(_ secret: String, id: UUID) throws {
    guard !secret.isEmpty else { throw GitPierError.invalidInput("A token is required.") }
    let values: [String: Any] = [
      kSecValueData as String: Data(secret.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    var status = SecItemUpdate(query(id) as CFDictionary, values as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(query(id).merging(values) { _, new in new } as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
      throw GitPierError.configuration("Keychain save failed (\(status)).")
    }
  }
  public func read(id: UUID, allowInteraction: Bool = true) throws -> String? {
    if !allowInteraction, !Self.backgroundAccessPrepared {
      throw GitPierError.configuration("Keychain lookup failed: background helper was not prepared.")
    }
    var q = query(id)
    if !allowInteraction { q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &value)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = value as? Data else {
      throw GitPierError.configuration("Keychain lookup failed (\(status)).")
    }
    return String(data: data, encoding: .utf8)
  }
  /// Read an existing macOS internet credential without unlocking or authorization UI.
  public static func internetResponse(request: String) -> String? {
    // Fail closed if invoked outside the noninteractive helper. Never toggle the process-wide
    // policy around a query in the GUI app, where a manual credential action may run in parallel.
    guard backgroundAccessPrepared else { return nil }
    var fields: [String: String] = [:]
    for line in request.split(separator: "\n") {
      let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
      if parts.count == 2 { fields[parts[0]] = parts[1] }
    }
    guard fields["protocol"] == "https", let host = fields["host"], !host.contains("\r") else { return nil }
    let components = URLComponents(string: "https://" + host)
    guard let server = components?.host else { return nil }
    var query: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
      kSecAttrServer as String: server, kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
      kSecAttrAuthenticationType as String: kSecAttrAuthenticationTypeDefault,
      kSecAttrPort as String: components?.port ?? 0,
      kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
      kSecReturnData as String: true, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    if let user = fields["username"] { query[kSecAttrAccount as String] = user }
    if let path = fields["path"] { query[kSecAttrPath as String] = path }
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let values = result as? [String: Any], let data = values[kSecValueData as String] as? Data,
      let secret = String(data: data, encoding: .utf8), let user = values[kSecAttrAccount as String] as? String,
      !secret.contains("\n"), !secret.contains("\r"), !user.contains("\n"), !user.contains("\r") else { return nil }
    return "username=\(user)\npassword=\(secret)\n\n"
  }
  public func delete(id: UUID) throws {
    let status = SecItemDelete(query(id) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw GitPierError.configuration("Keychain removal failed (\(status)).")
    }
  }
}

public struct AuthenticationContext: Sendable {
  public let arguments: [String]
  public let environment: [String: String]
  public static func make(
    profile: CredentialProfile?, executable: String, configurationPath: String
  ) throws -> AuthenticationContext {
    var environment = [
      "GIT_ASKPASS": executable, "SSH_ASKPASS": executable, "GITPIER_ASKPASS": "1",
      "SSH_ASKPASS_REQUIRE": "prefer", "GITPIER_HELPER_EXECUTABLE": executable, "GITPIER_CONFIGURATION": configurationPath,
    ]
    var arguments: [String] = []
    if let profile {
      guard !profile.host.isEmpty, !profile.host.contains("\n"), !profile.host.contains("/"),
        !profile.host.contains("@")
      else {
        throw GitPierError.invalidInput("Enter only the server hostname, optionally with a port.")
      }
      if profile.kind == .https {
        let helper =
          "!" + InputValidation.shellQuote(executable) + " --credential-helper "
          + InputValidation.shellQuote(profile.id.uuidString)
        arguments = [
          "-c", "credential.helper=", "-c", "credential.helper=" + helper, "-c",
          "credential.useHttpPath=true",
        ]
        environment["GITPIER_CREDENTIAL_ID"] = profile.id.uuidString
      } else {
        guard FileManager.default.isReadableFile(atPath: profile.identityPath),
          !profile.identityPath.contains("\n")
        else { throw GitPierError.invalidInput("SSH Identity is not readable.") }
        // No host verification bypass, no global config changes; ssh-agent and SSH config remain in effect.
        environment["GIT_SSH_COMMAND"] =
          InputValidation.shellQuote(executable) + " --ssh-profile "
          + InputValidation.shellQuote(profile.id.uuidString)
        environment["GIT_SSH_VARIANT"] = "ssh"
      }
    }
    return AuthenticationContext(arguments: arguments, environment: environment)
  }
  public static func helperResponse(request: String, profile: CredentialProfile, secret: String)
    -> String?
  {
    var fields: [String: String] = [:]
    for line in request.split(separator: "\n") {
      let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
    }
    guard fields["protocol"] == "https",
      fields["host"]?.lowercased() == profile.host.lowercased(), !profile.username.contains("\n"),
      !secret.contains("\n"), !secret.contains("\r")
    else { return nil }
    return "username=\(profile.username.isEmpty ? "git" : profile.username)\npassword=\(secret)\n\n"
  }
}
