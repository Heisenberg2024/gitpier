import XCTest
@testable import GitPierCore

private actor ReviewDashboardTransport: HostingTransport {
  let response: HostingHTTPResponse
  private var requests: [URLRequest] = []
  init(_ data: Data, status: Int = 200, headers: [String: String] = [:]) {
    response = HostingHTTPResponse(data: data, status: status, headers: headers)
  }
  func send(_ request: URLRequest, limit: Int) -> HostingHTTPResponse { requests.append(request); return response }
  func captured() -> [URLRequest] { requests }
}

@MainActor final class HostingReviewDashboardTests: XCTestCase {
  private let token = HostingToken(accessToken: "synthetic-dashboard-only")
  private let sha = String(repeating: "a", count: 40)
  private func account(_ provider: HostingProvider = .github, id: UUID = UUID(), user: String = "42", url: String? = nil) throws -> HostingAccount {
    HostingAccount(id: id, instance: try HostingInstance(provider: provider, url: url ?? (provider == .github ? "https://github.com" : "https://code.example.invalid")),
      user: HostingUser(stableID: user, login: "display-name-is-not-identity"), kind: .pat, scopes: [])
  }
  private func githubRow(id: Int = 100, number: Int = 7, repository: String = "owner/repo", authorID: Int = 42) -> [String: Any] {
    ["id": id, "number": number, "title": "Synthetic PR", "state": "open", "user": ["id": authorID, "login": "display-user"],
      "repository_url": "https://api.github.com/repos/" + repository, "pull_request": ["url": "https://api.github.com/repos/\(repository)/pulls/\(number)"],
      "html_url": "https://github.com/\(repository)/pull/\(number)", "updated_at": "2026-10-18T00:00:00Z"]
  }
  private func github(_ rows: [[String: Any]], total: Int? = nil, incomplete: Bool = false) -> [String: Any] {
    ["items": rows, "total_count": total ?? rows.count, "incomplete_results": incomplete]
  }
  private func gitlabRow(authorID: Int = 42, reviewerID: Int = 42) -> [String: Any] {
    ["id": 101, "iid": 7, "project_id": 99, "title": "Synthetic MR", "state": "opened",
      "references": ["full": "group/subgroup/repo!7"], "author": ["id": authorID, "username": "display-user"],
      "reviewers": [["id": reviewerID, "username": "display-name-is-not-identity"]],
      "web_url": "https://code.example.invalid/group/subgroup/repo/-/merge_requests/7", "updated_at": "2026-10-18T00:00:00Z"]
  }
  private func client(_ transport: ReviewDashboardTransport) -> HostingAPIClient { HostingAPIClient(http: HostingHTTPClient(transport: transport)) }
  private func fixture(_ object: Any, status: Int = 200, headers: [String: String] = [:]) throws -> ReviewDashboardTransport {
    let data = try JSONSerialization.data(withJSONObject: object)
    return ReviewDashboardTransport(data, status: status, headers: headers)
  }
  private func request(source: String = "feature/topic", repository: String = "owner/repo", head: String? = nil, state: String = "open") -> HostingPullRequest {
    HostingPullRequest(number: 7, title: "Synthetic", body: "", author: "someone", state: state, draft: false, source: source,
      target: "main", sourceRepository: repository, sha: head ?? sha, webURL: nil, createdAt: "", updatedAt: "", reviewers: [])
  }

  func testGitHubQueriesAuthenticatedUserScopesWithoutRepositoryEnumeration() async throws {
    let transport = try fixture(github([githubRow()])), api = client(transport), account = try account()
    _ = try await api.reviewDashboard(account: account, token: token, kind: .requestedReviews)
    _ = try await api.reviewDashboard(account: account, token: token, kind: .myOpenRequests)
    let requests = await transport.captured(); XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.path == "/search/issues" })
    let queries = requests.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value }
    XCTAssertEqual(queries, ["is:pr state:open user-review-requested:@me", "is:pr state:open author:@me"])
    XCTAssertFalse(queries.joined().contains(account.user.login))
  }

  func testGitLabUsesServerScopeAndOneExplicitPage() async throws {
    let transport = try fixture([gitlabRow()], headers: ["x-next-page": "2"]), api = client(transport), account = try account(.gitlab)
    let page = try await api.reviewDashboard(account: account, token: token, kind: .requestedReviews)
    _ = try await api.reviewDashboard(account: account, token: token, kind: .myOpenRequests)
    XCTAssertEqual(page.nextPage, 2); XCTAssertEqual(page.items.first?.repository, "group/subgroup/repo")
    let requests = await transport.captured(); XCTAssertEqual(requests.count, 2)
    let scopes = requests.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "scope" })?.value }
    XCTAssertEqual(scopes, ["reviews_for_me", "created_by_me"])
    XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/api/v4/merge_requests" && $0.httpMethod == "GET" })
  }

  func testGiteaHasNoSpeculativeAccountSummaryCalls() async throws {
    let transport = try fixture([])
    do { _ = try await client(transport).reviewDashboard(account: account(.gitea), token: token, kind: .requestedReviews); XCTFail("Unsupported query must fail") }
    catch { XCTAssertEqual(error as? HostingError, .unsupported) }
    let requests = await transport.captured(); XCTAssertTrue(requests.isEmpty)
  }

  func testGitHubPaginationDoesNotAutomaticallyFetchFollowingPage() async throws {
    let transport = try fixture(github([githubRow()], total: 31))
    let page = try await client(transport).reviewDashboard(account: account(), token: token, kind: .myOpenRequests)
    XCTAssertEqual(page.nextPage, 2); XCTAssertEqual(page.total, 31)
    let requests = await transport.captured(); XCTAssertEqual(requests.count, 1)
  }

  func testGitHubIncompleteAndThousandResultCapRemainVisible() async throws {
    let transport = try fixture(github([githubRow()], total: 2000, incomplete: true))
    let page = try await client(transport).reviewDashboard(account: account(), token: token, kind: .myOpenRequests, page: 34)
    XCTAssertTrue(page.incomplete); XCTAssertNil(page.nextPage)
  }

  func testInvalidPageIsRejectedBeforeAnyNetworkRequest() async throws {
    let transport = try fixture(github([])), api = client(transport), account = try account()
    for number in [0, 35, 101] {
      do { _ = try await api.reviewDashboard(account: account, token: token, kind: .myOpenRequests, page: number); XCTFail("Unbounded page accepted") }
      catch { XCTAssertEqual(error as? HostingError, .responseTooLarge) }
    }
    let requests = await transport.captured(); XCTAssertTrue(requests.isEmpty)
  }

  func testDuplicateServerIDsAreNotRepeatedWithinPage() async throws {
    let transport = try fixture(github([githubRow(), githubRow()]))
    let page = try await client(transport).reviewDashboard(account: account(), token: token, kind: .myOpenRequests)
    XCTAssertEqual(page.items.count, 1)
  }

  func testSameNumberInDifferentRepositoriesRemainsDistinct() async throws {
    let transport = try fixture(github([githubRow(), githubRow(id: 200, repository: "other/repo")]))
    let page = try await client(transport).reviewDashboard(account: account(), token: token, kind: .myOpenRequests)
    XCTAssertEqual(page.items.count, 2); XCTAssertEqual(Set(page.items.map(\.id)).count, 2)
  }

  func testForeignRepositoryURLIsRejectedWithoutFollowingIt() async throws {
    var row = githubRow(); row["repository_url"] = "https://other.example.invalid/repos/owner/repo"
    let transport = try fixture(github([row]))
    do { _ = try await client(transport).reviewDashboard(account: account(), token: token, kind: .myOpenRequests); XCTFail("Foreign repository URL accepted") }
    catch { XCTAssertEqual(error as? HostingError, .invalidResponse) }
    let requests = await transport.captured(); XCTAssertEqual(requests.count, 1)
  }

  func testForeignGitLabWebURLCannotBecomeAResultLink() async throws {
    var row = gitlabRow(); row["web_url"] = "https://other.example.invalid/group/subgroup/repo/-/merge_requests/7"
    let transport = try fixture([row])
    do { _ = try await client(transport).reviewDashboard(account: account(.gitlab), token: token, kind: .myOpenRequests); XCTFail("Foreign result link accepted") }
    catch { XCTAssertEqual(error as? HostingError, .invalidResponse) }
  }

  func testMyOpenItemsRequireStableAuthorID() async throws {
    let transport = try fixture(github([githubRow(authorID: 77)]))
    do { _ = try await client(transport).reviewDashboard(account: account(), token: token, kind: .myOpenRequests); XCTFail("Another user's PR labeled mine") }
    catch { XCTAssertEqual(error as? HostingError, .invalidResponse) }
  }

  func testGitLabReviewerNameCannotSubstituteForStableID() async throws {
    let transport = try fixture([gitlabRow(reviewerID: 77)])
    do { _ = try await client(transport).reviewDashboard(account: account(.gitlab), token: token, kind: .requestedReviews); XCTFail("A matching display name was treated as reviewer identity") }
    catch { XCTAssertEqual(error as? HostingError, .invalidResponse) }
  }

  func testIssueSearchRowWithoutPullRequestIdentityIsRejected() async throws {
    var row = githubRow(); row.removeValue(forKey: "pull_request")
    let transport = try fixture(github([row]))
    do { _ = try await client(transport).reviewDashboard(account: account(), token: token, kind: .myOpenRequests); XCTFail("An issue was shown as a PR") }
    catch { XCTAssertEqual(error as? HostingError, .invalidResponse) }
  }

  func testCacheSeparatesAccountsScopesAndPages() async throws {
    let cache = HostingReviewDashboardCache(), first = try account(), other = try account()
    let page = HostingReviewDashboardPage(items: [], nextPage: nil, total: 0)
    await cache.put(page, account: first, kind: .requestedReviews, page: 1)
    let same = await cache.get(account: first, kind: .requestedReviews, page: 1)
    let otherUser = await cache.get(account: other, kind: .requestedReviews, page: 1)
    let otherScope = await cache.get(account: first, kind: .myOpenRequests, page: 1)
    let otherPage = await cache.get(account: first, kind: .requestedReviews, page: 2)
    XCTAssertNotNil(same); XCTAssertNil(otherUser); XCTAssertNil(otherScope); XCTAssertNil(otherPage)
  }

  func testCacheSeparatesInstancesEvenForSameAccountUUID() async throws {
    let cache = HostingReviewDashboardCache(), first = try account(.gitlab)
    let other = try account(.gitlab, id: first.id, url: "https://other.example.invalid")
    await cache.put(HostingReviewDashboardPage(items: [], nextPage: nil, total: 0), account: first, kind: .requestedReviews, page: 1)
    let result = await cache.get(account: other, kind: .requestedReviews, page: 1); XCTAssertNil(result)
  }

  func testExpiredCacheIsNotPresentedAsCurrentSnapshot() async throws {
    let cache = HostingReviewDashboardCache(lifetime: -1), account = try account()
    await cache.put(HostingReviewDashboardPage(items: [], nextPage: nil, total: 0), account: account, kind: .myOpenRequests, page: 1)
    let result = await cache.get(account: account, kind: .myOpenRequests, page: 1); XCTAssertNil(result)
  }

  func testCacheClearPreservesAnotherAccount() async throws {
    let cache = HostingReviewDashboardCache(), first = try account(), second = try account()
    for account in [first, second] { await cache.put(HostingReviewDashboardPage(items: [], nextPage: nil, total: 0), account: account, kind: .requestedReviews, page: 1) }
    await cache.clear(account: first)
    let removed = await cache.get(account: first, kind: .requestedReviews, page: 1), retained = await cache.get(account: second, kind: .requestedReviews, page: 1)
    XCTAssertNil(removed); XCTAssertNotNil(retained)
  }

  func testCurrentBranchRequiresExactSourceRepositoryAndFullCommit() throws {
    let account = try account(), snapshot = try HostingCurrentBranchSnapshot(account: account, branch: "feature/topic", head: sha, sourceRemoteURL: "git@github.com:owner/repo.git")
    XCTAssertTrue(snapshot.matches(request(), account: account))
    XCTAssertFalse(snapshot.matches(request(repository: "fork/repo"), account: account))
    XCTAssertFalse(snapshot.matches(request(head: String(repeating: "b", count: 40)), account: account))
    XCTAssertFalse(snapshot.matches(request(source: "other"), account: account))
    XCTAssertFalse(snapshot.matches(request(state: "closed"), account: account))
  }

  func testDifferentRemoteCommitIsRecognizedWithoutClaimingExactMatch() throws {
    let account = try account(), snapshot = try HostingCurrentBranchSnapshot(account: account, branch: "feature/topic", head: sha, sourceRemoteURL: "https://github.com/owner/repo.git")
    let remote = request(head: String(repeating: "b", count: 40))
    XCTAssertTrue(snapshot.sameSource(remote, account: account)); XCTAssertFalse(snapshot.matches(remote, account: account))
  }

  func testGitLabRequiresStableSourceProjectIDAndNeverUsesLoginOrPath() throws {
    let account = try account(.gitlab), remote = "https://code.example.invalid/group/repo.git"
    XCTAssertThrowsError(try HostingCurrentBranchSnapshot(account: account, branch: "feature/topic", head: sha, sourceRemoteURL: remote))
    let snapshot = try HostingCurrentBranchSnapshot(account: account, branch: "feature/topic", head: sha, sourceRemoteURL: remote, sourceRepositoryID: "99")
    XCTAssertTrue(snapshot.matches(request(repository: "99"), account: account))
    XCTAssertFalse(snapshot.matches(request(repository: "group/repo"), account: account))
    XCTAssertFalse(snapshot.matches(request(repository: "100"), account: account))
  }

  func testSnapshotCannotCrossAccountOrSameUUIDDifferentUser() throws {
    let account = try account(), snapshot = try HostingCurrentBranchSnapshot(account: account, branch: "feature/topic", head: sha, sourceRemoteURL: "https://github.com/owner/repo")
    XCTAssertFalse(snapshot.matches(request(), account: try self.account()))
    XCTAssertFalse(snapshot.matches(request(), account: try self.account(id: account.id, user: "77")))
  }

  func testDetachedAndAbbreviatedLocalHeadsHaveNoShortcut() throws {
    let account = try account()
    for branch in ["HEAD", "(detached)"] {
      XCTAssertThrowsError(try HostingCurrentBranchSnapshot(account: account, branch: branch, head: sha, sourceRemoteURL: "https://github.com/owner/repo"))
    }
    XCTAssertThrowsError(try HostingCurrentBranchSnapshot(account: account, branch: "feature/topic", head: "abc123", sourceRemoteURL: "https://github.com/owner/repo"))
  }

  func testSourceRemoteMustBelongToRegisteredInstance() throws {
    let account = try account(.gitlab)
    XCTAssertThrowsError(try HostingCurrentBranchSnapshot(account: account, branch: "feature/topic", head: sha,
      sourceRemoteURL: "https://other.example.invalid/group/repo", sourceRepositoryID: "99"))
  }

  func testCustomHTTPSPortDoesNotGuessAnSSHInstanceMapping() throws {
    let account = try account(.gitlab, url: "https://code.example.invalid:8443")
    XCTAssertThrowsError(try HostingCurrentBranchSnapshot(account: account, branch: "feature/topic", head: sha,
      sourceRemoteURL: "git@code.example.invalid:group/repo.git", sourceRepositoryID: "99"))
    XCTAssertNoThrow(try HostingCurrentBranchSnapshot(account: account, branch: "feature/topic", head: sha,
      sourceRemoteURL: "https://code.example.invalid:8443/group/repo.git", sourceRepositoryID: "99"))
  }
}
