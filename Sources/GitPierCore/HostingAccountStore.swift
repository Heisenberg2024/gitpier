import Foundation
import Security

public protocol HostingCredentialStore: Sendable {
  func read(account: HostingAccount) async throws -> HostingToken?
  func save(_ token: HostingToken, account: HostingAccount) async throws
  func delete(account: HostingAccount) async throws
  func replace(_ token: HostingToken, account: HostingAccount) async throws
  func exists(account: HostingAccount) async throws -> Bool
}
public extension HostingCredentialStore {
  func replace(_ token: HostingToken, account: HostingAccount) async throws { try await save(token, account: account) }
  func exists(account: HostingAccount) async throws -> Bool { try await read(account: account) != nil }
}
public actor HostingKeychainStore: HostingCredentialStore {
  public static let service = "GitPier.hosting.oauth"
  private let service: String
  public init(service: String = HostingKeychainStore.service) { self.service = service }
  private func query(_ account: HostingAccount) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account.id.uuidString]
  }
  private struct Envelope: Codable { let identity: String; let token: HostingToken }
  public func read(account: HostingAccount) throws -> HostingToken? {
    var query = query(account); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }; try check(status)
    guard let data = result as? Data, let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.identity == account.identity else { throw HostingError.accountChanged }
    return envelope.token
  }
  public func save(_ token: HostingToken, account: HostingAccount) throws {
    let data = try JSONEncoder().encode(Envelope(identity: account.identity, token: token))
    let values: [String: Any] = [kSecValueData as String: data]
    var status = SecItemUpdate(query(account) as CFDictionary, values as CFDictionary)
    if status == errSecItemNotFound {
      var q = query(account); q[kSecValueData as String] = data
      q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      status = SecItemAdd(q as CFDictionary, nil)
    }
    try check(status)
  }
  public func delete(account: HostingAccount) throws {
    let status = SecItemDelete(query(account) as CFDictionary)
    if status != errSecItemNotFound { try check(status) }
  }
  private func check(_ status: OSStatus) throws {
    if [errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed].contains(status) { throw HostingError.keychainDenied }
    guard status == errSecSuccess else { throw HostingError.storageFailure }
  }
}

public struct HostingMetadata: Codable, Sendable {
  public var version = 2
  public var defaultStorageMode: HostingStorageMode = .localVault
  public var accounts: [HostingAccount] = []
  public var configurations: [OAuthConfiguration] = []
  public var bindings: [RepositoryHostingBinding] = []
  public init() {}
  private enum CodingKeys: String, CodingKey { case version, accounts, configurations, bindings, defaultStorageMode }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let sourceVersion = try c.decode(Int.self, forKey: .version)
    guard [1, 2].contains(sourceVersion) else { throw HostingError.configurationUnreadable }
    version = 2
    accounts = try c.decode([HostingAccount].self, forKey: .accounts)
    configurations = try c.decode([OAuthConfiguration].self, forKey: .configurations)
    bindings = try c.decode([RepositoryHostingBinding].self, forKey: .bindings)
    defaultStorageMode = try c.decodeIfPresent(HostingStorageMode.self, forKey: .defaultStorageMode) ?? .localVault
  }
}
public struct HostingMetadataStore: Sendable {
  public let url: URL
  public init(url: URL) { self.url = url }
  public func load() throws -> HostingMetadata {
    do {
      let directory = try HostingPrivateDirectory(url.deletingLastPathComponent()); defer { directory.closeDirectory() }
      guard let data = try directory.read(url.lastPathComponent) else { return HostingMetadata() }
      let value = try JSONDecoder().decode(HostingMetadata.self, from: data)
      guard value.version == 2, Set(value.accounts.map(\.id)).count == value.accounts.count,
        Set(value.accounts.map(\.identity)).count == value.accounts.count,
        Set(value.bindings.map(\.repositoryID)).count == value.bindings.count else { throw HostingError.configurationUnreadable }
      for account in value.accounts { try account.validateCredentialContext() }
      return value
    } catch { throw HostingError.configurationUnreadable }
  }
  public func save(_ metadata: HostingMetadata) throws {
    do {
      let directory = try HostingPrivateDirectory(url.deletingLastPathComponent()); defer { directory.closeDirectory() }
      let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try directory.write(encoder.encode(metadata), name: url.lastPathComponent)
    } catch { throw HostingError.storageFailure }
  }
}

