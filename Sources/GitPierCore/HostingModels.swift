import Foundation

public enum HostingProvider: String, Codable, CaseIterable, Sendable {
  case github, gitlab, gitea
  public var title: String { switch self { case .github: "GitHub"; case .gitlab: "GitLab"; case .gitea: "Gitea" } }
  public var requestName: String { self == .gitlab ? "Merge Requests" : "Pull Requests" }
  public var capabilities: HostingProviderCapabilities {
    HostingProviderCapabilities(deviceFlow: self == .github, pkce: self != .github, drafts: self != .gitea, granularOAuthScopes: self == .gitea)
  }
}
public struct HostingProviderCapabilities: Sendable {
  public let deviceFlow: Bool
  public let pkce: Bool
  public let drafts: Bool
  public let granularOAuthScopes: Bool
}

public enum HostingError: String, Error, LocalizedError, Sendable {
  case invalidInstance, missingClientID, unsupported, invalidCallback, expired, denied, invalidClient
  case deviceDisabled, invalidResponse, insecureURL, redirectRejected, responseTooLarge
  case unauthorized, permissionRequired, notFound, rateLimited, serverFailure, networkFailure
  case credentialsLocked, keychainDenied, storageFailure, configurationUnreadable, accountChanged
  case pushRequired, branchMissing, duplicateRequest, operationInProgress, creationUnknown
  case vaultCorrupt, vaultUnavailable, sessionOnly
  public var errorDescription: String? {
    switch self {
    case .invalidInstance: "Enter an HTTPS instance URL without credentials, query or fragment."
    case .missingClientID: "The public OAuth Client ID has not been configured. Use PAT or ask the maintainer."
    case .unsupported: "This instance or version does not support this OAuth capability. Use PAT."
    case .invalidCallback: "The OAuth callback does not match the active session."
    case .expired: "Authorization expired. Start again."
    case .denied: "Authorization was denied."
    case .invalidClient: "The instance rejected the public Client ID or redirect configuration."
    case .deviceDisabled: "Device Flow is disabled for this GitHub OAuth application."
    case .invalidResponse: "The hosting service returned an invalid response."
    case .insecureURL: "The destination is outside this account's authorized HTTPS instance."
    case .redirectRejected: "An HTTP redirect was rejected. Verify the instance URL."
    case .responseTooLarge: "The response exceeds the preview limit. Open the item in your browser."
    case .unauthorized: "The token is invalid or expired. Reauthorize the account."
    case .permissionRequired: "Permission required. Review scopes and explicitly reauthorize."
    case .notFound: "The item was not found, or this account cannot access the private repository."
    case .rateLimited: "The platform rate limit was reached. Try again later."
    case .serverFailure: "The hosting service is temporarily unavailable."
    case .networkFailure: "The hosting request failed. Check the network and system certificate trust."
    case .credentialsLocked: "Unlock this account with Verify Connection before loading platform data."
    case .keychainDenied: "Keychain access was denied or cancelled. Existing credentials were preserved."
    case .storageFailure: "Hosting metadata or credentials could not be saved."
    case .vaultCorrupt: "The local credential or key is missing, damaged, or belongs to another account. Reauthorize this account."
    case .vaultUnavailable: "The local credential directory is unavailable or has unsafe ownership, permissions or links. Existing files were preserved."
    case .sessionOnly: "Credentials are available only in this session. Saving failed; reauthorize before quitting. Restart may require authorization again."
    case .configurationUnreadable: "Hosting configuration could not be read. The original file was preserved."
    case .accountChanged: "The account or repository binding changed. Review again."
    case .pushRequired: "Push the source branch with Git before creating a request. GitPier will not push automatically."
    case .branchMissing: "The source or target branch does not exist on the selected platform repository."
    case .duplicateRequest: "An open request already exists for these branches."
    case .operationInProgress: "Finish the current Git operation before creating a request."
    case .creationUnknown: "Creation may have succeeded. Refresh and check for an existing request before trying again."
    }
  }
}

/// A registered instance is an explicit trust boundary, including its port and installation path.
public struct HostingInstance: Codable, Hashable, Sendable, Identifiable {
  public var id: String { provider.rawValue + "|" + baseURL.absoluteString }
  public let provider: HostingProvider
  public let baseURL: URL
  public init(provider: HostingProvider, url: String) throws {
    guard var c = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
      c.scheme?.lowercased() == "https", let host = c.host, !host.isEmpty,
      c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
      !c.percentEncodedPath.lowercased().contains("%2f"), !c.percentEncodedPath.lowercased().contains("%2e"),
      !c.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
      !url.contains("\\"), !url.unicodeScalars.contains(where: { $0.value < 32 })
    else { throw HostingError.invalidInstance }
    c.scheme = "https"; c.host = host.lowercased(); if c.port == 443 { c.port = nil }
    while c.path.hasSuffix("/") { c.path.removeLast() }
    guard let base = c.url, provider != .github || base.absoluteString == "https://github.com" else {
      throw HostingError.invalidInstance
    }
    self.provider = provider; baseURL = base
  }
  public var apiURL: URL {
    if provider == .github { return URL(string: "https://api.github.com")! }
    return baseURL.appendingPathComponent(provider == .gitlab ? "api/v4" : "api/v1")
  }
  public func endpoint(_ path: String, api: Bool = false, query: [URLQueryItem] = []) throws -> URL {
    // Path components are encoded individually by callers; never accept URLs or traversal.
    guard !path.hasPrefix("/"), !path.contains("://"), !path.contains("?"), !path.contains("#"),
      !path.split(separator: "/").contains("..") else { throw HostingError.insecureURL }
    let base = api ? apiURL : baseURL
    guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw HostingError.insecureURL }
    c.percentEncodedPath += "/" + path
    c.queryItems = query.isEmpty ? nil : query
    guard let url = c.url else { throw HostingError.insecureURL }; return url
  }
  public func accepts(_ url: URL, api: Bool) -> Bool {
    let base = api ? apiURL : baseURL
    return url.scheme == "https" && url.host?.lowercased() == base.host?.lowercased()
      && (url.port ?? 443) == (base.port ?? 443) && url.user == nil && url.password == nil
      && (base.path.isEmpty || url.path == base.path || url.path.hasPrefix(base.path + "/"))
  }
  public static func component(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
  }
}

public enum HostingAuthorizationLevel: String, CaseIterable, Codable, Sendable {
  case read, publicWrite, privateWrite
  public func scopes(for provider: HostingProvider) -> [String] {
    switch provider {
    case .github: self == .read ? ["read:user"] : self == .publicWrite ? ["read:user", "public_repo"] : ["read:user", "repo"]
    case .gitlab: self == .read ? ["read_user", "read_api"] : ["api"]
    case .gitea: self == .read ? ["read:user", "read:repository"] : ["read:user", "write:repository"]
    }
  }
}

public enum HostingRedirect: Codable, Hashable, Sendable {
  case application
  case loopback(port: UInt16)
  public func registrationURL(for provider: HostingProvider) -> String {
    switch self {
    case .application: "gitpier://oauth/gitlab"
    case .loopback(let port): "http://127.0.0.1" + (port == 0 ? "" : ":\(port)") + "/oauth/\(provider.rawValue)/callback"
    }
  }
}
public struct OAuthConfiguration: Codable, Hashable, Sendable, Identifiable {
  public var id: String { instance.id }
  public let instance: HostingInstance
  public var clientID: String
  public var redirect: HostingRedirect
  public init(instance: HostingInstance, clientID: String, redirect: HostingRedirect = .application) {
    self.instance = instance; self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines); self.redirect = redirect
  }
  public func validate() throws {
    _ = try HostingInstance(provider: instance.provider, url: instance.baseURL.absoluteString)
    guard !clientID.isEmpty else { throw HostingError.missingClientID }
    guard clientID.count <= 512, !clientID.unicodeScalars.contains(where: { $0.value < 33 }) else { throw HostingError.invalidClient }
    if instance.provider == .gitea, case .application = redirect { throw HostingError.unsupported }
    if instance.provider == .gitlab, case .loopback(port: 0) = redirect { throw HostingError.unsupported }
  }
}
public struct HostingOAuthConfiguration: Codable, Sendable {
  public var githubClientID: String
  public var gitlabClientID: String
  public init(githubClientID: String = "", gitlabClientID: String = "") { self.githubClientID = githubClientID; self.gitlabClientID = gitlabClientID }
  public func configuration(for provider: HostingProvider) throws -> OAuthConfiguration {
    guard provider != .gitea else { throw HostingError.invalidInstance }
    return OAuthConfiguration(instance: try HostingInstance(provider: provider, url: provider == .github ? "https://github.com" : "https://gitlab.com"), clientID: provider == .github ? githubClientID : gitlabClientID)
  }
}

public struct HostingUser: Codable, Equatable, Sendable {
  public let stableID: String
  public let login: String
  public let name: String
  public let avatarURL: URL?
  public init(stableID: String, login: String, name: String = "", avatarURL: URL? = nil) {
    self.stableID = stableID; self.login = login; self.name = name; self.avatarURL = avatarURL
  }
}
public enum HostingAuthenticationKind: String, Codable, Sendable { case oauth, pat }
public enum HostingStorageMode: String, Codable, CaseIterable, Sendable {
  case localVault, keychain
  public var title: String { self == .localVault ? "Local Encrypted Vault" : "macOS Keychain" }
}
public enum HostingAccountState: String, Codable, Sendable { case connected, credentialsLocked, expired, reauthorize, permissionRequired, networkFailure, keychainDenied }
public struct HostingAccount: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let instance: HostingInstance
  public var user: HostingUser
  public var kind: HostingAuthenticationKind
  public var scopes: [String]
  public var lastVerified: Date?
  public var oauth: OAuthConfiguration?
  public var storageMode: HostingStorageMode
  /// Intent is durable before destination writes. The source stays authoritative until metadata commit.
  public var pendingMigration: HostingStorageMode?
  public var pendingCleanup: [HostingStorageMode]
  public var credentialRecoveryRequired: Bool
  public var identity: String { instance.id + "|" + user.stableID }
  public func validateCredentialContext() throws {
    guard try HostingInstance(provider: instance.provider, url: instance.baseURL.absoluteString) == instance,
      oauth == nil || oauth?.instance == instance else { throw HostingError.accountChanged }
  }
  public init(id: UUID = UUID(), instance: HostingInstance, user: HostingUser, kind: HostingAuthenticationKind, scopes: [String], oauth: OAuthConfiguration? = nil, storageMode: HostingStorageMode = .localVault) {
    self.id = id; self.instance = instance; self.user = user; self.kind = kind; self.scopes = scopes; self.oauth = oauth; lastVerified = Date()
    self.storageMode = storageMode; pendingCleanup = []; credentialRecoveryRequired = false
  }
  private enum CodingKeys: String, CodingKey { case id, instance, user, kind, scopes, lastVerified, oauth, storageMode, pendingMigration, pendingCleanup, credentialRecoveryRequired }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id); instance = try c.decode(HostingInstance.self, forKey: .instance)
    user = try c.decode(HostingUser.self, forKey: .user); kind = try c.decode(HostingAuthenticationKind.self, forKey: .kind)
    scopes = try c.decode([String].self, forKey: .scopes); lastVerified = try c.decodeIfPresent(Date.self, forKey: .lastVerified)
    oauth = try c.decodeIfPresent(OAuthConfiguration.self, forKey: .oauth)
    // v1 exclusively used Keychain. Unknown explicit values fail decoding; never guess a backend.
    storageMode = try c.decodeIfPresent(HostingStorageMode.self, forKey: .storageMode) ?? .keychain
    pendingMigration = try c.decodeIfPresent(HostingStorageMode.self, forKey: .pendingMigration)
    pendingCleanup = try c.decodeIfPresent([HostingStorageMode].self, forKey: .pendingCleanup) ?? []
    credentialRecoveryRequired = try c.decodeIfPresent(Bool.self, forKey: .credentialRecoveryRequired) ?? false
  }
}
/// Encrypt or protect the complete token pair as one value. Never encode in ordinary configuration.
public struct HostingToken: Codable, Sendable, Equatable {
  public var accessToken: String
  public var refreshToken: String?
  public var tokenType: String
  public var expiresAt: Date?
  public var refreshExpiresAt: Date?
  public var scopes: [String]
  public init(accessToken: String, refreshToken: String? = nil, tokenType: String = "bearer", expiresAt: Date? = nil, refreshExpiresAt: Date? = nil, scopes: [String] = []) {
    self.accessToken = accessToken; self.refreshToken = refreshToken; self.tokenType = tokenType; self.expiresAt = expiresAt; self.refreshExpiresAt = refreshExpiresAt; self.scopes = scopes
  }
}

public struct RepositoryHostingBinding: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID { repositoryID }
  public let repositoryID: UUID
  public let accountID: UUID
  public let remote: String
  public let repository: String
  public init(repositoryID: UUID, accountID: UUID, remote: String, repository: String) throws {
    let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
      !repository.contains(":"), !repository.contains("\\"), !repository.contains("?"), !repository.contains("#"),
      !repository.unicodeScalars.contains(where: { $0.value < 33 }) else { throw HostingError.invalidResponse }
    self.repositoryID = repositoryID; self.accountID = accountID; self.remote = remote; self.repository = repository
  }
}

public enum HostingRemoteParser {
  public static func repository(_ remote: String, instance: HostingInstance) -> String? {
    var value = remote
    if !value.contains("://"), let colon = value.firstIndex(of: ":") {
      value = "ssh://" + value[..<colon] + "/" + value[value.index(after: colon)...]
    }
    guard let url = URL(string: value), ["https", "ssh"].contains(url.scheme ?? ""),
      url.host?.lowercased() == instance.baseURL.host?.lowercased(), url.password == nil,
      url.query == nil, url.fragment == nil else { return nil }
    if url.scheme == "https", (url.port ?? 443) != (instance.baseURL.port ?? 443) { return nil }
    var path = url.path
    let prefix = instance.baseURL.path
    if !prefix.isEmpty {
      guard path.hasPrefix(prefix + "/") else { return nil }; path = String(path.dropFirst(prefix.count))
    }
    if path.hasPrefix("/") { path.removeFirst() }; if path.hasSuffix(".git") { path.removeLast(4) }
    guard (try? RepositoryHostingBinding(repositoryID: UUID(), accountID: UUID(), remote: "", repository: path)) != nil else { return nil }
    if instance.provider != .gitlab, path.split(separator: "/").count != 2 { return nil }
    return path
  }
}
