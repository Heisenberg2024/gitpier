import XCTest
@testable import GitPierCore

@MainActor final class HostingApprovalRulesTests: XCTestCase {
  private func setup(_ json: String, status: Int = 200, provider: HostingProvider = .gitlab) throws -> (HostingAPIClient, HostingFixtureTransport, HostingAccount, RepositoryHostingBinding, HostingToken) {
    let instance = try HostingInstance(provider: provider, url: provider == .github ? "https://github.com" : "https://forge.example.invalid")
    let account = HostingAccount(instance: instance, user: HostingUser(stableID: "42", login: "reader"), kind: .pat, scopes: [])
    let binding = try RepositoryHostingBinding(repositoryID: UUID(), accountID: account.id, remote: "origin", repository: "group/project")
    let transport = HostingFixtureTransport([HostingHTTPResponse(data: Data(json.utf8), status: status)])
    let api = HostingAPIClient(http: HostingHTTPClient(transport: transport, sleep: { _ in try Task.checkCancellation() }))
    return (api, transport, account, binding, HostingToken(accessToken: "fixture-approval-rules-only"))
  }
  private func rule(_ extra: String = "", id: Int = 1, required: String = "2", approved: String = "true") -> String {
    "{\"id\":\(id),\"name\":\"Code Owners\",\"rule_type\":\"code_owner\",\"approvals_required\":\(required),\"approved\":\(approved)\(extra)}"
  }
  private func expect(_ expected: HostingError, _ json: String) async throws {
    let (api, _, account, binding, token) = try setup(json)
    do { _ = try await api.approvalRules(binding, number: 7, account: account, token: token); XCTFail("Expected \(expected)") }
    catch let error as HostingError { XCTAssertEqual(error, expected) }
  }
  func testReadsNativeApprovalStateAndStableRuleFields() async throws {
    let (api, transport, account, binding, token) = try setup("{\"approval_rules_overwritten\":true,\"rules\":[\(rule())]}")
    let value = try await api.approvalRules(binding, number: 7, account: account, token: token)
    XCTAssertEqual(value.availability, .available); XCTAssertEqual(value.rules.first?.id, "1"); XCTAssertEqual(value.rules.first?.name, "Code Owners")
    XCTAssertEqual(value.rules.first?.ruleType, "code_owner"); XCTAssertEqual(value.rules.first?.approvalsRequired, 2); XCTAssertEqual(value.rules.first?.approved, true); XCTAssertEqual(value.rulesOverwritten, true)
    let requests = await transport.captured(); XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests.first?.httpMethod, "GET"); XCTAssertTrue(requests.first!.url!.path.hasSuffix("/merge_requests/7/approval_state"))
  }
  func testApprovedByContainsOnlyRuleUsersWithoutImplyingCurrentUserApproval() async throws {
    let extra = ",\"approved_by\":[{\"id\":8,\"username\":\"rule-approver\",\"name\":\"Approver\"}]"
    let (api, _, account, binding, token) = try setup("{\"rules\":[\(rule(extra))]}")
    let value = try await api.approvalRules(binding, number: 7, account: account, token: token)
    XCTAssertEqual(value.rules.first?.approvedBy?.map(\.stableID), ["8"]); XCTAssertFalse(value.rules.first?.approvedBy?.contains(where: { $0.stableID == account.user.stableID }) == true)
  }
  func testRuleApprovalUsesServerDecisionInsteadOfComparingUserCount() async throws {
    let extra = ",\"approved_by\":[{\"id\":8,\"username\":\"one\"},{\"id\":9,\"username\":\"two\"}]"
    let (api, _, account, binding, token) = try setup("{\"rules\":[\(rule(extra, required: "1", approved: "false"))]}")
    let value = try await api.approvalRules(binding, number: 7, account: account, token: token); XCTAssertEqual(value.rules.first?.approved, false)
  }
  func testMissingApproverListRemainsUnknownRatherThanEmpty() async throws {
    let (api, _, account, binding, token) = try setup("{\"rules\":[\(rule())]}")
    let value = try await api.approvalRules(binding, number: 7, account: account, token: token); XCTAssertNil(value.rules.first?.approvedBy); XCTAssertNil(value.rules.first?.eligibleApprovers)
  }
  func testExplicitEmptyApproverListIsPreserved() async throws {
    let (api, _, account, binding, token) = try setup("{\"rules\":[\(rule(",\"approved_by\":[]"))]}")
    let value = try await api.approvalRules(binding, number: 7, account: account, token: token); XCTAssertEqual(value.rules.first?.approvedBy?.count, 0)
  }
  func testEligibleApproversAndHiddenGroupsAreSeparateFromApprovedUsers() async throws {
    let extra = ",\"eligible_approvers\":[{\"id\":9,\"username\":\"eligible\"}],\"contains_hidden_groups\":true,\"overridden\":false"
    let (api, _, account, binding, token) = try setup("{\"rules\":[\(rule(extra))]}")
    let value = try await api.approvalRules(binding, number: 7, account: account, token: token)
    XCTAssertEqual(value.rules.first?.eligibleApprovers?.map(\.stableID), ["9"]); XCTAssertNil(value.rules.first?.approvedBy)
    XCTAssertEqual(value.rules.first?.containsHiddenGroups, true); XCTAssertEqual(value.rules.first?.overridden, false)
  }
  func testPermissionDeniedIsExplicitlyUnavailableNotZeroRulesSuccess() async throws {
    let (api, _, account, binding, token) = try setup("{}", status: 403)
    let value = try await api.approvalRules(binding, number: 7, account: account, token: token); XCTAssertEqual(value.availability, .permissionRequired); XCTAssertTrue(value.rules.isEmpty); XCTAssertNil(value.rulesOverwritten)
  }
  func testEditionVersionOrVisibilityNotFoundIsUnavailable() async throws {
    let (api, _, account, binding, token) = try setup("{}", status: 404)
    let value = try await api.approvalRules(binding, number: 7, account: account, token: token); XCTAssertEqual(value.availability, .unavailable); XCTAssertTrue(value.rules.isEmpty)
  }
  func testVerifiedEmptyRulesAreDifferentFromUnavailableRules() async throws {
    let (api, _, account, binding, token) = try setup("{\"rules\":[]}")
    let value = try await api.approvalRules(binding, number: 7, account: account, token: token); XCTAssertEqual(value.availability, .available); XCTAssertTrue(value.rules.isEmpty); XCTAssertNil(value.rulesOverwritten)
  }
  func testUnauthorizedRemainsAuthenticationFailure() async throws {
    let (api, _, account, binding, token) = try setup("{}", status: 401)
    do { _ = try await api.approvalRules(binding, number: 7, account: account, token: token); XCTFail("Unauthorized returned rules") }
    catch let error as HostingError { XCTAssertEqual(error, .unauthorized) }
  }
  func testMissingRulesDoesNotBecomeAnEmptyApprovedState() async throws { try await expect(.invalidResponse, "{}") }
  func testNegativeApprovalRequirementIsRejected() async throws { try await expect(.invalidResponse, "{\"rules\":[\(rule(required: "-1"))]}") }
  func testStringApprovalRequirementIsRejected() async throws { try await expect(.invalidResponse, "{\"rules\":[\(rule(required: "\"2\""))]}") }
  func testStringApprovalDecisionIsRejected() async throws { try await expect(.invalidResponse, "{\"rules\":[\(rule(approved: "\"true\""))]}") }
  func testDuplicateRuleStableIDsAreRejected() async throws { try await expect(.invalidResponse, "{\"rules\":[\(rule()),\(rule())]}") }
  func testMalformedApproverIdentityIsRejected() async throws { try await expect(.invalidResponse, "{\"rules\":[\(rule(",\"approved_by\":[{\"username\":\"missing-id\"}]"))]}") }
  func testUnknownRuleTypeIsPreservedForForwardCompatibility() async throws {
    let json = "{\"rules\":[\(rule().replacingOccurrences(of: "code_owner", with: "future_policy"))]}"
    let (api, _, account, binding, token) = try setup(json)
    let value = try await api.approvalRules(binding, number: 7, account: account, token: token); XCTAssertEqual(value.rules.first?.ruleType, "future_policy")
  }
  func testWrongAccountIsRejectedBeforeNetwork() async throws {
    let (api, transport, account, _, token) = try setup("{\"rules\":[]}")
    let binding = try RepositoryHostingBinding(repositoryID: UUID(), accountID: UUID(), remote: "origin", repository: "group/project")
    do { _ = try await api.approvalRules(binding, number: 7, account: account, token: token); XCTFail("Foreign account accepted") }
    catch let error as HostingReviewError { XCTAssertEqual(error, .targetChanged) }
    let requests = await transport.captured(); XCTAssertTrue(requests.isEmpty)
  }
  func testNonGitlabProviderIsRejectedBeforeNetwork() async throws {
    let (api, transport, account, binding, token) = try setup("{\"rules\":[]}", provider: .github)
    do { _ = try await api.approvalRules(binding, number: 7, account: account, token: token); XCTFail("Invented GitHub rules") }
    catch let error as HostingError { XCTAssertEqual(error, .unsupported) }
    let requests = await transport.captured(); XCTAssertTrue(requests.isEmpty)
  }
  func testZeroApprovalRuleStillUsesServerApprovedField() async throws {
    let (api, _, account, binding, token) = try setup("{\"rules\":[\(rule(required: "0", approved: "false"))]}")
    let value = try await api.approvalRules(binding, number: 7, account: account, token: token); XCTAssertEqual(value.rules.first?.approvalsRequired, 0); XCTAssertEqual(value.rules.first?.approved, false)
  }
}
