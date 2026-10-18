import XCTest
@testable import GitPierCore

private actor ReviewAPIFixture: HostingTransport {
  let provider: HostingProvider
  var requests: [URLRequest] = []
  var overrides: [String: HostingHTTPResponse] = [:]
  var head = String(repeating: "a", count: 40)
  var base = String(repeating: "b", count: 40)
  var state = "open"
  var privateRepository = false
  var author = "99"
  var canApprove = true
  var version = "1.27.3"
  var approved = false
  var requestedUsers: [Int] = []
  func requested(_ ids: [Int]) { requestedUsers = ids }
  var reviewState = "COMMENTED"
  var reviewBodyJSON = "\"\""
  var headAfterReviewList: String?
  var approvalReadChange: String?
  var approvalReadsBeforeChange = 0
  var requestID = "200", targetRepositoryID = "100"
  var start = String(repeating: "c", count: 40), diffID = "10"
  init(_ provider: HostingProvider) { self.provider = provider }
  func configure(head: String? = nil, base: String? = nil, state: String? = nil, privateRepository: Bool? = nil, author: String? = nil, canApprove: Bool? = nil, version: String? = nil) {
    if let head { self.head = head }; if let state { self.state = state }; if let privateRepository { self.privateRepository = privateRepository }
    if let base { self.base = base }
    if let author { self.author = author }; if let canApprove { self.canApprove = canApprove }; if let version { self.version = version }
  }
  func override(_ suffix: String, json: String, status: Int = 200, headers: [String: String] = [:], method: String = "GET") {
    overrides[method + " " + suffix] = HostingHTTPResponse(data: Data(json.utf8), status: status, headers: headers)
  }
  func captured() -> [URLRequest] { requests }
  func changeHeadAfterReviewList(_ value: String) { headAfterReviewList = value }
  func changeAfterApprovalRead(_ field: String, after reads: Int = 0) { approvalReadChange = field; approvalReadsBeforeChange = reads }
  func send(_ request: URLRequest, limit: Int) async throws -> HostingHTTPResponse {
    requests.append(request)
    let method = request.httpMethod ?? "GET", path = request.url!.path
    for (key, response) in overrides.sorted(by: { $0.key.count > $1.key.count }) {
      let parts = key.split(separator: " ", maxSplits: 1)
      if method == parts[0], path.hasSuffix(parts[1]) { return response }
    }
    let user = "\"user\":{\"id\":42,\"login\":\"alice\"}"
    let json: String
    if method == "POST" || method == "PUT" {
      let body = try HostingJSON.decode(request.httpBody ?? Data("{}".utf8))
      if path.hasSuffix("/approve") { approved = true; json = "{\"user_has_approved\":true,\"approved_by\":[{\"user\":{\"id\":42}}]}" }
      else if path.hasSuffix("/discussions") { json = "{\"id\":\"discussion77\",\"notes\":[{\"id\":77,\"author\":{\"id\":42,\"username\":\"alice\"},\"body\":\"saved\"}]}" }
      else if provider == .gitlab { json = "{\"id\":78,\"author\":{\"id\":42,\"username\":\"alice\"},\"body\":\"reply\"}" }
      else if path.hasSuffix("/reviews") || path.hasSuffix("/events") {
        let event = body["event"].string
        reviewBodyJSON = String(decoding: try JSONEncoder().encode(body["body"]), as: UTF8.self)
        reviewState = event.isEmpty || event == "PENDING" ? "PENDING" : event == "APPROVE" || event == "APPROVED" ? "APPROVED" : event == "REQUEST_CHANGES" && provider == .github ? "CHANGES_REQUESTED" : event == "REQUEST_CHANGES" ? "REQUEST_CHANGES" : provider == .gitea ? "COMMENT" : "COMMENTED"
        json = "{\"id\":77,\(user),\"body\":\(reviewBodyJSON),\"state\":\"\(reviewState)\",\"commit_id\":\"\(head)\",\"submitted_at\":\"2026-10-18T00:00:00Z\"}"
      } else { json = "{\"id\":77,\(user),\"body\":\"saved\"}" }
    } else if path.hasSuffix("/version") { json = "{\"version\":\"\(version)\"}" }
    else if path.hasSuffix("/versions") { json = "[{\"id\":\(diffID),\"head_commit_sha\":\"\(head)\",\"base_commit_sha\":\"\(base)\",\"start_commit_sha\":\"\(start)\"}]" }
    else if path.hasSuffix("/approvals") {
      json = "{\"user_can_approve\":\(canApprove),\"user_has_approved\":\(approved),\"approved_by\":\(approved ? "[{\"user\":{\"id\":42}}]" : "[]") }"
      if approvalReadsBeforeChange > 0 { approvalReadsBeforeChange -= 1 }
      else if let field = approvalReadChange {
        approvalReadChange = nil
        switch field {
        case "head": head = String(repeating: "d", count: 40)
        case "base": base = String(repeating: "d", count: 40)
        case "start": start = String(repeating: "d", count: 40)
        case "version": diffID = "11"
        case "request": requestID = "201"
        case "repository": targetRepositoryID = "101"
        default: break
        }
      }
    }
    else if path.hasSuffix("/reviews/77") { json = "{\"id\":77,\(user),\"body\":\(reviewBodyJSON),\"state\":\"\(reviewState)\",\"commit_id\":\"\(head)\"}" }
    else if path.hasSuffix("/pulls/7") || path.hasSuffix("/merge_requests/7") {
      let requestedJSON = "[" + requestedUsers.map { "{\"id\":\($0),\"login\":\"user\($0)\"}" }.joined(separator: ",") + "]"
      json = "{\"id\":\(requestID),\"number\":7,\"iid\":7,\"target_project_id\":\(targetRepositoryID),\"state\":\"\(state)\",\"author\":{\"id\":\(author)},\"user\":{\"id\":\(author)},\"sha\":\"\(head)\",\"head\":{\"sha\":\"\(head)\"},\"base\":{\"sha\":\"\(base)\",\"repo\":{\"id\":\(targetRepositoryID)}},\"diff_refs\":{\"head_sha\":\"\(head)\",\"base_sha\":\"\(base)\",\"start_sha\":\"\(start)\"},\"requested_reviewers\":\(requestedJSON)}"
    } else if path.hasSuffix("/owner/repo") || path.hasSuffix("/owner%2Frepo") || path.hasSuffix("/projects/owner/repo") { json = "{\"id\":100,\"private\":\(privateRepository)}" }
    else if path.hasSuffix("/comments") || path.hasSuffix("/reviews") || path.hasSuffix("/discussions") {
      if path.hasSuffix("/reviews"), let value = headAfterReviewList { head = value; headAfterReviewList = nil }
      json = "[]"
    }
    else { throw HostingError.invalidResponse }
    return HostingHTTPResponse(data: Data(json.utf8))
  }
}

@MainActor final class HostingReviewAPITests: XCTestCase {
  private let sha = String(repeating: "a", count: 40)
  private func setup(_ provider: HostingProvider = .github, scopes: [String]? = nil, kind: HostingAuthenticationKind = .oauth) throws -> (HostingAPIClient, ReviewAPIFixture, HostingAccount, RepositoryHostingBinding, HostingToken) {
    let instance = try HostingInstance(provider: provider, url: provider == .github ? "https://github.com" : "https://forge.example.invalid")
    let account = HostingAccount(instance: instance, user: HostingUser(stableID: "42", login: "alice"), kind: kind, scopes: scopes ?? [], storageMode: .localVault)
    let fixture = ReviewAPIFixture(provider), binding = try RepositoryHostingBinding(repositoryID: UUID(), accountID: account.id, remote: "origin", repository: "owner/repo")
    let token = HostingToken(accessToken: "review-fixture-only", scopes: scopes ?? (provider == .github ? ["public_repo"] : provider == .gitlab ? ["api"] : ["write:repository", "write:issue"]))
    return (HostingAPIClient(http: HostingHTTPClient(transport: fixture, sleep: { _ in try Task.checkCancellation() })), fixture, account, binding, token)
  }
  private func expect(_ error: HostingReviewError, _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await operation(); XCTFail("Expected \(error)", file: file, line: line) } catch let value as HostingReviewError { XCTAssertEqual(value, error, file: file, line: line) } catch { XCTFail("Unexpected \(error)", file: file, line: line) }
  }
  private func anchor(_ context: HostingReviewContext, side: HostingReviewSide, kind: DiffLineKind) throws -> HostingDiffAnchor {
    let patch = "@@ -4,2 +4,2 @@\n context\n-old\n+new\n", document = DiffParser.parse(Data(patch.utf8))
    let file = HostingChangedFile(path: "A.swift", oldPath: "", kind: "modified", patch: patch)
    let line = try XCTUnwrap(document.hunks.flatMap(\.lines).first(where: { $0.kind == kind }))
    return try HostingDiffAnchor.make(context: context, file: file, document: document, lineID: line.id, side: side)
  }
  private func lastWrite(_ fixture: ReviewAPIFixture) async throws -> URLRequest {
    let values = await fixture.captured(); return try XCTUnwrap(values.last(where: { $0.httpMethod != "GET" }))
  }

  func testGithubPublicWriteCapabilitiesUseActualScope() async throws {
    let (api, _, account, binding, token) = try setup()
    let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    XCTAssertTrue(context.capabilities.isSuperset(of: [.generalComment, .inlineComment, .draft, .submitReview, .approve, .requestChanges]))
    XCTAssertFalse(context.capabilities.contains(.resolveDiscussion)); XCTAssertEqual(context.target.repositoryID, "100")
  }
  func testGithubPublicScopeCannotWritePrivateRepository() async throws {
    let (api, fixture, account, binding, token) = try setup(); await fixture.configure(privateRepository: true)
    let value = try await api.reviewContext(binding, number: 7, account: account, token: token); XCTAssertTrue(value.capabilities.isEmpty)
  }
  func testGithubRepoScopeAllowsPrivateReview() async throws {
    let (api, fixture, account, binding, token) = try setup(scopes: ["repo"]); await fixture.configure(privateRepository: true)
    let value = try await api.reviewContext(binding, number: 7, account: account, token: token); XCTAssertTrue(value.capabilities.contains(.approve))
  }
  func testGithubReadOnlyScopeCannotAcquireWriteCapabilities() async throws {
    let (api, _, account, binding, token) = try setup(scopes: ["read:user"])
    let value = try await api.reviewContext(binding, number: 7, account: account, token: token); XCTAssertTrue(value.capabilities.isEmpty)
  }
  func testOpaquePATRetainsPlatformEnforcedPermissionBoundary() async throws {
    let (api, _, account, binding, token) = try setup(scopes: [], kind: .pat)
    let value = try await api.reviewContext(binding, number: 7, account: account, token: token); XCTAssertTrue(value.capabilities.contains(.generalComment))
  }
  func testAuthorCannotApproveOrRequestChangesOnOwnRequest() async throws {
    let (api, fixture, account, binding, token) = try setup(); await fixture.configure(author: "42")
    let value = try await api.reviewContext(binding, number: 7, account: account, token: token)
    XCTAssertFalse(value.capabilities.contains(.approve)); XCTAssertFalse(value.capabilities.contains(.requestChanges)); XCTAssertTrue(value.capabilities.contains(.submitReview))
  }
  func testClosedRequestHasNoWriteCapabilities() async throws {
    let (api, fixture, account, binding, token) = try setup(); await fixture.configure(state: "closed")
    let value = try await api.reviewContext(binding, number: 7, account: account, token: token); XCTAssertTrue(value.capabilities.isEmpty)
  }
  func testContextRejectsDifferentAccountBeforeNetwork() async throws {
    let (api, fixture, account, _, token) = try setup()
    let binding = try RepositoryHostingBinding(repositoryID: UUID(), accountID: UUID(), remote: "origin", repository: "owner/repo")
    await expect(.targetChanged) { _ = try await api.reviewContext(binding, number: 7, account: account, token: token) }
    let requests = await fixture.captured(); XCTAssertTrue(requests.isEmpty)
  }
  func testContextRejectsRequestFromDifferentRepository() async throws {
    let (api, fixture, account, binding, token) = try setup()
    await fixture.override("/pulls/7", json: "{\"id\":200,\"number\":7,\"base\":{\"repo\":{\"id\":101}}}")
    await expect(.targetChanged) { _ = try await api.reviewContext(binding, number: 7, account: account, token: token) }
  }
  func testContextRejectsMissingStableRequestIdentity() async throws {
    let (api, fixture, account, binding, token) = try setup(); await fixture.override("/pulls/7", json: "{\"number\":7}")
    await expect(.targetChanged) { _ = try await api.reviewContext(binding, number: 7, account: account, token: token) }
  }
  private func contextRejectsMissingRepositoryIdentity(_ provider: HostingProvider) async throws {
    let (api, fixture, account, binding, token) = try setup(provider)
    let request = "{\"id\":200,\"number\":7,\"iid\":7,\"state\":\"opened\",\"sha\":\"\(sha)\",\"head\":{\"sha\":\"\(sha)\"},\"base\":{\"sha\":\"\(String(repeating: "b", count: 40))\"}}"
    await fixture.override(provider == .gitlab ? "/merge_requests/7" : "/pulls/7", json: request)
    await expect(.targetChanged) { _ = try await api.reviewContext(binding, number: 7, account: account, token: token) }
    let requests = await fixture.captured(); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
  }
  func testGithubContextRequiresServerBaseRepositoryIdentity() async throws { try await contextRejectsMissingRepositoryIdentity(.github) }
  func testGitlabContextRequiresServerTargetProjectIdentity() async throws { try await contextRejectsMissingRepositoryIdentity(.gitlab) }
  func testGiteaContextRequiresServerBaseRepositoryIdentity() async throws { try await contextRejectsMissingRepositoryIdentity(.gitea) }
  func testGitlabRevisionBindsEveryVersionCoordinate() async throws {
    let (api, _, account, binding, token) = try setup(.gitlab)
    let value = try await api.reviewContext(binding, number: 7, account: account, token: token)
    XCTAssertEqual(value.revision.diffID, "10"); XCTAssertEqual(value.revision.baseSHA, String(repeating: "b", count: 40)); XCTAssertEqual(value.revision.startSHA, String(repeating: "c", count: 40))
    XCTAssertTrue(value.capabilities.contains(.inlineComment)); XCTAssertFalse(value.capabilities.contains(.draft)); XCTAssertFalse(value.capabilities.contains(.requestChanges))
  }
  func testGitlabUnavailableVersionKeepsConversationButDisablesInline() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitlab); await fixture.override("/versions", json: "{}", status: 404)
    let value = try await api.reviewContext(binding, number: 7, account: account, token: token)
    XCTAssertTrue(value.capabilities.contains(.generalComment)); XCTAssertFalse(value.capabilities.contains(.inlineComment))
    XCTAssertFalse(value.capabilities.contains(.approve)); XCTAssertFalse(value.capabilities.contains(.requestReviewers))
  }
  func testGitlabMismatchedVersionCannotBecomeInlineContext() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitlab); await fixture.override("/versions", json: "[{\"id\":11,\"head_commit_sha\":\"wrong\"}]")
    let value = try await api.reviewContext(binding, number: 7, account: account, token: token); XCTAssertFalse(value.capabilities.contains(.inlineComment))
  }
  func testGitlabApprovalRequiresExplicitServerPermission() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitlab); await fixture.configure(canApprove: false)
    let value = try await api.reviewContext(binding, number: 7, account: account, token: token); XCTAssertFalse(value.capabilities.contains(.approve))
  }
  func testGitlabReadAPIIsNotWriteAPIScope() async throws {
    let (api, _, account, binding, token) = try setup(.gitlab, scopes: ["read_api", "read_user"])
    let value = try await api.reviewContext(binding, number: 7, account: account, token: token); XCTAssertTrue(value.capabilities.isEmpty)
  }
  func testGiteaRepositoryWriteDoesNotGrantIssueConversationWrite() async throws {
    let (api, _, account, binding, token) = try setup(.gitea, scopes: ["write:repository"])
    let value = try await api.reviewContext(binding, number: 7, account: account, token: token)
    XCTAssertFalse(value.capabilities.contains(.submitReview)); XCTAssertFalse(value.capabilities.contains(.generalComment)); XCTAssertFalse(value.capabilities.contains(.inlineComment))
    XCTAssertTrue(value.capabilities.contains(.reply)); XCTAssertTrue(value.capabilities.contains(.requestReviewers))
    XCTAssertTrue(value.capabilities.isDisjoint(with: [.draft, .approve, .requestChanges]))
  }
  func testGiteaIssueWriteDoesNotGrantReviewWrite() async throws {
    let (api, _, account, binding, token) = try setup(.gitea, scopes: ["write:issue"])
    let value = try await api.reviewContext(binding, number: 7, account: account, token: token)
    XCTAssertTrue(value.capabilities.contains(.generalComment)); XCTAssertFalse(value.capabilities.contains(.submitReview))
  }
  func testGiteaGranularScopeVersionIsNotReviewCapabilityProof() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitea); await fixture.configure(version: "1.23.0")
    let value = try await api.reviewContext(binding, number: 7, account: account, token: token); XCTAssertFalse(value.capabilities.contains(.submitReview))
  }
  func testGithubGeneralCommentUsesIssueConversationEndpoint() async throws {
    let (api, fixture, account, binding, token) = try setup(); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    let receipt = try await api.performReviewMutation(.comment(body: "评论\nbody"), context: context, account: account, token: token)
    let write = try await lastWrite(fixture); XCTAssertEqual(write.url?.path, "/repos/owner/repo/issues/7/comments"); XCTAssertEqual(receipt.id, "77")
    let body = try HostingJSON.decode(try XCTUnwrap(write.httpBody)); XCTAssertEqual(body["body"].string, "评论\nbody"); XCTAssertTrue(body["event"].string.isEmpty)
  }
  func testGithubDeletedLineUsesLeftAndActualOldLine() async throws {
    let (api, fixture, account, binding, token) = try setup(); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    _ = try await api.performReviewMutation(.inline(body: "old", anchor: anchor(context, side: .old, kind: .deletion)), context: context, account: account, token: token)
    let write = try await lastWrite(fixture), body = try HostingJSON.decode(try XCTUnwrap(write.httpBody))
    XCTAssertEqual(body["side"].string, "LEFT"); XCTAssertEqual(body["line"].int, 5); XCTAssertEqual(body["commit_id"].string, sha); XCTAssertTrue(body["position"].string.isEmpty)
  }
  func testGithubAddedLineUsesRightAndActualNewLine() async throws {
    let (api, fixture, account, binding, token) = try setup(); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    _ = try await api.performReviewMutation(.inline(body: "new", anchor: anchor(context, side: .new, kind: .addition)), context: context, account: account, token: token)
    let write = try await lastWrite(fixture), body = try HostingJSON.decode(try XCTUnwrap(write.httpBody)); XCTAssertEqual(body["side"].string, "RIGHT"); XCTAssertEqual(body["line"].int, 5)
  }
  func testGithubPendingReviewOmitsEventInsteadOfSendingPendingEnum() async throws {
    let (api, fixture, account, binding, token) = try setup(); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    let receipt = try await api.performReviewMutation(.review(summary: "draft", decision: .comment, comments: [], pending: true), context: context, account: account, token: token)
    let write = try await lastWrite(fixture), body = try HostingJSON.decode(try XCTUnwrap(write.httpBody)); XCTAssertTrue(body["event"].string.isEmpty); XCTAssertEqual(receipt.state, .pending)
  }
  func testGithubApproveAndChangesRequestedUseProviderEvents() async throws {
    for decision in [HostingReviewDecision.approve, .requestChanges] {
      let (api, fixture, account, binding, token) = try setup(); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
      let mutation = HostingReviewMutation.review(summary: "review", decision: decision, comments: [], pending: false)
      let receipt = try await api.performReviewMutation(mutation, context: context, account: account, token: token)
      let write = try await lastWrite(fixture), body = try HostingJSON.decode(try XCTUnwrap(write.httpBody)); XCTAssertEqual(body["event"].string, decision == .approve ? "APPROVE" : "REQUEST_CHANGES")
      let readback = try await api.readReviewReceipt(receipt, mutation: mutation, context: context, account: account, token: token); XCTAssertEqual(readback.commitSHA, sha)
    }
  }
  func testHeadChangeStopsBeforeAnyPost() async throws {
    let (api, fixture, account, binding, token) = try setup(); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.configure(head: String(repeating: "d", count: 40))
    await expect(.revisionChanged) { _ = try await api.performReviewMutation(.comment(body: "safe"), context: context, account: account, token: token) }
    let requests = await fixture.captured(); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
  }
  func testGithubReplyChecksPullRequestOwnershipBeforePost() async throws {
    let (api, fixture, account, binding, token) = try setup(); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/pulls/comments/5", json: "{\"id\":5,\"pull_request_url\":\"https://api.github.com/repos/owner/repo/pulls/8\"}")
    await expect(.targetChanged) { _ = try await api.performReviewMutation(.reply(threadID: "5", commentID: "5", body: "reply"), context: context, account: account, token: token) }
    let requests = await fixture.captured(); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
  }
  func testGithubReplyToReplyIsRejected() async throws {
    let (api, fixture, account, binding, token) = try setup(); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/pulls/comments/5", json: "{\"id\":5,\"in_reply_to_id\":4,\"pull_request_url\":\"https://api.github.com/repos/owner/repo/pulls/7\"}")
    await expect(.unsupported) { _ = try await api.performReviewMutation(.reply(threadID: "5", commentID: "5", body: "reply"), context: context, account: account, token: token) }
  }
  func testGithubStableRootReplyUsesNativeReplyEndpoint() async throws {
    let (api, fixture, account, binding, token) = try setup(); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/pulls/comments/5", json: "{\"id\":5,\"pull_request_url\":\"https://api.github.com/repos/owner/repo/pulls/7\"}")
    _ = try await api.performReviewMutation(.reply(threadID: "5", commentID: "5", body: "reply"), context: context, account: account, token: token)
    let write = try await lastWrite(fixture); XCTAssertEqual(write.url?.path, "/repos/owner/repo/pulls/7/comments/5/replies")
  }
  func testGitlabContextLinePostsBothLineNumbersAndVersionTriple() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitlab); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    _ = try await api.performReviewMutation(.inline(body: "context", anchor: anchor(context, side: .new, kind: .context)), context: context, account: account, token: token)
    let write = try await lastWrite(fixture), body = try HostingJSON.decode(try XCTUnwrap(write.httpBody)), position = body["position"]
    XCTAssertEqual(position["old_line"].int, 4); XCTAssertEqual(position["new_line"].int, 4); XCTAssertEqual(position["head_sha"].string, sha); XCTAssertEqual(position["base_sha"].string, context.revision.baseSHA); XCTAssertEqual(position["start_sha"].string, context.revision.startSHA)
  }
  func testGitlabApprovalPostsExactSHAAndVerifiesCurrentUser() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitlab); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    let mutation = HostingReviewMutation.review(summary: "", decision: .approve, comments: [], pending: false)
    let receipt = try await api.performReviewMutation(mutation, context: context, account: account, token: token)
    let write = try await lastWrite(fixture), body = try HostingJSON.decode(try XCTUnwrap(write.httpBody)); XCTAssertTrue(write.url!.path.hasSuffix("/approve")); XCTAssertEqual(body["sha"].string, sha)
    let verified = try await api.readReviewReceipt(receipt, mutation: mutation, context: context, account: account, token: token); XCTAssertEqual(verified.authorID, "42")
  }
  func testGitlabDiscussionReplyRequiresScopedDiscussionMembership() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitlab); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/discussions/discussion5", json: "{\"id\":\"discussion5\",\"notes\":[{\"id\":9}]}")
    await expect(.targetChanged) { _ = try await api.performReviewMutation(.reply(threadID: "discussion5", commentID: "5", body: "reply"), context: context, account: account, token: token) }
  }
  func testGiteaReviewDecisionsAreBrowserOnlyEvenWithForgedCapabilities() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitea); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    let forged = HostingReviewContext(target: context.target, revision: context.revision, capabilities: [.draft, .submitReview, .approve, .requestChanges], state: context.state, authorID: context.authorID)
    let before = await fixture.captured().count
    for decision in [HostingReviewDecision.comment, .approve, .requestChanges] {
      await expect(.unsupported) { _ = try await api.performReviewMutation(.review(summary: "review", decision: decision, comments: [], pending: false), context: forged, account: account, token: token) }
    }
    await expect(.unsupported) { _ = try await api.performReviewMutation(.review(summary: "pending", decision: .comment, comments: [], pending: true), context: forged, account: account, token: token) }
    let requests = await fixture.captured(); XCTAssertEqual(requests.count, before); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
  }
  func testGiteaPendingSubmitCannotRebindToUnreviewedHead() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitea); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await expect(.unsupported) { _ = try await api.performReviewMutation(.submitPending(reviewID: "77", summary: "review", decision: .approve), context: context, account: account, token: token) }
    let requests = await fixture.captured(); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
  }
  func testPostServerFailureIsUnknownAndNeverRetried() async throws {
    let (api, fixture, account, binding, token) = try setup(); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/comments", json: "{}", status: 503, method: "POST")
    await expect(.resultUnknown) { _ = try await api.performReviewMutation(.comment(body: "once"), context: context, account: account, token: token) }
    let writes = await fixture.captured().filter { $0.httpMethod == "POST" }; XCTAssertEqual(writes.count, 1)
  }
  func testMalformedSuccessfulPostIsUnknownAndKeepsStableIDRequirement() async throws {
    let (api, fixture, account, binding, token) = try setup(); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/comments", json: "{\"body\":\"once\"}", method: "POST")
    await expect(.resultUnknown) { _ = try await api.performReviewMutation(.comment(body: "once"), context: context, account: account, token: token) }
  }
  func testPermissionFailureRemainsActionableAndDoesNotRetry() async throws {
    let (api, fixture, account, binding, token) = try setup(); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/comments", json: "{}", status: 403, method: "POST")
    await expect(.permissionRequired) { _ = try await api.performReviewMutation(.comment(body: "once"), context: context, account: account, token: token) }
    let writes = await fixture.captured().filter { $0.httpMethod == "POST" }; XCTAssertEqual(writes.count, 1)
  }
  func testGiteaReviewCannotReachPartiallyMutatingValidationEndpoint() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitea); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/reviews", json: "{}", status: 422, method: "POST")
    await expect(.unsupported) { _ = try await api.performReviewMutation(.review(summary: "once", decision: .comment, comments: [], pending: false), context: context, account: account, token: token) }
    let requests = await fixture.captured(); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
  }
  func testGitlabTimelineKeepsDiscussionAndNoteIDsSeparate() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitlab)
    await fixture.override("/discussions", json: "[{\"id\":\"threadA\",\"notes\":[{\"id\":1,\"author\":{\"id\":42,\"username\":\"alice\"},\"body\":\"root\"},{\"id\":2,\"author\":{\"id\":9,\"username\":\"bob\"},\"body\":\"reply\"}]}]", headers: ["x-next-page": "2"])
    let page = try await api.reviewTimeline(binding, number: 7, account: account, token: token, source: .conversation)
    XCTAssertEqual(page.items.first?.remoteID, "threadA"); XCTAssertEqual(page.items.first?.comments.map(\.id), ["1", "2"]); XCTAssertEqual(page.nextPage, 2)
    XCTAssertEqual(page.items.first?.comments.last?.kind, .reply); XCTAssertEqual(page.items.first?.comments.last?.replyToID, "1")
  }
  func testGithubTimelineGroupsRepliesByExplicitRootID() async throws {
    let (api, fixture, account, binding, token) = try setup()
    await fixture.override("/comments", json: "[{\"id\":1,\"user\":{\"id\":42},\"line\":5,\"side\":\"RIGHT\"},{\"id\":2,\"user\":{\"id\":9},\"in_reply_to_id\":1,\"line\":5,\"side\":\"RIGHT\"}]")
    let page = try await api.reviewTimeline(binding, number: 7, account: account, token: token, source: .inline)
    XCTAssertEqual(page.items.count, 1); XCTAssertEqual(page.items.first?.comments.count, 2); XCTAssertEqual(page.items.first?.remoteID, "1")
  }
  func testReadbackDoesNotAcceptSameBodyUnderDifferentStableID() async throws {
    let (api, fixture, account, binding, token) = try setup(); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/comments", json: "[{\"id\":78,\"user\":{\"id\":42},\"body\":\"same\"}]")
    await expect(.readbackRequired) { _ = try await api.readReviewReceipt(HostingReviewReceipt(id: "77", authorID: "42"), mutation: .comment(body: "same"), context: context, account: account, token: token) }
  }
  func testCommentReadbackRejectsDifferentBodyUnderSameID() async throws {
    let (api, fixture, account, binding, token) = try setup(), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/comments", json: "[{\"id\":77,\"user\":{\"id\":42},\"body\":\"changed\"}]")
    await expect(.readbackRequired) { _ = try await api.readReviewReceipt(HostingReviewReceipt(id: "77", authorID: "42"), mutation: .comment(body: "original"), context: context, account: account, token: token) }
  }
  func testCommentReadbackAcceptsStableIDAndExactBody() async throws {
    let (api, fixture, account, binding, token) = try setup(), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/comments", json: "[{\"id\":77,\"user\":{\"id\":42},\"body\":\"original\"}]")
    let result = try await api.readReviewReceipt(HostingReviewReceipt(id: "77", authorID: "42"), mutation: .comment(body: "original"), context: context, account: account, token: token)
    XCTAssertEqual(result.id, "77")
  }
  func testReviewReadbackRejectsDifferentSummaryUnderSameID() async throws {
    let (api, fixture, account, binding, token) = try setup(), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/reviews/77", json: "{\"id\":77,\"user\":{\"id\":42},\"body\":\"changed\",\"state\":\"COMMENTED\",\"commit_id\":\"\(sha)\"}")
    await expect(.readbackRequired) { _ = try await api.readReviewReceipt(HostingReviewReceipt(id: "77", state: .commented, authorID: "42", commitSHA: sha), mutation: .review(summary: "original", decision: .comment, comments: [], pending: false), context: context, account: account, token: token) }
  }
  func testReplyReadbackRejectsDifferentBodyUnderSameID() async throws {
    let (api, fixture, account, binding, token) = try setup(), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/pulls/comments/77", json: "{\"id\":77,\"user\":{\"id\":42},\"body\":\"changed\",\"pull_request_url\":\"https://api.github.com/repos/owner/repo/pulls/7\"}")
    await expect(.readbackRequired) { _ = try await api.readReviewReceipt(HostingReviewReceipt(id: "77", authorID: "42"), mutation: .reply(threadID: "5", commentID: "5", body: "original"), context: context, account: account, token: token) }
  }
  func testGiteaInlineTimelineLoadsOnlyReviewPageAndDefersComments() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitea)
    await fixture.override("/reviews", json: "[{\"id\":8,\"comments_count\":120,\"state\":\"COMMENT\"},{\"id\":9,\"comments_count\":0}]")
    let page = try await api.reviewTimeline(binding, number: 7, account: account, token: token, source: .inline)
    XCTAssertEqual(page.items.count, 1); XCTAssertEqual(page.items.first?.remoteID, "8"); XCTAssertTrue(page.items.first?.hasMoreReplies == true); XCTAssertTrue(page.items.first?.comments.isEmpty == true)
    let requests = await fixture.captured(); XCTAssertEqual(requests.count, 1); XCTAssertTrue(requests.allSatisfy { !$0.url!.path.hasSuffix("/comments") })
  }
  func testGiteaReviewRepliesDoNotInventServerPaginationOrParentID() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitea)
    await fixture.override("/reviews/8/comments", json: "[{\"id\":91,\"pull_request_review_id\":8,\"user\":{\"id\":42},\"path\":\"A.swift\",\"position\":9}]", headers: ["x-hasmore": "true"])
    let thread = HostingReviewThread(id: "inline:8", remoteID: "8", source: .inline, comments: [], hasMoreReplies: true)
    let page = try await api.reviewReplies(binding, number: 7, thread: thread, account: account, token: token)
    XCTAssertEqual(page.items.first?.id, "91"); XCTAssertNil(page.items.first?.replyToID); XCTAssertNil(page.nextPage)
    let requests = await fixture.captured(), query = URLComponents(url: try XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems
    XCTAssertTrue(query?.isEmpty ?? true); XCTAssertEqual(requests.count, 1)
  }
  func testHeadChangedDuringPendingReviewDiscoveryStopsBeforePost() async throws {
    let (api, fixture, account, binding, token) = try setup(); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.changeHeadAfterReviewList(String(repeating: "d", count: 40))
    await expect(.revisionChanged) { _ = try await api.performReviewMutation(.review(summary: "review", decision: .approve, comments: [], pending: false), context: context, account: account, token: token) }
    let requests = await fixture.captured(); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
  }
  func testGithubInlineReadbackRejectsWrongPathAtSameSHA() async throws {
    try await wrongGithubAnchorReadback(path: "B.swift", line: 5, side: "RIGHT")
  }
  func testGithubInlineReadbackRejectsWrongSideAtSameSHA() async throws {
    try await wrongGithubAnchorReadback(path: "A.swift", line: 5, side: "LEFT")
  }
  func testGithubInlineReadbackRejectsWrongLineAtSameSHA() async throws {
    try await wrongGithubAnchorReadback(path: "A.swift", line: 6, side: "RIGHT")
  }
  private func wrongGithubAnchorReadback(path: String, line: Int, side: String) async throws {
    let (api, fixture, account, binding, token) = try setup(); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    let mutation = HostingReviewMutation.inline(body: "saved", anchor: try anchor(context, side: .new, kind: .addition))
    await fixture.override("/pulls/comments/77", json: "{\"id\":77,\"user\":{\"id\":42},\"body\":\"saved\",\"path\":\"\(path)\",\"line\":\(line),\"side\":\"\(side)\",\"commit_id\":\"\(sha)\",\"pull_request_url\":\"https://api.github.com/repos/owner/repo/pulls/7\"}")
    await expect(.readbackRequired) { _ = try await api.readReviewReceipt(HostingReviewReceipt(id: "77", authorID: "42", commitSHA: self.sha), mutation: mutation, context: context, account: account, token: token) }
  }
  func testGithubInlineReadbackAcceptsExactDeletedLineCoordinates() async throws {
    let (api, fixture, account, binding, token) = try setup(); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    let mutation = HostingReviewMutation.inline(body: "saved", anchor: try anchor(context, side: .old, kind: .deletion))
    await fixture.override("/pulls/comments/77", json: "{\"id\":77,\"user\":{\"id\":42},\"body\":\"saved\",\"path\":\"A.swift\",\"line\":5,\"side\":\"LEFT\",\"commit_id\":\"\(sha)\",\"pull_request_url\":\"https://api.github.com/repos/owner/repo/pulls/7\"}")
    let value = try await api.readReviewReceipt(HostingReviewReceipt(id: "77", authorID: "42", commitSHA: sha), mutation: mutation, context: context, account: account, token: token); XCTAssertEqual(value.id, "77")
  }
  func testGithubReviewReadbackRequiresEveryExpectedInlineComment() async throws {
    let (api, fixture, account, binding, token) = try setup(); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    let comment = HostingReviewDraftComment(body: "saved", anchor: try anchor(context, side: .new, kind: .addition))
    let mutation = HostingReviewMutation.review(summary: "review", decision: .comment, comments: [comment], pending: false)
    await fixture.override("/reviews/77/comments", json: "[]")
    await expect(.readbackRequired) { _ = try await api.readReviewReceipt(HostingReviewReceipt(id: "77", state: .commented, authorID: "42", commitSHA: self.sha), mutation: mutation, context: context, account: account, token: token) }
  }
  func testGithubReviewReadbackRejectsUnexpectedAttachedPendingComments() async throws {
    let (api, fixture, account, binding, token) = try setup(); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    let mutation = HostingReviewMutation.review(summary: "review", decision: .comment, comments: [], pending: false)
    await fixture.override("/reviews/77/comments", json: "[{\"id\":78,\"user\":{\"id\":42},\"body\":\"unexpected\"}]")
    await expect(.readbackRequired) { _ = try await api.readReviewReceipt(HostingReviewReceipt(id: "77", state: .commented, authorID: "42", commitSHA: self.sha), mutation: mutation, context: context, account: account, token: token) }
  }
  func testGitlabInlineReadbackRejectsWrongVersionTriple() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitlab); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    let mutation = HostingReviewMutation.inline(body: "saved", anchor: try anchor(context, side: .new, kind: .context))
    let position = "\"position_type\":\"text\",\"head_sha\":\"\(sha)\",\"base_sha\":\"wrong\",\"start_sha\":\"\(context.revision.startSHA)\",\"old_path\":\"A.swift\",\"new_path\":\"A.swift\",\"old_line\":4,\"new_line\":4"
    await fixture.override("/discussions/threadA", json: "{\"id\":\"threadA\",\"notes\":[{\"id\":77,\"body\":\"saved\",\"author\":{\"id\":42},\"position\":{\(position)}}]}")
    await expect(.readbackRequired) { _ = try await api.readReviewReceipt(HostingReviewReceipt(id: "77", threadID: "threadA", authorID: "42", commitSHA: self.sha), mutation: mutation, context: context, account: account, token: token) }
  }
  func testGithubReviewReadbackAcceptsExactStableReviewAndInlineComments() async throws {
    let (api, fixture, account, binding, token) = try setup(); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    let draft = HostingReviewDraftComment(body: "saved", anchor: try anchor(context, side: .new, kind: .addition))
    let mutation = HostingReviewMutation.review(summary: "review", decision: .comment, comments: [draft], pending: false)
    await fixture.override("/reviews/77", json: "{\"id\":77,\"user\":{\"id\":42},\"body\":\"review\",\"state\":\"COMMENTED\",\"commit_id\":\"\(sha)\"}")
    await fixture.override("/reviews/77/comments", json: "[{\"id\":78,\"pull_request_review_id\":77,\"user\":{\"id\":42},\"body\":\"saved\",\"path\":\"A.swift\",\"line\":5,\"side\":\"RIGHT\",\"commit_id\":\"\(sha)\"}]")
    let verified = try await api.readReviewReceipt(HostingReviewReceipt(id: "77", state: .commented, authorID: "42", commitSHA: sha), mutation: mutation, context: context, account: account, token: token)
    XCTAssertEqual(verified.state, .commented); XCTAssertEqual(verified.id, "77")
  }
  func testGitlabInlineReadbackAcceptsBothContextCoordinatesAndVersion() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitlab); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    let mutation = HostingReviewMutation.inline(body: "saved", anchor: try anchor(context, side: .new, kind: .context))
    let position = "\"position_type\":\"text\",\"head_sha\":\"\(sha)\",\"base_sha\":\"\(context.revision.baseSHA)\",\"start_sha\":\"\(context.revision.startSHA)\",\"old_path\":\"A.swift\",\"new_path\":\"A.swift\",\"old_line\":4,\"new_line\":4"
    await fixture.override("/discussions/threadA", json: "{\"id\":\"threadA\",\"notes\":[{\"id\":77,\"body\":\"saved\",\"author\":{\"id\":42},\"position\":{\(position)}}]}")
    let verified = try await api.readReviewReceipt(HostingReviewReceipt(id: "77", threadID: "threadA", authorID: "42", commitSHA: sha), mutation: mutation, context: context, account: account, token: token)
    XCTAssertEqual(verified.threadID, "threadA"); XCTAssertEqual(verified.commitSHA, sha)
  }
  func testBaseChangeAtSameHeadStopsGithubAndGiteaCommentWrites() async throws {
    for provider in [HostingProvider.github, .gitea] {
      let (api, fixture, account, binding, token) = try setup(provider); let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
      await fixture.configure(base: String(repeating: "e", count: 40))
      await expect(.revisionChanged) { _ = try await api.performReviewMutation(.comment(body: "comment"), context: context, account: account, token: token) }
      let requests = await fixture.captured(); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }
  }
  func testMissingBaseCommitCannotGrantGithubWriteCapabilities() async throws {
    let (api, fixture, account, binding, token) = try setup(); await fixture.configure(base: "")
    let context = try await api.reviewContext(binding, number: 7, account: account, token: token); XCTAssertTrue(context.capabilities.isEmpty)
  }
  func testGitlabDoesNotAdvertiseGithubStyleReviewSubmission() async throws {
    let (api, _, account, binding, token) = try setup(.gitlab)
    let context = try await api.reviewContext(binding, number: 7, account: account, token: token); XCTAssertFalse(context.capabilities.contains(.submitReview))
    await expect(.permissionRequired) { _ = try await api.performReviewMutation(.review(summary: "summary", decision: .comment, comments: [], pending: false), context: context, account: account, token: token) }
  }
  private func gitlabApprovalRace(_ field: String, expected: HostingReviewError) async throws {
    let (api, fixture, account, binding, token) = try setup(.gitlab)
    let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    let mutation = HostingReviewMutation.review(summary: "", decision: .approve, comments: [], pending: false)
    let receipt = try await api.performReviewMutation(mutation, context: context, account: account, token: token)
    await fixture.changeAfterApprovalRead(field)
    await expect(expected) { _ = try await api.readReviewReceipt(receipt, mutation: mutation, context: context, account: account, token: token) }
    let writes = await fixture.captured().filter { $0.httpMethod != "GET" }; XCTAssertEqual(writes.count, 1)
  }
  func testGitlabApprovalReadbackRejectsHeadChangedAfterApprovalList() async throws { try await gitlabApprovalRace("head", expected: .revisionChanged) }
  func testGitlabApprovalReadbackRejectsBaseChangedAtSameHeadAfterApprovalList() async throws { try await gitlabApprovalRace("base", expected: .revisionChanged) }
  func testGitlabApprovalReadbackRejectsStartChangedAfterApprovalList() async throws { try await gitlabApprovalRace("start", expected: .revisionChanged) }
  func testGitlabApprovalReadbackRejectsDiffVersionChangedAfterApprovalList() async throws { try await gitlabApprovalRace("version", expected: .revisionChanged) }
  func testGitlabApprovalReadbackRejectsStableRequestChangedAfterApprovalList() async throws { try await gitlabApprovalRace("request", expected: .targetChanged) }
  func testGitlabApprovalReadbackRejectsTargetRepositoryChangedAfterApprovalList() async throws { try await gitlabApprovalRace("repository", expected: .targetChanged) }
  func testGitlabApprovalReadbackEndsWithRawSnapshotAfterFinalPermissionRead() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitlab), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    let mutation = HostingReviewMutation.review(summary: "", decision: .approve, comments: [], pending: false)
    let receipt = try await api.performReviewMutation(mutation, context: context, account: account, token: token)
    await fixture.changeAfterApprovalRead("head", after: 1)
    await expect(.readbackRequired) { _ = try await api.readReviewReceipt(receipt, mutation: mutation, context: context, account: account, token: token) }
    let requests = await fixture.captured(); XCTAssertTrue(requests.last?.url?.path.hasSuffix("/merge_requests/7") == true)
    XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
  }
  func testGitlabApprovalReadbackRequiresCompleteFinalDiffRefs() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitlab), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    let mutation = HostingReviewMutation.review(summary: "", decision: .approve, comments: [], pending: false)
    let receipt = try await api.performReviewMutation(mutation, context: context, account: account, token: token)
    await fixture.override("/merge_requests/7", json: "{\"id\":200,\"iid\":7,\"target_project_id\":100,\"state\":\"opened\",\"sha\":\"\(sha)\",\"author\":{\"id\":99}}")
    await expect(.readbackRequired) { _ = try await api.readReviewReceipt(receipt, mutation: mutation, context: context, account: account, token: token) }
  }

  func testGithubReplyReadbackRejectsDifferentRootUnderSameIDAndBody() async throws {
    let (api, fixture, account, binding, token) = try setup(), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/pulls/comments/77", json: "{\"id\":77,\"user\":{\"id\":42},\"body\":\"reply\",\"in_reply_to_id\":6,\"pull_request_url\":\"https://api.github.com/repos/owner/repo/pulls/7\"}")
    await expect(.readbackRequired) { _ = try await api.readReviewReceipt(HostingReviewReceipt(id: "77", authorID: "42"), mutation: .reply(threadID: "5", commentID: "5", body: "reply"), context: context, account: account, token: token) }
  }
  func testGithubReplyReadbackRequiresExplicitParentInsteadOfAcceptingRootComment() async throws {
    let (api, fixture, account, binding, token) = try setup(), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/pulls/comments/77", json: "{\"id\":77,\"user\":{\"id\":42},\"body\":\"reply\",\"pull_request_url\":\"https://api.github.com/repos/owner/repo/pulls/7\"}")
    await expect(.readbackRequired) { _ = try await api.readReviewReceipt(HostingReviewReceipt(id: "77", authorID: "42"), mutation: .reply(threadID: "5", commentID: "5", body: "reply"), context: context, account: account, token: token) }
  }
  func testGithubReplyReadbackAcceptsExactStableRootAndBody() async throws {
    let (api, fixture, account, binding, token) = try setup(), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/pulls/comments/77", json: "{\"id\":77,\"user\":{\"id\":42},\"body\":\"reply\",\"in_reply_to_id\":5,\"pull_request_url\":\"https://api.github.com/repos/owner/repo/pulls/7\"}")
    let verified = try await api.readReviewReceipt(HostingReviewReceipt(id: "77", authorID: "42"), mutation: .reply(threadID: "5", commentID: "5", body: "reply"), context: context, account: account, token: token)
    XCTAssertEqual(verified.id, "77"); XCTAssertEqual(verified.authorID, "42")
  }
  private func giteaComments(_ count: Int, reviewID: Int = 8) -> String {
    "[" + (1...count).map { "{\"id\":\($0),\"pull_request_review_id\":\(reviewID),\"user\":{\"id\":42,\"login\":\"alice\"},\"body\":\"comment \($0)\",\"path\":\"A.swift\",\"position\":\($0)}" }.joined(separator: ",") + "]"
  }
  func testGiteaFiftyAndHundredPlusCommentsAreOneCollectionWithNoNextPage() async throws {
    for count in [50, 120, 1000] {
      let (api, fixture, account, binding, token) = try setup(.gitea)
      await fixture.override("/reviews/8/comments", json: giteaComments(count))
      let thread = HostingReviewThread(id: "inline:8", remoteID: "8", source: .inline, comments: [], hasMoreReplies: true)
      let page = try await api.reviewReplies(binding, number: 7, thread: thread, account: account, token: token)
      XCTAssertEqual(page.items.count, count); XCTAssertNil(page.nextPage)
      let requests = await fixture.captured(); XCTAssertEqual(requests.count, 1); XCTAssertNil(requests.first?.url?.query)
    }
  }
  func testGiteaSecondRepliesPageDoesNotRepeatWholeCollection() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitea)
    let thread = HostingReviewThread(id: "inline:8", remoteID: "8", source: .inline, comments: [], hasMoreReplies: true)
    let page = try await api.reviewReplies(binding, number: 7, thread: thread, account: account, token: token, page: 2)
    XCTAssertTrue(page.items.isEmpty); XCTAssertNil(page.nextPage)
    let requests = await fixture.captured(); XCTAssertTrue(requests.isEmpty)
  }
  func testGiteaOversizedReviewCollectionFailsWithoutTruncating() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitea)
    await fixture.override("/reviews/8/comments", json: giteaComments(1001))
    let thread = HostingReviewThread(id: "inline:8", remoteID: "8", source: .inline, comments: [], hasMoreReplies: true)
    do { _ = try await api.reviewReplies(binding, number: 7, thread: thread, account: account, token: token); XCTFail("Expected bounded collection") }
    catch let error as HostingError { XCTAssertEqual(error, .responseTooLarge) }
    let requests = await fixture.captured(); XCTAssertEqual(requests.count, 1)
  }
  func testLegacyGiteaReviewCommentsUseSameUnpaginatedBound() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitea)
    await fixture.override("/reviews/8/comments", json: giteaComments(120), headers: ["x-hasmore": "true"])
    let first = try await api.giteaReviewCommentsPage(binding, number: 7, reviewID: "8", account: account, token: token)
    let second = try await api.giteaReviewCommentsPage(binding, number: 7, reviewID: "8", account: account, token: token, page: 2)
    XCTAssertEqual(first.items.count, 120); XCTAssertNil(first.nextPage); XCTAssertTrue(second.items.isEmpty)
    let requests = await fixture.captured(); XCTAssertEqual(requests.count, 1); XCTAssertNil(requests.first?.url?.query)
  }
  func testLegacyGiteaOversizedReviewCommentsFailWithoutTruncating() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitea)
    await fixture.override("/reviews/8/comments", json: giteaComments(1001))
    do { _ = try await api.giteaReviewCommentsPage(binding, number: 7, reviewID: "8", account: account, token: token); XCTFail("Expected bounded collection") }
    catch let error as HostingError { XCTAssertEqual(error, .responseTooLarge) }
  }
  func testGiteaReplyParentAfterHundredCommentsIsFoundWithOneRead() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitea), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/reviews/8/comments", json: giteaComments(120))
    _ = try await api.performReviewMutation(.reply(threadID: "8", commentID: "120", body: "saved"), context: context, account: account, token: token)
    let requests = await fixture.captured(), reads = requests.filter { $0.httpMethod == "GET" && $0.url!.path.hasSuffix("/reviews/8/comments") }
    XCTAssertEqual(reads.count, 1); XCTAssertNil(reads.first?.url?.query)
    XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
  }
  func testGiteaMissingReplyParentDoesNotRepeatFiftyComments() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitea), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/reviews/8/comments", json: giteaComments(50))
    await expect(.targetChanged) { _ = try await api.performReviewMutation(.reply(threadID: "8", commentID: "999", body: "saved"), context: context, account: account, token: token) }
    let requests = await fixture.captured(); XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("/reviews/8/comments") }.count, 1); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
  }
  func testGiteaReviewBatchReadbackDoesNotInventFiftyCommentPages() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitea), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/reviews/77", json: "{\"id\":77,\"user\":{\"id\":42},\"body\":\"summary\",\"state\":\"COMMENT\",\"commit_id\":\"\(sha)\"}")
    await fixture.override("/reviews/77/comments", json: giteaComments(50, reviewID: 77))
    await expect(.readbackRequired) { _ = try await api.readReviewReceipt(HostingReviewReceipt(id: "77", state: .commented, authorID: "42", commitSHA: sha), mutation: .review(summary: "summary", decision: .comment, comments: [], pending: false), context: context, account: account, token: token) }
    let requests = await fixture.captured(); XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("/reviews/77/comments") }.count, 1)
  }
  func testGiteaCannotPublishExternalPendingCommentsEvenIfTheyAppearAfterConfirmation() async throws {
    let (api, fixture, account, binding, token) = try setup(.gitea), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/reviews", json: "[{\"id\":88,\"state\":\"PENDING\",\"user\":{\"id\":42},\"comments_count\":1}]")
    for pending in [false, true] {
      await expect(.unsupported) { _ = try await api.performReviewMutation(.review(summary: "only confirmed summary", decision: .comment, comments: [], pending: pending), context: context, account: account, token: token) }
    }
    let requests = await fixture.captured(); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" }); XCTAssertFalse(requests.contains { $0.url!.path.hasSuffix("/reviews") })
  }

  func testGithubReviewReadbackRequiresConfirmedDecisionInsteadOfReceiptAgreement() async throws {
    for (decision, pending, returned) in [(HostingReviewDecision.approve, false, "COMMENTED"), (.requestChanges, false, "APPROVED"), (.comment, false, "PENDING"), (.comment, true, "COMMENTED")] {
      let (api, fixture, account, binding, token) = try setup(), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
      let response = "{\"id\":77,\"user\":{\"id\":42},\"body\":\"summary\",\"state\":\"\(returned)\",\"commit_id\":\"\(sha)\"}"
      await fixture.override("/reviews", json: response, method: "POST")
      await fixture.override("/reviews/77", json: response)
      let mutation = HostingReviewMutation.review(summary: "summary", decision: decision, comments: [], pending: pending)
      let receipt = try await api.performReviewMutation(mutation, context: context, account: account, token: token)
      XCTAssertEqual(receipt.id, "77")
      await expect(.readbackRequired) { _ = try await api.readReviewReceipt(receipt, mutation: mutation, context: context, account: account, token: token) }
      let requests = await fixture.captured(); XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
    }
  }
  func testGithubReviewReadbackRequiresFullConfirmedCommitEvenWhenPOSTOmittedIt() async throws {
    for commit in ["", "abc123", String(repeating: "d", count: 40)] {
      let (api, fixture, account, binding, token) = try setup(), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
      let response = "{\"id\":77,\"user\":{\"id\":42},\"body\":\"summary\",\"state\":\"APPROVED\",\"commit_id\":\"\(commit)\"}"
      await fixture.override("/reviews", json: response, method: "POST"); await fixture.override("/reviews/77", json: response)
      let mutation = HostingReviewMutation.review(summary: "summary", decision: .approve, comments: [], pending: false)
      let receipt = try await api.performReviewMutation(mutation, context: context, account: account, token: token)
      XCTAssertEqual(receipt.id, "77")
      await expect(.readbackRequired) { _ = try await api.readReviewReceipt(receipt, mutation: mutation, context: context, account: account, token: token) }
    }
  }
  func testGithubIncompletePOSTReceiptKeepsIDForAuthoritativeReadback() async throws {
    let (api, fixture, account, binding, token) = try setup(), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/reviews", json: "{\"id\":77}", method: "POST")
    await fixture.override("/reviews/77", json: "{\"id\":77,\"user\":{\"id\":42},\"body\":\"summary\",\"state\":\"APPROVED\",\"commit_id\":\"\(sha)\"}")
    let mutation = HostingReviewMutation.review(summary: "summary", decision: .approve, comments: [], pending: false)
    let receipt = try await api.performReviewMutation(mutation, context: context, account: account, token: token)
    XCTAssertEqual(receipt.id, "77"); XCTAssertEqual(receipt.authorID, ""); XCTAssertEqual(receipt.state, .unknown); XCTAssertEqual(receipt.commitSHA, "")
    let verified = try await api.readReviewReceipt(receipt, mutation: mutation, context: context, account: account, token: token)
    XCTAssertEqual(verified.state, .approved); XCTAssertEqual(verified.commitSHA, sha); XCTAssertEqual(verified.authorID, "42")
  }
  func testGithubPOSTWithWrongAuthorRetainsReceiptButCannotVerify() async throws {
    let (api, fixture, account, binding, token) = try setup(), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/issues/7/comments", json: "{\"id\":77,\"user\":{\"id\":43},\"body\":\"saved\"}", method: "POST")
    await fixture.override("/issues/7/comments", json: "[{\"id\":77,\"user\":{\"id\":43},\"body\":\"saved\"}]")
    let mutation = HostingReviewMutation.comment(body: "saved"), receipt = try await api.performReviewMutation(mutation, context: context, account: account, token: token)
    XCTAssertEqual(receipt.id, "77")
    await expect(.readbackRequired) { _ = try await api.readReviewReceipt(receipt, mutation: mutation, context: context, account: account, token: token) }
  }
  func testGithubInvalidPOSTReceiptIDRemainsUnknownAfterSendingOnce() async throws {
    let (api, fixture, account, binding, token) = try setup(), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/issues/7/comments", json: "{\"id\":\"../77\",\"user\":{\"id\":42}}", method: "POST")
    await expect(.resultUnknown) { _ = try await api.performReviewMutation(.comment(body: "saved"), context: context, account: account, token: token) }
    let requests = await fixture.captured(); XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
  }
  func testGithubPendingSubmissionReadbackRequiresConfirmedDecision() async throws {
    let (api, fixture, account, binding, token) = try setup(), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    await fixture.override("/reviews/77", json: "{\"id\":77,\"user\":{\"id\":42},\"body\":\"summary\",\"state\":\"COMMENTED\",\"commit_id\":\"\(sha)\"}")
    let receipt = HostingReviewReceipt(id: "77", state: .commented, authorID: "42", commitSHA: sha)
    await expect(.readbackRequired) { _ = try await api.readReviewReceipt(receipt, mutation: .submitPending(reviewID: "77", summary: "summary", decision: .approve), context: context, account: account, token: token) }
  }
  func testCommentReadbackRejectsReusedRepositoryPathOrRequestNumber() async throws {
    for provider in HostingProvider.allCases {
      for field in ["repository", "request"] {
        let (api, fixture, account, binding, token) = try setup(provider), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
        if field == "repository" { await fixture.override("/owner/repo", json: "{\"id\":101}"); await fixture.override("/projects/owner/repo", json: "{\"id\":101}") }
        else { await fixture.override(provider == .gitlab ? "/merge_requests/7" : "/pulls/7", json: "{\"id\":201,\"number\":7,\"iid\":7,\"target_project_id\":100,\"base\":{\"repo\":{\"id\":100}}}") }
        await expect(.targetChanged) { _ = try await api.readReviewReceipt(HostingReviewReceipt(id: "77", authorID: "42"), mutation: .comment(body: "saved"), context: context, account: account, token: token) }
        let requests = await fixture.captured(); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
      }
    }
  }
  func testGitlabReplyReadbackCannotUseAnotherReceiptThread() async throws {
    let (api, _, account, binding, token) = try setup(.gitlab), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    let receipt = HostingReviewReceipt(id: "77", threadID: "anotherThread", authorID: "42")
    await expect(.readbackRequired) { _ = try await api.readReviewReceipt(receipt, mutation: .reply(threadID: "expectedThread", commentID: "5", body: "saved"), context: context, account: account, token: token) }
  }
  func testGitlabUnresolveReadbackRequiresExplicitBooleanAndResolvableRoot() async throws {
    for fields in ["\"resolvable\":true", "\"resolved\":false", "\"resolvable\":true,\"resolved\":\"false\""] {
      let (api, fixture, account, binding, token) = try setup(.gitlab), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
      await fixture.override("/discussions/threadA", json: "{\"id\":\"threadA\",\"notes\":[{\"id\":77,\(fields)}]}")
      let receipt = HostingReviewReceipt(id: "threadA", threadID: "threadA", authorID: "42")
      await expect(.readbackRequired) { _ = try await api.readReviewReceipt(receipt, mutation: .resolve(threadID: "threadA", resolved: false), context: context, account: account, token: token) }
    }
  }


  private func recoveredRecord(_ context: HostingReviewContext, mutation: HostingReviewMutation, receipt: HostingReviewReceipt? = nil) throws -> HostingReviewOperationRecord {
    let item = HostingReviewSubmissionItem(mutation: mutation), confirmation = try HostingReviewConfirmation(context: context, items: [item])
    var record = HostingReviewOperationRecord(confirmation: confirmation, item: item, now: Date())
    record.update(.resultUnknown, receipt: receipt); return record
  }
  func testRecoveredCommentReadsKnownIDWithoutBodyOrChangingUnknownState() async throws {
    for provider in [HostingProvider.github, .gitea] {
      let (api, fixture, account, binding, token) = try setup(provider), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
      await fixture.override("/issues/7/comments", json: "[{\"id\":77,\"user\":{\"id\":42},\"body\":\"not stored in journal\"}]")
      let record = try recoveredRecord(context, mutation: .comment(body: "private draft absent after restart"), receipt: HostingReviewReceipt(id: "77", authorID: ""))
      let value = try await api.readRecoveredReviewReceipt(record: record, context: context, account: account, token: token)
      XCTAssertEqual(value.id, "77"); XCTAssertEqual(value.authorID, "42"); XCTAssertEqual(record.state, .resultUnknown)
      let requests = await fixture.captured(); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
      let data = try JSONEncoder().encode(record); XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private draft"))
    }
  }
  func testRecoveredOperationWithoutReceiptRefusesNetworkOrResend() async throws {
    let (api, fixture, account, binding, token) = try setup(), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    let record = try recoveredRecord(context, mutation: .comment(body: "unknown")), count = await fixture.captured().count
    await expect(.readbackRequired) { _ = try await api.readRecoveredReviewReceipt(record: record, context: context, account: account, token: token) }
    let after = await fixture.captured().count; XCTAssertEqual(after, count)
  }
  func testRecoveredReceiptRejectsDifferentAccountAndRevisionBeforeNetwork() async throws {
    let (api, fixture, account, binding, token) = try setup(), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    let record = try recoveredRecord(context, mutation: .comment(body: "unknown"), receipt: HostingReviewReceipt(id: "77", authorID: "42"))
    let target = context.target
    let another = HostingReviewContext(target: HostingReviewTarget(instance: target.instance, accountID: UUID(), userID: target.userID, repository: target.repository, repositoryID: target.repositoryID, requestNumber: target.requestNumber, requestID: target.requestID), revision: context.revision, capabilities: context.capabilities, state: context.state, authorID: context.authorID)
    let changed = HostingReviewContext(target: target, revision: HostingReviewRevision(headSHA: String(repeating: "d", count: 40)), capabilities: context.capabilities, state: context.state, authorID: context.authorID)
    let count = await fixture.captured().count
    await expect(.targetChanged) { _ = try await api.readRecoveredReviewReceipt(record: record, context: another, account: account, token: token) }
    await expect(.revisionChanged) { _ = try await api.readRecoveredReviewReceipt(record: record, context: changed, account: account, token: token) }
    let after = await fixture.captured().count; XCTAssertEqual(after, count)
  }
  func testRecoveredReviewRequiresConfirmedStateAndCurrentFullSHA() async throws {
    for state in ["COMMENTED", "APPROVED"] {
      let (api, fixture, account, binding, token) = try setup(), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
      let record = try recoveredRecord(context, mutation: .review(summary: "not persisted", decision: .approve, comments: [], pending: false), receipt: HostingReviewReceipt(id: "77", authorID: ""))
      await fixture.override("/reviews/77", json: "{\"id\":77,\"user\":{\"id\":42},\"state\":\"\(state)\",\"commit_id\":\"\(sha)\"}")
      if state == "APPROVED" {
        let value = try await api.readRecoveredReviewReceipt(record: record, context: context, account: account, token: token)
        XCTAssertEqual(value.state, .approved); XCTAssertEqual(record.state, .resultUnknown)
      } else {
        await expect(.readbackRequired) { _ = try await api.readRecoveredReviewReceipt(record: record, context: context, account: account, token: token) }
      }
      let requests = await fixture.captured(); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }
  }
  func testRecoveredReceiptCannotReuseContextAfterServerHeadChanges() async throws {
    let (api, fixture, account, binding, token) = try setup(), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    let record = try recoveredRecord(context, mutation: .comment(body: "unknown"), receipt: HostingReviewReceipt(id: "77", authorID: "42"))
    await fixture.configure(head: String(repeating: "d", count: 40))
    await expect(.revisionChanged) { _ = try await api.readRecoveredReviewReceipt(record: record, context: context, account: account, token: token) }
  }
  func testRecoveredGitlabInlineRequiresAllThreeSHAsWithoutInventingAnchor() async throws {
    for base in [String(repeating: "b", count: 40), String(repeating: "d", count: 40)] {
      let (api, fixture, account, binding, token) = try setup(.gitlab), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
      let record = try recoveredRecord(context, mutation: .inline(body: "not persisted", anchor: anchor(context, side: .new, kind: .addition)), receipt: HostingReviewReceipt(id: "77", threadID: "threadA", authorID: "42"))
      await fixture.override("/discussions/threadA", json: "{\"id\":\"threadA\",\"notes\":[{\"id\":77,\"author\":{\"id\":42},\"position\":{\"head_sha\":\"\(sha)\",\"base_sha\":\"\(base)\",\"start_sha\":\"\(context.revision.startSHA)\"}}]}")
      if base == context.revision.baseSHA {
        let value = try await api.readRecoveredReviewReceipt(record: record, context: context, account: account, token: token)
        XCTAssertEqual(value.commitSHA, sha); XCTAssertEqual(record.state, .resultUnknown)
      } else { await expect(.readbackRequired) { _ = try await api.readRecoveredReviewReceipt(record: record, context: context, account: account, token: token) } }
    }
  }
  func testGiteaReplyReadbackRequiresParentFileAndSideCoordinates() async throws {
    for (path, position, oldPosition, valid) in [("A.swift", 5, 0, true), ("Other.swift", 5, 0, false), ("A.swift", 6, 0, false), ("A.swift", 0, 5, false), ("A.swift", 5, 5, false)] {
      let (api, fixture, account, binding, token) = try setup(.gitea), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
      await fixture.override("/reviews/8/comments", json: "[{\"id\":5,\"pull_request_review_id\":8,\"path\":\"A.swift\",\"position\":5,\"original_position\":0},{\"id\":77,\"pull_request_review_id\":8,\"user\":{\"id\":42},\"body\":\"saved\",\"path\":\"\(path)\",\"position\":\(position),\"original_position\":\(oldPosition)}]")
      let mutation = HostingReviewMutation.reply(threadID: "8", commentID: "5", body: "saved"), receipt = HostingReviewReceipt(id: "77", authorID: "42")
      let record = try recoveredRecord(context, mutation: mutation, receipt: receipt)
      if valid {
        let full = try await api.readReviewReceipt(receipt, mutation: mutation, context: context, account: account, token: token)
        let metadata = try await api.readRecoveredReviewReceipt(record: record, context: context, account: account, token: token)
        XCTAssertEqual(full.id, "77"); XCTAssertEqual(metadata.id, "77")
      } else {
        await expect(.readbackRequired) { _ = try await api.readReviewReceipt(receipt, mutation: mutation, context: context, account: account, token: token) }
        await expect(.readbackRequired) { _ = try await api.readRecoveredReviewReceipt(record: record, context: context, account: account, token: token) }
      }
    }
  }


  func testRecoveredReviewerRequestRequiresTheEntireKnownSet() async throws {
    for ids in [[500, 501], [501]] {
      let (api, fixture, account, binding, token) = try setup(), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
      let selection = HostingReviewerSelection(context: context, reviewers: [HostingReviewer(id: "501", login: "user501")])
      let receipt = HostingReviewReceipt(id: context.target.requestID, authorID: "42", commitSHA: sha, requestedReviewerIDs: ["500", "501"])
      let record = try recoveredRecord(context, mutation: .requestReviewers(selection), receipt: receipt)
      await fixture.requested(ids)
      if ids.count == 2 {
        let result = try await api.readRecoveredReviewReceipt(record: record, context: context, account: account, token: token)
        XCTAssertEqual(result.requestedReviewerIDs, ["500", "501"]); XCTAssertEqual(record.state, .resultUnknown)
      } else { await expect(.readbackRequired) { _ = try await api.readRecoveredReviewReceipt(record: record, context: context, account: account, token: token) } }
      let requests = await fixture.captured(); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }
  }


  func testGithubReviewUpdatedAfterPOSTCannotVerifyOldReceipt() async throws {
    let (api, fixture, account, binding, token) = try setup(), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    let mutation = HostingReviewMutation.review(summary: "saved", decision: .approve, comments: [], pending: false)
    let receipt = try await api.performReviewMutation(mutation, context: context, account: account, token: token)
    await fixture.override("/reviews/77", json: "{\"id\":77,\"user\":{\"id\":42},\"body\":\"saved\",\"state\":\"APPROVED\",\"commit_id\":\"\(sha)\"}")
    await fixture.configure(head: String(repeating: "d", count: 40))
    await expect(.revisionChanged) { _ = try await api.readReviewReceipt(receipt, mutation: mutation, context: context, account: account, token: token) }
    XCTAssertEqual(receipt.id, "77"); let requests = await fixture.captured(); XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
  }
  func testInlineUpdatedAfterPOSTCannotVerifyOldAnchor() async throws {
    for provider in [HostingProvider.github, .gitlab] {
      let (api, fixture, account, binding, token) = try setup(provider), context = try await api.reviewContext(binding, number: 7, account: account, token: token)
      let anchor = try anchor(context, side: .new, kind: .addition), mutation = HostingReviewMutation.inline(body: "saved", anchor: anchor)
      let receipt: HostingReviewReceipt
      if provider == .github {
        await fixture.override("/pulls/comments/77", json: "{\"id\":77,\"user\":{\"id\":42},\"body\":\"saved\",\"path\":\"A.swift\",\"side\":\"RIGHT\",\"line\":5,\"commit_id\":\"\(sha)\",\"pull_request_url\":\"https://api.github.com/repos/owner/repo/pulls/7\"}")
        receipt = HostingReviewReceipt(id: "77", authorID: "42", commitSHA: sha)
      } else {
        let position = "\"position_type\":\"text\",\"head_sha\":\"\(sha)\",\"base_sha\":\"\(context.revision.baseSHA)\",\"start_sha\":\"\(context.revision.startSHA)\",\"old_path\":\"A.swift\",\"new_path\":\"A.swift\",\"new_line\":5"
        await fixture.override("/discussions/threadA", json: "{\"id\":\"threadA\",\"notes\":[{\"id\":77,\"author\":{\"id\":42},\"body\":\"saved\",\"position\":{\(position)}}]}")
        receipt = HostingReviewReceipt(id: "77", threadID: "threadA", authorID: "42", commitSHA: sha)
      }
      await fixture.configure(head: String(repeating: "d", count: 40))
      await expect(.revisionChanged) { _ = try await api.readReviewReceipt(receipt, mutation: mutation, context: context, account: account, token: token) }
      let requests = await fixture.captured(); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }
  }

}
