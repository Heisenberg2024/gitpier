import Foundation
@preconcurrency import Network

/// Owns one short-lived listener, bound explicitly to IPv4 loopback, and at most eight HTTP clients.
public actor OAuthLoopbackListener {
  private var listener: NWListener?
  private var connections: [UUID: NWConnection] = [:]
  private var ready: CheckedContinuation<UInt16, Error>?
  private var waiting: CheckedContinuation<URL, Error>?
  private var pending: Result<URL, Error>?
  private var session: OAuthPKCESession?
  private var deadline: Task<Void, Never>?
  private var started = false
  private var delivered = false
  public init() {}
  public func start(port: UInt16 = 0) async throws -> UInt16 {
    guard !started else { throw HostingError.operationInProgress }; started = true
    try Task.checkCancellation()
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
    let listener = try NWListener(using: parameters)
    self.listener = listener
    listener.stateUpdateHandler = { [weak self] state in Task { await self?.stateChanged(state) } }
    listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
    deadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(300)); await self?.finish(.failure(HostingError.expired)) } catch {}
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        ready = continuation; listener.start(queue: DispatchQueue(label: "GitPier.oauth.loopback"))
      }
    } onCancel: { Task { await self.cancel() } }
  }
  private func stateChanged(_ state: NWListener.State) {
    switch state {
    case .ready:
      if let port = listener?.port?.rawValue { ready?.resume(returning: port); ready = nil }
      else { finish(.failure(HostingError.invalidCallback)) }
    case .failed: finish(.failure(HostingError.networkFailure))
    default: break
    }
  }
  public func configure(_ session: OAuthPKCESession) throws {
    guard listener?.port?.rawValue == session.redirectURL.port.map(UInt16.init), self.session == nil else { throw HostingError.invalidCallback }
    self.session = session
  }
  public func callback() async throws -> URL {
    try Task.checkCancellation()
    guard !delivered else { throw HostingError.invalidCallback }
    delivered = true
    if let pending { return try pending.get() }
    guard waiting == nil else { throw HostingError.operationInProgress }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { waiting = $0 }
    } onCancel: { Task { await self.cancel() } }
  }
  public func cancel() { finish(.failure(CancellationError())) }
  private func accept(_ connection: NWConnection) {
    guard listener != nil, connections.count < 8 else { connection.cancel(); return }
    let id = UUID(); connections[id] = connection
    connection.start(queue: DispatchQueue(label: "GitPier.oauth.callback"))
    receive(id, data: Data())
    Task { [weak self] in
      do { try await Task.sleep(for: .seconds(10)); await self?.drop(id) } catch {}
    }
  }
  private func drop(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }
  private func receive(_ id: UUID, data: Data) {
    guard let connection = connections[id] else { return }
    connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, 8192 - data.count)) { [weak self] bytes, _, complete, error in
      Task { await self?.received(id, previous: data, bytes: bytes, complete: complete || error != nil) }
    }
  }
  private func received(_ id: UUID, previous: Data, bytes: Data?, complete: Bool) {
    var data = previous; if let bytes { data.append(bytes) }
    guard data.count < 8192 else { reply(id, success: false); return }
    guard let text = String(data: data, encoding: .utf8), text.contains("\r\n\r\n") else {
      if complete { drop(id) } else { receive(id, data: data) }; return
    }
    guard var session, let line = text.components(separatedBy: "\r\n").first else { reply(id, success: false); return }
    let parts = line.split(separator: " ")
    let headers = text.components(separatedBy: "\r\n").dropFirst()
    let hosts = headers.filter { $0.lowercased().hasPrefix("host:") }
    guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1", parts[1].hasPrefix("/"), !parts[1].hasPrefix("//"),
      hosts.count == 1, hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(session.redirectURL.port!)",
      !headers.contains(where: { $0.lowercased().hasPrefix("transfer-encoding:") }),
      let url = URL(string: "http://127.0.0.1:\(session.redirectURL.port!)" + parts[1]) else { reply(id, success: false); return }
    do {
      _ = try session.consume(url); self.session = session
      reply(id, success: true); finish(.success(url), retaining: id)
    } catch {
      // A validated provider error ends this attempt, including unknown provider codes. Invalid
      // origin/state/code callbacks keep listening; an expired session cannot accept any retry.
      if session.callbackConsumed && error as? HostingError != .invalidCallback || error as? HostingError == .expired {
        self.session = session
        reply(id, success: false, terminalFailure: true); finish(.failure(error), retaining: id)
      } else { reply(id, success: false) }
    }
  }
  private func reply(_ id: UUID, success: Bool, terminalFailure: Bool = false) {
    guard let connection = connections[id] else { return }
    let body = success ? "Authorization received. Return to GitPier." : terminalFailure
      ? "Authorization failed. Return to GitPier for details." : "Invalid or expired authorization callback."
    let text = "HTTP/1.1 \(success ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
    connection.send(content: Data(text.utf8), completion: .contentProcessed { [weak self] _ in Task { await self?.drop(id) } })
  }
  private func finish(_ result: Result<URL, Error>, retaining: UUID? = nil) {
    guard pending == nil else { return }; pending = result
    ready?.resume(throwing: (try? result.get()) == nil ? (result.failure ?? HostingError.invalidCallback) : HostingError.invalidCallback); ready = nil
    waiting?.resume(with: result); waiting = nil
    deadline?.cancel(); deadline = nil; listener?.cancel(); listener = nil; session = nil
    for id in Array(connections.keys) where id != retaining { drop(id) }
  }
}
private extension Result {
  var failure: Failure? { if case .failure(let error) = self { return error }; return nil }
}
