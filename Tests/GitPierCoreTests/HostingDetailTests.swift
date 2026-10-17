import XCTest
@testable import GitPierCore

private actor HostingDetailGate {
  private var held: Set<String> = []
  private var continuations: [String: [CheckedContinuation<Void, Never>]] = [:]
  func hold(_ path: String) { held.insert(path) }
  func wait(_ path: String) async { if held.contains(path) { await withCheckedContinuation { continuations[path, default: []].append($0) } } }
  func release(_ path: String) { held.remove(path); for value in continuations.removeValue(forKey: path) ?? [] { value.resume() } }
}

@MainActor final class HostingDetailTests: XCTestCase {
  let sha = String(repeating: "a", count: 40)
  func account(_ provider: HostingProvider = .github, id: UUID = UUID()) throws -> HostingAccount {
    HostingAccount(id: id, instance: try HostingInstance(provider: provider, url: provider == .github ? "https://github.com" : "https://forge.example.invalid"), user: HostingUser(stableID: "42", login: "fixture"), kind: .pat, scopes: [])
  }
  func binding(_ account: HostingAccount) throws -> RepositoryHostingBinding { try RepositoryHostingBinding(repositoryID: UUID(), accountID: account.id, remote: "origin", repository: "owner/repo") }
  func pull(_ number: Int = 1) -> HostingPullRequest {
    HostingPullRequest(number: number, title: "Fixture \(number)", body: "Immediate overview", author: "fixture", state: "open", draft: false, source: "topic", target: "main", sourceRepository: "owner/repo", sha: sha, webURL: nil, createdAt: "", updatedAt: "revision", reviewers: [])
  }
  func pullJSON(_ number: Int = 1, sha: String? = nil, updated: String = "revision") -> String { "{\"number\":\(number),\"title\":\"Fixture \(number)\",\"body\":\"Fetched overview\",\"state\":\"open\",\"updated_at\":\"\(updated)\",\"head\":{\"sha\":\"\(sha ?? self.sha)\",\"ref\":\"topic\"},\"base\":{\"ref\":\"main\"}}" }
  func response(_ json: String = "[]", status: Int = 200, headers: [String: String] = [:]) -> HostingHTTPResponse { HostingHTTPResponse(data: Data(json.utf8), status: status, headers: headers) }
  func loader(_ transport: HostingFixtureTransport, account: HostingAccount? = nil, request: HostingPullRequest? = nil,
    cache: HostingRequestDetailCache = HostingRequestDetailCache()) throws -> HostingRequestDetailLoader {
    let account = try account ?? self.account()
    return HostingRequestDetailLoader(request: request ?? pull(), binding: try binding(account), account: account,
      api: HostingAPIClient(http: HostingHTTPClient(transport: transport, sleep: { _ in try Task.checkCancellation() })), cache: cache,
      token: { HostingToken(accessToken: "fixture-only") })
  }
  func eventually(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
    XCTAssertTrue(condition(), file: file, line: line)
  }
  func eventuallyRequests(_ transport: HostingFixtureTransport, suffix: String, count: Int,
    file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = Date().addingTimeInterval(3)
    while await transport.captured().filter({ $0.url!.path.hasSuffix(suffix) }).count < count, Date() < deadline {
      try? await Task.sleep(for: .milliseconds(2))
    }
    let captured = await transport.captured().filter { $0.url!.path.hasSuffix(suffix) }
    XCTAssertGreaterThanOrEqual(captured.count, count, file: file, line: line)
  }
  func testOverviewStartsNoUnselectedModules() async throws {
    let transport = HostingFixtureTransport([response(pullJSON())]), value = try loader(transport)
    XCTAssertEqual(value.detail.body, "Immediate overview")
    value.select(.overview); await eventually { value.state(.overview).loaded }
    let paths = await transport.captured().map { $0.url!.path }
    XCTAssertEqual(paths, ["/repos/owner/repo/pulls/1"])
    XCTAssertTrue(value.commits.isEmpty); XCTAssertTrue(value.files.isEmpty); XCTAssertTrue(value.reviews.isEmpty); XCTAssertTrue(value.checks.isEmpty)
  }
  func testSlowOverviewDoesNotBlockSelectedFiles() async throws {
    let gate = HostingDetailGate(); await gate.hold("overview")
    let json = pullJSON()
    let transport = HostingFixtureTransport(handler: { request in
      if request.url!.path.hasSuffix("/files") { return HostingHTTPResponse(data: Data("[{\"filename\":\"A.swift\",\"patch\":\"@@ -1 +1 @@\\n-a\\n+b\"}]".utf8)) }
      await gate.wait("overview"); return HostingHTTPResponse(data: Data(json.utf8))
    })
    let value = try loader(transport); value.select(.files)
    await eventually { value.state(.files).loaded }
    XCTAssertTrue(value.state(.overview).loading); XCTAssertEqual(value.detail.body, "Immediate overview"); XCTAssertEqual(value.files.count, 1)
    await gate.release("overview"); await eventually { value.state(.overview).loaded }
  }
  func testSlowCommitModuleDoesNotBlockOverviewOrOtherTabs() async throws {
    let gate = HostingDetailGate(); await gate.hold("commits"); let json = pullJSON()
    let transport = HostingFixtureTransport(handler: { request in
      if request.url!.path.hasSuffix("/commits") { await gate.wait("commits"); return HostingHTTPResponse(data: Data("[{\"sha\":\"late\",\"commit\":{\"message\":\"late\"}}]".utf8)) }
      return HostingHTTPResponse(data: Data((request.url!.path.hasSuffix("/files") ? "[]" : json).utf8))
    })
    let value = try loader(transport); value.select(.commits); await eventually { value.state(.overview).loaded }
    XCTAssertTrue(value.state(.commits).loading)
    value.select(.files); await eventually { value.state(.files).loaded }; await gate.release("commits")
    try await Task.sleep(for: .milliseconds(20)); XCTAssertTrue(value.commits.isEmpty); XCTAssertFalse(value.state(.commits).loaded)
  }
  func testReviewFailuresAreIsolatedAndConversationStillLoads() async throws {
    let json = pullJSON()
    let transport = HostingFixtureTransport(handler: { request in
      let path = request.url!.path
      if path.hasSuffix("/reviews") { return HostingHTTPResponse(data: Data(), status: 404) }
      if path.contains("/issues/") { return HostingHTTPResponse(data: Data("[{\"id\":1,\"body\":\"Conversation\"}]".utf8)) }
      return HostingHTTPResponse(data: Data((path.hasSuffix("/1") ? json : "[]").utf8))
    })
    let value = try loader(transport); value.select(.reviews)
    await eventually { value.state(.reviews).error != nil && value.state(.comments).loaded && value.state(.conversations).loaded }
    XCTAssertEqual(value.state(.reviews).error, .notFound); XCTAssertEqual(value.conversations.first?.body, "Conversation")
    value.select(.commits); await eventually { value.state(.commits).loaded }
    value.select(.files); await eventually { value.state(.files).loaded }
    XCTAssertNil(value.state(.files).error); XCTAssertNil(value.state(.commits).error)
  }
  func testModuleErrors403404429And5xxRemainSpecificAndRetryable() async throws {
    for (status, expected) in [(403, HostingError.permissionRequired), (404, .notFound), (429, .rateLimited), (503, .serverFailure)] {
      let json = pullJSON()
      let transport = HostingFixtureTransport(handler: { request in HostingHTTPResponse(data: Data((request.url!.path.hasSuffix("/commits") ? "[]" : json).utf8), status: request.url!.path.hasSuffix("/commits") ? status : 200) })
      let value = try loader(transport); value.select(.commits)
      await eventually { value.state(.commits).error != nil && value.state(.overview).loaded }
      XCTAssertEqual(value.state(.commits).error, expected); XCTAssertFalse(value.state(.commits).loaded)
      let captured = await transport.captured(); XCTAssertEqual(captured.filter { $0.url!.path.hasSuffix("/commits") }.count, status >= 500 || status == 429 ? 3 : 1)
    }
  }
  func testFailedPageRetryKeepsAlreadyLoadedItems() async throws {
    let json = pullJSON()
    actor Attempts { var page2 = 0; func status() -> Int { page2 += 1; return page2 == 1 ? 403 : 200 } }
    let attempts = Attempts()
    let transport = HostingFixtureTransport(handler: { request in
      guard request.url!.path.hasSuffix("/commits") else { return HostingHTTPResponse(data: Data(json.utf8)) }
      if request.url!.query!.contains("page=2") { return HostingHTTPResponse(data: Data("[{\"sha\":\"two\",\"commit\":{\"message\":\"second\"}}]".utf8), status: await attempts.status()) }
      return HostingHTTPResponse(data: Data("[{\"sha\":\"one\",\"commit\":{\"message\":\"first\"}}]".utf8), headers: ["link": "<https://ignored.invalid>; rel=\"next\""])
    })
    let value = try loader(transport); value.select(.commits); await eventually { value.state(.commits).loaded }
    value.loadMore(.commits); await eventually { value.state(.commits).error == .permissionRequired }
    XCTAssertEqual(value.commits.map(\.id), ["one"]); XCTAssertEqual(value.nextPages[.commits], 2)
    value.retry(.commits); await eventually { value.commits.count == 2 }
    XCTAssertNil(value.state(.commits).error); XCTAssertNil(value.nextPages[.commits])
  }
  func testHugePRFetchesOnlyExplicitPagesAndDeduplicates() async throws {
    let json = pullJSON(), rows = (0..<50).map { "{\"filename\":\"file-\($0).swift\"}" }.joined(separator: ",")
    let transport = HostingFixtureTransport(handler: { request in
      HostingHTTPResponse(data: Data((request.url!.path.hasSuffix("/files") ? "[" + rows + "]" : json).utf8), headers: request.url!.path.hasSuffix("/files") ? ["link": "<https://ignored.invalid>; rel=\"next\""] : [:])
    })
    let value = try loader(transport); value.select(.files); await eventually { value.state(.files).loaded }
    XCTAssertEqual(value.files.count, 50); XCTAssertEqual(value.nextPages[.files], 2)
    var requests = await transport.captured(); XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("/files") }.count, 1)
    value.loadMore(.files); await eventually { !value.state(.files).loading }
    XCTAssertEqual(value.files.count, 50); XCTAssertEqual(value.nextPages[.files], 3)
    requests = await transport.captured(); XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("/files") }.count, 2)
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
  }
  func testCIPermissionFailureAfterEmptyStatusesDoesNotCompleteAsNoChecks() async throws {
    let json = pullJSON(), sha = sha
    let transport = HostingFixtureTransport(handler: { request in
      if request.url!.path.hasSuffix("/check-runs") { return HostingHTTPResponse(data: Data(), status: 403) }
      return HostingHTTPResponse(data: Data((request.url!.path.hasSuffix("/status") ? "{\"sha\":\"\(sha)\",\"statuses\":[]}" : json).utf8))
    })
    let value = try loader(transport); value.select(.checks); await eventually { value.state(.checks).error != nil }
    XCTAssertTrue(value.state(.checks).loaded); XCTAssertTrue(value.checks.isEmpty)
    XCTAssertEqual(value.state(.checks).error, .permissionRequired); XCTAssertNotNil(value.nextChecks)
  }
  func testFirstCISelectionAutomaticallyLoadsOnlyFirstChecksPageAfterEmptyStatuses() async throws {
    let json = pullJSON(), sha = sha
    let transport = HostingFixtureTransport(handler: { request in
      let path = request.url!.path
      if path.hasSuffix("/status") { return HostingHTTPResponse(data: Data("{\"sha\":\"\(sha)\",\"statuses\":[]}".utf8)) }
      if path.hasSuffix("/check-runs") {
        let second = request.url!.query!.contains("page=2")
        let body = "{\"total_count\":101,\"check_runs\":[{\"id\":\(second ? 102 : 101),\"name\":\"Build \(second ? 2 : 1)\",\"head_sha\":\"\(sha)\",\"status\":\"in_progress\"}]}"
        return HostingHTTPResponse(data: Data(body.utf8), headers: second ? [:] : ["link": "<https://ignored.invalid>; rel=\"next\""])
      }
      return HostingHTTPResponse(data: Data(json.utf8))
    })
    let value = try loader(transport); value.select(.overview); await eventually { value.state(.overview).loaded }
    var requests = await transport.captured(); XCTAssertEqual(requests.count, 1)
    value.select(.checks); await eventually { value.checks.count == 1 && !value.state(.checks).loading }
    XCTAssertEqual(value.checks.first?.name, "Build 1"); XCTAssertEqual(value.nextChecks, HostingChecksCursor(source: .checkRuns, page: 2))
    requests = await transport.captured()
    XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("/status") }.count, 1)
    XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("/check-runs") }.count, 1)
    XCTAssertFalse(requests.contains { $0.url!.query?.contains("page=2") == true })
    value.select(.overview); value.select(.checks)
    requests = await transport.captured(); XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("/check-runs") }.count, 1)
    value.loadMore(.checks); await eventually { value.checks.count == 2 && !value.state(.checks).loading }
    XCTAssertNil(value.nextChecks)
  }
  func testClearingCacheDuringAutomaticChecksCancelsWithoutStartingAnotherRequest() async throws {
    let json = pullJSON(), sha = sha, account = try account(), cache = HostingRequestDetailCache(), gate = HostingDetailGate()
    await gate.hold("checks")
    let transport = HostingFixtureTransport(handler: { request in
      let path = request.url!.path
      if path.hasSuffix("/status") { return HostingHTTPResponse(data: Data("{\"sha\":\"\(sha)\",\"statuses\":[]}".utf8)) }
      if path.hasSuffix("/check-runs") {
        await gate.wait("checks")
        return HostingHTTPResponse(data: Data("{\"check_runs\":[{\"id\":101,\"name\":\"Build\",\"head_sha\":\"\(sha)\",\"status\":\"in_progress\"}]}".utf8))
      }
      return HostingHTTPResponse(data: Data(json.utf8))
    })
    let value = try loader(transport, account: account, cache: cache)
    value.select(.overview); await eventually { value.state(.overview).loaded }
    value.select(.checks); await eventuallyRequests(transport, suffix: "/check-runs", count: 1)
    await cache.clear(account: account); await gate.release("checks")
    await eventually { !value.state(.checks).loading }; try await Task.sleep(for: .milliseconds(30))
    var requests = await transport.captured()
    XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("/check-runs") }.count, 1)
    XCTAssertTrue(value.checks.isEmpty); XCTAssertNil(value.state(.checks).error)
    XCTAssertEqual(value.nextChecks, HostingChecksCursor(source: .checkRuns))
    value.select(.checks); await eventually { value.checks.count == 1 && !value.state(.checks).loading }
    requests = await transport.captured()
    XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("/check-runs") }.count, 2)
    XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("/status") }.count, 1)
  }
  func testSlowAutomaticChecksTabSwitchRestoresFirstPageAndRejectsOldResponse() async throws {
    let json = pullJSON(), sha = sha, gate = HostingDetailGate()
    await gate.hold("old-checks")
    actor Attempts {
      var value = 0, cancelled = false
      func next() -> Int { value += 1; return value }
      func markCancelled() { cancelled = true }
      func observedCancellation() -> Bool { cancelled }
    }
    let attempts = Attempts()
    let transport = HostingFixtureTransport(handler: { request in
      let path = request.url!.path
      if path.hasSuffix("/status") { return HostingHTTPResponse(data: Data("{\"sha\":\"\(sha)\",\"statuses\":[]}".utf8)) }
      if path.hasSuffix("/check-runs") {
        let old = await attempts.next() == 1
        if old {
          await withTaskCancellationHandler { await gate.wait("old-checks") }
            onCancel: { Task { await attempts.markCancelled() } }
        }
        return HostingHTTPResponse(data: Data("{\"check_runs\":[{\"id\":\(old ? 101 : 102),\"name\":\"\(old ? "Stale" : "Replacement") check\",\"head_sha\":\"\(sha)\",\"status\":\"in_progress\"}]}".utf8))
      }
      return HostingHTTPResponse(data: Data(json.utf8))
    })
    let value = try loader(transport); value.select(.checks)
    await eventuallyRequests(transport, suffix: "/check-runs", count: 1)
    value.select(.overview)
    let cancellationDeadline = Date().addingTimeInterval(3)
    while !(await attempts.observedCancellation()), Date() < cancellationDeadline { await Task.yield() }
    let cancelled = await attempts.observedCancellation(); XCTAssertTrue(cancelled)
    // Observe transport cancellation before returning, so this proves restoration after
    // cancellation rather than assuming when the cache's reader-removal task runs.
    value.select(.checks)
    await eventuallyRequests(transport, suffix: "/check-runs", count: 2)
    await eventually { value.checks.first?.name == "Replacement check" && !value.state(.checks).loading }
    await gate.release("old-checks"); try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(value.checks.map(\.name), ["Replacement check"])
    let requests = await transport.captured()
    XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("/status") }.count, 1)
    XCTAssertTrue(requests.filter { $0.url!.path.hasSuffix("/check-runs") }.allSatisfy { $0.url!.query?.contains("page=1") == true })
  }
  func testAutomaticChecks403WaitsForExplicitRetryOfSameFirstPage() async throws {
    let json = pullJSON(), sha = sha
    actor Attempts { var value = 0; func next() -> Int { value += 1; return value } }
    let attempts = Attempts()
    let transport = HostingFixtureTransport(handler: { request in
      let path = request.url!.path
      if path.hasSuffix("/status") { return HostingHTTPResponse(data: Data("{\"sha\":\"\(sha)\",\"statuses\":[]}".utf8)) }
      if path.hasSuffix("/check-runs") {
        if await attempts.next() == 1 { return HostingHTTPResponse(data: Data(), status: 403) }
        return HostingHTTPResponse(data: Data("{\"check_runs\":[{\"id\":101,\"name\":\"Build\",\"head_sha\":\"\(sha)\",\"status\":\"in_progress\"}]}".utf8))
      }
      return HostingHTTPResponse(data: Data(json.utf8))
    })
    let value = try loader(transport); value.select(.checks)
    await eventually { value.state(.checks).error == .permissionRequired && !value.state(.checks).loading }
    try await Task.sleep(for: .milliseconds(30))
    var requests = await transport.captured(); XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("/check-runs") }.count, 1)
    value.retry(.checks); await eventually { value.checks.count == 1 && !value.state(.checks).loading }
    XCTAssertNil(value.state(.checks).error); XCTAssertNil(value.nextChecks)
    requests = await transport.captured()
    XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("/status") }.count, 1)
    XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("/check-runs") }.count, 2)
    XCTAssertTrue(requests.filter { $0.url!.path.hasSuffix("/check-runs") }.allSatisfy { $0.url!.query?.contains("page=1") == true })
  }
  func testCIPaginationIsExplicitAndSHAIsBound() async throws {
    let json = pullJSON(), sha = sha
    let transport = HostingFixtureTransport(handler: { request in
      let path = request.url!.path
      if path.hasSuffix("/status") { return HostingHTTPResponse(data: Data("{\"sha\":\"\(sha)\",\"statuses\":[{\"context\":\"test\",\"state\":\"success\"}]}".utf8)) }
      if path.hasSuffix("/check-runs") { return HostingHTTPResponse(data: Data("{\"total_count\":1,\"check_runs\":[{\"name\":\"CI\",\"head_sha\":\"\(sha)\",\"status\":\"in_progress\"}]}".utf8)) }
      return HostingHTTPResponse(data: Data(json.utf8))
    })
    let value = try loader(transport); value.select(.checks); await eventually { value.state(.checks).loaded }
    XCTAssertEqual(value.checks.count, 1); XCTAssertEqual(value.nextChecks?.source, .checkRuns)
    value.loadMore(.checks); await eventually { value.checks.count == 2 }
    XCTAssertNil(value.nextChecks); XCTAssertEqual(value.checks.last?.state, .running)
  }
  func testCacheAcrossTabAndRequestReopenAvoidsRedundantRequests() async throws {
    let json = pullJSON(), account = try account(), cache = HostingRequestDetailCache()
    let transport = HostingFixtureTransport(handler: { request in HostingHTTPResponse(data: Data((request.url!.path.hasSuffix("/1") ? json : "[]").utf8)) })
    let first = try loader(transport, account: account, cache: cache); first.select(.commits)
    await eventually { first.state(.overview).loaded && first.state(.commits).loaded }
    first.select(.files); await eventually { first.state(.files).loaded }; first.select(.commits)
    let second = try loader(transport, account: account, cache: cache); second.select(.commits)
    await eventually { second.state(.overview).loaded && second.state(.commits).loaded }
    let paths = await transport.captured().map { $0.url!.path }; XCTAssertEqual(paths.count, 3)
  }
  func testAccountCacheClearCancelsAnUncooperativeOldRequest() async throws {
    let gate = HostingDetailGate(); await gate.hold("all"); let json = pullJSON(), account = try account(), cache = HostingRequestDetailCache()
    let transport = HostingFixtureTransport(handler: { request in await gate.wait("all"); return HostingHTTPResponse(data: Data((request.url!.path.hasSuffix("/commits") ? "[]" : json).utf8)) })
    let value = try loader(transport, account: account, cache: cache); value.select(.commits)
    while await transport.captured().count < 2 { await Task.yield() }
    await cache.clear(account: account); value.cancelAll(); await gate.release("all")
    try await Task.sleep(for: .milliseconds(20)); XCTAssertFalse(value.state(.overview).loaded); XCTAssertFalse(value.state(.commits).loaded)
  }
  func testQuickPRSwitchCannotPublishThePreviousRequest() async throws {
    let gate = HostingDetailGate(); await gate.hold("old"); let old = pullJSON(1), new = pullJSON(2)
    let transport = HostingFixtureTransport(handler: { request in
      if request.url!.path.hasSuffix("/1") { await gate.wait("old"); return HostingHTTPResponse(data: Data(old.utf8)) }
      return HostingHTTPResponse(data: Data(new.utf8))
    })
    let first = try loader(transport); first.select(.overview); first.cancelAll()
    let second = try loader(transport, request: pull(2)); second.select(.overview); await eventually { second.state(.overview).loaded }
    await gate.release("old"); try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(second.detail.number, 2); XCTAssertFalse(first.state(.overview).loaded)
  }
  func testOverviewRevisionChangeInvalidatesInFlightModule() async throws {
    let gate = HostingDetailGate(); await gate.hold("overview"); let json = pullJSON(1, sha: String(repeating: "b", count: 40), updated: "new")
    let transport = HostingFixtureTransport(handler: { request in
      if request.url!.path.hasSuffix("/1") { await gate.wait("overview"); return HostingHTTPResponse(data: Data(json.utf8)) }
      return HostingHTTPResponse(data: Data("[]".utf8))
    })
    let value = try loader(transport); value.select(.files); await eventually { value.state(.files).loaded }
    await gate.release("overview"); await eventually { value.detail.sha == String(repeating: "b", count: 40) && value.state(.files).loaded }
    let files = await transport.captured().filter { $0.url!.path.hasSuffix("/files") }; XCTAssertEqual(files.count, 2)
  }
  func testCancellationAndRetryStartsAReplacementModuleTask() async throws {
    let gate = HostingDetailGate(); await gate.hold("commits"); let json = pullJSON()
    let transport = HostingFixtureTransport(handler: { request in
      if request.url!.path.hasSuffix("/commits") { await gate.wait("commits"); return HostingHTTPResponse(data: Data("[]".utf8)) }
      return HostingHTTPResponse(data: Data(json.utf8))
    })
    let value = try loader(transport); value.select(.commits); await eventually { value.state(.overview).loaded }
    value.select(.overview); await gate.release("commits")
    try await Task.sleep(for: .milliseconds(20)); value.select(.commits); await eventually { value.state(.commits).loaded }
    XCTAssertNil(value.state(.commits).error)
  }
  func testSimultaneousReadersShareOneFlightAndOneCancellationKeepsTheOther() async throws {
    let cache = HostingRequestDetailCache(), account = try account(), gate = HostingDetailGate()
    await gate.hold("flight")
    let key = HostingRequestDetailCache.Key(account: account, binding: try binding(account), request: pull(), section: .files, page: "1")
    actor Count { var value = 0; func add() { value += 1 }; func get() -> Int { value } }
    let count = Count()
    let operation: @Sendable () async throws -> HostingDetailValue = { await count.add(); await gate.wait("flight"); return .files(HostingPage(items: [], nextPage: nil)) }
    let first = Task { try await cache.value(for: key, load: operation) }
    let second = Task { try await cache.value(for: key, load: operation) }
    while await count.get() == 0 { await Task.yield() }
    // Let both readers register before cancelling only the first.
    try await Task.sleep(for: .milliseconds(10)); first.cancel(); await gate.release("flight")
    _ = try await second.value
    do { _ = try await first.value; XCTFail("Cancelled reader completed") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error") }
    let requests = await count.get(); XCTAssertEqual(requests, 1)
  }
  func testExpiredCacheAndDifferentAccountsNeverReusePrivatePages() async throws {
    let cache = HostingRequestDetailCache(lifetime: -1), account = try account(), other = try self.account()
    let first = HostingRequestDetailCache.Key(account: account, binding: try binding(account), request: pull(), section: .files, page: "1")
    let second = HostingRequestDetailCache.Key(account: other, binding: try binding(other), request: pull(), section: .files, page: "1")
    actor Count { var value = 0; func add() { value += 1 }; func get() -> Int { value } }
    let count = Count()
    let operation: @Sendable () async throws -> HostingDetailValue = { await count.add(); return .files(HostingPage(items: [], nextPage: nil)) }
    _ = try await cache.value(for: first, load: operation); _ = try await cache.value(for: first, load: operation)
    _ = try await cache.value(for: second, load: operation)
    let requests = await count.get(); XCTAssertEqual(requests, 3)
  }
}
