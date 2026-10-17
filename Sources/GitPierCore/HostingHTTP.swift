import Foundation

public struct HostingHTTPResponse: Sendable {
  public let data: Data
  public let status: Int
  public let headers: [String: String]
  public init(data: Data, status: Int = 200, headers: [String: String] = [:]) { self.data = data; self.status = status; self.headers = headers }
}
public protocol HostingTransport: Sendable {
  func send(_ request: URLRequest, limit: Int) async throws -> HostingHTTPResponse
}
/// No URLSession credential store, cookies, persistent cache, redirects or TLS overrides.
public final class HostingURLSessionTransport: NSObject, HostingTransport, URLSessionTaskDelegate, @unchecked Sendable {
  private let configuration: URLSessionConfiguration
  public init(configuration: URLSessionConfiguration = .ephemeral) {
    configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
    configuration.httpShouldSetCookies = false; self.configuration = configuration
  }
  public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
  public func send(_ request: URLRequest, limit: Int) async throws -> HostingHTTPResponse {
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    do {
      let (bytes, response) = try await session.bytes(for: request)
      guard let http = response as? HTTPURLResponse else { throw HostingError.invalidResponse }
      guard response.expectedContentLength <= Int64(limit) else { throw HostingError.responseTooLarge }
      var data = Data(); data.reserveCapacity(min(max(0, Int(response.expectedContentLength)), limit))
      for try await byte in bytes {
        try Task.checkCancellation()
        guard data.count < limit else { throw HostingError.responseTooLarge }; data.append(byte)
      }
      var headers: [String: String] = [:]
      for (key, value) in http.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
      return HostingHTTPResponse(data: data, status: http.statusCode, headers: headers)
    } catch is CancellationError { throw CancellationError() }
      catch let error as HostingError { throw error }
      catch { if Task.isCancelled { throw CancellationError() }; throw HostingError.networkFailure }
  }
}

public struct HostingHTTPClient: Sendable {
  public let transport: any HostingTransport
  public let sleep: @Sendable (TimeInterval) async throws -> Void
  public init(transport: any HostingTransport = HostingURLSessionTransport(), sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
    self.transport = transport; self.sleep = sleep
  }
  public func request(instance: HostingInstance, path: String, api: Bool = true, query: [URLQueryItem] = [],
    token: HostingToken? = nil, method: String = "GET", body: Data? = nil, form: Bool = false, limit: Int = 4 * 1024 * 1024,
    oauthResponse: Bool = false) async throws -> HostingHTTPResponse {
    _ = try HostingInstance(provider: instance.provider, url: instance.baseURL.absoluteString)
    let url = try instance.endpoint(path, api: api, query: query)
    guard instance.accepts(url, api: api) else { throw HostingError.insecureURL }
    var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("GitPier/1.5", forHTTPHeaderField: "User-Agent")
    if body != nil { request.setValue(form ? "application/x-www-form-urlencoded" : "application/json", forHTTPHeaderField: "Content-Type") }
    if let token {
      guard !token.accessToken.isEmpty, !token.accessToken.unicodeScalars.contains(where: { $0.value < 32 }),
        token.tokenType.lowercased() == "bearer" || token.tokenType.lowercased() == "token" else { throw HostingError.unauthorized }
      request.setValue((token.tokenType.lowercased() == "token" ? "token " : "Bearer ") + token.accessToken, forHTTPHeaderField: "Authorization")
    }
    var attempt = 0
    while true {
      try Task.checkCancellation()
      let response: HostingHTTPResponse
      do { response = try await transport.send(request, limit: limit) }
      catch is CancellationError { throw CancellationError() }
      catch let error as HostingError { throw error }
      catch { throw HostingError.networkFailure }
      guard response.data.count <= limit else { throw HostingError.responseTooLarge }
      if (300...399).contains(response.status) { throw HostingError.redirectRejected }
      let limited = response.status == 429 || response.status == 403 && (response.headers["x-ratelimit-remaining"] == "0" || response.headers["retry-after"] != nil)
      if method == "GET", attempt < 2, limited || response.status >= 500 {
        let retry = response.headers["retry-after"].flatMap(Double.init) ?? pow(2, Double(attempt))
        if retry <= 10 { attempt += 1; try await sleep(max(1, retry)); continue }
      }
      if oauthResponse, (200...499).contains(response.status) { return response }
      if limited { throw HostingError.rateLimited }
      switch response.status {
      case 200...299: return response
      case 401: throw HostingError.unauthorized
      case 403: throw HostingError.permissionRequired
      case 404: throw HostingError.notFound
      case 500...599: throw HostingError.serverFailure
      default: throw HostingError.invalidResponse
      }
    }
  }
  public static func form(_ fields: [String: String]) -> Data {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    return Data(fields.sorted { $0.key < $1.key }.map {
      ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    }.joined(separator: "&").utf8)
  }
}

/// Provider DTOs differ; this bounded JSON representation keeps all decoding inside the API boundary.
enum HostingJSON: Codable, Sendable {
  case object([String: HostingJSON]), array([HostingJSON]), string(String), integer(Int64), number(Double), bool(Bool), null
  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let v = try? c.decode([String: HostingJSON].self) { self = .object(v) }
    else if let v = try? c.decode([HostingJSON].self) { self = .array(v) }
    else if let v = try? c.decode(String.self) { self = .string(v) }
    else if let v = try? c.decode(Bool.self) { self = .bool(v) }
    else if let v = try? c.decode(Int64.self) { self = .integer(v) }
    else { self = .number(try c.decode(Double.self)) }
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self { case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .string(let v): try c.encode(v); case .integer(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .null: try c.encodeNil() }
  }
  subscript(_ key: String) -> HostingJSON { if case .object(let v) = self { return v[key] ?? .null }; return .null }
  var string: String { switch self { case .string(let v): v; case .integer(let v): String(v); case .number(let v): String(format: "%.0f", v); default: "" } }
  var int: Int { Int(string) ?? 0 }
  var bool: Bool { if case .bool(let v) = self { return v }; return false }
  var array: [HostingJSON] { if case .array(let v) = self { return v }; return [] }
  static func decode(_ data: Data) throws -> HostingJSON {
    do { return try JSONDecoder().decode(Self.self, from: data) } catch { throw HostingError.invalidResponse }
  }
}
