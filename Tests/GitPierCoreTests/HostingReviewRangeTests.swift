import Foundation
import XCTest
@testable import GitPierCore

private actor RangeReviewTransport: HostingTransport {
  let sha = String(repeating: "a", count: 40)
  var comment: [String: HostingJSON] = [:]
  var wrongStart = false
  func changeStartSide() { wrongStart = true }
  func send(_ request: URLRequest, limit: Int) async throws -> HostingHTTPResponse {
    let path = request.url!.path
    let value: HostingJSON
    if request.httpMethod == "POST" {
      guard case .object(var fields) = try HostingJSON.decode(request.httpBody!) else { throw HostingError.invalidResponse }
      fields["id"] = .integer(77); fields["user"] = .object(["id": .integer(42)])
      fields["pull_request_url"] = .string("https://api.github.com/repos/owner/repo/pulls/7")
      comment = fields; value = .object(fields)
    } else if path.hasSuffix("/owner/repo") { value = .object(["id": .integer(100)]) }
    else if path.hasSuffix("/pulls/7") {
      value = .object(["id": .integer(200), "number": .integer(7), "state": .string("open"),
        "head": .object(["sha": .string(sha)]), "base": .object(["sha": .string(String(repeating: "b", count: 40)), "repo": .object(["id": .integer(100)])]),
        "user": .object(["id": .integer(99)])])
    } else if path.hasSuffix("/pulls/comments/77") {
      var fields = comment; if wrongStart { fields["start_side"] = .string("LEFT") }; value = .object(fields)
    } else if path.hasSuffix("/reviews") || path.hasSuffix("/comments") { value = .array([]) }
    else { throw HostingError.notFound }
    return HostingHTTPResponse(data: try JSONEncoder().encode(value))
  }
}
@MainActor final class HostingReviewRangeTests: XCTestCase {
  private let patch = "@@ -1,2 +1,4 @@\n context\n+new one\n+new two\n end\n"
  private func context(_ provider: HostingProvider = .github, capabilities: Set<HostingReviewCapability> = [.inlineComment, .multiLineComment]) throws -> HostingReviewContext {
    HostingReviewContext(target: HostingReviewTarget(instance: try HostingInstance(provider: provider, url: provider == .github ? "https://github.com" : "https://forge.example.invalid"),
      accountID: UUID(), userID: "42", repository: "owner/repo", repositoryID: "100", requestNumber: 7, requestID: "200"),
      revision: HostingReviewRevision(headSHA: String(repeating: "a", count: 40), baseSHA: String(repeating: "b", count: 40), startSHA: String(repeating: "c", count: 40), diffID: "10"),
      capabilities: capabilities, state: "open", authorID: "99")
  }
  private func range(_ context: HostingReviewContext, patch: String? = nil, start: Int = 1, end: Int = 2, side: HostingReviewSide = .new) throws -> HostingDiffAnchor {
    let text = patch ?? self.patch
    return try HostingDiffAnchor.makeRange(context: context, file: HostingChangedFile(path: "A.swift", kind: "modified", patch: text),
      document: DiffParser.parse(Data(text.utf8)), startLineID: start, endLineID: end, side: side)
  }
  func testRangeRetainsActualNewCoordinatesAndSelectedCode() throws {
    let anchor = try range(context())
    XCTAssertEqual(anchor.startLine, 2); XCTAssertEqual(anchor.newLine, 3); XCTAssertEqual(anchor.rangeCode, "new one\nnew two")
  }
  func testDeletedRangeUsesOldCoordinates() throws {
    let anchor = try range(context(), patch: "@@ -1,4 +1,2 @@\n context\n-old one\n-old two\n end\n", side: .old)
    XCTAssertEqual(anchor.startLine, 2); XCTAssertEqual(anchor.oldLine, 3); XCTAssertNil(anchor.newLine)
  }
  func testRangeCannotCrossHunks() throws {
    XCTAssertThrowsError(try range(context(), patch: "@@ -1 +1 @@\n-a\n+b\n@@ -4 +4 @@\n-c\n+d\n", start: 1, end: 4))
  }
  func testRangeCannotReverseOrUseOneLine() throws {
    XCTAssertThrowsError(try range(context(), start: 2, end: 1)); XCTAssertThrowsError(try range(context(), start: 1, end: 1))
  }
  func testRangeCannotUseUnavailableSide() throws { XCTAssertThrowsError(try range(context(), side: .old)) }
  func testRangeCannotExceedTwoHundredActualLines() throws {
    let patch = "@@ -0,0 +1,201 @@\n" + (1...201).map { "+row \($0)\n" }.joined()
    XCTAssertThrowsError(try range(context(), patch: patch, start: 0, end: 200))
  }
  func testRangeCannotBeEnabledOnUnverifiedProviders() throws {
    XCTAssertThrowsError(try range(context(.gitlab))); XCTAssertThrowsError(try range(context(.gitea)))
  }
  func testRangeRequiresExplicitCapability() throws { XCTAssertThrowsError(try range(context(capabilities: [.inlineComment]))) }
  func testRangeValidationRebuildsExactRangeFromFreshPatch() throws {
    let context = try context(), anchor = try range(context), file = HostingChangedFile(path: "A.swift", kind: "modified", patch: patch)
    XCTAssertNoThrow(try anchor.validate(context: context, file: file, document: DiffParser.parse(Data(patch.utf8))))
    let changed = patch.replacingOccurrences(of: "+new one", with: "+changed")
    XCTAssertThrowsError(try anchor.validate(context: context, file: HostingChangedFile(path: "A.swift", kind: "modified", patch: changed), document: DiffParser.parse(Data(changed.utf8))))
  }
  func testRangePreservesCRLFCode() throws {
    XCTAssertEqual(try range(context(), patch: patch.replacingOccurrences(of: "\n", with: "\r\n")).rangeCode, "new one\r\nnew two\r")
  }
  func testRangePOSTUsesStartLineAndSideAndVerifiesReadback() async throws {
    let transport = RangeReviewTransport(), api = HostingAPIClient(http: HostingHTTPClient(transport: transport))
    let account = HostingAccount(instance: try HostingInstance(provider: .github, url: "https://github.com"), user: HostingUser(stableID: "42", login: "reviewer"), kind: .pat, scopes: [])
    let binding = try RepositoryHostingBinding(repositoryID: UUID(), accountID: account.id, remote: "origin", repository: "owner/repo"), token = HostingToken(accessToken: "synthetic-range-only")
    let context = try await api.reviewContext(binding, number: 7, account: account, token: token), anchor = try range(context)
    let mutation = HostingReviewMutation.inline(body: "range", anchor: anchor), receipt = try await api.performReviewMutation(mutation, context: context, account: account, token: token)
    let result = try await api.readReviewReceipt(receipt, mutation: mutation, context: context, account: account, token: token)
    XCTAssertEqual(result.id, "77"); let fields = await transport.comment
    XCTAssertEqual(fields["start_line"]?.int, 2); XCTAssertEqual(fields["start_side"]?.string, "RIGHT"); XCTAssertNil(fields["position"])
    await transport.changeStartSide()
    do { _ = try await api.readReviewReceipt(receipt, mutation: mutation, context: context, account: account, token: token); XCTFail("Wrong range accepted") }
    catch { XCTAssertEqual(error as? HostingReviewError, .readbackRequired) }
  }
}
