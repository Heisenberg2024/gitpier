import Foundation
import XCTest
@testable import GitPierCore

private enum ReviewFixture {
  static let sha = String(repeating: "a", count: 40)
  static let patch = "@@ -1,2 +1,2 @@\n-old\n+new\n context\n"
  static func context(_ provider: HostingProvider = .github, account: UUID = UUID(), head: String = sha,
    repository: String = "owner/repo", request: String = "42", author: String = "other",
    capabilities: Set<HostingReviewCapability> = Set(HostingReviewCapability.allCases)) throws -> HostingReviewContext {
    let instance = try HostingInstance(provider: provider, url: provider == .github ? "https://github.com" : "https://code.example")
    return HostingReviewContext(target: HostingReviewTarget(instance: instance, accountID: account, userID: "viewer",
      repository: repository, repositoryID: "r1", requestNumber: 7, requestID: request),
      revision: HostingReviewRevision(headSHA: head, baseSHA: String(repeating: "b", count: 40),
        startSHA: String(repeating: "c", count: 40), diffID: "v1"), capabilities: capabilities, state: "open", authorID: author)
  }
  static func file(_ patch: String = patch, kind: String = "modified", oldPath: String = "") -> HostingChangedFile {
    HostingChangedFile(path: "file.swift", oldPath: oldPath, kind: kind, patch: patch)
  }
  static func anchor(_ context: HostingReviewContext, patch: String = patch, line: Int = 1, side: HostingReviewSide = .new,
    kind: String = "modified", oldPath: String = "") throws -> HostingDiffAnchor {
    try HostingDiffAnchor.make(context: context, file: file(patch, kind: kind, oldPath: oldPath),
      document: DiffParser.parse(Data(patch.utf8)), lineID: line, side: side)
  }
  static func receipt(_ context: HostingReviewContext, id: String = "100", state: HostingReviewState = .commented) -> HostingReviewReceipt {
    HostingReviewReceipt(id: id, state: state, authorID: context.target.userID, commitSHA: context.revision.headSHA)
  }
  static func confirmation(_ context: HostingReviewContext, mutations: [HostingReviewMutation] = [.comment(body: "hello")]) throws -> HostingReviewConfirmation {
    try HostingReviewConfirmation(context: context, items: mutations.map { HostingReviewSubmissionItem(mutation: $0) })
  }
}
private actor ReviewDriver {
  let context: HostingReviewContext
  var sendCount = 0
  var reads = 0
  var currentCount = 0
  var rejectValidation = false
  init(_ context: HostingReviewContext) { self.context = context }
  func current() -> HostingReviewContext { currentCount += 1; return context }
  func validate() throws { if rejectValidation { throw HostingError.accountChanged } }
  func stop() { rejectValidation = true }
  func send(_ mutation: HostingReviewMutation, _ context: HostingReviewContext) -> HostingReviewReceipt {
    sendCount += 1; return ReviewFixture.receipt(context, id: String(sendCount))
  }
  func read(_ receipt: HostingReviewReceipt, _ mutation: HostingReviewMutation, _ context: HostingReviewContext) -> HostingReviewReceipt { reads += 1; return receipt }
  func counts() -> (Int, Int, Int) { (sendCount, reads, currentCount) }
}

@MainActor final class HostingReviewSafetyTests: XCTestCase {
  func testDeletedLineUsesOldCoordinates() throws {
    let anchor = try ReviewFixture.anchor(ReviewFixture.context(), line: 0, side: .old)
    XCTAssertEqual(anchor.oldLine, 1); XCTAssertNil(anchor.newLine); XCTAssertEqual(anchor.side, .old)
  }
  func testAddedLineUsesNewCoordinates() throws {
    let anchor = try ReviewFixture.anchor(ReviewFixture.context())
    XCTAssertEqual(anchor.newLine, 1); XCTAssertNil(anchor.oldLine); XCTAssertEqual(anchor.code, "new")
  }
  func testContextPreservesBothCoordinatesAndChosenSide() throws {
    let context = try ReviewFixture.context(.gitlab)
    let old = try ReviewFixture.anchor(context, line: 2, side: .old), new = try ReviewFixture.anchor(context, line: 2)
    XCTAssertEqual(old.oldLine, 2); XCTAssertEqual(old.newLine, 2); XCTAssertNotEqual(old, new)
  }
  func testDeletedLineCannotUseNewSide() throws { XCTAssertThrowsError(try ReviewFixture.anchor(ReviewFixture.context(), line: 0)) }
  func testAddedLineCannotUseOldSide() throws { XCTAssertThrowsError(try ReviewFixture.anchor(ReviewFixture.context(), side: .old)) }
  func testHunkHeaderCannotBecomeComment() throws { XCTAssertThrowsError(try ReviewFixture.anchor(ReviewFixture.context(), line: 3)) }
  func testMalformedHunkHasNoAnchor() throws {
    XCTAssertThrowsError(try ReviewFixture.anchor(ReviewFixture.context(), patch: "@@ -1,4 +1,2 @@\n-a\n+b\n"))
  }
  func testBinaryFileHasNoAnchor() throws { XCTAssertThrowsError(try ReviewFixture.anchor(ReviewFixture.context(), patch: "Binary files a/file and b/file differ\n")) }
  func testOversizedPatchHasNoAnchor() throws {
    let patch = "@@ -1 +1 @@\n-" + String(repeating: "x", count: 1024 * 1024) + "\n+new\n"
    XCTAssertThrowsError(try ReviewFixture.anchor(ReviewFixture.context(), patch: patch))
  }
  func testMissingPatchHasNoAnchor() throws {
    XCTAssertThrowsError(try HostingDiffAnchor.make(context: ReviewFixture.context(), file: HostingChangedFile(path: "file.swift", kind: "modified", patch: nil),
      document: DiffParser.parse(Data(ReviewFixture.patch.utf8)), lineID: 1, side: .new))
  }
  func testCRLFContentPreserved() throws {
    let anchor = try ReviewFixture.anchor(ReviewFixture.context(), patch: "@@ -1 +1 @@\r\n-old\r\n+new\r\n")
    XCTAssertEqual(anchor.code, "new\r"); XCTAssertEqual(anchor.newLine, 1)
  }
  func testNoNewlineMarkerDoesNotShiftPosition() throws {
    let anchor = try ReviewFixture.anchor(ReviewFixture.context(), patch: "@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n")
    XCTAssertEqual(anchor.newLine, 1)
  }
  func testAddedFileStartsAtOne() throws {
    let anchor = try ReviewFixture.anchor(ReviewFixture.context(), patch: "@@ -0,0 +1 @@\n+new\n", line: 0, kind: "added")
    XCTAssertNil(anchor.oldLine); XCTAssertEqual(anchor.newLine, 1)
  }
  func testDeletedFileStartsAtOne() throws {
    let anchor = try ReviewFixture.anchor(ReviewFixture.context(), patch: "@@ -1 +0,0 @@\n-old\n", line: 0, side: .old, kind: "removed")
    XCTAssertEqual(anchor.oldLine, 1); XCTAssertNil(anchor.newLine)
  }
  func testRenameCarriesBothPaths() throws {
    let anchor = try ReviewFixture.anchor(ReviewFixture.context(), kind: "renamed", oldPath: "before.swift")
    XCTAssertEqual(anchor.oldPath, "before.swift"); XCTAssertEqual(anchor.newPath, "file.swift")
  }
  func testUnsafeModeMetadataDisablesInlineComments() throws {
    XCTAssertThrowsError(try ReviewFixture.anchor(ReviewFixture.context(), patch: "old mode 100644\nnew mode 120000\n" + ReviewFixture.patch))
  }
  func testMultipleHunksUseFileLineNumbers() throws {
    let patch = "@@ -1 +1 @@\n-a\n+b\n@@ -80 +81 @@\n-x\n+y\n"
    let context = try ReviewFixture.context(), anchor = try ReviewFixture.anchor(context, patch: patch, line: 4)
    XCTAssertEqual(anchor.newLine, 81); XCTAssertNotEqual(anchor.hunkID, try ReviewFixture.anchor(context, patch: patch).hunkID)
  }
  func testFileDocumentMismatchRejected() throws {
    XCTAssertThrowsError(try HostingDiffAnchor.make(context: ReviewFixture.context(), file: ReviewFixture.file(),
      document: DiffParser.parse(Data(ReviewFixture.patch.replacingOccurrences(of: "+new", with: "+other").utf8)), lineID: 1, side: .new))
  }
  func testOverlappingHunksCannotCreateAmbiguousAnchor() throws {
    XCTAssertThrowsError(try ReviewFixture.anchor(ReviewFixture.context(), patch: "@@ -1 +1 @@\n-a\n+b\n@@ -1 +1 @@\n-c\n+d\n"))
  }
  func testReversedHunksCannotCreateAnchor() throws {
    XCTAssertThrowsError(try ReviewFixture.anchor(ReviewFixture.context(), patch: "@@ -50 +50 @@\n-a\n+b\n@@ -1 +1 @@\n-c\n+d\n"))
  }
  func testIgnoredMalformedBodyCannotCreateAnchor() throws {
    XCTAssertThrowsError(try ReviewFixture.anchor(ReviewFixture.context(), patch: "@@ -1 +1 @@\n-a\ninvalid protocol row\n+b\n"))
  }
  func testSecondFileInOnePatchCannotCreateAnchor() throws {
    XCTAssertThrowsError(try ReviewFixture.anchor(ReviewFixture.context(), patch: "@@ -1 +1 @@\n-a\n+b\ndiff --git a/other b/other\n@@ -5 +5 @@\n-c\n+d\n"))
  }
  func testAnchorValidationRejectsChangedPatchEvenWithSameLineNumbers() throws {
    let context = try ReviewFixture.context(), anchor = try ReviewFixture.anchor(context)
    let file = ReviewFixture.file(ReviewFixture.patch.replacingOccurrences(of: "+new", with: "+newer"))
    XCTAssertThrowsError(try anchor.validate(context: context, file: file, document: DiffParser.parse(Data(file.patch!.utf8))))
  }
  func testGitLabMissingVersionTripleDisablesAnchor() throws {
    let old = try ReviewFixture.context(.gitlab)
    let context = HostingReviewContext(target: old.target, revision: HostingReviewRevision(headSHA: ReviewFixture.sha), capabilities: old.capabilities, state: "open", authorID: "other")
    XCTAssertThrowsError(try ReviewFixture.anchor(context))
  }
  func testSHAValidationRejectsAbbreviationsAndNonHex() {
    XCTAssertFalse(HostingReviewRevision.isSHA("abc123")); XCTAssertFalse(HostingReviewRevision.isSHA(String(repeating: "z", count: 40)))
    XCTAssertTrue(HostingReviewRevision.isSHA(String(repeating: "b", count: 64)))
  }
  func testReviewStatesAreProviderSpecific() {
    XCTAssertEqual(HostingReviewState(provider: .gitea, value: "REQUEST_CHANGES"), .changesRequested)
    XCTAssertEqual(HostingReviewState(provider: .gitlab, value: "REQUEST_CHANGES"), .unknown)
    XCTAssertEqual(HostingReviewState(provider: .github, value: "CHANGES_REQUESTED"), .changesRequested)
    XCTAssertEqual(HostingReviewState(provider: .gitea, value: "PENDING"), .pending)
  }
  func testGiteaIssueScopeExpansionRequiresSeparateExplicitLevel() {
    XCTAssertEqual(HostingAuthorizationLevel.read.scopes(for: .gitea), ["read:user", "read:repository"])
    XCTAssertEqual(HostingAuthorizationLevel.publicWrite.scopes(for: .gitea), ["read:user", "write:repository"])
    XCTAssertEqual(HostingAuthorizationLevel.privateWrite.scopes(for: .gitea), ["read:user", "write:repository"])
    XCTAssertEqual(HostingAuthorizationLevel.reviewCollaboration.scopes(for: .gitea), ["read:user", "write:repository", "write:issue"])
  }
  func testGiteaReviewScopeOptionCannotRequestBroadAccessOnOtherProviders() {
    XCTAssertTrue(HostingAuthorizationLevel.reviewCollaboration.scopes(for: .github).isEmpty)
    XCTAssertTrue(HostingAuthorizationLevel.reviewCollaboration.scopes(for: .gitlab).isEmpty)
  }
  func testCommentsDeduplicateOnlyStableIDs() {
    let first = HostingReviewComment(id: "1", authorID: "u", author: "user", body: "same", kind: .inline)
    let second = HostingReviewComment(id: "2", authorID: "u", author: "user", body: "same", kind: .inline)
    var thread = HostingReviewThread(id: "t", remoteID: "1", source: .inline, comments: [first])
    thread.append([first, second]); XCTAssertEqual(thread.comments.count, 2)
  }
  func testGitLabDraftCreatesIndependentDiscussionAndApprovalActions() throws {
    let context = try ReviewFixture.context(.gitlab), anchor = try ReviewFixture.anchor(context)
    let draft = HostingReviewDraft(context: context, summary: "summary", decision: .approve, comments: [HostingReviewDraftComment(body: "line", anchor: anchor)])
    let confirmation = try HostingReviewConfirmation.draft(draft)
    XCTAssertEqual(confirmation.items.count, 3)
    guard case .inline = confirmation.items[0].mutation, case .comment = confirmation.items[1].mutation,
      case .review(_, .approve, _, false) = confirmation.items[2].mutation else { return XCTFail("Wrong platform semantics") }
  }
  func testGitLabDoesNotInventRequestChanges() throws {
    XCTAssertThrowsError(try HostingReviewConfirmation.draft(HostingReviewDraft(context: ReviewFixture.context(.gitlab), summary: "change", decision: .requestChanges)))
  }
  func testSelfApprovalIsRejected() throws {
    XCTAssertThrowsError(try ReviewFixture.confirmation(ReviewFixture.context(author: "viewer"), mutations: [.review(summary: "", decision: .approve, comments: [], pending: false)]))
  }
  func testBlankAndOversizedCommentRejected() throws {
    let context = try ReviewFixture.context()
    XCTAssertThrowsError(try ReviewFixture.confirmation(context, mutations: [.comment(body: " \n")]))
    XCTAssertThrowsError(try ReviewFixture.confirmation(context, mutations: [.comment(body: String(repeating: "中", count: 20_001))]))
  }
  func testPermissionCannotBeBypassedByConstructingMutation() throws {
    XCTAssertThrowsError(try ReviewFixture.confirmation(ReviewFixture.context(capabilities: [])))
  }
  func testConfirmationIsImmutableSnapshotOfDraft() throws {
    var draft = HostingReviewDraft(context: try ReviewFixture.context(), summary: "before")
    let confirmation = try HostingReviewConfirmation.draft(draft); draft.summary = "after"
    guard case .review(let body, _, _, _) = confirmation.items[0].mutation else { return XCTFail() }; XCTAssertEqual(body, "before")
  }
  func testCrossAccountAnchorRejectedBeforeSubmission() throws {
    let context = try ReviewFixture.context(), other = try ReviewFixture.context()
    XCTAssertThrowsError(try ReviewFixture.confirmation(context, mutations: [.inline(body: "line", anchor: ReviewFixture.anchor(other))]))
  }
  func testWrongRequestAnchorRejectedBeforeSubmission() throws {
    let context = try ReviewFixture.context(), other = try ReviewFixture.context(account: context.target.accountID, request: "other")
    XCTAssertThrowsError(try ReviewFixture.confirmation(context, mutations: [.inline(body: "line", anchor: ReviewFixture.anchor(other))]))
  }
  func testForkRepositoryCannotReuseAnchor() throws {
    let context = try ReviewFixture.context(), other = try ReviewFixture.context(account: context.target.accountID, repository: "fork/repo")
    XCTAssertThrowsError(try ReviewFixture.confirmation(context, mutations: [.inline(body: "line", anchor: ReviewFixture.anchor(other))]))
  }
  func testConfirmedCommentReadsBackStableReceipt() async throws {
    let context = try ReviewFixture.context(), driver = ReviewDriver(context), coordinator = HostingReviewSubmissionCoordinator()
    let report = try await coordinator.submit(ReviewFixture.confirmation(context), current: { await driver.current() }, validate: {}, validateAnchor: { _ in },
      send: { await driver.send($0, $1) }, readback: { await driver.read($0, $1, $2) })
    XCTAssertTrue(report.complete); let counts = await driver.counts(); XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1); XCTAssertEqual(counts.2, 2)
  }
  func testSameConfirmationNeverSendsTwice() async throws {
    let context = try ReviewFixture.context(), driver = ReviewDriver(context), coordinator = HostingReviewSubmissionCoordinator(), confirmation = try ReviewFixture.confirmation(context)
    for _ in 0..<2 {
      _ = try await coordinator.submit(confirmation, current: { await driver.current() }, validate: {}, validateAnchor: { _ in }, send: { await driver.send($0, $1) }, readback: { await driver.read($0, $1, $2) })
    }
    let counts = await driver.counts(); XCTAssertEqual(counts.0, 1)
  }
  func testChangedHeadStopsBeforePOST() async throws {
    let context = try ReviewFixture.context(), changed = try ReviewFixture.context(account: context.target.accountID, head: String(repeating: "d", count: 40)), driver = ReviewDriver(context)
    let report = try await HostingReviewSubmissionCoordinator().submit(ReviewFixture.confirmation(context), current: { changed }, validate: {}, validateAnchor: { _ in },
      send: { await driver.send($0, $1) }, readback: { await driver.read($0, $1, $2) })
    XCTAssertFalse(report.complete); XCTAssertFalse(report.hasUnknown); let counts = await driver.counts(); XCTAssertEqual(counts.0, 0)
  }
  func testDisconnectStopsBeforePOST() async throws {
    let context = try ReviewFixture.context(), driver = ReviewDriver(context)
    let report = try await HostingReviewSubmissionCoordinator().submit(ReviewFixture.confirmation(context), current: { context }, validate: { throw HostingError.accountChanged }, validateAnchor: { _ in },
      send: { await driver.send($0, $1) }, readback: { await driver.read($0, $1, $2) })
    XCTAssertFalse(report.hasUnknown); let counts = await driver.counts(); XCTAssertEqual(counts.0, 0)
  }
  func testTimeoutProducesUnknownAndBlocksNewTicket() async throws {
    let context = try ReviewFixture.context(), coordinator = HostingReviewSubmissionCoordinator()
    let report = try await coordinator.submit(ReviewFixture.confirmation(context), current: { context }, validate: {}, validateAnchor: { _ in },
      send: { _, _ in throw HostingError.networkFailure }, readback: { receipt, _, _ in receipt })
    XCTAssertTrue(report.hasUnknown)
    do { _ = try await coordinator.submit(ReviewFixture.confirmation(context), current: { context }, validate: {}, validateAnchor: { _ in },
      send: { _, _ in XCTFail("Must not resend"); throw HostingError.networkFailure }, readback: { receipt, _, _ in receipt }); XCTFail("Must block") }
    catch { XCTAssertEqual(error as? HostingReviewError, .resultUnknown) }
  }
  func testCancelledSendIsUnknown() async throws {
    let context = try ReviewFixture.context()
    let report = try await HostingReviewSubmissionCoordinator().submit(ReviewFixture.confirmation(context), current: { context }, validate: {}, validateAnchor: { _ in },
      send: { _, _ in throw CancellationError() }, readback: { receipt, _, _ in receipt })
    XCTAssertTrue(report.hasUnknown)
  }
  func testExplicit403IsFailureAndDoesNotBlockTarget() async throws {
    let context = try ReviewFixture.context(), coordinator = HostingReviewSubmissionCoordinator()
    let report = try await coordinator.submit(ReviewFixture.confirmation(context), current: { context }, validate: {}, validateAnchor: { _ in },
      send: { _, _ in throw HostingError.permissionRequired }, readback: { receipt, _, _ in receipt })
    XCTAssertFalse(report.hasUnknown); let blocked = await coordinator.isBlocked(context.target); XCTAssertFalse(blocked)
  }
  func testReadbackFailureRetainsReceiptForReconciliation() async throws {
    let context = try ReviewFixture.context(), coordinator = HostingReviewSubmissionCoordinator(), confirmation = try ReviewFixture.confirmation(context)
    let report = try await coordinator.submit(confirmation, current: { context }, validate: {}, validateAnchor: { _ in },
      send: { _, context in ReviewFixture.receipt(context) }, readback: { _, _, _ in throw HostingError.networkFailure })
    XCTAssertTrue(report.hasUnknown)
    let reconciled = try await coordinator.reconcile(confirmation.id, validate: {}, readback: { receipt, _, _ in receipt })
    XCTAssertTrue(reconciled.complete)
  }
  func testUnknownWithoutServerIDCannotBeResolvedByBodyMatching() async throws {
    let context = try ReviewFixture.context(), coordinator = HostingReviewSubmissionCoordinator(), confirmation = try ReviewFixture.confirmation(context)
    _ = try await coordinator.submit(confirmation, current: { context }, validate: {}, validateAnchor: { _ in },
      send: { _, _ in throw HostingError.networkFailure }, readback: { receipt, _, _ in receipt })
    let report = try await coordinator.reconcile(confirmation.id, validate: {}, readback: { receipt, _, _ in XCTFail("No stable ID to query"); return receipt })
    XCTAssertTrue(report.hasUnknown)
  }
  func testWrongAuthorInReadbackCannotBecomeSuccess() async throws {
    let context = try ReviewFixture.context()
    let report = try await HostingReviewSubmissionCoordinator().submit(ReviewFixture.confirmation(context), current: { context }, validate: {}, validateAnchor: { _ in },
      send: { _, context in ReviewFixture.receipt(context) }, readback: { receipt, _, _ in HostingReviewReceipt(id: receipt.id, authorID: "other") })
    XCTAssertTrue(report.hasUnknown); XCTAssertFalse(report.complete)
  }
  func testWrongApprovalSHAInReadbackCannotBecomeSuccess() async throws {
    let context = try ReviewFixture.context()
    let confirmation = try ReviewFixture.confirmation(context, mutations: [.review(summary: "", decision: .approve, comments: [], pending: false)])
    let report = try await HostingReviewSubmissionCoordinator().submit(confirmation, current: { context }, validate: {}, validateAnchor: { _ in },
      send: { _, context in ReviewFixture.receipt(context, state: .approved) }, readback: { receipt, _, context in HostingReviewReceipt(id: receipt.id, state: .approved, authorID: context.target.userID, commitSHA: String(repeating: "e", count: 40)) })
    XCTAssertTrue(report.hasUnknown)
  }
  func testPartialBatchRecordsPublishedAndUnsentIndependently() async throws {
    let context = try ReviewFixture.context(.gitlab), driver = ReviewDriver(context)
    let confirmation = try ReviewFixture.confirmation(context, mutations: [.comment(body: "one"), .comment(body: "two"), .comment(body: "three")])
    let report = try await HostingReviewSubmissionCoordinator().submit(confirmation, current: { context }, validate: {}, validateAnchor: { _ in },
      send: { mutation, context in if mutation == .comment(body: "two") { throw HostingError.permissionRequired }; return await driver.send(mutation, context) }, readback: { receipt, _, _ in receipt })
    XCTAssertEqual(report.submittedCount, 1); XCTAssertEqual(report.results[2].outcome, .notSent); XCTAssertFalse(report.complete)
  }
  func testAnchorRevalidationOccursBeforeSend() async throws {
    let context = try ReviewFixture.context(), driver = ReviewDriver(context)
    let confirmation = try ReviewFixture.confirmation(context, mutations: [.inline(body: "comment", anchor: ReviewFixture.anchor(context))])
    let report = try await HostingReviewSubmissionCoordinator().submit(confirmation, current: { context }, validate: {}, validateAnchor: { _ in throw HostingReviewError.unanchorable },
      send: { await driver.send($0, $1) }, readback: { receipt, _, _ in receipt })
    XCTAssertFalse(report.complete); let counts = await driver.counts(); XCTAssertEqual(counts.0, 0)
  }
}
