import Foundation
import CryptoKit
import Security

public struct OAuthPKCESession: Sendable {
  public let id = UUID()
  public let configuration: OAuthConfiguration
  public let state: String
  public let verifier: String
  public let redirectURL: URL
  public let expiresAt: Date
  private var consumed = false
  var callbackConsumed: Bool { consumed }
  private var codeDigest: Data?
  func permitsExchange(code: String) -> Bool { consumed && codeDigest == Data(SHA256.hash(data: Data(code.utf8))) }
  public static func random() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw HostingError.invalidResponse }
    return base64(Data(bytes))
  }
  private static func base64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
  public static func challenge(_ verifier: String) -> String { base64(Data(SHA256.hash(data: Data(verifier.utf8)))) }
  public init(configuration: OAuthConfiguration, redirectURL: URL, now: Date = Date()) throws {
    try configuration.validate()
    guard configuration.instance.provider != .github else { throw HostingError.unsupported }
    let expected = configuration.redirect.registrationURL(for: configuration.instance.provider)
    switch configuration.redirect {
    case .application: guard redirectURL.absoluteString == expected else { throw HostingError.invalidCallback }
    case .loopback(let port):
      guard redirectURL.scheme == "http", redirectURL.host == "127.0.0.1", let actualPort = redirectURL.port,
        actualPort > 0, port == 0 || Int(port) == actualPort,
        redirectURL.path == "/oauth/\(configuration.instance.provider.rawValue)/callback",
        redirectURL.query == nil, redirectURL.fragment == nil, redirectURL.user == nil else { throw HostingError.invalidCallback }
    }
    self.configuration = configuration; self.redirectURL = redirectURL
    state = try Self.random(); verifier = try Self.random(); expiresAt = now.addingTimeInterval(300)
  }
  public func authorizationURL(scopes: [String]) throws -> URL {
    try configuration.instance.endpoint(configuration.instance.provider == .gitlab ? "oauth/authorize" : "login/oauth/authorize", query: [
      URLQueryItem(name: "client_id", value: configuration.clientID), URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
      URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "scope", value: scopes.joined(separator: " ")), URLQueryItem(name: "code_challenge", value: Self.challenge(verifier)), URLQueryItem(name: "code_challenge_method", value: "S256")])
  }
  public mutating func consume(_ url: URL, now: Date = Date()) throws -> String {
    guard !consumed else { throw HostingError.invalidCallback }
    guard now < expiresAt else { throw HostingError.expired }
    guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), url.scheme == redirectURL.scheme,
      url.host == redirectURL.host, url.port == redirectURL.port,
      c.percentEncodedPath == URLComponents(url: redirectURL, resolvingAgainstBaseURL: false)?.percentEncodedPath,
      url.user == nil, url.password == nil, url.fragment == nil else { throw HostingError.invalidCallback }
    let items = c.queryItems ?? []
    guard items.filter({ $0.name == "state" }).count == 1, items.first(where: { $0.name == "state" })?.value == state,
      !items.contains(where: { ["access_token", "refresh_token", "token"].contains($0.name) }) else { throw HostingError.invalidCallback }
    let errors = items.filter { $0.name == "error" }, codes = items.filter { $0.name == "code" }
    guard errors.count <= 1 else { throw HostingError.invalidCallback }
    if !errors.isEmpty {
      guard errors[0].value?.isEmpty == false, codes.isEmpty,
        items.filter({ $0.name == "error_description" }).count <= 1 else { throw HostingError.invalidCallback }
    } else {
      guard codes.count == 1, let code = codes[0].value, !code.isEmpty, code.utf8.count <= 4096 else { throw HostingError.invalidCallback }
    }
    consumed = true // Includes provider errors: a callback can terminate only this session, once.
    if let error = items.first(where: { $0.name == "error" })?.value {
      throw OAuthAuthorizationCoordinator.oauthError(error, provider: configuration.instance.provider,
        description: items.first(where: { $0.name == "error_description" })?.value)
    }
    guard let code = codes.first?.value else { throw HostingError.invalidCallback }
    codeDigest = Data(SHA256.hash(data: Data(code.utf8))); return code
  }
}

/// Receives one state-bound private-scheme callback from the ordinary system browser.
/// Invalid/unrelated URLs leave the active authorization pending; no callback is persisted.
public actor OAuthBrowserCallback {
  private var session: OAuthPKCESession
  private var result: Result<URL, Error>?
  private var continuation: CheckedContinuation<URL, Error>?
  private var deadline: Task<Void, Never>?
  private var waited = false
  public init(session: OAuthPKCESession) { self.session = session }
  @discardableResult public func receive(_ url: URL, now: Date = Date()) -> Bool {
    guard result == nil else { return false }
    guard url.absoluteString.utf8.count <= 8192 else { return false }
    guard now < session.expiresAt else { finish(.failure(HostingError.expired)); return false }
    var candidate = session
    do {
      _ = try candidate.consume(url, now: now)
      session = candidate; finish(.success(url)); return true
    } catch {
      // Only a matching, terminal provider callback can end the current authorization.
      if candidate.callbackConsumed, error as? HostingError != .invalidCallback { session = candidate; finish(.failure(error)); return true }
      return false
    }
  }
  public func wait() async throws -> URL {
    guard !Task.isCancelled else { cancel(); throw CancellationError() }
    guard !waited else { throw HostingError.operationInProgress }; waited = true
    if let result { return try result.get() }
    guard session.expiresAt > Date() else { finish(.failure(HostingError.expired)); throw HostingError.expired }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        let remaining = max(0, session.expiresAt.timeIntervalSinceNow)
        deadline = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(remaining)); await self?.finish(.failure(HostingError.expired)) } catch {}
        }
      }
    } onCancel: { Task { await self.cancel() } }
  }
  public func cancel() { finish(.failure(CancellationError())) }
  private func finish(_ result: Result<URL, Error>) {
    guard self.result == nil else { return }; self.result = result
    deadline?.cancel(); deadline = nil
    let continuation = continuation; self.continuation = nil; continuation?.resume(with: result)
  }
}

public struct GitHubDeviceAuthorization: Sendable {
  public let userCode: String
  public let verificationURL: URL
  public let expiresAt: Date
  let deviceCode: String
  let interval: TimeInterval
}
public actor OAuthAuthorizationCoordinator {
  private let http: HostingHTTPClient
  private var deviceSession: UUID?
  private var exchanged: [UUID: Date] = [:]
  public init(http: HostingHTTPClient = HostingHTTPClient()) { self.http = http }
  public func cancel() { deviceSession = nil }
  private func tokenPath(_ provider: HostingProvider) -> String { provider == .github ? "login/oauth/access_token" : provider == .gitlab ? "oauth/token" : "login/oauth/access_token" }
  private func post(_ config: OAuthConfiguration, fields: [String: String]) async throws -> HostingJSON {
    try config.validate()
    let r = try await http.request(instance: config.instance, path: tokenPath(config.instance.provider), api: false,
      method: "POST", body: HostingHTTPClient.form(fields), form: true, limit: 64 * 1024, oauthResponse: true)
    let json = try HostingJSON.decode(r.data)
    let error = json["error"].string
    if !error.isEmpty { throw Self.oauthError(error, provider: config.instance.provider, description: json["error_description"].string) }
    guard (200...299).contains(r.status) else { throw HostingError.invalidClient }; return json
  }
  static func oauthError(_ code: String, provider: HostingProvider? = nil, description: String? = nil) -> HostingError {
    // Gitea rejects a scope change while retaining its existing grant. Match only this known
    // provider response; never surface the remote description, which may contain private data.
    if provider == .gitea, code == "server_error",
      description?.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased() == "a grant exists with different scope" {
      return .scopeConflict
    }
    return switch code {
    case "expired_token": .expired
    case "access_denied": .denied
    case "incorrect_client_credentials", "invalid_client", "invalid_request": .invalidClient
    case "device_flow_disabled": .deviceDisabled
    case "invalid_grant", "bad_refresh_token": .unauthorized
    case "invalid_scope": .permissionRequired
    case "server_error", "temporarily_unavailable": .serverFailure
    default: .invalidResponse
    }
  }
  static func token(_ json: HostingJSON, fallbackScopes: [String] = [], now: Date = Date()) throws -> HostingToken {
    let access = json["access_token"].string
    guard !access.isEmpty, !access.unicodeScalars.contains(where: { $0.value < 32 }) else { throw HostingError.invalidResponse }
    let scope = json["scope"].string.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
    let type = json["token_type"].string
    guard type.isEmpty || type.lowercased() == "bearer" else { throw HostingError.invalidResponse }
    let expiry = json["expires_in"].int; let refreshExpiry = json["refresh_token_expires_in"].int
    return HostingToken(accessToken: access, refreshToken: json["refresh_token"].string.isEmpty ? nil : json["refresh_token"].string,
      expiresAt: expiry > 0 ? now.addingTimeInterval(Double(expiry)) : nil,
      refreshExpiresAt: refreshExpiry > 0 ? now.addingTimeInterval(Double(refreshExpiry)) : nil,
      scopes: scope.isEmpty ? fallbackScopes : scope)
  }
  public func github(configuration: OAuthConfiguration, scopes: [String],
    display: @Sendable (GitHubDeviceAuthorization) async -> Void) async throws -> HostingToken {
    try configuration.validate(); guard configuration.instance.provider == .github else { throw HostingError.unsupported }
    guard deviceSession == nil else { throw HostingError.operationInProgress }
    let session = UUID(); deviceSession = session
    defer { if deviceSession == session { deviceSession = nil } }
    let response = try await http.request(instance: configuration.instance, path: "login/device/code", api: false,
      method: "POST", body: HostingHTTPClient.form(["client_id": configuration.clientID, "scope": scopes.joined(separator: " ")]), form: true, limit: 64 * 1024, oauthResponse: true)
    let j = try HostingJSON.decode(response.data)
    if !j["error"].string.isEmpty { throw Self.oauthError(j["error"].string) }
    guard let verification = URL(string: j["verification_uri"].string), verification.absoluteString == "https://github.com/login/device",
      !j["device_code"].string.isEmpty, !j["user_code"].string.isEmpty, j["expires_in"].int > 0 else { throw HostingError.invalidResponse }
    var interval = Double(max(1, j["interval"].int == 0 ? 5 : j["interval"].int))
    let auth = GitHubDeviceAuthorization(userCode: j["user_code"].string, verificationURL: verification,
      expiresAt: Date().addingTimeInterval(Double(j["expires_in"].int)), deviceCode: j["device_code"].string, interval: interval)
    try Task.checkCancellation(); guard deviceSession == session else { throw CancellationError() }
    await display(auth)
    while Date() < auth.expiresAt {
      try await http.sleep(interval); try Task.checkCancellation()
      guard deviceSession == session else { throw CancellationError() }
      guard Date() < auth.expiresAt else { throw HostingError.expired }
      let r = try await http.request(instance: configuration.instance, path: tokenPath(.github), api: false, method: "POST",
        body: HostingHTTPClient.form(["client_id": configuration.clientID, "device_code": auth.deviceCode, "grant_type": "urn:ietf:params:oauth:grant-type:device_code"]), form: true, limit: 64 * 1024, oauthResponse: true)
      try Task.checkCancellation(); guard deviceSession == session else { throw CancellationError() }
      let json = try HostingJSON.decode(r.data)
      switch json["error"].string {
      case "authorization_pending": continue
      case "slow_down": interval += 5; continue
      case "": return try Self.token(json, fallbackScopes: scopes)
      case let code: throw Self.oauthError(code)
      }
    }
    throw HostingError.expired
  }
  public func exchange(session: OAuthPKCESession, code: String, scopes: [String]) async throws -> HostingToken {
    exchanged = exchanged.filter { $0.value > Date() }
    guard session.expiresAt > Date() else { throw HostingError.expired }
    guard exchanged[session.id] == nil, session.permitsExchange(code: code) else { throw HostingError.invalidCallback }
    exchanged[session.id] = session.expiresAt
    let json = try await post(session.configuration, fields: ["grant_type": "authorization_code", "client_id": session.configuration.clientID,
      "code": code, "code_verifier": session.verifier, "redirect_uri": session.redirectURL.absoluteString])
    try Task.checkCancellation(); return try Self.token(json, fallbackScopes: scopes)
  }
  public func refresh(configuration: OAuthConfiguration, token: HostingToken) async throws -> HostingToken {
    guard let refresh = token.refreshToken, token.refreshExpiresAt.map({ $0 > Date() }) ?? true else { throw HostingError.unauthorized }
    let j = try await post(configuration, fields: ["grant_type": "refresh_token", "client_id": configuration.clientID, "refresh_token": refresh])
    var next = try Self.token(j, fallbackScopes: token.scopes)
    if next.refreshToken == nil { next.refreshToken = token.refreshToken; next.refreshExpiresAt = token.refreshExpiresAt }
    return next
  }
  public func giteaSupportsGranularScopes(_ instance: HostingInstance) async throws -> Bool {
    guard instance.provider == .gitea else { return true }
    let r = try await http.request(instance: instance, path: "version", limit: 64 * 1024)
    let v = try HostingJSON.decode(r.data)["version"].string
    let parts = v.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".")
    guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return false }
    return major > 1 || major == 1 && minor >= 23
  }
}
