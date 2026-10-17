import XCTest
@testable import GitPierCore

/// Offline provider contracts. Every credential, response and write below belongs to an injected transport.
/// These tests do not authorize a real account or create a request on a hosting platform.
@MainActor final class HostingCompatibilityTests: XCTestCase {
  private let sha = String(repeating: "a", count: 40)
  private let changedSHA = String(repeating: "b", count: 40)

  private func account(_ provider: HostingProvider, kind: HostingAuthenticationKind = .oauth) throws -> HostingAccount {
    let url = provider == .github ? "https://github.com" : "https://forge.example.invalid"
    return HostingAccount(instance: try HostingInstance(provider: provider, url: url),
      user: HostingUser(stableID: "42", login: "alice"), kind: kind, scopes: [], storageMode: .localVault)
  }
  private func binding(_ account: HostingAccount) throws -> RepositoryHostingBinding {
    try RepositoryHostingBinding(repositoryID: UUID(), accountID: account.id, remote: "upstream", repository: "owner/repo")
  }
  private func response(_ json: String = "[]", status: Int = 200, headers: [String: String] = [:]) -> HostingHTTPResponse {
    HostingHTTPResponse(data: Data(json.utf8), status: status, headers: headers)
  }
  private func client(_ transport: any HostingTransport) -> HostingAPIClient {
    HostingAPIClient(http: HostingHTTPClient(transport: transport, sleep: { _ in try Task.checkCancellation() }))
  }
  private func token(_ provider: HostingProvider, kind: HostingAuthenticationKind = .oauth) -> HostingToken {
    HostingToken(accessToken: "fixture-compatibility-only", tokenType: provider == .gitea && kind == .pat ? "token" : "bearer",
      scopes: provider == .github ? ["public_repo"] : provider == .gitlab ? ["api"] : ["write:repository"])
  }
  private func expect(_ expected: HostingError, _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
    catch { XCTAssertEqual(error as? HostingError, expected, file: file, line: line) }
  }
  private func pull(_ provider: HostingProvider, number: Int = 7, state: String = "open", draft: Bool = false, merged: Bool = false,
    sourceRepository: String = "alice/fork", source: String = "feature") -> String {
    if provider == .gitlab {
      return "{\"iid\":\(number),\"title\":\"Fixture\",\"state\":\"\(state)\",\"draft\":\(draft),\"source_branch\":\"feature\",\"target_branch\":\"main\",\"source_project_id\":13,\"sha\":\"\(sha)\",\"author\":{\"username\":\"alice\"}}"
    }
    let mergeDate = merged ? "\"2026-01-01T00:00:00Z\"" : "null"
    return "{\"number\":\(number),\"title\":\"Fixture\",\"state\":\"\(state)\",\"draft\":\(draft),\"merged\":\(merged),\"merged_at\":\(mergeDate),\"head\":{\"ref\":\"\(source)\",\"sha\":\"\(sha)\",\"repo\":{\"full_name\":\"\(sourceRepository)\"}},\"base\":{\"ref\":\"main\"},\"user\":{\"login\":\"alice\"}}"
  }

  func testOAuthAndPATUseProviderHeadersOnCurrentUserRequests() async throws {
    for provider in HostingProvider.allCases {
      for kind in [HostingAuthenticationKind.oauth, .pat] {
        let account = try account(provider, kind: kind)
        let transport = HostingFixtureTransport([response("{\"id\":42,\"login\":\"alice\",\"username\":\"alice\"}")])
        let user = try await client(transport).user(instance: account.instance, token: token(provider, kind: kind))
        XCTAssertEqual(user.stableID, "42")
        let requests = await transport.captured(), request = try XCTUnwrap(requests.first)
        let prefix = provider == .gitea && kind == .pat ? "token " : "Bearer "
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), prefix + "fixture-compatibility-only")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, provider == .github ? "api.github.com" : "forge.example.invalid")
        XCTAssertNil(request.url?.query)
      }
    }
  }

  func testPrivateRepositoryForbiddenAndHiddenRemainDistinctErrorsForEveryProvider() async throws {
    for provider in HostingProvider.allCases {
      let account = try account(provider), binding = try binding(account)
      for (status, error) in [(403, HostingError.permissionRequired), (404, .notFound)] {
        let transport = HostingFixtureTransport([response("{\"message\":\"private repository fixture\"}", status: status)])
        await expect(error) { try await self.client(transport).validateRepository(binding, account: account, token: self.token(provider)) }
        let requests = await transport.captured()
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
      }
    }
  }

  func testClosedMergedAndDraftFiltersPreserveProviderSemantics() async throws {
    for provider in HostingProvider.allCases {
      let account = try account(provider), binding = try binding(account)
      let open = provider == .gitlab ? "opened" : "open"
      let merged = provider == .gitlab ? "merged" : "closed"
      let json = "[" + pull(provider, number: 1, state: open, draft: true) + ","
        + pull(provider, number: 2, state: "closed") + "," + pull(provider, number: 3, state: merged, merged: true) + "]"
      for (filter, expectedNumber) in [(HostingRequestFilter.draft, 1), (.closed, 2), (.merged, 3)] {
        let transport = HostingFixtureTransport([response(json)])
        let page = try await client(transport).requests(binding, account: account, token: token(provider), filter: filter)
        XCTAssertEqual(page.items.map(\.number), [expectedNumber], "\(provider): \(filter)")
        let requests = await transport.captured(), request = try XCTUnwrap(requests.first)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let expectedState = filter == .draft ? open : filter == .merged && provider == .gitlab ? "merged" : "closed"
        XCTAssertEqual(query.first { $0.name == "state" }?.value, expectedState)
      }
    }
  }

  func testUnsupportedReviewEndpointLeavesCommitsAndFilesReadableForEveryProvider() async throws {
    for provider in HostingProvider.allCases {
      let account = try account(provider), binding = try binding(account)
      let commit = provider == .gitlab ? "{\"id\":\"\(sha)\",\"message\":\"Fixture commit\"}" : "{\"sha\":\"\(sha)\",\"commit\":{\"message\":\"Fixture commit\"}}"
      let file = provider == .gitlab ? "{\"new_path\":\"file.swift\",\"old_path\":\"file.swift\",\"diff\":\"@@ -1 +1 @@\\n-old\\n+new\"}" : "{\"filename\":\"file.swift\",\"status\":\"modified\",\"patch\":\"@@ -1 +1 @@\\n-old\\n+new\"}"
      let transport = HostingFixtureTransport([response(status: 404), response("[" + commit + "]"), response("[" + file + "]")])
      let api = client(transport)
      await expect(.notFound) { _ = try await api.reviews(binding, number: 7, account: account, token: self.token(provider)) }
      let commits = try await api.commits(binding, number: 7, account: account, token: token(provider))
      let files = try await api.files(binding, number: 7, account: account, token: token(provider))
      XCTAssertEqual(commits.items.map(\.id), [sha]); XCTAssertEqual(files.items.map(\.path), ["file.swift"])
      let requests = await transport.captured(); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }
  }

  func testCIForbiddenAndHiddenAreNeverReportedAsNoChecksOnAnyProvider() async throws {
    for provider in HostingProvider.allCases {
      let account = try account(provider), binding = try binding(account)
      for (status, error) in [(403, HostingError.permissionRequired), (404, .notFound)] {
        let transport = HostingFixtureTransport([response(status: status)])
        await expect(error) { _ = try await self.client(transport).checks(binding, sha: self.sha, account: account, token: self.token(provider)) }
      }
    }
  }

  func testCIRateLimitAndServerFailureRemainErrorsAfterBoundedRetries() async throws {
    for provider in HostingProvider.allCases {
      let account = try account(provider), binding = try binding(account)
      for (status, error) in [(429, HostingError.rateLimited), (503, .serverFailure)] {
        let transport = HostingFixtureTransport(Array(repeating: response(status: status), count: 3))
        await expect(error) { _ = try await self.client(transport).checks(binding, sha: self.sha, account: account, token: self.token(provider)) }
        let requests = await transport.captured(); XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
      }
    }
  }

  func testCIEmptySuccessIsAnExplicitValidResponseForEveryProvider() async throws {
    for provider in HostingProvider.allCases {
      let account = try account(provider), binding = try binding(account)
      var responses = provider == .gitlab ? [response()] : [response(provider == .gitea
        ? "{\"sha\":\"\(sha)\",\"total_count\":0,\"state\":\"pending\",\"statuses\":null}" : "{\"sha\":\"\(sha)\",\"statuses\":[]}")]
      if provider == .github { responses.append(response("{\"check_runs\":[]}")) }
      let transport = HostingFixtureTransport(responses)
      let checks = try await client(transport).checks(binding, sha: sha, account: account, token: token(provider))
      XCTAssertTrue(checks.isEmpty)
      let requests = await transport.captured(); XCTAssertEqual(requests.count, provider == .github ? 2 : 1)
    }
  }

  func testCIPaginationUsesProviderPageControlsAndIncludesLaterFailure() async throws {
    for provider in HostingProvider.allCases {
      let account = try account(provider), binding = try binding(account)
      let headers = provider == .gitlab ? ["x-next-page": "2"] : provider == .gitea ? ["x-hasmore": "true"] : ["link": "<https://foreign.invalid/ignored>; rel=\"next\""]
      let statusKey = provider == .gitea ? "status" : "state"
      let first = provider == .gitlab ? "[{\"id\":1,\"sha\":\"\(sha)\",\"status\":\"success\"}]" : "{\"sha\":\"\(sha)\",\"total_count\":2,\"statuses\":[{\"context\":\"first\",\"\(statusKey)\":\"success\"}]}"
      let last = provider == .gitlab ? "[{\"id\":2,\"sha\":\"\(sha)\",\"status\":\"failed\"}]" : "{\"sha\":\"\(sha)\",\"total_count\":2,\"statuses\":[{\"context\":\"last\",\"\(statusKey)\":\"failure\"}]}"
      var responses = [response(first, headers: headers), response(last)]
      if provider == .github { responses.append(response("{\"check_runs\":[]}")) }
      let transport = HostingFixtureTransport(responses)
      let checks = try await client(transport).checks(binding, sha: sha, account: account, token: token(provider))
      XCTAssertEqual(checks.map(\.state), [.success, .failed])
      let requests = await transport.captured()
      for (index, request) in requests.prefix(2).enumerated() {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "page" }?.value, String(index + 1))
        XCTAssertEqual(query.first { $0.name == (provider == .gitea ? "limit" : "per_page") }?.value, "100")
        XCTAssertEqual(request.url?.host, provider == .github ? "api.github.com" : "forge.example.invalid")
      }
    }
  }

  func testGiteaNullStatusesRequireExplicitNumericZeroCorrectSHAAndTerminalPage() async throws {
    let account = try account(.gitea), binding = try binding(account)
    let valid = "{\"sha\":\"\(sha)\",\"total_count\":0,\"statuses\":null}"
    let transport = HostingFixtureTransport([response(valid)])
    let page = try await client(transport).checksPage(binding, sha: sha, account: account, token: token(.gitea))
    XCTAssertTrue(page.items.isEmpty); XCTAssertNil(page.next)
    let invalidBodies = [
      "{\"sha\":\"\(sha)\",\"total_count\":0}",
      "{\"sha\":\"\(sha)\",\"statuses\":null}",
      "{\"sha\":\"\(changedSHA)\",\"total_count\":0,\"statuses\":null}",
      "{\"total_count\":0,\"statuses\":null}",
      "{\"sha\":\"\(sha)\",\"total_count\":1,\"statuses\":null}",
      "{\"sha\":\"\(sha)\",\"total_count\":-1,\"statuses\":null}",
      "{\"sha\":\"\(sha)\",\"total_count\":\"0\",\"statuses\":null}",
      "{\"sha\":\"\(sha)\",\"total_count\":false,\"statuses\":null}",
      "{\"sha\":\"\(sha)\",\"total_count\":null,\"statuses\":null}",
      "{\"sha\":\"\(sha)\",\"total_count\":0,\"statuses\":{}}"]
    for json in invalidBodies {
      let rejected = HostingFixtureTransport([response(json)])
      await expect(.invalidResponse) { _ = try await self.client(rejected).checks(binding, sha: self.sha, account: account, token: self.token(.gitea)) }
    }
    for headers in [["x-hasmore": "true"], ["x-next-page": "2"], ["link": "<https://ignored.invalid>; rel=\"next\""]] {
      let rejected = HostingFixtureTransport([response(valid, headers: headers)])
      await expect(.invalidResponse) { _ = try await self.client(rejected).checks(binding, sha: self.sha, account: account, token: self.token(.gitea)) }
    }
    let github = try self.account(.github), githubBinding = try self.binding(github)
    let githubNull = HostingFixtureTransport([response(valid)])
    await expect(.invalidResponse) { _ = try await self.client(githubNull).checks(githubBinding, sha: self.sha, account: github, token: self.token(.github)) }

    let isolated = HostingFixtureTransport([response(invalidBodies[4]), response("[{\"sha\":\"\(sha)\",\"commit\":{\"message\":\"Fixture\"}}]"), response("[{\"filename\":\"file.swift\"}]")])
    let api = client(isolated)
    await expect(.invalidResponse) { _ = try await api.checks(binding, sha: self.sha, account: account, token: self.token(.gitea)) }
    let commits = try await api.commits(binding, number: 7, account: account, token: token(.gitea))
    let files = try await api.files(binding, number: 7, account: account, token: token(.gitea))
    XCTAssertEqual(commits.items.count, 1); XCTAssertEqual(files.items.first?.path, "file.swift")
  }

  func testGiteaCIUsesStatusFieldForAllProviderStatesAcrossPages() async throws {
    let account = try account(.gitea), binding = try binding(account)
    let states: [(String, HostingCIState)] = [("pending", .pending), ("success", .success), ("error", .failed), ("failure", .failed), ("warning", .unknown)]
    let rows = states.enumerated().map { "{\"context\":\"check-\($0.offset)\",\"status\":\"\($0.element.0)\"}" }.joined(separator: ",")
    let first = "{\"sha\":\"\(sha)\",\"total_count\":6,\"statuses\":[\(rows)]}"
    let last = "{\"sha\":\"\(sha)\",\"total_count\":6,\"statuses\":[{\"context\":\"last\",\"status\":\"success\"}]}"
    let transport = HostingFixtureTransport([response(first, headers: ["x-hasmore": "true"]), response(last, headers: ["x-hasmore": "false"])])
    let checks = try await client(transport).checks(binding, sha: sha, account: account, token: token(.gitea))
    XCTAssertEqual(checks.map(\.state), states.map { $0.1 } + [.success])
    let requests = await transport.captured(); XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    XCTAssertTrue(requests.last?.url?.query?.contains("page=2") == true)
    let wrongKey = HostingFixtureTransport([response("{\"sha\":\"\(sha)\",\"total_count\":1,\"statuses\":[{\"context\":\"legacy-fixture\",\"state\":\"success\"}]}")])
    let unknown = try await client(wrongKey).checks(binding, sha: sha, account: account, token: token(.gitea))
    XCTAssertEqual(unknown.first?.state, .unknown) // Never fall back to GitHub's DTO key.
  }

  func testCancellingDuringHTTPBackoffStopsFurtherRequests() async throws {
    let account = try account(.gitlab), binding = try binding(account)
    let transport = HostingFixtureTransport([response(status: 503)])
    let api = HostingAPIClient(http: HostingHTTPClient(transport: transport, sleep: { _ in throw CancellationError() }))
    do {
      _ = try await api.requests(binding, account: account, token: token(.gitlab))
      XCTFail("Cancellation must remain cancellation")
    } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    let requests = await transport.captured(); XCTAssertEqual(requests.count, 1)
  }

  func testGitHubConversationAndInlineReviewCommentsUseSeparateReadOnlyEndpoints() async throws {
    let account = try account(.github), binding = try binding(account)
    let transport = HostingFixtureTransport([
      response("[{\"id\":11,\"user\":{\"login\":\"alice\"},\"body\":\"Ordinary discussion\"}]", headers: ["link": "<https://foreign.invalid/ignored>; rel=\"next\""]),
      response("[{\"id\":12,\"user\":{\"login\":\"bob\"},\"body\":\"Inline review\",\"path\":\"file.swift\",\"line\":9}]")])
    let api = client(transport)
    let conversation = try await api.conversationComments(binding, number: 7, account: account, token: token(.github))
    let inline = try await api.reviews(binding, number: 7, account: account, token: token(.github), comments: true)
    XCTAssertEqual(conversation.items.first?.body, "Ordinary discussion"); XCTAssertEqual(conversation.nextPage, 2)
    XCTAssertEqual(inline.items.first?.path, "file.swift"); XCTAssertEqual(inline.items.first?.line, "9")
    let requests = await transport.captured()
    XCTAssertEqual(requests.map { $0.url!.path }, ["/repos/owner/repo/issues/7/comments", "/repos/owner/repo/pulls/7/comments"])
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
  }

  func testDeniedGitHubConversationDoesNotPreventInlineReviews() async throws {
    let account = try account(.github), binding = try binding(account)
    let transport = HostingFixtureTransport([response(status: 403), response("[{\"id\":12,\"body\":\"Inline review\"}]")])
    let api = client(transport)
    await expect(.permissionRequired) { _ = try await api.conversationComments(binding, number: 7, account: account, token: self.token(.github)) }
    let inline = try await api.reviews(binding, number: 7, account: account, token: token(.github), comments: true)
    XCTAssertEqual(inline.items.count, 1)
  }

  func testGiteaReviewCommentPaginationIsExplicitAndReadOnly() async throws {
    let account = try account(.gitea), binding = try binding(account)
    let transport = HostingFixtureTransport([
      response("[{\"id\":1,\"body\":\"first\",\"path\":\"a.swift\",\"position\":1}]", headers: ["x-hasmore": "true"]),
      response("[{\"id\":2,\"body\":\"last\",\"path\":\"b.swift\",\"position\":2}]", headers: ["x-hasmore": "false"])])
    let api = client(transport)
    let first = try await api.giteaReviewCommentsPage(binding, number: 7, reviewID: "5", account: account, token: token(.gitea))
    let last = try await api.giteaReviewCommentsPage(binding, number: 7, reviewID: "5", account: account, token: token(.gitea), page: try XCTUnwrap(first.nextPage))
    XCTAssertEqual(first.items.first?.body, "first"); XCTAssertEqual(last.items.first?.body, "last"); XCTAssertNil(last.nextPage)
    let requests = await transport.captured(); XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.path.hasSuffix("/pulls/7/reviews/5/comments") == true })
  }

  func testGiteaSlashBranchReadsCommitIDAndRejectsSHAOnlyResponse() async throws {
    let account = try account(.gitea), name = "gitpier-acceptance/v151-20261017"
    // Gitea's Branch contains a PayloadCommit, with id and no GitHub-style sha.
    let transport = HostingFixtureTransport([
      response("{\"name\":\"\(name)\",\"commit\":{\"id\":\"\(sha)\",\"message\":\"Fixture commit\",\"url\":\"https://forge.example.invalid/owner/repo/commit/\(sha)\",\"author\":{\"name\":\"Fixture\"}}}"),
      response("{\"id\":12}")])
    let branch = try await client(transport).branch("owner/repo", name: name, account: account, token: token(.gitea))
    XCTAssertEqual(branch.sha, sha); XCTAssertEqual(branch.projectID, "12")
    let requests = await transport.captured(), request = try XCTUnwrap(requests.first)
    XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath,
      "/api/v1/repos/owner/repo/branches/gitpier-acceptance%2Fv151-20261017")
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })

    let wrongShape = HostingFixtureTransport([response("{\"commit\":{\"sha\":\"\(sha)\"}}")])
    await expect(.branchMissing) { _ = try await self.client(wrongShape).branch("owner/repo", name: name, account: account, token: self.token(.gitea)) }
    let rejectedRequests = await wrongShape.captured(); XCTAssertEqual(rejectedRequests.count, 1)
  }

  func testGiteaIDShapedSlashBranchesRevalidateSourceAndTargetBeforePOST() async throws {
    let account = try account(.gitea), binding = try binding(account), name = "feature/review"
    let laterSHA = String(repeating: "c", count: 40)
    for moveSource in [true, false] {
      let fixture = HostingCompatibilityCreationFixture(provider: .gitea, sha: sha, created: pull(.gitea), sourceBranch: name)
      await fixture.moveTarget(to: changedSHA)
      let api = client(fixture), token = token(.gitea)
      let draft = HostingCreateDraft(sourceRepository: binding.repository, source: name, target: "main", title: "Fixture")
      let review = try await api.prepareCreation(binding, draft: draft, localHead: sha, localBranch: name,
        operationInProgress: false, account: account, token: token)
      XCTAssertEqual(review.sourceSHA, sha); XCTAssertEqual(review.targetSHA, changedSHA)
      if moveSource { await fixture.moveSource(to: laterSHA) } else { await fixture.moveTarget(to: laterSHA) }
      await expect(moveSource ? .pushRequired : .accountChanged) {
        _ = try await api.create(review, localHead: self.sha, localBranch: name, operationInProgress: false, account: account, token: token)
      }
      let requests = await fixture.captured()
      XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
      let paths = requests.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath }
      XCTAssertEqual(paths.filter { $0.hasSuffix("/branches/feature%2Freview") }.count, 2)
      XCTAssertEqual(paths.filter { $0.hasSuffix("/branches/main") }.count, 2)
    }
  }

  func testForkCreationUsesReviewedProviderBodyAndOnlyConfirmedPOST() async throws {
    for provider in HostingProvider.allCases {
      let account = try account(provider), binding = try binding(account)
      let fixture = HostingCompatibilityCreationFixture(provider: provider, sha: sha, created: pull(provider))
      let api = client(fixture), token = token(provider)
      let draft = HostingCreateDraft(sourceRepository: "alice/fork", source: "feature", target: "main", title: "Fixture", body: "Body", draft: provider != .gitea)
      let review = try await api.prepareCreation(binding, draft: draft, localHead: sha, localBranch: "feature", operationInProgress: false, account: account, token: token)
      let beforeConfirmation = await fixture.captured(); XCTAssertTrue(beforeConfirmation.allSatisfy { $0.httpMethod == "GET" })
      _ = try await api.create(review, localHead: sha, localBranch: "feature", operationInProgress: false, account: account, token: token)
      let requests = await fixture.captured(), posts = requests.filter { $0.httpMethod == "POST" }
      XCTAssertEqual(posts.count, 1)
      let post = try XCTUnwrap(posts.first), body = try HostingJSON.decode(try XCTUnwrap(post.httpBody))
      if provider == .gitlab {
        XCTAssertTrue(post.url!.absoluteString.contains("projects/alice%2Ffork/merge_requests"))
        XCTAssertEqual(body["source_branch"].string, "feature"); XCTAssertEqual(body["target_project_id"].int, 12)
        XCTAssertEqual(body["title"].string, "Draft: Fixture")
      } else {
        XCTAssertEqual(post.url?.path, account.instance.apiURL.path + "/repos/owner/repo/pulls")
        XCTAssertEqual(body["head"].string, provider == .gitea ? "alice/fork:feature" : "alice:feature"); XCTAssertEqual(body["base"].string, "main")
        if provider == .github { XCTAssertEqual(body["head_repo"].string, "fork"); XCTAssertTrue(body["draft"].bool) }
      }
    }
  }

  func testGiteaCreationPostsTheExactReviewedSourceRepositoryForEveryForkShape() async throws {
    let account = try account(.gitea), binding = try binding(account), branch = "feature/review"
    for sourceRepository in ["owner/repo", "owner/other-repo", "alice/fork"] {
      let fixture = HostingCompatibilityCreationFixture(provider: .gitea, sha: sha,
        created: pull(.gitea, sourceRepository: sourceRepository, source: branch), sourceBranch: branch, sourceRepository: sourceRepository)
      await fixture.moveTarget(to: changedSHA)
      let api = client(fixture), token = token(.gitea)
      let draft = HostingCreateDraft(sourceRepository: sourceRepository, source: branch, target: "main", title: "Fixture")
      let review = try await api.prepareCreation(binding, draft: draft, localHead: sha, localBranch: branch,
        operationInProgress: false, account: account, token: token)
      XCTAssertEqual(review.draft.sourceRepository, sourceRepository)
      XCTAssertEqual(review.sourceSHA, sha); XCTAssertEqual(review.targetSHA, changedSHA)
      let preparedRequests = await fixture.captured(); XCTAssertTrue(preparedRequests.allSatisfy { $0.httpMethod == "GET" })
      let created = try await api.create(review, localHead: sha, localBranch: branch, operationInProgress: false, account: account, token: token)
      XCTAssertEqual(created.sourceRepository, sourceRepository); XCTAssertEqual(created.source, branch); XCTAssertEqual(created.sha, review.sourceSHA)
      let requests = await fixture.captured(), posts = requests.filter { $0.httpMethod == "POST" }
      XCTAssertEqual(posts.count, 1)
      let post = try XCTUnwrap(posts.first), body = try HostingJSON.decode(try XCTUnwrap(post.httpBody))
      XCTAssertEqual(post.url?.path, "/api/v1/repos/owner/repo/pulls")
      XCTAssertEqual(body["head"].string, sourceRepository == binding.repository ? branch : sourceRepository + ":" + branch)
      XCTAssertEqual(body["base"].string, "main")
      let sourcePath = "/api/v1/repos/" + sourceRepository + "/branches/feature%2Freview"
      XCTAssertEqual(requests.filter { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath == sourcePath }.count, 2)
    }
  }

  func testGiteaRejectedExactForkHeadNeverFallsBackToOwnerOnlyOrRetriesPOST() async throws {
    let account = try account(.gitea), binding = try binding(account), branch = "feature/review", sourceRepository = "owner/other-repo"
    let fixture = HostingCompatibilityCreationFixture(provider: .gitea, sha: sha, created: pull(.gitea),
      sourceBranch: branch, sourceRepository: sourceRepository, postStatus: 404)
    let api = client(fixture), token = token(.gitea)
    let draft = HostingCreateDraft(sourceRepository: sourceRepository, source: branch, target: "main", title: "Fixture")
    let review = try await api.prepareCreation(binding, draft: draft, localHead: sha, localBranch: branch,
      operationInProgress: false, account: account, token: token)
    await expect(.notFound) { _ = try await api.create(review, localHead: self.sha, localBranch: branch, operationInProgress: false, account: account, token: token) }
    let requests = await fixture.captured(), posts = requests.filter { $0.httpMethod == "POST" }
    XCTAssertEqual(posts.count, 1)
    let body = try HostingJSON.decode(try XCTUnwrap(posts.first?.httpBody))
    XCTAssertEqual(body["head"].string, "owner/other-repo:feature/review")
  }

  func testMovingSourceAfterReviewPreventsEveryProviderFromPosting() async throws {
    for provider in HostingProvider.allCases {
      let account = try account(provider), binding = try binding(account)
      let fixture = HostingCompatibilityCreationFixture(provider: provider, sha: sha, created: pull(provider))
      let api = client(fixture), token = token(provider)
      let review = try await api.prepareCreation(binding, draft: HostingCreateDraft(sourceRepository: "alice/fork", source: "feature", target: "main", title: "Fixture"), localHead: sha, localBranch: "feature", operationInProgress: false, account: account, token: token)
      await fixture.moveSource(to: changedSHA)
      await expect(.pushRequired) { _ = try await api.create(review, localHead: self.sha, localBranch: "feature", operationInProgress: false, account: account, token: token) }
      let requests = await fixture.captured(); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }
  }

  func testMovingTargetAfterReviewPreventsEveryProviderFromPosting() async throws {
    for provider in HostingProvider.allCases {
      let account = try account(provider), binding = try binding(account)
      let fixture = HostingCompatibilityCreationFixture(provider: provider, sha: sha, created: pull(provider))
      let api = client(fixture), token = token(provider)
      let review = try await api.prepareCreation(binding, draft: HostingCreateDraft(sourceRepository: "alice/fork", source: "feature", target: "main", title: "Fixture"), localHead: sha, localBranch: "feature", operationInProgress: false, account: account, token: token)
      await fixture.moveTarget(to: changedSHA)
      await expect(.accountChanged) { _ = try await api.create(review, localHead: self.sha, localBranch: "feature", operationInProgress: false, account: account, token: token) }
      let requests = await fixture.captured(); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }
  }

  func testReconnectingUnderDifferentStableIdentityRejectsOldCreationReviewBeforeNetwork() async throws {
    for provider in HostingProvider.allCases {
      let account = try account(provider), binding = try binding(account)
      let fixture = HostingCompatibilityCreationFixture(provider: provider, sha: sha, created: pull(provider))
      let api = client(fixture), token = token(provider)
      let review = try await api.prepareCreation(binding, draft: HostingCreateDraft(sourceRepository: "alice/fork", source: "feature", target: "main", title: "Fixture"), localHead: sha, localBranch: "feature", operationInProgress: false, account: account, token: token)
      var replacement = account; replacement.user = HostingUser(stableID: "43", login: "alice")
      let before = await fixture.captured()
      await expect(.accountChanged) { _ = try await api.create(review, localHead: self.sha, localBranch: "feature", operationInProgress: false, account: replacement, token: token) }
      let after = await fixture.captured(); XCTAssertEqual(after.count, before.count)
    }
  }
}

private actor HostingCompatibilityCreationFixture: HostingTransport {
  let provider: HostingProvider
  let created: String
  let sourceBranch: String
  let sourceRepository: String
  let postStatus: Int
  var sourceSHA: String
  var targetSHA: String
  var requests: [URLRequest] = []
  init(provider: HostingProvider, sha: String, created: String, sourceBranch: String = "feature",
    sourceRepository: String = "alice/fork", postStatus: Int = 200) {
    self.provider = provider; sourceSHA = sha; targetSHA = sha; self.created = created; self.sourceBranch = sourceBranch
    self.sourceRepository = sourceRepository; self.postStatus = postStatus
  }
  func moveSource(to sha: String) { sourceSHA = sha }
  func moveTarget(to sha: String) { targetSHA = sha }
  func captured() -> [URLRequest] { requests }
  func send(_ request: URLRequest, limit: Int) throws -> HostingHTTPResponse {
    requests.append(request)
    let path = request.url!.path
    let json: String
    if request.httpMethod == "POST" { json = created }
    else if path.contains("/branches/") {
      let source = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath.hasSuffix("/branches/" + HostingInstance.component(sourceBranch)) == true
      let sha = source ? sourceSHA : targetSHA
      json = "{\"commit\":{\"\(provider == .github ? "sha" : "id")\":\"\(sha)\"}}"
    } else if path.hasSuffix("/pulls") || path.hasSuffix("/merge_requests") { json = "[]" }
    else {
      let sourcePath = provider == .gitlab ? "/projects/" + HostingInstance.component(sourceRepository) : "/repos/" + sourceRepository
      let source = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath.hasSuffix(sourcePath) == true
      json = source ? "{\"id\":13}" : "{\"id\":12}"
    }
    return HostingHTTPResponse(data: Data(json.utf8), status: request.httpMethod == "POST" ? postStatus : 200)
  }
}
