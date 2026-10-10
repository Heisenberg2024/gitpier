import Foundation
import Security

public struct KeychainStore: Sendable {
  public let service: String
  public init(service: String = "GitPier.credentials") { self.service = service }
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
  public func read(id: UUID) throws -> String? {
    var q = query(id)
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
      "SSH_ASKPASS_REQUIRE": "prefer", "GITPIER_CONFIGURATION": configurationPath,
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
