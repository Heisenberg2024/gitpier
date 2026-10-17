import XCTest
@testable import GitPierCore

private actor ReviewerFixture: HostingTransport {
  let provider: HostingProvider
  var requests: [URLRequest] = []
  var requested = ["77"]
  var head = String(repeating: "a", count: 40)
  var base = String(repeating: "b", count: 40)
  var memberID = "10"
  var memberLogin = "reviewer10"
  var memberAccess = 30
  var memberState = "active"
  var postStatus = 200
  var partial = false
  var applyThenFail = false
  var changeDuringMembership = false
  var candidateHeaders: [String: String] = [:]
  var invalidTargetOnFinalRead = false
  var requestReads = 0
  var diffRefsHead: String?
  var readbackRace: String?
  init(_ provider: HostingProvider) { self.provider = provider }
  func configure(requested: [String]? = nil, memberID: String? = nil, memberLogin: String? = nil, memberAccess: Int? = nil,
    memberState: String? = nil, postStatus: Int? = nil, partial: Bool = false, applyThenFail: Bool = false, changeDuringMembership: Bool = false, headers: [String: String] = [:]) {
    if let requested { self.requested = requested }; if let memberID { self.memberID = memberID }; if let memberLogin { self.memberLogin = memberLogin }
    if let memberAccess { self.memberAccess = memberAccess }; if let memberState { self.memberState = memberState }; if let postStatus { self.postStatus = postStatus }
    self.partial = partial; self.applyThenFail = applyThenFail; self.changeDuringMembership = changeDuringMembership; candidateHeaders = headers
  }
  func moveHead() { head = String(repeating: "d", count: 40) }
  func moveBase() { base = String(repeating: "e", count: 40) }
  func clearBase() { base = "" }
  func changeTargetOnFinalRead() { invalidTargetOnFinalRead = true }
  func invalidateDiffRefs() { diffRefsHead = "invalid" }
  func raceFinalReadback(_ field: String) { readbackRace = field }
  func captured() -> [URLRequest] { requests }
  private func user(_ id: String, login: String? = nil, access: Int = 30, state: String = "active") -> [String: Any] {
    ["id": Int(id) ?? 0, "login": login ?? "reviewer" + id, "username": login ?? "reviewer" + id,
      "name": "Synthetic Reviewer " + id, "state": state, "access_level": access,
      "permissions": ["push": access >= 30, "pull": true]]
  }
  private func response(_ value: Any, status: Int = 200, headers: [String: String] = [:]) throws -> HostingHTTPResponse {
    HostingHTTPResponse(data: try JSONSerialization.data(withJSONObject: value), status: status, headers: headers)
  }
  func send(_ request: URLRequest, limit: Int) async throws -> HostingHTTPResponse {
    requests.append(request)
    let path = request.url!.path, method = request.httpMethod ?? "GET"
    if method != "GET" {
      let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data("{}".utf8)) as? [String: Any] ?? [:]
      if postStatus < 300 || applyThenFail || partial {
        if provider == .gitlab { requested = (body["reviewer_ids"] as? [Int] ?? []).map(String.init) }
        else {
          let logins = body["reviewers"] as? [String] ?? []
          for login in partial ? Array(logins.prefix(1)) : logins {
            let id = String(login.dropFirst("reviewer".count))
            if !requested.contains(id) { requested.append(id) }
          }
        }
      }
      return try response(["id": 200], status: postStatus)
    }
    if path.hasSuffix("/version") { return try response(["version": "1.27.3"]) }
    if path.hasSuffix("/versions") { return try response([["id": 5, "head_commit_sha": head, "base_commit_sha": base, "start_commit_sha": String(repeating: "c", count: 40)]]) }
    if path.hasSuffix("/approvals") { return try response(["approved_by": [], "user_can_approve": false, "user_has_approved": false]) }
    if path.hasSuffix("/permission") || path.contains("/members/all/") {
      let member = user(memberID, login: memberLogin, access: memberAccess, state: memberState)
      if changeDuringMembership { head = String(repeating: "d", count: 40) }
      return try response(provider == .gitlab ? member : ["user": member, "permission": memberAccess >= 30 ? "write" : "read"])
    }
    if path.hasSuffix("/collaborators") || path.hasSuffix("/members/all") || path.hasSuffix("/reviewers") {
      let values = provider == .gitea ? [user(memberID, login: memberLogin), user("12")] : [user(memberID, login: memberLogin, access: memberAccess, state: memberState), user("11", access: 20), user("99")]
      return try response(values, headers: candidateHeaders)
    }
    if path.hasSuffix("/requested_reviewers") { return try response(["users": requested.map { user($0) }, "teams": [["id": 900, "slug": "untouched-team"]]]) }
    if path.hasSuffix("/pulls/7") || path.hasSuffix("/merge_requests/7") {
      requestReads += 1
      if requestReads == 6 && readbackRace == "head" { head = String(repeating: "d", count: 40) }
      if requestReads == 6 && readbackRace == "base" { base = String(repeating: "e", count: 40) }
      let repositoryID = invalidTargetOnFinalRead && requestReads >= 4 || requestReads == 6 && readbackRace == "repository" ? 101 : 100
      let requestID = requestReads == 6 && readbackRace == "request" ? 201 : 200
      return try response(["id": requestID, "number": 7, "iid": 7, "title": "Synthetic review", "state": "open", "user": ["id": 99], "author": ["id": 99],
        "target_project_id": repositoryID, "sha": head, "head": ["sha": head], "base": ["sha": base, "repo": ["id": repositoryID]],
        "diff_refs": ["head_sha": diffRefsHead ?? head, "base_sha": base, "start_sha": String(repeating: "c", count: 40)],
        "requested_reviewers": requested.map { user($0) }, "reviewers": requested.map { user($0) }])
    }
    if path.hasSuffix("/owner/repo") { return try response(["id": 100, "private": false, "permissions": ["push": true, "admin": true]]) }
    throw HostingError.invalidResponse
  }
}

@MainActor final class HostingReviewersTests: XCTestCase {
  private let chosen = HostingReviewer(id: "10", login: "reviewer10", name: "Selected")
  private func setup(_ provider: HostingProvider = .github) async throws -> (HostingAPIClient, ReviewerFixture, HostingAccount, RepositoryHostingBinding, HostingToken, HostingReviewContext) {
    let instance = try HostingInstance(provider: provider, url: provider == .github ? "https://github.com" : "https://forge.example.invalid")
    let scopes = provider == .github ? ["repo", "read:org"] : provider == .gitlab ? ["api"] : ["write:repository"]
    let account = HostingAccount(instance: instance, user: HostingUser(stableID: "42", login: "actor"), kind: .oauth, scopes: scopes)
    let binding = try RepositoryHostingBinding(repositoryID: UUID(), accountID: account.id, remote: "origin", repository: "owner/repo")
    let fixture = ReviewerFixture(provider), token = HostingToken(accessToken: "fixture-reviewers-only", scopes: scopes)
    let api = HostingAPIClient(http: HostingHTTPClient(transport: fixture, sleep: { _ in try Task.checkCancellation() }))
    let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
    return (api, fixture, account, binding, token, context)
  }
  private func expect(_ error: HostingReviewError, _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await operation(); XCTFail("Expected \(error)", file: file, line: line) } catch let value as HostingReviewError { XCTAssertEqual(value, error, file: file, line: line) } catch { XCTFail("Unexpected \(error)", file: file, line: line) }
  }
  private func writes(_ fixture: ReviewerFixture) async -> [URLRequest] { await fixture.captured().filter { $0.httpMethod != "GET" } }
  private func lastWrite(_ fixture: ReviewerFixture) async throws -> URLRequest { let values = await writes(fixture); return try XCTUnwrap(values.last) }
  private func json(_ request: URLRequest) throws -> HostingJSON { try HostingJSON.decode(try XCTUnwrap(request.httpBody)) }
  private func withReviewerCapability(_ context: HostingReviewContext) -> HostingReviewContext {
    HostingReviewContext(target: context.target, revision: context.revision, capabilities: context.capabilities.union([.requestReviewers]),
      state: context.state, authorID: context.authorID, webURL: context.webURL, permissionExplanation: context.permissionExplanation)
  }
  func testGithubCandidatesUseRepositoryCollaboratorsAndWritePermission() async throws {
    let (api, fixture, account, binding, token, context) = try await setup()
    let result = try await api.reviewerCandidates(binding, context: context, account: account, token: token)
    XCTAssertEqual(result.items.map(\.id), ["10"])
    let requests = await fixture.captured(); XCTAssertTrue(requests.last!.url!.path.hasSuffix("/collaborators"))
  }
  func testGitlabCandidatesUseActiveDeveloperMembersRatherThanApprovers() async throws {
    let (api, fixture, account, binding, token, context) = try await setup(.gitlab)
    let result = try await api.reviewerCandidates(binding, context: withReviewerCapability(context), account: account, token: token)
    XCTAssertEqual(result.items.map(\.id), ["10"])
    let requests = await fixture.captured(); XCTAssertTrue(requests.last!.url!.path.hasSuffix("/members/all"))
  }
  func testGiteaCandidatesUseNativeEligibleReviewersEndpoint() async throws {
    let (api, fixture, account, binding, token, context) = try await setup(.gitea)
    let result = try await api.reviewerCandidates(binding, context: context, account: account, token: token)
    XCTAssertEqual(result.items.map(\.id), ["10", "12"])
    let requests = await fixture.captured(); XCTAssertTrue(requests.last!.url!.path.hasSuffix("/reviewers"))
  }
  func testCandidatePaginationFetchesOnlyRequestedPageAndDoesNotFollowForeignLink() async throws {
    let (api, fixture, account, binding, token, context) = try await setup()
    await fixture.configure(headers: ["link": "<https://foreign.invalid/users?page=4>; rel=\"next\""])
    let result = try await api.reviewerCandidates(binding, context: context, account: account, token: token, page: 3)
    XCTAssertEqual(result.nextPage, 4)
    let requests = await fixture.captured(), request = try XCTUnwrap(requests.last), query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
    XCTAssertEqual(request.url?.host, "api.github.com"); XCTAssertEqual(query?.first(where: { $0.name == "page" })?.value, "3")
  }
  func testGiteaDoesNotPretendUnpaginatedEndpointHasPageTwo() async throws {
    let (api, fixture, account, binding, token, context) = try await setup(.gitea); let before = await fixture.captured().count
    let result = try await api.reviewerCandidates(binding, context: context, account: account, token: token, page: 2)
    let after = await fixture.captured().count; XCTAssertTrue(result.items.isEmpty); XCTAssertNil(result.nextPage); XCTAssertEqual(before, after)
  }
  func testGitlabInactiveMemberIsNotOfferedAsCandidate() async throws {
    let (api, fixture, account, binding, token, context) = try await setup(.gitlab); await fixture.configure(memberState: "blocked")
    let result = try await api.reviewerCandidates(binding, context: withReviewerCapability(context), account: account, token: token); XCTAssertTrue(result.items.isEmpty)
  }
  func testRequestedGithubUsersDoNotTurnTeamsIntoUserSelections() async throws {
    let (api, _, account, binding, token, _) = try await setup()
    let result = try await api.requestedReviewers(binding, number: 7, account: account, token: token); XCTAssertEqual(result.items.map(\.id), ["77"])
  }
  func testRequestedGitlabUsersComeFromMRReviewers() async throws {
    let (api, _, account, binding, token, _) = try await setup(.gitlab)
    let result = try await api.requestedReviewers(binding, number: 7, account: account, token: token); XCTAssertEqual(result.items.map(\.id), ["77"])
  }
  func testRequestedGiteaUsersComeFromPRRequestedReviewers() async throws {
    let (api, _, account, binding, token, _) = try await setup(.gitea)
    let result = try await api.requestedReviewers(binding, number: 7, account: account, token: token); XCTAssertEqual(result.items.map(\.id), ["77"])
  }
  func testEmptyReviewerSelectionIsRejectedBeforeSending() async throws {
    let (api, fixture, account, _, token, context) = try await setup()
    await expect(.invalidBody) { _ = try await api.performReviewerRequest(HostingReviewerSelection(context: context, reviewers: []), context: context, account: account, token: token) }
    let writes = await writes(fixture); XCTAssertTrue(writes.isEmpty)
  }
  func testDuplicateStableIDsAreRejected() async throws {
    let (_, _, _, _, _, context) = try await setup()
    XCTAssertThrowsError(try HostingReviewerSelection(context: context, reviewers: [chosen, HostingReviewer(id: "10", login: "other")]).validate(context: context))
  }
  func testCaseInsensitiveDuplicateLoginsAreRejected() async throws {
    let (_, _, _, _, _, context) = try await setup()
    XCTAssertThrowsError(try HostingReviewerSelection(context: context, reviewers: [chosen, HostingReviewer(id: "11", login: "REVIEWER10")]).validate(context: context))
  }
  func testReviewerLimitIsFifteenUsersPerConfirmation() async throws {
    let (_, _, _, _, _, context) = try await setup()
    let values = (1...16).map { HostingReviewer(id: String($0), login: "person" + String($0)) }
    XCTAssertThrowsError(try HostingReviewerSelection(context: context, reviewers: values).validate(context: context))
  }
  func testPullRequestAuthorCannotBeRequestedToReviewOwnChange() async throws {
    let (_, _, _, _, _, context) = try await setup()
    do { try HostingReviewerSelection(context: context, reviewers: [HostingReviewer(id: "99", login: "author")]).validate(context: context); XCTFail("Author accepted") }
    catch let error as HostingReviewError { XCTAssertEqual(error, .selfReview) }
  }
  func testReviewerLoginCannotInjectPathOrControlCharacters() async throws {
    let (_, _, _, _, _, context) = try await setup()
    for login in ["a/b", "a\\b", "a\nb", "a b"] {
      XCTAssertThrowsError(try HostingReviewerSelection(context: context, reviewers: [HostingReviewer(id: "10", login: login)]).validate(context: context))
    }
  }
  func testReviewerStableIDMustBePositiveCanonicalNumber() async throws {
    let (_, _, _, _, _, context) = try await setup()
    for id in ["0", "-1", "010", "user", "10/11"] {
      XCTAssertThrowsError(try HostingReviewerSelection(context: context, reviewers: [HostingReviewer(id: id, login: "person")]).validate(context: context))
    }
  }
  func testGithubRequestUsesNativePostAndReviewerLoginsOnly() async throws {
    let (api, fixture, account, _, token, context) = try await setup()
    let selection = HostingReviewerSelection(context: context, reviewers: [chosen])
    let receipt = try await api.performReviewerRequest(selection, context: context, account: account, token: token)
    let write = try await lastWrite(fixture), body = try json(write)
    XCTAssertTrue(write.url!.path.hasSuffix("/pulls/7/requested_reviewers")); XCTAssertEqual(write.httpMethod, "POST"); XCTAssertEqual(body["reviewers"].array.map(\.string), ["reviewer10"])
    XCTAssertTrue(body["team_reviewers"].array.isEmpty); XCTAssertEqual(receipt.requestedReviewerIDs, ["10", "77"])
    let verified = try await api.readReviewerRequest(receipt, selection: selection, context: context, account: account, token: token); XCTAssertEqual(verified.requestedReviewerIDs, ["10", "77"])
  }
  func testGiteaRequestUsesNativePostWithoutChangingIssueAssignments() async throws {
    let (api, fixture, account, _, token, context) = try await setup(.gitea)
    let receipt = try await api.performReviewerRequest(HostingReviewerSelection(context: context, reviewers: [chosen]), context: context, account: account, token: token)
    let write = try await lastWrite(fixture), body = try json(write)
    XCTAssertTrue(write.url!.path.hasSuffix("/pulls/7/requested_reviewers")); XCTAssertEqual(body["reviewers"].array.map(\.string), ["reviewer10"]); XCTAssertEqual(receipt.id, "200")
  }
  func testGitlabWriteIsBrowserOnlyEvenWhenCapabilityIsForged() async throws {
    let (api, fixture, account, _, token, context) = try await setup(.gitlab)
    let forged = withReviewerCapability(context), before = await fixture.captured().count
    let selection = HostingReviewerSelection(context: forged, reviewers: [chosen], existingReviewers: [HostingReviewer(id: "77", login: "reviewer77")])
    await fixture.configure(requested: ["77", "88"])
    await expect(.unsupported) { _ = try await api.performReviewerRequest(selection, context: forged, account: account, token: token) }
    let after = await fixture.captured().count, values = await writes(fixture); XCTAssertEqual(before, after); XCTAssertTrue(values.isEmpty)
  }
  func testGitlabReviewerListChangesRemainReadOnly() async throws {
    let (api, fixture, account, binding, token, _) = try await setup(.gitlab)
    await fixture.configure(requested: ["88"])
    let current = try await api.requestedReviewers(binding, number: 7, account: account, token: token)
    XCTAssertEqual(current.items.map(\.id), ["88"]); let values = await writes(fixture); XCTAssertTrue(values.isEmpty)
  }
  func testAlreadyRequestedSelectionDoesNotSendAnotherNotification() async throws {
    let (api, fixture, account, _, token, context) = try await setup(); await fixture.configure(requested: ["10", "77"])
    await expect(.alreadySubmitted) { _ = try await api.performReviewerRequest(HostingReviewerSelection(context: context, reviewers: [self.chosen]), context: context, account: account, token: token) }
    let writes = await writes(fixture); XCTAssertTrue(writes.isEmpty)
  }
  func testMemberStableIDChangeStopsBeforePost() async throws {
    let (api, fixture, account, _, token, context) = try await setup(); await fixture.configure(memberID: "11")
    await expect(.targetChanged) { _ = try await api.performReviewerRequest(HostingReviewerSelection(context: context, reviewers: [self.chosen]), context: context, account: account, token: token) }
    let writes = await writes(fixture); XCTAssertTrue(writes.isEmpty)
  }
  func testMemberRenameNeedsSelectionToBeRefreshed() async throws {
    let (api, fixture, account, _, token, context) = try await setup(); await fixture.configure(memberLogin: "renamed")
    await expect(.targetChanged) { _ = try await api.performReviewerRequest(HostingReviewerSelection(context: context, reviewers: [self.chosen]), context: context, account: account, token: token) }
  }
  func testGitlabContextNeverOffersReviewerWriteCapability() async throws {
    let (api, fixture, account, _, token, context) = try await setup(.gitlab)
    XCTAssertFalse(context.capabilities.contains(.requestReviewers))
    await expect(.unsupported) { _ = try await api.performReviewerRequest(HostingReviewerSelection(context: context, reviewers: [self.chosen]), context: context, account: account, token: token) }
    let values = await writes(fixture); XCTAssertTrue(values.isEmpty)
  }
  func testHeadChangedDuringMemberRevalidationStopsBeforeWrite() async throws {
    let (api, fixture, account, _, token, context) = try await setup(); await fixture.configure(changeDuringMembership: true)
    await expect(.revisionChanged) { _ = try await api.performReviewerRequest(HostingReviewerSelection(context: context, reviewers: [self.chosen]), context: context, account: account, token: token) }
    let writes = await writes(fixture); XCTAssertTrue(writes.isEmpty)
  }
  func testBaseChangedAtSameHeadStopsBeforeWrite() async throws {
    let (api, fixture, account, _, token, context) = try await setup(); await fixture.moveBase()
    await expect(.revisionChanged) { _ = try await api.performReviewerRequest(HostingReviewerSelection(context: context, reviewers: [self.chosen]), context: context, account: account, token: token) }
    let writes = await writes(fixture); XCTAssertTrue(writes.isEmpty)
  }
  func testAccountSwitchRejectsOldSelectionBeforeNetwork() async throws {
    let (api, fixture, account, _, token, context) = try await setup()
    let replacement = HostingAccount(instance: account.instance, user: account.user, kind: account.kind, scopes: account.scopes)
    let before = await fixture.captured().count
    await expect(.targetChanged) { _ = try await api.performReviewerRequest(HostingReviewerSelection(context: context, reviewers: [self.chosen]), context: context, account: replacement, token: token) }
    let after = await fixture.captured().count; XCTAssertEqual(before, after)
  }
  func testPermissionDenialDoesNotRetryRequestReviewersPost() async throws {
    let (api, fixture, account, _, token, context) = try await setup(); await fixture.configure(postStatus: 403)
    await expect(.permissionRequired) { _ = try await api.performReviewerRequest(HostingReviewerSelection(context: context, reviewers: [self.chosen]), context: context, account: account, token: token) }
    let writes = await writes(fixture); XCTAssertEqual(writes.count, 1)
  }
  func testGithubServerFailureCanOnlyReconcileThroughStableRequestedUserIDs() async throws {
    let (api, fixture, account, _, token, context) = try await setup(); await fixture.configure(postStatus: 503, applyThenFail: true)
    let selection = HostingReviewerSelection(context: context, reviewers: [chosen])
    let receipt = try await api.performReviewerRequest(selection, context: context, account: account, token: token)
    let verified = try await api.readReviewerRequest(receipt, selection: selection, context: context, account: account, token: token)
    XCTAssertTrue(verified.requestedReviewerIDs.contains("10")); let writes = await writes(fixture); XCTAssertEqual(writes.count, 1)
  }
  func testGithubServerFailureWithoutMutationRemainsUnverified() async throws {
    let (api, fixture, account, _, token, context) = try await setup(); await fixture.configure(postStatus: 503)
    let selection = HostingReviewerSelection(context: context, reviewers: [chosen])
    let receipt = try await api.performReviewerRequest(selection, context: context, account: account, token: token)
    await expect(.readbackRequired) { _ = try await api.readReviewerRequest(receipt, selection: selection, context: context, account: account, token: token) }
    let writes = await writes(fixture); XCTAssertEqual(writes.count, 1)
  }
  func testGiteaPartialMultiUserFailureRetainsKnownTargetReceiptAndDoesNotReplay() async throws {
    let (api, fixture, account, _, token, context) = try await setup(.gitea)
    await fixture.configure(postStatus: 422, partial: true)
    let selection = HostingReviewerSelection(context: context, reviewers: [chosen, HostingReviewer(id: "12", login: "reviewer12")])
    let receipt = try await api.performReviewerRequest(selection, context: context, account: account, token: token)
    await expect(.readbackRequired) { _ = try await api.readReviewerRequest(receipt, selection: selection, context: context, account: account, token: token) }
    XCTAssertEqual(receipt.id, "200"); XCTAssertEqual(Set(receipt.requestedReviewerIDs), Set(["10", "12", "77"])); let writes = await writes(fixture); XCTAssertEqual(writes.count, 1)
  }
  func testReadbackRejectsLossOfAnExistingReviewer() async throws {
    let (api, fixture, account, _, token, context) = try await setup(.gitea)
    let selection = HostingReviewerSelection(context: context, reviewers: [chosen]), receipt = try await api.performReviewerRequest(selection, context: context, account: account, token: token)
    await fixture.configure(requested: ["10"])
    await expect(.readbackRequired) { _ = try await api.readReviewerRequest(receipt, selection: selection, context: context, account: account, token: token) }
  }
  func testReadbackRejectsReceiptFromDifferentPullRequest() async throws {
    let (api, fixture, account, _, token, context) = try await setup()
    let receipt = HostingReviewReceipt(id: "201", authorID: "42", commitSHA: context.revision.headSHA, requestedReviewerIDs: ["10"])
    let before = await fixture.captured().count
    await expect(.readbackRequired) { _ = try await api.readReviewerRequest(receipt, selection: HostingReviewerSelection(context: context, reviewers: [self.chosen]), context: context, account: account, token: token) }
    let after = await fixture.captured().count; XCTAssertEqual(before, after)
  }
  func testReadbackRejectsNewHeadInsteadOfClaimingOriginalRequestWasVerified() async throws {
    let (api, fixture, account, _, token, context) = try await setup()
    let selection = HostingReviewerSelection(context: context, reviewers: [chosen]), receipt = try await api.performReviewerRequest(selection, context: context, account: account, token: token)
    await fixture.moveHead()
    await expect(.revisionChanged) { _ = try await api.readReviewerRequest(receipt, selection: selection, context: context, account: account, token: token) }
  }
  func testFinalSnapshotRejectsWrongTargetRepositoryAtSameHeadAndBase() async throws {
    for provider in [HostingProvider.github, .gitea] {
      let (api, fixture, account, _, token, context) = try await setup(provider); await fixture.changeTargetOnFinalRead()
      await expect(.targetChanged) { _ = try await api.performReviewerRequest(HostingReviewerSelection(context: context, reviewers: [self.chosen]), context: context, account: account, token: token) }
      let values = await writes(fixture); XCTAssertTrue(values.isEmpty)
    }
  }
  func testMissingBaseDisablesReviewerWriteCapability() async throws {
    for provider in [HostingProvider.github, .gitea] {
      let (api, fixture, account, binding, token, _) = try await setup(provider); await fixture.clearBase()
      let context = try await api.reviewContext(binding, number: 7, account: account, token: token)
      XCTAssertFalse(context.capabilities.contains(.requestReviewers))
      await expect(.permissionRequired) { _ = try await api.performReviewerRequest(HostingReviewerSelection(context: context, reviewers: [self.chosen]), context: context, account: account, token: token) }
    }
  }
  func testGitlabReadbackCannotPretendToVerifyUnsupportedReviewerWrite() async throws {
    let (api, fixture, account, _, token, context) = try await setup(.gitlab); await fixture.invalidateDiffRefs()
    let forged = withReviewerCapability(context), receipt = HostingReviewReceipt(id: "200", authorID: "42", commitSHA: context.revision.headSHA, requestedReviewerIDs: ["10", "77"])
    let before = await fixture.captured().count
    await expect(.unsupported) { _ = try await api.readReviewerRequest(receipt, selection: HostingReviewerSelection(context: forged, reviewers: [self.chosen]), context: forged, account: account, token: token) }
    let after = await fixture.captured().count; XCTAssertEqual(before, after)
  }
  func testFinalReadbackRejectsHeadChangedAfterContextRead() async throws {
    try await reviewerReadbackRace("head", expected: .revisionChanged)
  }
  func testFinalReadbackRejectsBaseChangedAfterContextRead() async throws {
    try await reviewerReadbackRace("base", expected: .revisionChanged)
  }
  func testFinalReadbackRejectsStableRequestIDChangedAfterContextRead() async throws {
    try await reviewerReadbackRace("request", expected: .targetChanged)
  }
  func testFinalReadbackRejectsRepositoryChangedAfterContextRead() async throws {
    try await reviewerReadbackRace("repository", expected: .targetChanged)
  }
  private func reviewerReadbackRace(_ field: String, expected: HostingReviewError) async throws {
    for provider in [HostingProvider.github, .gitea] {
      let (api, fixture, account, _, token, context) = try await setup(provider)
      let selection = HostingReviewerSelection(context: context, reviewers: [chosen])
      let receipt = try await api.performReviewerRequest(selection, context: context, account: account, token: token)
      await fixture.raceFinalReadback(field)
      await expect(expected) { _ = try await api.readReviewerRequest(receipt, selection: selection, context: context, account: account, token: token) }
      let values = await writes(fixture); XCTAssertEqual(values.count, 1)
    }
  }
}
