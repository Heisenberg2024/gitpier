import XCTest
@testable import GitPierCore

@MainActor final class HostingCallbackTests: XCTestCase {
  private let terminalBody = "Authorization failed. Return to GitPier for details."
  private func fixture() async throws -> (OAuthLoopbackListener, OAuthPKCESession) {
    let listener = OAuthLoopbackListener(), port = try await listener.start()
    let instance = try HostingInstance(provider: .gitea, url: "https://callback-fixture.invalid")
    let configuration = OAuthConfiguration(instance: instance, clientID: "synthetic-callback-client", redirect: .loopback(port: 0))
    let session = try OAuthPKCESession(configuration: configuration, redirectURL: URL(string: "http://127.0.0.1:\(port)/oauth/gitea/callback")!)
    try await listener.configure(session)
    return (listener, session)
  }
  private func url(_ session: OAuthPKCESession, _ items: [URLQueryItem]) -> URL {
    var components = URLComponents(url: session.redirectURL, resolvingAgainstBaseURL: false)!
    components.queryItems = items; return components.url!
  }
  private func errorURL(_ session: OAuthPKCESession, code: String, description: String? = nil, state: String? = nil) -> URL {
    var items = [URLQueryItem(name: "state", value: state ?? session.state), URLQueryItem(name: "error", value: code)]
    if let description { items.append(URLQueryItem(name: "error_description", value: description)) }
    return url(session, items)
  }
  private func send(_ url: URL) async throws -> (Int, String) {
    let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForRequest = 2
    let client = URLSession(configuration: configuration); defer { client.invalidateAndCancel() }
    let (data, response) = try await client.data(from: url)
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
  }
  private func flow(_ listener: OAuthLoopbackListener, session: OAuthPKCESession, transport: HostingFixtureTransport) async throws -> HostingToken {
    let callback = try await listener.callback()
    var candidate = session
    let code = try candidate.consume(callback)
    return try await OAuthAuthorizationCoordinator(http: HostingHTTPClient(transport: transport)).exchange(session: candidate, code: code, scopes: [])
  }
  private func expectTerminal(_ expected: HostingError, listener: OAuthLoopbackListener, task: Task<HostingToken, Error>, file: StaticString = #filePath, line: UInt = #line) async {
    // A regression fails within two seconds instead of leaving a real TCP listener pending for
    // its five-minute authorization deadline. Correct provider errors are already completed.
    let timeout = Task { try? await Task.sleep(for: .seconds(2)); if !Task.isCancelled { await listener.cancel() } }
    defer { timeout.cancel() }
    do { _ = try await task.value; XCTFail("Expected terminal provider error", file: file, line: line) }
    catch { XCTAssertEqual(error as? HostingError, expected, file: file, line: line) }
  }

  func testLoopbackServerAndTemporaryErrorsTerminateWithPrivateFixedResponse() async throws {
    for errorCode in ["server_error", "temporarily_unavailable"] {
      let (listener, session) = try await fixture(), transport = HostingFixtureTransport()
      let task = Task { try await flow(listener, session: session, transport: transport) }
      let response = try await send(errorURL(session, code: errorCode, description: "synthetic-private-provider-marker"))
      XCTAssertEqual(response.0, 400); XCTAssertTrue(response.1 == terminalBody)
      XCTAssertFalse(response.1.contains(session.state)); XCTAssertFalse(response.1.contains("synthetic-private-provider-marker"))
      await expectTerminal(.serverFailure, listener: listener, task: task)
      let requests = await transport.captured(); XCTAssertTrue(requests.isEmpty)
    }
  }

  func testLoopbackUnknownProviderErrorTerminatesWithoutTokenExchange() async throws {
    let (listener, session) = try await fixture(), transport = HostingFixtureTransport()
    let task = Task { try await flow(listener, session: session, transport: transport) }
    let response = try await send(errorURL(session, code: "unrecognized_provider_error", description: "synthetic-private-marker"))
    XCTAssertEqual(response.0, 400); XCTAssertTrue(response.1 == terminalBody)
    await expectTerminal(.invalidResponse, listener: listener, task: task)
    let requests = await transport.captured(); XCTAssertTrue(requests.isEmpty)
  }

  func testLoopbackInvalidScopeTerminatesAndPreservesExistingSession() async throws {
    let (listener, session) = try await fixture(), transport = HostingFixtureTransport(), vault = HostingFixtureVault()
    let account = HostingAccount(instance: session.configuration.instance, user: HostingUser(stableID: "callback-user", login: "fixture"), kind: .oauth, scopes: ["read:repository"], oauth: session.configuration)
    let manager = OAuthTokenManager(vault: vault), original = HostingToken(accessToken: "synthetic-existing-session")
    try await manager.install(original, account: account)
    let task = Task { try await flow(listener, session: session, transport: transport) }
    let response = try await send(errorURL(session, code: "invalid_scope"))
    XCTAssertEqual(response.0, 400); XCTAssertTrue(response.1 == terminalBody)
    await expectTerminal(.permissionRequired, listener: listener, task: task)
    let retained = try await manager.token(for: account), persisted = try await vault.read(account: account), requests = await transport.captured()
    XCTAssertEqual(retained, original); XCTAssertEqual(persisted, original); XCTAssertTrue(requests.isEmpty)
  }

  func testLoopbackWrongStateAndMalformedErrorsKeepListeningForCorrectCode() async throws {
    let (listener, session) = try await fixture()
    let callback = Task { try await listener.callback() }
    let wrong = try await send(errorURL(session, code: "server_error", state: "wrong-state")); XCTAssertEqual(wrong.0, 400)
    XCTAssertFalse(wrong.1 == terminalBody)
    let malformed = [
      [URLQueryItem(name: "state", value: session.state), URLQueryItem(name: "error", value: "server_error"), URLQueryItem(name: "error", value: "access_denied")],
      [URLQueryItem(name: "state", value: session.state), URLQueryItem(name: "error", value: "server_error"), URLQueryItem(name: "code", value: "synthetic-code")],
      [URLQueryItem(name: "state", value: session.state), URLQueryItem(name: "error", value: "")],
      [URLQueryItem(name: "state", value: session.state), URLQueryItem(name: "state", value: session.state), URLQueryItem(name: "error", value: "server_error")]
    ]
    for items in malformed {
      let response = try await send(url(session, items)); XCTAssertEqual(response.0, 400); XCTAssertFalse(response.1 == terminalBody)
    }
    let correct = url(session, [URLQueryItem(name: "state", value: session.state), URLQueryItem(name: "code", value: "synthetic-correct-code")])
    let response = try await send(correct); XCTAssertEqual(response.0, 200)
    let received = try await callback.value; XCTAssertTrue(received == correct)
    await listener.cancel()
  }

  func testLoopbackScopeConflictTerminatesAndFreshRetryUsesNewState() async throws {
    let (listener, session) = try await fixture(), transport = HostingFixtureTransport()
    let task = Task { try await flow(listener, session: session, transport: transport) }
    let response = try await send(errorURL(session, code: "server_error", description: "  A grant exists  with different scope \n"))
    XCTAssertEqual(response.0, 400); XCTAssertTrue(response.1 == terminalBody)
    await expectTerminal(.scopeConflict, listener: listener, task: task)
    let (retry, fresh) = try await fixture()
    XCTAssertNotEqual(fresh.state, session.state)
    let callback = Task { try await retry.callback() }
    let stale = try await send(errorURL(fresh, code: "server_error", description: "a grant exists with different scope", state: session.state))
    XCTAssertEqual(stale.0, 400); XCTAssertFalse(stale.1 == terminalBody)
    let correct = url(fresh, [URLQueryItem(name: "state", value: fresh.state), URLQueryItem(name: "code", value: "synthetic-fresh-code")])
    let success = try await send(correct); XCTAssertEqual(success.0, 200)
    let received = try await callback.value; XCTAssertTrue(received == correct)
    let requests = await transport.captured(); XCTAssertTrue(requests.isEmpty)
    await retry.cancel()
  }

  func testScopeConflictMappingRequiresGiteaServerErrorAndExactNormalizedDescription() {
    let description = "a grant exists with different scope"
    XCTAssertEqual(OAuthAuthorizationCoordinator.oauthError("server_error", provider: .gitea, description: description), .scopeConflict)
    for provider in [HostingProvider.github, .gitlab] {
      XCTAssertEqual(OAuthAuthorizationCoordinator.oauthError("server_error", provider: provider, description: description), .serverFailure)
    }
    for other in [description + " extra", "prefix " + description, "different scope", ""] {
      XCTAssertEqual(OAuthAuthorizationCoordinator.oauthError("server_error", provider: .gitea, description: other), .serverFailure)
    }
    XCTAssertEqual(OAuthAuthorizationCoordinator.oauthError("invalid_scope", provider: .gitea, description: description), .permissionRequired)
    XCTAssertTrue(HostingError.scopeConflict.localizedDescription.contains("will not revoke"))
  }

  private func formConflictURL(_ session: OAuthPKCESession, state: String? = nil) -> URL {
    URL(string: session.redirectURL.absoluteString + "?state=\(state ?? session.state)&error=server_error&error_description=a+grant+exists+with+different+scope")!
  }

  func testFormEncodedGiteaConflictConsumesOnlyMatchingSession() async throws {
    let (listener, original) = try await fixture(); await listener.cancel()
    var session = original
    XCTAssertThrowsError(try session.consume(formConflictURL(session, state: "wrong+state"))) {
      XCTAssertEqual($0 as? HostingError, .invalidCallback)
    }
    XCTAssertFalse(session.callbackConsumed)
    XCTAssertThrowsError(try session.consume(formConflictURL(session))) {
      XCTAssertEqual($0 as? HostingError, .scopeConflict)
    }
    XCTAssertTrue(session.callbackConsumed)
    XCTAssertThrowsError(try session.consume(formConflictURL(session))) {
      XCTAssertEqual($0 as? HostingError, .invalidCallback)
    }
    XCTAssertEqual(OAuthAuthorizationCoordinator.oauthError("server_error", provider: .gitlab,
      description: "a+grant+exists+with+different+scope"), .serverFailure)
    XCTAssertEqual(OAuthAuthorizationCoordinator.oauthError("server_error", provider: .gitea,
      description: "a+grant+exists+with+different+scope+extra"), .serverFailure)
    let gitlab = try HostingInstance(provider: .gitlab, url: "https://callback-fixture.invalid")
    var success = try OAuthPKCESession(configuration: OAuthConfiguration(instance: gitlab, clientID: "synthetic-client"), redirectURL: URL(string: "gitpier://oauth/gitlab")!)
    XCTAssertEqual(try success.consume(URL(string: "gitpier://oauth/gitlab?state=\(success.state)&code=synthetic+literal%2Bcode")!), "synthetic+literal+code")
  }

  func testLoopbackFormEncodedConflictTerminatesWithoutExposingCallbackOrExchangingToken() async throws {
    let (listener, session) = try await fixture(), transport = HostingFixtureTransport()
    let task = Task { try await flow(listener, session: session, transport: transport) }
    let rejected = try await send(formConflictURL(session, state: "wrong-state"))
    XCTAssertEqual(rejected.0, 400); XCTAssertFalse(rejected.1 == terminalBody)
    let response = try await send(formConflictURL(session))
    XCTAssertEqual(response.0, 400); XCTAssertEqual(response.1, terminalBody)
    XCTAssertFalse(response.1.contains(session.state)); XCTAssertFalse(response.1.contains("grant"))
    await expectTerminal(.scopeConflict, listener: listener, task: task)
    let requests = await transport.captured(); XCTAssertTrue(requests.isEmpty)
  }

  func testBrowserFormEncodedConflictIsTerminalAndCannotConsumeFreshReceiver() async throws {
    let (listener, session) = try await fixture(); await listener.cancel()
    let receiver = OAuthBrowserCallback(session: session)
    let wrong = await receiver.receive(formConflictURL(session, state: "wrong-state")); XCTAssertFalse(wrong)
    let accepted = await receiver.receive(formConflictURL(session)); XCTAssertTrue(accepted)
    do { _ = try await receiver.wait(); XCTFail("Expected scope conflict") }
    catch { XCTAssertEqual(error as? HostingError, .scopeConflict) }
    let duplicate = await receiver.receive(formConflictURL(session)); XCTAssertFalse(duplicate)
    let fresh = try OAuthPKCESession(configuration: session.configuration, redirectURL: session.redirectURL)
    let retry = OAuthBrowserCallback(session: fresh)
    let old = await retry.receive(formConflictURL(session)); XCTAssertFalse(old)
    let correct = url(fresh, [URLQueryItem(name: "state", value: fresh.state), URLQueryItem(name: "code", value: "synthetic-fresh-code")])
    let good = await retry.receive(correct); XCTAssertTrue(good)
    let received = try await retry.wait(); XCTAssertEqual(received, correct)
  }

  func testBrowserReceiverTerminatesProviderErrorsButIgnoresWrongStateAndMalformedErrors() async throws {
    let instance = try HostingInstance(provider: .gitlab, url: "https://callback-fixture.invalid")
    for (code, expected) in [("server_error", HostingError.serverFailure), ("temporarily_unavailable", .serverFailure), ("invalid_scope", .permissionRequired), ("unknown_error", .invalidResponse)] {
      let session = try OAuthPKCESession(configuration: OAuthConfiguration(instance: instance, clientID: "synthetic-client"), redirectURL: URL(string: "gitpier://oauth/gitlab")!)
      let receiver = OAuthBrowserCallback(session: session)
      let rejected = await receiver.receive(errorURL(session, code: code, state: "wrong")); XCTAssertFalse(rejected)
      let malformed = url(session, [URLQueryItem(name: "state", value: session.state), URLQueryItem(name: "error", value: code), URLQueryItem(name: "code", value: "synthetic-code")])
      let malformedAccepted = await receiver.receive(malformed); XCTAssertFalse(malformedAccepted)
      let accepted = await receiver.receive(errorURL(session, code: code)); XCTAssertTrue(accepted)
      do { _ = try await receiver.wait(); XCTFail("Expected provider error") }
      catch { XCTAssertEqual(error as? HostingError, expected) }
      let duplicate = await receiver.receive(errorURL(session, code: code)); XCTAssertFalse(duplicate)
    }
  }

  func testBrowserScopeConflictFinishesOnlyItsReceiverAndFreshSessionCanSucceed() async throws {
    let (listener, session) = try await fixture(); await listener.cancel()
    let receiver = OAuthBrowserCallback(session: session)
    let accepted = await receiver.receive(errorURL(session, code: "server_error", description: "a grant exists with different scope")); XCTAssertTrue(accepted)
    do { _ = try await receiver.wait(); XCTFail("Expected scope conflict") }
    catch { XCTAssertEqual(error as? HostingError, .scopeConflict) }
    let fresh = try OAuthPKCESession(configuration: session.configuration, redirectURL: session.redirectURL)
    let retry = OAuthBrowserCallback(session: fresh)
    let old = await retry.receive(errorURL(fresh, code: "server_error", state: session.state)); XCTAssertFalse(old)
    let correct = url(fresh, [URLQueryItem(name: "state", value: fresh.state), URLQueryItem(name: "code", value: "synthetic-fresh-code")])
    let good = await retry.receive(correct); XCTAssertTrue(good)
    let received = try await retry.wait(); XCTAssertTrue(received == correct)
  }
}
