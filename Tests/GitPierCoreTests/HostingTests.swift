import XCTest
import Security
@testable import GitPierCore

actor HostingFixtureTransport: HostingTransport {
  var requests: [URLRequest] = []
  var responses: [HostingHTTPResponse]
  let handler: (@Sendable (URLRequest) async throws -> HostingHTTPResponse)?
  init(_ responses: [HostingHTTPResponse] = [], handler: (@Sendable (URLRequest) async throws -> HostingHTTPResponse)? = nil) { self.responses = responses; self.handler = handler }
  func send(_ request: URLRequest, limit: Int) async throws -> HostingHTTPResponse {
    requests.append(request)
    if let handler { return try await handler(request) }
    guard !responses.isEmpty else { throw HostingError.invalidResponse }
    return responses.removeFirst()
  }
  func captured() -> [URLRequest] { requests }
}
actor HostingFixtureVault: HostingCredentialStore {
  var values: [UUID: HostingToken] = [:]
  var saves = 0; var reads = 0
  var reject = false
  func setReject(_ value: Bool) { reject = value }
  func read(account: HostingAccount) throws -> HostingToken? { reads += 1; if reject { throw HostingError.keychainDenied }; return values[account.id] }
  func save(_ token: HostingToken, account: HostingAccount) throws { if reject { throw HostingError.keychainDenied }; values[account.id] = token; saves += 1 }
  func delete(account: HostingAccount) throws { if reject { throw HostingError.keychainDenied }; values[account.id] = nil }
  func counts() -> (Int, Int) { (reads, saves) }
}
actor HostingSleepRecorder {
  var intervals: [Double] = []
  func record(_ interval: Double) { intervals.append(interval) }
  func values() -> [Double] { intervals }
}
actor HostingRotationGateVault: HostingCredentialStore {
  var values: [UUID: HostingToken] = [:]
  var saves = 0
  var gate: CheckedContinuation<Void, Never>?
  func read(account: HostingAccount) -> HostingToken? { values[account.id] }
  func save(_ token: HostingToken, account: HostingAccount) async {
    saves += 1
    if saves == 2 { await withCheckedContinuation { gate = $0 } }
    values[account.id] = token
  }
  func delete(account: HostingAccount) { values[account.id] = nil }
  func blocked() -> Bool { gate != nil }
  func release() { gate?.resume(); gate = nil }
}

@MainActor final class HostingTests: XCTestCase {
  let sha = String(repeating: "a", count: 40)
  func response(_ json: String, status: Int = 200, headers: [String: String] = [:]) -> HostingHTTPResponse { HostingHTTPResponse(data: Data(json.utf8), status: status, headers: headers) }
  func instance(_ provider: HostingProvider = .github) throws -> HostingInstance { try HostingInstance(provider: provider, url: provider == .github ? "https://github.com" : "https://forge.example.invalid") }
  func config(_ p: HostingProvider = .github) throws -> OAuthConfiguration { OAuthConfiguration(instance: try instance(p), clientID: "fixture-public-id", redirect: p == .gitea ? .loopback(port: 0) : .application) }
  func account(_ p: HostingProvider = .github, id: UUID = UUID(), user: String = "42", kind: HostingAuthenticationKind = .oauth) throws -> HostingAccount {
    HostingAccount(id: id, instance: try instance(p), user: HostingUser(stableID: user, login: "alice"), kind: kind, scopes: [], oauth: try config(p), storageMode: .keychain)
  }
  func binding(_ account: HostingAccount) throws -> RepositoryHostingBinding { try RepositoryHostingBinding(repositoryID: UUID(), accountID: account.id, remote: "upstream", repository: "owner/repo") }
  func http(_ transport: any HostingTransport) -> HostingHTTPClient { HostingHTTPClient(transport: transport, sleep: { _ in try Task.checkCancellation() }) }
  func expect(_ expected: HostingError, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await body(); XCTFail("Expected \(expected)", file: file, line: line) }
    catch { XCTAssertEqual(error as? HostingError, expected, file: file, line: line) }
  }
  let deviceJSON = "{\"device_code\":\"fixture-device\",\"user_code\":\"ABCD-EFGH\",\"verification_uri\":\"https://github.com/login/device\",\"interval\":2,\"expires_in\":300}"
  let tokenJSON = "{\"access_token\":\"fixture-access\",\"token_type\":\"bearer\",\"scope\":\"read:user\"}"
  func testPublicIDsMissingDisableOAuthWithoutInventedValues() throws {
    let defaults = HostingOAuthConfiguration()
    XCTAssertThrowsError(try defaults.configuration(for: .github).validate())
    XCTAssertThrowsError(try defaults.configuration(for: .gitlab).validate())
  }
  func testInstanceCanonicalizationAndPortBoundary() throws {
    let i = try HostingInstance(provider: .gitlab, url: "https://FORGE.example.invalid:443/group/")
    XCTAssertEqual(i.baseURL.absoluteString, "https://forge.example.invalid/group")
    XCTAssertFalse(i.accepts(URL(string: "https://forge.example.invalid:444/group/api/v4/user")!, api: true))
    XCTAssertFalse(i.accepts(URL(string: "https://forge.example.invalid/other/api/v4/user")!, api: true))
  }
  func testInstancesRejectCredentialsHTTPQueryTraversalAndForeignGitHub() throws {
    for url in ["http://forge.invalid", "https://u:p@forge.invalid", "https://forge.invalid?token=secret", "https://forge.invalid/#x", "https://forge.invalid/a/../b", "https://forge.invalid/%2e%2e"] {
      XCTAssertThrowsError(try HostingInstance(provider: .gitlab, url: url), url)
    }
    XCTAssertThrowsError(try HostingInstance(provider: .github, url: "https://github.example.invalid"))
  }
  func testRemoteParsingHandlesNestedSCPSSHPortsAndGitSuffix() throws {
    let i = try instance(.gitlab)
    for remote in ["git@forge.example.invalid:group/sub/repo.git", "ssh://git@forge.example.invalid:2222/group/sub/repo.git", "https://forge.example.invalid/group/sub/repo.git"] {
      XCTAssertEqual(HostingRemoteParser.repository(remote, instance: i), "group/sub/repo")
    }
    XCTAssertNil(HostingRemoteParser.repository("https://other.invalid/group/repo", instance: i))
    XCTAssertNil(HostingRemoteParser.repository("https://forge.example.invalid:444/group/repo", instance: i))
  }
  func testRemoteParserRespectsInstallationPrefixAndDoesNotGuessPlatform() throws {
    let i = try HostingInstance(provider: .gitea, url: "https://forge.invalid/gitea")
    XCTAssertEqual(HostingRemoteParser.repository("https://forge.invalid/gitea/me/repo.git", instance: i), "me/repo")
    XCTAssertNil(HostingRemoteParser.repository("https://forge.invalid/me/repo.git", instance: i))
    XCTAssertNil(HostingRemoteParser.repository("git://forge.invalid/gitea/me/repo", instance: i))
  }
  func testPKCERFC7636VectorAndFreshRandomness() throws {
    XCTAssertEqual(OAuthPKCESession.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    let a = try OAuthPKCESession(configuration: config(.gitlab), redirectURL: URL(string: "gitpier://oauth/gitlab")!)
    let b = try OAuthPKCESession(configuration: config(.gitlab), redirectURL: URL(string: "gitpier://oauth/gitlab")!)
    XCTAssertEqual(a.verifier.count, 43); XCTAssertNotEqual(a.verifier, b.verifier); XCTAssertNotEqual(a.state, b.state)
    let url = try a.authorizationURL(scopes: ["read_api"])
    XCTAssertTrue(url.absoluteString.contains("code_challenge_method=S256")); XCTAssertFalse(url.absoluteString.contains("client_secret"))
  }
  func testPKCEAcceptsOnlyMatchingCallbackAndConsumesItOnce() throws {
    var s = try OAuthPKCESession(configuration: config(.gitlab), redirectURL: URL(string: "gitpier://oauth/gitlab")!)
    let callback = URL(string: "gitpier://oauth/gitlab?state=\(s.state)&code=fixture")!
    XCTAssertEqual(try s.consume(callback), "fixture"); XCTAssertThrowsError(try s.consume(callback))
  }
  func testPKCERejectsWrongStateInstancePathAndDuplicateParameters() throws {
    for value in ["gitpier://other/gitlab", "gitpier://oauth/gitea", "https://forge.invalid/callback", "gitpier://oauth/gitlab?state=wrong", "gitpier://oauth/gitlab?state=DUPLICATE"] {
      var s = try OAuthPKCESession(configuration: config(.gitlab), redirectURL: URL(string: "gitpier://oauth/gitlab")!)
      let base = value.contains("?") ? value.replacingOccurrences(of: "DUPLICATE", with: s.state + "&state=" + s.state) : value + "?state=" + s.state
      XCTAssertThrowsError(try s.consume(URL(string: base + "&code=fixture")!))
    }
  }
  func testPKCERejectsExpiredCallbackAndTokensInURL() throws {
    var s = try OAuthPKCESession(configuration: config(.gitlab), redirectURL: URL(string: "gitpier://oauth/gitlab")!, now: Date(timeIntervalSince1970: 0))
    XCTAssertThrowsError(try s.consume(URL(string: "gitpier://oauth/gitlab?state=\(s.state)&code=x")!))
    s = try OAuthPKCESession(configuration: config(.gitlab), redirectURL: URL(string: "gitpier://oauth/gitlab")!)
    XCTAssertThrowsError(try s.consume(URL(string: "gitpier://oauth/gitlab?state=\(s.state)&code=x&access_token=x")!))
  }
  func testProviderRedirectStrategiesRejectUnsupportedRegistration() throws {
    XCTAssertThrowsError(try OAuthConfiguration(instance: instance(.gitea), clientID: "id").validate())
    XCTAssertThrowsError(try OAuthConfiguration(instance: instance(.gitlab), clientID: "id", redirect: .loopback(port: 0)).validate())
    XCTAssertNoThrow(try OAuthPKCESession(configuration: config(.gitea), redirectURL: URL(string: "http://127.0.0.1:40001/oauth/gitea/callback")!))
    XCTAssertThrowsError(try OAuthPKCESession(configuration: config(.gitea), redirectURL: URL(string: "http://localhost:40001/oauth/gitea/callback")!))
  }
  func testDeviceFlowPendingSlowDownAndSuccessRespectIntervals() async throws {
    let transport = HostingFixtureTransport([response(deviceJSON), response("{\"error\":\"authorization_pending\"}"), response("{\"error\":\"slow_down\"}"), response(tokenJSON)])
    let sleeper = HostingSleepRecorder()
    let coordinator = OAuthAuthorizationCoordinator(http: HostingHTTPClient(transport: transport, sleep: { await sleeper.record($0) }))
    let token = try await coordinator.github(configuration: config(), scopes: ["read:user"]) { auth in
      XCTAssertEqual(auth.userCode, "ABCD-EFGH"); XCTAssertEqual(auth.verificationURL.absoluteString, "https://github.com/login/device")
    }
    XCTAssertEqual(token.accessToken, "fixture-access")
    let intervals = await sleeper.values(); XCTAssertEqual(intervals, [2, 2, 7])
    let requests = await transport.captured(); XCTAssertEqual(requests.count, 4)
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "POST" && $0.value(forHTTPHeaderField: "Authorization") == nil })
  }
  func testOrdinaryBrowserCallbackCanArriveBeforeWaitAndIsConsumedOnce() async throws {
    let s = try OAuthPKCESession(configuration: config(.gitlab), redirectURL: URL(string: "gitpier://oauth/gitlab")!)
    let receiver = OAuthBrowserCallback(session: s), url = URL(string: "gitpier://oauth/gitlab?state=\(s.state)&code=fixture")!
    let accepted = await receiver.receive(url); XCTAssertTrue(accepted)
    let received = try await receiver.wait(); XCTAssertEqual(received, url)
    let duplicate = await receiver.receive(url); XCTAssertFalse(duplicate)
    await expect(.operationInProgress) { _ = try await receiver.wait() }
  }
  func testOrdinaryBrowserIgnoresForeignAndMalformedCallbacksWhileWaiting() async throws {
    let s = try OAuthPKCESession(configuration: config(.gitlab), redirectURL: URL(string: "gitpier://oauth/gitlab")!)
    let receiver = OAuthBrowserCallback(session: s), waiting = Task { try await receiver.wait() }
    for value in ["gitpier://oauth/gitea?state=\(s.state)&code=x", "gitpier://oauth/gitlab?state=wrong&code=x",
      "gitpier://oauth/gitlab?state=\(s.state)&code=x&code=y", "gitpier://oauth/gitlab?state=\(s.state)&code=x&access_token=fixture",
      "gitpier://oauth/gitlab?state=\(s.state)&code=" + String(repeating: "x", count: 9000)] {
      let accepted = await receiver.receive(URL(string: value)!); XCTAssertFalse(accepted)
    }
    let url = URL(string: "gitpier://oauth/gitlab?state=\(s.state)&code=fixture")!
    let accepted = await receiver.receive(url); XCTAssertTrue(accepted)
    let received = try await waiting.value; XCTAssertEqual(received, url)
  }
  func testOrdinaryBrowserMatchingDenialTerminatesOnlyItsSession() async throws {
    let s = try OAuthPKCESession(configuration: config(.gitlab), redirectURL: URL(string: "gitpier://oauth/gitlab")!)
    let receiver = OAuthBrowserCallback(session: s)
    let unrelated = await receiver.receive(URL(string: "gitpier://oauth/gitlab?state=wrong&error=access_denied")!); XCTAssertFalse(unrelated)
    let denied = await receiver.receive(URL(string: "gitpier://oauth/gitlab?state=\(s.state)&error=access_denied")!); XCTAssertTrue(denied)
    await expect(.denied) { _ = try await receiver.wait() }
  }
  func testOrdinaryBrowserCancellationBeforeWaitRejectsLateCallback() async throws {
    let s = try OAuthPKCESession(configuration: config(.gitlab), redirectURL: URL(string: "gitpier://oauth/gitlab")!)
    let receiver = OAuthBrowserCallback(session: s); await receiver.cancel()
    do { _ = try await receiver.wait(); XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
    let accepted = await receiver.receive(URL(string: "gitpier://oauth/gitlab?state=\(s.state)&code=fixture")!); XCTAssertFalse(accepted)
  }
  func testOrdinaryBrowserCancellingWaitingTaskClosesReceiver() async throws {
    let s = try OAuthPKCESession(configuration: config(.gitlab), redirectURL: URL(string: "gitpier://oauth/gitlab")!)
    let receiver = OAuthBrowserCallback(session: s), waiting = Task { try await receiver.wait() }
    await Task.yield(); waiting.cancel()
    do { _ = try await waiting.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
    let accepted = await receiver.receive(URL(string: "gitpier://oauth/gitlab?state=\(s.state)&code=fixture")!); XCTAssertFalse(accepted)
  }
  func testOrdinaryBrowserExpiredSessionCannotReceiveCode() async throws {
    let s = try OAuthPKCESession(configuration: config(.gitlab), redirectURL: URL(string: "gitpier://oauth/gitlab")!, now: .distantPast)
    let receiver = OAuthBrowserCallback(session: s)
    let accepted = await receiver.receive(URL(string: "gitpier://oauth/gitlab?state=\(s.state)&code=fixture")!); XCTAssertFalse(accepted)
    await expect(.expired) { _ = try await receiver.wait() }
  }
  func testOrdinaryBrowserDeadlineReleasesPendingWaiter() async throws {
    let s = try OAuthPKCESession(configuration: config(.gitlab), redirectURL: URL(string: "gitpier://oauth/gitlab")!, now: Date().addingTimeInterval(-299.8))
    let receiver = OAuthBrowserCallback(session: s)
    await expect(.expired) { _ = try await receiver.wait() }
  }
  func testOrdinaryBrowserConcurrentDeliveryAcceptsOnlyOneCallback() async throws {
    let s = try OAuthPKCESession(configuration: config(.gitlab), redirectURL: URL(string: "gitpier://oauth/gitlab")!)
    let receiver = OAuthBrowserCallback(session: s), url = URL(string: "gitpier://oauth/gitlab?state=\(s.state)&code=fixture")!
    let count = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
      for _ in 0..<10 { group.addTask { await receiver.receive(url) } }
      var count = 0; for await accepted in group where accepted { count += 1 }; return count
    }
    XCTAssertEqual(count, 1); let received = try await receiver.wait(); XCTAssertEqual(received, url)
  }
  func testOrdinaryBrowserNewSessionRejectsPreviousAuthorizationCallback() async throws {
    let a = try OAuthPKCESession(configuration: config(.gitlab), redirectURL: URL(string: "gitpier://oauth/gitlab")!)
    let b = try OAuthPKCESession(configuration: config(.gitlab), redirectURL: URL(string: "gitpier://oauth/gitlab")!)
    let old = OAuthBrowserCallback(session: a), current = OAuthBrowserCallback(session: b)
    await old.cancel()
    let stale = await current.receive(URL(string: "gitpier://oauth/gitlab?state=\(a.state)&code=old")!); XCTAssertFalse(stale)
    let url = URL(string: "gitpier://oauth/gitlab?state=\(b.state)&code=new")!
    let accepted = await current.receive(url); XCTAssertTrue(accepted)
    let received = try await current.wait(); XCTAssertEqual(received, url)
  }
  func testDeviceFlowReportsDeniedExpiredDisabledAndInvalidClient() async throws {
    for (code, expected) in [("access_denied", HostingError.denied), ("expired_token", .expired), ("incorrect_client_credentials", .invalidClient), ("device_flow_disabled", .deviceDisabled)] {
      let transport = HostingFixtureTransport([response(deviceJSON), response("{\"error\":\"\(code)\"}")])
      let c = OAuthAuthorizationCoordinator(http: http(transport))
      await expect(expected) { _ = try await c.github(configuration: config(), scopes: []) { _ in } }
    }
  }
  func testDeviceFlowRejectsForeignVerificationURI() async throws {
    let transport = HostingFixtureTransport([response(deviceJSON.replacingOccurrences(of: "github.com/login/device", with: "attacker.invalid/login/device"))])
    let c = OAuthAuthorizationCoordinator(http: http(transport))
    await expect(.invalidResponse) { _ = try await c.github(configuration: config(), scopes: []) { _ in XCTFail("Must not display foreign verification URL") } }
  }
  func testDeviceFlowCancellationStopsSubsequentPolling() async throws {
    let transport = HostingFixtureTransport([response(deviceJSON), response(tokenJSON)])
    let c = OAuthAuthorizationCoordinator(http: http(transport))
    do { _ = try await c.github(configuration: config(), scopes: []) { _ in await c.cancel() }; XCTFail("Expected cancellation") }
    catch is CancellationError {} catch { XCTFail("Unexpected error") }
    let requests = await transport.captured(); XCTAssertEqual(requests.count, 1)
  }
  func testPKCEExchangePOSTHasVerifierAndNeverSecretAndRejectsReplay() async throws {
    let transport = HostingFixtureTransport([response(tokenJSON)])
    let c = OAuthAuthorizationCoordinator(http: http(transport))
    var s = try OAuthPKCESession(configuration: config(.gitlab), redirectURL: URL(string: "gitpier://oauth/gitlab")!)
    let code = try s.consume(URL(string: "gitpier://oauth/gitlab?state=\(s.state)&code=fixture-code")!)
    _ = try await c.exchange(session: s, code: code, scopes: ["read_api"])
    await expect(.invalidCallback) { _ = try await c.exchange(session: s, code: code, scopes: []) }
    let requests = await transport.captured(); let r = try XCTUnwrap(requests.first)
    XCTAssertEqual(r.httpMethod, "POST"); XCTAssertEqual(r.url?.path, "/oauth/token"); XCTAssertNil(r.url?.query)
    let body = String(decoding: r.httpBody ?? Data(), as: UTF8.self)
    XCTAssertTrue(body.contains("code_verifier=" + s.verifier)); XCTAssertFalse(body.contains("client_secret"))
  }
  func testGiteaExchangeUsesInstancePublicPKCEEndpoint() async throws {
    let t = HostingFixtureTransport([response(tokenJSON)])
    let c = OAuthAuthorizationCoordinator(http: http(t))
    var s = try OAuthPKCESession(configuration: config(.gitea), redirectURL: URL(string: "http://127.0.0.1:40001/oauth/gitea/callback")!)
    let code = try s.consume(URL(string: "http://127.0.0.1:40001/oauth/gitea/callback?state=\(s.state)&code=fixture-code")!)
    _ = try await c.exchange(session: s, code: code, scopes: [])
    let requests = await t.captured(); XCTAssertEqual(requests.first?.url?.path, "/login/oauth/access_token")
  }
  func testGiteaVersionGatesGranularScopesAndOlderPATFallback() async throws {
    for (version, supported) in [("1.22.6", false), ("1.23.0", true), ("1.24.7", true), ("invalid", false)] {
      let c = OAuthAuthorizationCoordinator(http: http(HostingFixtureTransport([response("{\"version\":\"\(version)\"}")])))
      let result = try await c.giteaSupportsGranularScopes(instance(.gitea)); XCTAssertEqual(result, supported)
    }
    XCTAssertEqual(HostingAuthorizationLevel.read.scopes(for: .gitea), ["read:user", "read:repository"])
  }
  func testOptionalTokenExpiryAndRefreshFieldsAreNotInvented() throws {
    let token = try OAuthAuthorizationCoordinator.token(HostingJSON.decode(Data(tokenJSON.utf8)))
    XCTAssertNil(token.expiresAt); XCTAssertNil(token.refreshToken)
    let expiring = try OAuthAuthorizationCoordinator.token(HostingJSON.decode(Data("{\"access_token\":\"fixture\",\"refresh_token\":\"refresh\",\"expires_in\":3600,\"refresh_token_expires_in\":7200,\"scope\":\"read_api read_user\"}".utf8)), now: Date(timeIntervalSince1970: 0))
    XCTAssertEqual(expiring.expiresAt, Date(timeIntervalSince1970: 3600)); XCTAssertEqual(expiring.scopes, ["read_api", "read_user"])
  }
  func testRefreshRotationUsesOnePOSTAndNoClientSecret() async throws {
    let t = HostingFixtureTransport([response("{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\",\"expires_in\":3600}")])
    let c = OAuthAuthorizationCoordinator(http: http(t))
    let next = try await c.refresh(configuration: config(.gitlab), token: HostingToken(accessToken: "old", refreshToken: "old-refresh", scopes: ["read_api"]))
    XCTAssertEqual(next.refreshToken, "new-refresh"); XCTAssertEqual(next.scopes, ["read_api"])
    let requests = await t.captured(); XCTAssertEqual(requests.count, 1)
    let body = String(decoding: requests[0].httpBody!, as: UTF8.self)
    XCTAssertTrue(body.contains("grant_type=refresh_token")); XCTAssertFalse(body.contains("client_secret"))
  }
  func testExpiredRefreshRequiresReauthorizationBeforeNetwork() async throws {
    let t = HostingFixtureTransport(); let c = OAuthAuthorizationCoordinator(http: http(t))
    await expect(.unauthorized) { _ = try await c.refresh(configuration: config(), token: HostingToken(accessToken: "x", refreshToken: "y", refreshExpiresAt: .distantPast)) }
    let requests = await t.captured(); XCTAssertTrue(requests.isEmpty)
  }
  func testTokenManagerRequiresExplicitUnlockAndNeverReadsOnBackgroundAccess() async throws {
    let vault = HostingFixtureVault(), a = try account()
    let manager = OAuthTokenManager(vault: vault)
    await expect(.credentialsLocked) { _ = try await manager.token(for: a) }
    let counts = await vault.counts(); XCTAssertEqual(counts.0, 0)
  }
  func testExpiredAccessTokenWithoutRefreshIsDistinctFromRevokedCredential() async throws {
    let a = try account(), manager = OAuthTokenManager(vault: HostingFixtureVault())
    try await manager.install(HostingToken(accessToken: "fixture", expiresAt: .distantPast), account: a)
    await expect(.expired) { _ = try await manager.token(for: a) }
  }
  func testTokenManagerConcurrentRefreshIsSingleFlightAndAtomic() async throws {
    let vault = HostingFixtureVault()
    let t = HostingFixtureTransport(handler: { _ in
      try await Task.sleep(for: .milliseconds(20))
      return HostingHTTPResponse(data: Data("{\"access_token\":\"next\",\"refresh_token\":\"rotated\",\"expires_in\":3600}".utf8))
    })
    let manager = OAuthTokenManager(vault: vault, oauth: OAuthAuthorizationCoordinator(http: http(t))), a = try account(.gitlab)
    try await manager.install(HostingToken(accessToken: "old", refreshToken: "old-refresh", expiresAt: .distantPast), account: a)
    async let first = manager.token(for: a); async let second = manager.token(for: a)
    let values = try await [first, second]; XCTAssertEqual(values.map(\.accessToken), ["next", "next"])
    let requests = await t.captured(), counts = await vault.counts(); XCTAssertEqual(requests.count, 1); XCTAssertEqual(counts.1, 2)
    let saved = try await vault.read(account: a); XCTAssertEqual(saved?.refreshToken, "rotated")
  }
  func testConcurrentRequestJoinsRefreshWhileRotatedPairIsBeingSaved() async throws {
    let a = try account(.gitlab), vault = HostingRotationGateVault()
    let t = HostingFixtureTransport([response("{\"access_token\":\"next\",\"refresh_token\":\"rotated\",\"expires_in\":3600}")])
    let manager = OAuthTokenManager(vault: vault, oauth: OAuthAuthorizationCoordinator(http: http(t)))
    try await manager.install(HostingToken(accessToken: "old", refreshToken: "old-refresh", expiresAt: .distantPast), account: a)
    let first = Task { try await manager.token(for: a) }
    let deadline = Date().addingTimeInterval(2)
    while !(await vault.blocked()) {
      if Date() > deadline { first.cancel(); throw HostingError.networkFailure }
      await Task.yield()
    }
    // Hold the atomic Keychain write, then issue another API request during that exact phase.
    let release = Task { try await Task.sleep(for: .milliseconds(50)); await vault.release() }
    do {
      let concurrent = try await manager.token(for: a)
      XCTAssertEqual(concurrent.accessToken, "next")
      let original = try await first.value; XCTAssertEqual(original.refreshToken, "rotated")
      try await release.value
    } catch { await vault.release(); _ = try? await first.value; throw error }
    let requests = await t.captured(); XCTAssertEqual(requests.count, 1)
  }
  func testFailedRotationSaveKeepsNewSessionAndPreservesOldKeychainPair() async throws {
    let vault = HostingFixtureVault(), a = try account(.gitlab)
    let manager = OAuthTokenManager(vault: vault, oauth: OAuthAuthorizationCoordinator(http: http(HostingFixtureTransport([response("{\"access_token\":\"next\",\"refresh_token\":\"rotated\"}")]))))
    try await manager.install(HostingToken(accessToken: "old", refreshToken: "old-refresh", expiresAt: .distantPast), account: a)
    await vault.setReject(true)
    await expect(.sessionOnly) { _ = try await manager.token(for: a) }
    let active = try await manager.token(for: a); XCTAssertEqual(active.refreshToken, "rotated")
    let transient = await manager.isSessionOnly(a.id); XCTAssertTrue(transient)
    await vault.setReject(false); let saved = try await vault.read(account: a); XCTAssertEqual(saved?.refreshToken, "old-refresh")
  }
  func testStableUserIDAndInstancePartitionAccountsEvenWithSameUsername() throws {
    let a = try account(.gitlab), b = try account(.gitlab, user: "43")
    let other = HostingAccount(instance: try HostingInstance(provider: .gitlab, url: "https://other.invalid"), user: a.user, kind: .oauth, scopes: [])
    XCTAssertNotEqual(a.identity, b.identity); XCTAssertNotEqual(a.identity, other.identity)
  }
  func testServerStableIdentityPreservesExact64BitInteger() throws {
    let value = try HostingJSON.decode(Data("{\"id\":9007199254740993}".utf8))
    XCTAssertEqual(value["id"].string, "9007199254740993")
  }
  func testCachedTokenCannotBeRetargetedToAnotherInstanceOrUser() async throws {
    let a = try account(.gitlab), manager = OAuthTokenManager(vault: HostingFixtureVault())
    try await manager.install(HostingToken(accessToken: "fixture"), account: a)
    let b = HostingAccount(id: a.id, instance: try HostingInstance(provider: .gitlab, url: "https://other.invalid"), user: a.user, kind: .oauth, scopes: [])
    await expect(.accountChanged) { _ = try await manager.token(for: b) }
  }
  func testDisconnectDeletesOnlySelectedAccountAndDenialPreservesVault() async throws {
    let vault = HostingFixtureVault(), manager = OAuthTokenManager(vault: vault), a = try account(), b = try account(user: "43")
    try await manager.install(HostingToken(accessToken: "first"), account: a); try await manager.install(HostingToken(accessToken: "second"), account: b)
    try await manager.forget(a)
    let first = try await vault.read(account: a), second = try await manager.token(for: b)
    XCTAssertNil(first); XCTAssertEqual(second.accessToken, "second")
    await vault.setReject(true); await expect(.keychainDenied) { try await manager.forget(b) }
    await vault.setReject(false); let preserved = try await vault.read(account: b); XCTAssertEqual(preserved?.accessToken, "second")
  }
  func testMetadataContainsNoSecretsAndCorruptionIsPreserved() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-hosting-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = HostingMetadataStore(url: root.appendingPathComponent("hosting.json"))
    var m = HostingMetadata(); m.accounts = [try account()]; try store.save(m)
    XCTAssertEqual(try store.load().accounts.count, 1)
    let data = try Data(contentsOf: store.url); XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("accessToken"))
    try Data("broken".utf8).write(to: store.url)
    XCTAssertThrowsError(try store.load()); XCTAssertEqual(try Data(contentsOf: store.url), Data("broken".utf8))
  }
  func testHostingKeychainNamespaceRoundTripDoesNotTouchGitCredentials() async throws {
    let service = "GitPier.hosting.synthetic." + UUID().uuidString
    let vault = HostingKeychainStore(service: service), a = try account()
    let token = HostingToken(accessToken: "fixture-access", refreshToken: "fixture-refresh", expiresAt: Date(timeIntervalSince1970: 1000))
    try await vault.save(token, account: a)
    do {
      let loaded = try await vault.read(account: a); XCTAssertEqual(loaded, token)
      var rotated = token; rotated.refreshToken = "rotated"; try await vault.save(rotated, account: a)
      let updated = try await vault.read(account: a); XCTAssertEqual(updated?.refreshToken, "rotated")
      XCTAssertEqual(HostingKeychainStore.service, "GitPier.hosting.oauth"); XCTAssertEqual(KeychainStore().service, "GitPier.credentials")
      try await vault.delete(account: a); let deleted = try await vault.read(account: a); XCTAssertNil(deleted)
    } catch { try? await vault.delete(account: a); throw error }
  }
  func testAPIHeadersAndPathsStayOnExplicitInstance() async throws {
    let t = HostingFixtureTransport([response("{\"id\":42,\"username\":\"alice\"}")]), api = HostingAPIClient(http: http(t))
    let i = try HostingInstance(provider: .gitlab, url: "https://forge.invalid:8443/gitlab")
    let user = try await api.user(instance: i, token: HostingToken(accessToken: "fixture-secret"))
    XCTAssertEqual(user.stableID, "42")
    let requests = await t.captured(); XCTAssertEqual(requests[0].url?.absoluteString, "https://forge.invalid:8443/gitlab/api/v4/user")
    XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
    XCTAssertFalse(requests[0].url!.absoluteString.contains("fixture-secret"))
  }
  func testAvatarMetadataDoesNotPersistTokenBearingQueryOrFragment() async throws {
    let t = HostingFixtureTransport([response("{\"id\":42,\"login\":\"alice\",\"avatar_url\":\"https://avatars.example.invalid/user.png?access_token=synthetic#secret\"}")])
    let user = try await HostingAPIClient(http: http(t)).user(instance: instance(), token: HostingToken(accessToken: "fixture"))
    XCTAssertEqual(user.avatarURL?.absoluteString, "https://avatars.example.invalid/user.png")
  }
  func testGiteaPATUsesDocumentedTokenHeaderRatherThanOAuthBearer() async throws {
    let t = HostingFixtureTransport([response("{\"id\":42,\"login\":\"alice\"}")])
    _ = try await HostingAPIClient(http: http(t)).user(instance: instance(.gitea), token: HostingToken(accessToken: "fixture-pat", tokenType: "token"))
    let requests = await t.captured(); XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "token fixture-pat")
    XCTAssertNil(requests[0].url?.query)
  }
  func testAPIRejectsRedirectWithoutFollowingLocation() async throws {
    let t = HostingFixtureTransport([response("", status: 302, headers: ["location": "https://attacker.invalid"])]), client = http(t)
    await expect(.redirectRejected) { _ = try await client.request(instance: instance(), path: "user", token: HostingToken(accessToken: "fixture")) }
    let requests = await t.captured(); XCTAssertEqual(requests.count, 1)
  }
  func testAPIErrorsNeverEchoRemoteBodiesOrToken() async throws {
    for (status, expected) in [(401, HostingError.unauthorized), (403, .permissionRequired), (404, .notFound), (429, .rateLimited), (503, .serverFailure)] {
      let r = response("fixture-secret", status: status, headers: status == 403 ? [:] : ["retry-after": "120"])
      let t = HostingFixtureTransport([r, r, r])
      await expect(expected) { _ = try await http(t).request(instance: instance(), path: "user") }
      XCTAssertFalse(expected.localizedDescription.contains("fixture-secret"))
    }
  }
  func testGETBackoffIsBoundedButPOSTNeverRetries() async throws {
    let r = response("", status: 503), t = HostingFixtureTransport([r, r, response("{}")]), recorder = HostingSleepRecorder()
    let c = HostingHTTPClient(transport: t, sleep: { await recorder.record($0) })
    _ = try await c.request(instance: instance(), path: "user")
    let intervals = await recorder.values(); XCTAssertEqual(intervals, [1, 2])
    let post = HostingFixtureTransport([r, response("{}")])
    await expect(.serverFailure) { _ = try await http(post).request(instance: instance(), path: "repos/owner/repo/pulls", method: "POST", body: Data()) }
    let requests = await post.captured(); XCTAssertEqual(requests.count, 1)
  }
  func testAPIRejectsOversizeResponsesAndMalformedJSON() async throws {
    let t = HostingFixtureTransport([response(String(repeating: "x", count: 100))])
    await expect(.responseTooLarge) { _ = try await http(t).request(instance: instance(), path: "user", limit: 50) }
    XCTAssertThrowsError(try HostingJSON.decode(Data("invalid".utf8)))
  }
  func testAPIPathsEncodeNestedGroupsAndBranchesLiterally() throws {
    let api = HostingAPIClient()
    XCTAssertEqual(try api.repositoryPath("group/sub/repo", provider: .gitlab), "projects/group%2Fsub%2Frepo")
    XCTAssertEqual(HostingInstance.component("feature/space name"), "feature%2Fspace%20name")
    XCTAssertThrowsError(try api.repositoryPath("https://attacker.invalid/a", provider: .github))
    XCTAssertThrowsError(try instance().endpoint("../token"))
  }
  func pr(_ p: HostingProvider, state: String = "open", draft: Bool = false) -> String {
    p == .gitlab ? "{\"iid\":7,\"title\":\"Fixture\",\"state\":\"\(state)\",\"draft\":\(draft),\"source_branch\":\"feature\",\"target_branch\":\"main\",\"source_project_id\":12,\"sha\":\"\(sha)\",\"author\":{\"username\":\"alice\"}}"
      : "{\"number\":7,\"title\":\"Fixture\",\"state\":\"\(state)\",\"draft\":\(draft),\"head\":{\"ref\":\"feature\",\"sha\":\"\(sha)\",\"repo\":{\"full_name\":\"owner/repo\"}},\"base\":{\"ref\":\"main\"},\"user\":{\"login\":\"alice\"}}"
  }
  func testThreeProvidersNormalizeListsAndPaginateWithoutFollowingLinks() async throws {
    for p in HostingProvider.allCases {
      let a = try account(p), b = try binding(a), t = HostingFixtureTransport([response("[" + pr(p) + "]", headers: ["link": "<https://attacker.invalid/private>; rel=\"next\""])])
      let result = try await HostingAPIClient(http: http(t)).requests(b, account: a, token: HostingToken(accessToken: "fixture"))
      XCTAssertEqual(result.items[0].number, 7); XCTAssertEqual(result.items[0].source, "feature"); XCTAssertEqual(result.nextPage, 2)
      let requests = await t.captured(); XCTAssertEqual(requests.count, 1)
    }
  }
  func testDraftAndMergedFilteringDoNotMislabelClosedRequests() async throws {
    let a = try account(), b = try binding(a)
    let t = HostingFixtureTransport([response("[" + pr(.github, draft: true) + "," + pr(.github, state: "closed") + "]")])
    let result = try await HostingAPIClient(http: http(t)).requests(b, account: a, token: HostingToken(accessToken: "fixture"), filter: .draft)
    XCTAssertEqual(result.items.count, 1); XCTAssertTrue(result.items[0].draft)
  }
  func testCINoDataIsEmptyAndWrongCommitIsRejected() async throws {
    let a = try account(), b = try binding(a)
    let t = HostingFixtureTransport([response("{\"sha\":\"\(sha)\",\"statuses\":[]}"), response("{\"check_runs\":[]}")])
    let checks = try await HostingAPIClient(http: http(t)).checks(b, sha: sha, account: a, token: HostingToken(accessToken: "fixture")); XCTAssertTrue(checks.isEmpty)
    let wrong = HostingFixtureTransport([response("{\"sha\":\"old\",\"statuses\":[]}")])
    await expect(.invalidResponse) { _ = try await HostingAPIClient(http: http(wrong)).checks(b, sha: sha, account: a, token: HostingToken(accessToken: "fixture")) }
  }
  func testGitHubChecksAndStatusesUseExactSHAAndExposePermissions() async throws {
    let a = try account(), b = try binding(a)
    let t = HostingFixtureTransport([response("{\"sha\":\"\(sha)\",\"statuses\":[{\"context\":\"unit\",\"state\":\"success\"}]}"), response("{\"check_runs\":[{\"name\":\"build\",\"head_sha\":\"\(sha)\",\"status\":\"in_progress\"},{\"name\":\"old\",\"head_sha\":\"old\",\"conclusion\":\"success\"}]}")])
    let checks = try await HostingAPIClient(http: http(t)).checks(b, sha: sha, account: a, token: HostingToken(accessToken: "fixture"))
    XCTAssertEqual(checks.map(\.state), [.success, .running]); XCTAssertTrue(checks.allSatisfy { $0.sha == sha })
    let denied = HostingFixtureTransport([response("", status: 403)])
    await expect(.permissionRequired) { _ = try await HostingAPIClient(http: http(denied)).checks(b, sha: sha, account: a, token: HostingToken(accessToken: "fixture")) }
  }
  func testGitLabPipelinesIgnoreOldSHA() async throws {
    let a = try account(.gitlab), b = try binding(a)
    let t = HostingFixtureTransport([response("[{\"id\":1,\"sha\":\"\(sha)\",\"status\":\"failed\"},{\"id\":2,\"sha\":\"old\",\"status\":\"success\"}]")])
    let checks = try await HostingAPIClient(http: http(t)).checks(b, sha: sha, account: a, token: HostingToken(accessToken: "fixture"))
    XCTAssertEqual(checks.count, 1); XCTAssertEqual(checks[0].state, .failed)
  }
  func testRemoteDiffDataIsReadOnlyAndMissingPatchIsExplicit() async throws {
    let a = try account(), b = try binding(a), t = HostingFixtureTransport([response("[{\"filename\":\"file.swift\",\"status\":\"modified\",\"patch\":\"@@ -1 +1 @@\\n-old\\n+new\"},{\"filename\":\"image.png\",\"status\":\"added\"}]")])
    let files = try await HostingAPIClient(http: http(t)).files(b, number: 7, account: a, token: HostingToken(accessToken: "fixture"))
    XCTAssertEqual(files.items.count, 2); XCTAssertNotNil(files.items[0].patch); XCTAssertNil(files.items[1].patch)
    let requests = await t.captured(); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    XCTAssertEqual(DiffParser.parse(Data(files.items[0].patch!.utf8)).additions, 1)
  }
  func testMalformedSuccessfulReviewResponsesDoNotBecomeEmptyNormalData() async throws {
    let a = try account(), b = try binding(a), t = HostingFixtureTransport([response("{}"), response("{}"), response("{}")])
    let api = HostingAPIClient(http: http(t)), token = HostingToken(accessToken: "fixture")
    await expect(.invalidResponse) { _ = try await api.commits(b, number: 7, account: a, token: token) }
    await expect(.invalidResponse) { _ = try await api.files(b, number: 7, account: a, token: token) }
    await expect(.invalidResponse) { _ = try await api.reviews(b, number: 7, account: a, token: token) }
  }
  func testCachePartitionsStableAccountsAndClearsRevokedData() async throws {
    let cache = HostingAPICache(), a = try account(), b = try account(user: "43"), binding = try binding(a)
    let page = HostingPage<HostingPullRequest>(items: [], nextPage: 2)
    await cache.put(page, account: a, binding: binding, filter: .open, page: 1)
    let own = await cache.get(account: a, binding: binding, filter: .open, page: 1), other = await cache.get(account: b, binding: binding, filter: .open, page: 1)
    XCTAssertNotNil(own); XCTAssertNil(other)
    await cache.clear(account: a); let cleared = await cache.get(account: a, binding: binding, filter: .open, page: 1); XCTAssertNil(cleared)
  }
  func creationTransport(postFailure: Bool = false) -> HostingFixtureTransport {
    let branch = response("{\"commit\":{\"sha\":\"\(sha)\"}}"), repo = response("{\"id\":12}"), empty = response("[]"), created = response(pr(.github))
    return HostingFixtureTransport(handler: { request in
      if request.httpMethod == "POST" { if postFailure { throw HostingError.networkFailure }; return created }
      if request.url!.path.contains("/branches/") { return branch }
      if request.url!.path.hasSuffix("/pulls") { return empty }; return repo
    })
  }
  func testCreationRequiresScopesPushedSHAAndNoGitOperation() async throws {
    let a = try account(), b = try binding(a), api = HostingAPIClient(http: http(creationTransport()))
    let d = HostingCreateDraft(sourceRepository: "owner/repo", source: "feature", target: "main", title: "Fixture")
    await expect(.permissionRequired) { _ = try await api.prepareCreation(b, draft: d, localHead: sha, localBranch: "feature", operationInProgress: false, account: a, token: HostingToken(accessToken: "fixture")) }
    let token = HostingToken(accessToken: "fixture", scopes: ["public_repo"])
    await expect(.operationInProgress) { _ = try await api.prepareCreation(b, draft: d, localHead: sha, localBranch: "feature", operationInProgress: true, account: a, token: token) }
    await expect(.pushRequired) { _ = try await api.prepareCreation(b, draft: d, localHead: "other", localBranch: "feature", operationInProgress: false, account: a, token: token) }
  }
  func testCreationReviewIsReadOnlyAndPOSTOccursOnlyAfterConfirmation() async throws {
    let a = try account(), b = try binding(a), t = creationTransport(), api = HostingAPIClient(http: http(t)), token = HostingToken(accessToken: "fixture", scopes: ["public_repo"])
    let d = HostingCreateDraft(sourceRepository: "owner/repo", source: "feature", target: "main", title: "Fixture")
    let review = try await api.prepareCreation(b, draft: d, localHead: sha, localBranch: "feature", operationInProgress: false, account: a, token: token)
    let before = await t.captured(); XCTAssertTrue(before.allSatisfy { $0.httpMethod == "GET" })
    let result = try await api.create(review, localHead: sha, localBranch: "feature", operationInProgress: false, account: a, token: token)
    XCTAssertEqual(result.number, 7); let after = await t.captured(); XCTAssertEqual(after.filter { $0.httpMethod == "POST" }.count, 1)
  }
  func testCreationUnknownDoesNotBlindlyRetryPOST() async throws {
    let a = try account(), b = try binding(a), t = creationTransport(postFailure: true), api = HostingAPIClient(http: http(t)), token = HostingToken(accessToken: "fixture", scopes: ["public_repo"])
    let d = HostingCreateDraft(sourceRepository: "owner/repo", source: "feature", target: "main", title: "Fixture")
    let review = try await api.prepareCreation(b, draft: d, localHead: sha, localBranch: "feature", operationInProgress: false, account: a, token: token)
    await expect(.creationUnknown) { _ = try await api.create(review, localHead: sha, localBranch: "feature", operationInProgress: false, account: a, token: token) }
    let requests = await t.captured(); XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
  }
  func testCreationRejectsExistingOpenPRBeforePosting() async throws {
    let a = try account(), b = try binding(a), branch = response("{\"commit\":{\"sha\":\"\(sha)\"}}"), repo = response("{\"id\":12}"), duplicate = response("[" + pr(.github) + "]")
    let t = HostingFixtureTransport(handler: { r in r.url!.path.contains("/branches/") ? branch : r.url!.path.hasSuffix("/pulls") ? duplicate : repo })
    let api = HostingAPIClient(http: http(t)), token = HostingToken(accessToken: "fixture", scopes: ["public_repo"])
    await expect(.duplicateRequest) { _ = try await api.prepareCreation(b, draft: HostingCreateDraft(sourceRepository: "owner/repo", source: "feature", target: "main", title: "Fixture"), localHead: sha, localBranch: "feature", operationInProgress: false, account: a, token: token) }
    let requests = await t.captured(); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
  }
  func testLoopbackDynamicPortRejectsWrongStateAcceptsOnceAndCloses() async throws {
    let listener = OAuthLoopbackListener(); let port = try await listener.start()
    let redirect = URL(string: "http://127.0.0.1:\(port)/oauth/gitea/callback")!
    let session = try OAuthPKCESession(configuration: config(.gitea), redirectURL: redirect)
    try await listener.configure(session)
    let urlSession = URLSession(configuration: .ephemeral); defer { urlSession.invalidateAndCancel() }
    let (_, wrong) = try await urlSession.data(from: URL(string: redirect.absoluteString + "?state=wrong&code=fixture")!)
    XCTAssertEqual((wrong as? HTTPURLResponse)?.statusCode, 400)
    async let callback = listener.callback()
    let (_, good) = try await urlSession.data(from: URL(string: redirect.absoluteString + "?state=\(session.state)&code=fixture")!)
    XCTAssertEqual((good as? HTTPURLResponse)?.statusCode, 200)
    let received = try await callback; XCTAssertTrue(received.absoluteString.contains("code=fixture"))
    do { _ = try await urlSession.data(from: redirect); XCTFail("Listener should close") } catch {}
    await listener.cancel()
  }
  func testLoopbackCancellationClosesWaitingSession() async throws {
    let listener = OAuthLoopbackListener(); _ = try await listener.start(); await listener.cancel()
    do { _ = try await listener.callback(); XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
  }
  func testGiteaFilesUseBoundedDiffEndpointAndNeverTrustContentsURL() async throws {
    let a = try account(.gitea), b = try binding(a)
    let t = HostingFixtureTransport([response("[{\"filename\":\"file.swift\",\"status\":\"modified\",\"contents_url\":\"https://attacker.invalid\"}]"),
      response("diff --git a/other b/other\n--- a/other\n+++ b/other\n@@ -1 +1 @@\n-x\n+y\ndiff --git a/file.swift b/file.swift\n--- a/file.swift\n+++ b/file.swift\n@@ -1 +1 @@\n-old\n+new\n")])
    let api = HostingAPIClient(http: http(t)), token = HostingToken(accessToken: "fixture")
    let files = try await api.files(b, number: 7, account: a, token: token)
    let patch = try await api.giteaPatch(b, number: 7, file: files.items[0], account: a, token: token)
    XCTAssertTrue(patch?.contains("-old") == true); XCTAssertFalse(patch?.contains("a/other") == true)
    let requests = await t.captured(); XCTAssertEqual(requests.last?.url?.path, "/api/v1/repos/owner/repo/pulls/7.diff")
    XCTAssertTrue(requests.allSatisfy { $0.url?.host == a.instance.baseURL.host })
  }
  func testGiteaReviewCommentsUseReviewSpecificEndpoint() async throws {
    let a = try account(.gitea), b = try binding(a), t = HostingFixtureTransport([response("[{\"id\":3,\"user\":{\"login\":\"bob\"},\"body\":\"Review\",\"path\":\"file.swift\",\"position\":4}]")])
    let reviews = try await HostingAPIClient(http: http(t)).giteaReviewComments(b, number: 7, reviewID: "9", account: a, token: HostingToken(accessToken: "fixture"))
    XCTAssertEqual(reviews[0].path, "file.swift"); XCTAssertEqual(reviews[0].line, "4")
    let requests = await t.captured(); XCTAssertEqual(requests[0].url?.path, "/api/v1/repos/owner/repo/pulls/7/reviews/9/comments")
  }
  func testCIPaginationLoadsLaterFailureBeforeShowingSuccess() async throws {
    let a = try account(), b = try binding(a)
    let t = HostingFixtureTransport([response("{\"sha\":\"\(sha)\",\"statuses\":[]}"),
      response("{\"check_runs\":[{\"name\":\"first\",\"head_sha\":\"\(sha)\",\"conclusion\":\"success\"}]}", headers: ["link": "<https://attacker.invalid>; rel=\"next\""]),
      response("{\"check_runs\":[{\"name\":\"second\",\"head_sha\":\"\(sha)\",\"conclusion\":\"failure\"}]}", headers: ["link": ""])])
    let checks = try await HostingAPIClient(http: http(t)).checks(b, sha: sha, account: a, token: HostingToken(accessToken: "fixture"))
    XCTAssertEqual(checks.map(\.state), [.success, .failed])
    let requests = await t.captured(); XCTAssertTrue(requests.last?.url?.query?.contains("page=2") == true); XCTAssertEqual(requests.last?.url?.host, "api.github.com")
  }
  func testGiteaConversationAndHasMorePaginationAreProviderSpecific() async throws {
    let a = try account(.gitea), b = try binding(a), t = HostingFixtureTransport([response("[]", headers: ["x-hasmore": "true"])])
    let page = try await HostingAPIClient(http: http(t)).reviews(b, number: 7, account: a, token: HostingToken(accessToken: "fixture"), comments: true)
    XCTAssertEqual(page.nextPage, 2); let requests = await t.captured(); XCTAssertEqual(requests[0].url?.path, "/api/v1/repos/owner/repo/issues/7/comments")
  }
  func testGitLabApprovalStateDoesNotTreatNoRequiredRulesAsHumanApproval() async throws {
    let a = try account(.gitlab), b = try binding(a)
    let t = HostingFixtureTransport([response("{\"approved\":true,\"approved_by\":[]}"), response("{\"approved\":true,\"approved_by\":[{\"user\":{\"id\":8,\"username\":\"bob\"}}]}")])
    let api = HostingAPIClient(http: http(t)), token = HostingToken(accessToken: "fixture")
    let none = try await api.reviews(b, number: 7, account: a, token: token)
    let approved = try await api.reviews(b, number: 7, account: a, token: token)
    XCTAssertTrue(none.items.isEmpty); XCTAssertEqual(approved.items[0].state, "APPROVED"); XCTAssertEqual(approved.items[0].author, "bob")
    let requests = await t.captured(); XCTAssertTrue(requests[0].url!.path.hasSuffix("/merge_requests/7/approvals"))
  }
  func testExchangeRequiresValidatedCallbackAndMatchingAuthorizationCode() async throws {
    let t = HostingFixtureTransport(), c = OAuthAuthorizationCoordinator(http: http(t))
    var s = try OAuthPKCESession(configuration: config(.gitlab), redirectURL: URL(string: "gitpier://oauth/gitlab")!)
    await expect(.invalidCallback) { _ = try await c.exchange(session: s, code: "fixture", scopes: []) }
    _ = try s.consume(URL(string: "gitpier://oauth/gitlab?state=\(s.state)&code=fixture")!)
    await expect(.invalidCallback) { _ = try await c.exchange(session: s, code: "wrong-code", scopes: []) }
    let requests = await t.captured(); XCTAssertTrue(requests.isEmpty)
  }
  func testSelectedSourceBranchReadDoesNotSwitchHEADOrChangeIndex() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-hosting-branch-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let git = GitService(root: root)
    await git.configure(gitPath: "/usr/bin/git", authEnvironment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
    _ = try await git.perform(["init", "-b", "main"])
    _ = try await git.perform(["config", "user.name", "Hosting Fixture"])
    _ = try await git.perform(["config", "user.email", "fixture@example.invalid"])
    try Data("fixture\n".utf8).write(to: root.appendingPathComponent("fixture.txt"))
    _ = try await git.perform(["add", "--", "fixture.txt"])
    _ = try await git.perform(["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "fixture"])
    _ = try await git.perform(["branch", "feature/source"])
    let before = try await git.status(localOnly: true)
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    let selected = try await git.hostingCreationState(sourceBranch: "feature/source")
    XCTAssertEqual(selected.branch, "feature/source"); XCTAssertEqual(selected.head, before.head)
    let after = try await git.status(localOnly: true); XCTAssertEqual(after.branch, "main")
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    await expect(.branchMissing) { _ = try await git.hostingCreationState(sourceBranch: "not-a-local-branch") }
  }
  func testGitLabForkCreationTargetsSourceProjectWithExplicitTargetID() async throws {
    let a = try account(.gitlab), b = try binding(a), sourceSHA = sha, created = response(pr(.gitlab)), empty = response("[]")
    let t = HostingFixtureTransport(handler: { request in
      if request.httpMethod == "POST" { return created }
      if request.url!.path.contains("/repository/branches/") { return HostingHTTPResponse(data: Data("{\"commit\":{\"id\":\"\(sourceSHA)\"}}".utf8)) }
      if request.url!.path.hasSuffix("/merge_requests") { return empty }
      return HostingHTTPResponse(data: Data((request.url!.absoluteString.contains("fork") ? "{\"id\":13}" : "{\"id\":12}").utf8))
    })
    let api = HostingAPIClient(http: http(t)), token = HostingToken(accessToken: "fixture", scopes: ["api"])
    let d = HostingCreateDraft(sourceRepository: "alice/fork", source: "feature", target: "main", title: "Fixture", draft: true)
    let review = try await api.prepareCreation(b, draft: d, localHead: sha, localBranch: "feature", operationInProgress: false, account: a, token: token)
    _ = try await api.create(review, localHead: sha, localBranch: "feature", operationInProgress: false, account: a, token: token)
    let requests = await t.captured(), post = try XCTUnwrap(requests.first { $0.httpMethod == "POST" })
    XCTAssertTrue(post.url!.absoluteString.contains("projects/alice%2Ffork/merge_requests"))
    let body = try HostingJSON.decode(post.httpBody!); XCTAssertEqual(body["target_project_id"].int, 12); XCTAssertEqual(body["title"].string, "Draft: Fixture")
  }
  func testGiteaCreationUsesForkHeadAndRejectsUnsupportedDraftFlag() async throws {
    let a = try account(.gitea), b = try binding(a), sourceSHA = sha, created = response(pr(.gitea)), empty = response("[]")
    let t = HostingFixtureTransport(handler: { request in
      if request.httpMethod == "POST" { return created }
      if request.url!.path.contains("/branches/") { return HostingHTTPResponse(data: Data("{\"commit\":{\"sha\":\"\(sourceSHA)\"}}".utf8)) }
      if request.url!.path.hasSuffix("/pulls") { return empty }; return HostingHTTPResponse(data: Data("{\"id\":12}".utf8))
    })
    let api = HostingAPIClient(http: http(t)), token = HostingToken(accessToken: "fixture", scopes: ["write:repository"])
    var d = HostingCreateDraft(sourceRepository: "alice/fork", source: "feature", target: "main", title: "Fixture", draft: true)
    await expect(.unsupported) { _ = try await api.prepareCreation(b, draft: d, localHead: sha, localBranch: "feature", operationInProgress: false, account: a, token: token) }
    d.draft = false
    let review = try await api.prepareCreation(b, draft: d, localHead: sha, localBranch: "feature", operationInProgress: false, account: a, token: token)
    _ = try await api.create(review, localHead: sha, localBranch: "feature", operationInProgress: false, account: a, token: token)
    let requests = await t.captured(), post = try XCTUnwrap(requests.first { $0.httpMethod == "POST" })
    let body = try HostingJSON.decode(post.httpBody!); XCTAssertEqual(body["head"].string, "alice:feature"); XCTAssertEqual(body["draft"].string, "")
  }
  func testFinalLocalRevalidationCanPreventCreationAfterNetworkChecks() async throws {
    let a = try account(), b = try binding(a), t = creationTransport(), api = HostingAPIClient(http: http(t)), token = HostingToken(accessToken: "fixture", scopes: ["public_repo"])
    let review = try await api.prepareCreation(b, draft: HostingCreateDraft(sourceRepository: "owner/repo", source: "feature", target: "main", title: "Fixture"), localHead: sha, localBranch: "feature", operationInProgress: false, account: a, token: token)
    await expect(.accountChanged) { _ = try await api.create(review, localHead: sha, localBranch: "feature", operationInProgress: false, account: a, token: token) { throw HostingError.accountChanged } }
    let requests = await t.captured(); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
  }
  func testDisconnectDuringRefreshCannotResurrectToken() async throws {
    let vault = HostingFixtureVault(), a = try account(.gitlab)
    let t = HostingFixtureTransport(handler: { _ in try await Task.sleep(for: .milliseconds(50)); return HostingHTTPResponse(data: Data("{\"access_token\":\"late\",\"refresh_token\":\"late-refresh\"}".utf8)) })
    let manager = OAuthTokenManager(vault: vault, oauth: OAuthAuthorizationCoordinator(http: http(t)))
    try await manager.install(HostingToken(accessToken: "old", refreshToken: "old-refresh", expiresAt: .distantPast), account: a)
    let task = Task { try await manager.token(for: a) }
    while await t.captured().isEmpty { await Task.yield() }
    try await manager.forget(a)
    do { _ = try await task.value; XCTFail("Late refresh must not succeed") } catch {}
    await expect(.accountChanged) { _ = try await manager.token(for: a) }
    let saved = try await vault.read(account: a); XCTAssertNil(saved)
  }
}
