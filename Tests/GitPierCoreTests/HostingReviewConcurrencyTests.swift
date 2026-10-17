import XCTest
@testable import GitPierCore

/// Deliberately ignores cancellation so a test can release a genuinely late response.
private actor ReviewInterleaveGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var arrived = false
  private var released = false
  func suspend() async {
    arrived = true
    if released { return }
    await withCheckedContinuation { continuation = $0 }
  }
  func waiting() -> Bool { arrived }
  func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor ReviewInterleaveCounter {
  private var values: [String: Int] = [:]
  @discardableResult func add(_ key: String = "send") -> Int { values[key, default: 0] += 1; return values[key]! }
  func get(_ key: String = "send") -> Int { values[key, default: 0] }
}
private actor ReviewInterleaveIdentity {
  private var valid = true
  func disconnect() { valid = false }
  func validate() throws { if !valid { throw HostingError.accountChanged } }
}
private enum ReviewInterleaveFixture {
  static let sha = String(repeating: "a", count: 40)
  static func context(_ provider: HostingProvider = .github, accountID: UUID = UUID(), repository: String = "owner/repo",
    number: Int = 7, head: String = sha) throws -> HostingReviewContext {
    let instance = try HostingInstance(provider: provider, url: provider == .github ? "https://github.com" : "https://gitlab.example.invalid")
    return HostingReviewContext(target: HostingReviewTarget(instance: instance, accountID: accountID, userID: "42",
      repository: repository, repositoryID: "repo-" + repository, requestNumber: number, requestID: "request-\(number)"),
      revision: HostingReviewRevision(headSHA: head, baseSHA: String(repeating: "b", count: 40),
        startSHA: String(repeating: "c", count: 40), diffID: "version-1"),
      capabilities: Set(HostingReviewCapability.allCases), state: "open", authorID: "77")
  }
  static func confirmation(_ context: HostingReviewContext, id: UUID = UUID(), body: String = "synthetic comment") throws -> HostingReviewConfirmation {
    try HostingReviewConfirmation(id: id, context: context, items: [HostingReviewSubmissionItem(mutation: .comment(body: body))])
  }
  static func receipt(_ context: HostingReviewContext, id: String = "100") -> HostingReviewReceipt {
    HostingReviewReceipt(id: id, state: .commented, authorID: context.target.userID, commitSHA: context.revision.headSHA)
  }
  static func anchor(_ context: HostingReviewContext) throws -> HostingDiffAnchor {
    let patch = "@@ -1 +1 @@\n-old\n+new\n"
    return try HostingDiffAnchor.make(context: context, file: HostingChangedFile(path: "file.swift", oldPath: "", kind: "modified", patch: patch),
      document: DiffParser.parse(Data(patch.utf8)), lineID: 1, side: .new)
  }
  static func account(id: UUID = UUID()) throws -> HostingAccount {
    HostingAccount(id: id, instance: try HostingInstance(provider: .github, url: "https://github.com"),
      user: HostingUser(stableID: "42", login: "synthetic"), kind: .pat, scopes: [])
  }
  static func binding(_ account: HostingAccount, repository: String = "owner/repo") throws -> RepositoryHostingBinding {
    try RepositoryHostingBinding(repositoryID: UUID(), accountID: account.id, remote: "origin", repository: repository)
  }
  static func request(number: Int = 7, sha: String = sha) -> HostingPullRequest {
    HostingPullRequest(number: number, title: "Synthetic request", body: "", author: "other", state: "open", draft: false,
      source: "feature", target: "main", sourceRepository: "owner/repo", sha: sha, webURL: nil,
      createdAt: "2026-10-18T00:00:00Z", updatedAt: "2026-10-18T00:00:00Z", reviewers: [])
  }
  static func key(_ account: HostingAccount, _ binding: RepositoryHostingBinding, section: HostingDetailSection = .reviews,
    number: Int = 7, page: String = "1", sha: String = sha) -> HostingRequestDetailCache.Key {
    HostingRequestDetailCache.Key(account: account, binding: binding, request: request(number: number, sha: sha), section: section, page: page)
  }
}

@MainActor final class HostingReviewConcurrencyTests: XCTestCase {
  private func waitForGate(_ gate: ReviewInterleaveGate) async throws {
    for _ in 0..<1_000 {
      if await gate.waiting() { return }
      try await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("The operation did not reach its controlled suspension point")
    throw HostingError.networkFailure
  }
  private func cached(_ cache: HostingRequestDetailCache, _ key: HostingRequestDetailCache.Key,
    counter: ReviewInterleaveCounter, name: String) async throws {
    _ = try await cache.value(for: key) {
      await counter.add(name)
      return .reviews(HostingPage(items: [], nextPage: nil))
    }
  }
  private func contextAlias(_ context: HostingReviewContext, repository: String = "Owner/Repo", repositoryID: String? = nil,
    requestID: String? = nil, number: Int? = nil) -> HostingReviewContext {
    let original = context.target
    return HostingReviewContext(target: HostingReviewTarget(instance: original.instance, accountID: original.accountID, userID: original.userID,
      repository: repository, repositoryID: repositoryID ?? original.repositoryID, requestNumber: number ?? original.requestNumber,
      requestID: requestID ?? original.requestID), revision: context.revision, capabilities: context.capabilities,
      state: context.state, authorID: context.authorID, webURL: context.webURL, permissionExplanation: context.permissionExplanation)
  }

  func testRepositoryAliasCannotBypassActiveStableTargetLock() async throws {
    let context = try ReviewInterleaveFixture.context(), gate = ReviewInterleaveGate(), count = ReviewInterleaveCounter()
    let alias = contextAlias(context), coordinator = HostingReviewSubmissionCoordinator()
    XCTAssertNotEqual(context.target, alias.target); XCTAssertEqual(context.target.repositoryID, alias.target.repositoryID)
    let task = Task {
      try await coordinator.submit(ReviewInterleaveFixture.confirmation(context), current: { context }, validate: {}, validateAnchor: { _ in },
        send: { _, context in await count.add(); await gate.suspend(); return ReviewInterleaveFixture.receipt(context) }, readback: { receipt, _, _ in receipt })
    }
    defer { task.cancel(); Task { await gate.release() } }
    try await waitForGate(gate)
    do {
      _ = try await coordinator.submit(ReviewInterleaveFixture.confirmation(alias), current: { alias }, validate: {}, validateAnchor: { _ in },
        send: { _, context in await count.add(); return ReviewInterleaveFixture.receipt(context) }, readback: { receipt, _, _ in receipt })
      XCTFail("A repository path alias bypassed the stable request lock")
    } catch { XCTAssertEqual(error as? HostingReviewError, .alreadySubmitting) }
    let beforeRelease = await count.get(); XCTAssertEqual(beforeRelease, 1)
    await gate.release(); let report = try await task.value
    XCTAssertTrue(report.complete); XCTAssertEqual(report.target, context.target)
    let sent = await count.get(); XCTAssertEqual(sent, 1)
  }

  func testRepositoryAliasSharesUnknownBarrierWithoutWeakeningConfirmationIdentity() async throws {
    let context = try ReviewInterleaveFixture.context(), alias = contextAlias(context), coordinator = HostingReviewSubmissionCoordinator()
    let first = try ReviewInterleaveFixture.confirmation(context), count = ReviewInterleaveCounter()
    let report = try await coordinator.submit(first, current: { context }, validate: {}, validateAnchor: { _ in },
      send: { _, _ in await count.add(); throw HostingError.networkFailure }, readback: { receipt, _, _ in receipt })
    XCTAssertTrue(report.hasUnknown); XCTAssertEqual(report.target, context.target)
    let blocked = await coordinator.isBlocked(alias.target); XCTAssertTrue(blocked)
    do {
      _ = try await coordinator.submit(ReviewInterleaveFixture.confirmation(alias), current: { alias }, validate: {}, validateAnchor: { _ in },
        send: { _, context in await count.add(); return ReviewInterleaveFixture.receipt(context) }, readback: { receipt, _, _ in receipt })
      XCTFail("An unknown result must block a differently cased repository path")
    } catch { XCTAssertEqual(error as? HostingReviewError, .resultUnknown) }
    let sent = await count.get(); XCTAssertEqual(sent, 1)
    await coordinator.acknowledgePlatformCheck(alias.target)
    let originalBlocked = await coordinator.isBlocked(context.target), aliasBlocked = await coordinator.isBlocked(alias.target)
    XCTAssertFalse(originalBlocked); XCTAssertFalse(aliasBlocked)
    do {
      _ = try await coordinator.submit(ReviewInterleaveFixture.confirmation(alias, id: first.id), current: { alias }, validate: {}, validateAnchor: { _ in },
        send: { _, context in await count.add(); return ReviewInterleaveFixture.receipt(context) }, readback: { receipt, _, _ in receipt })
      XCTFail("Sharing the lock key must not share confirmation identity or reports")
    } catch { XCTAssertEqual(error as? HostingReviewError, .targetChanged) }
    let retained = await coordinator.report(first.id); XCTAssertEqual(retained?.target, context.target)
    let finalCount = await count.get(); XCTAssertEqual(finalCount, 1)
  }

  func testDifferentStableRepositoryOrRequestIDsRemainIndependentDuringSend() async throws {
    let context = try ReviewInterleaveFixture.context(), gate = ReviewInterleaveGate(), count = ReviewInterleaveCounter()
    let otherRepository = contextAlias(context, repository: context.target.repository, repositoryID: "other-repository", requestID: "other-repository-request")
    let otherRequest = contextAlias(context, repository: context.target.repository, requestID: "request-8", number: 8)
    let coordinator = HostingReviewSubmissionCoordinator()
    let task = Task {
      try await coordinator.submit(ReviewInterleaveFixture.confirmation(context), current: { context }, validate: {}, validateAnchor: { _ in },
        send: { _, context in await count.add("first"); await gate.suspend(); return ReviewInterleaveFixture.receipt(context) }, readback: { receipt, _, _ in receipt })
    }
    defer { task.cancel(); Task { await gate.release() } }
    try await waitForGate(gate)
    for other in [otherRepository, otherRequest] {
      let report = try await coordinator.submit(ReviewInterleaveFixture.confirmation(other), current: { other }, validate: {}, validateAnchor: { _ in },
        send: { _, context in await count.add("other"); return ReviewInterleaveFixture.receipt(context) }, readback: { receipt, _, _ in receipt })
      XCTAssertTrue(report.complete); XCTAssertEqual(report.target, other.target)
    }
    let firstCount = await count.get("first"), otherCount = await count.get("other")
    XCTAssertEqual(firstCount, 1); XCTAssertEqual(otherCount, 2)
    await gate.release(); let report = try await task.value; XCTAssertTrue(report.complete)
  }

  func testSecondWindowCannotSendWhileFirstIsPausedBeforePOST() async throws {
    let context = try ReviewInterleaveFixture.context(), gate = ReviewInterleaveGate(), count = ReviewInterleaveCounter()
    let coordinator = HostingReviewSubmissionCoordinator(), first = try ReviewInterleaveFixture.confirmation(context)
    let task = Task {
      try await coordinator.submit(first, current: { await gate.suspend(); return context }, validate: {}, validateAnchor: { _ in },
        send: { _, context in await count.add(); return ReviewInterleaveFixture.receipt(context) }, readback: { receipt, _, _ in receipt })
    }
    defer { task.cancel(); Task { await gate.release() } }
    try await waitForGate(gate)
    do {
      _ = try await coordinator.submit(ReviewInterleaveFixture.confirmation(context), current: { context }, validate: {}, validateAnchor: { _ in },
        send: { _, context in await count.add(); return ReviewInterleaveFixture.receipt(context) }, readback: { receipt, _, _ in receipt })
      XCTFail("The second window bypassed the shared target lock")
    } catch { XCTAssertEqual(error as? HostingReviewError, .alreadySubmitting) }
    let beforeRelease = await count.get(); XCTAssertEqual(beforeRelease, 0)
    await gate.release()
    let result = try await task.value; XCTAssertTrue(result.complete)
    let sent = await count.get(); XCTAssertEqual(sent, 1)
  }

  func testDifferentRequestCanSubmitWhileAnotherTargetIsSuspended() async throws {
    let context = try ReviewInterleaveFixture.context(), other = try ReviewInterleaveFixture.context(accountID: context.target.accountID, number: 8)
    let coordinator = HostingReviewSubmissionCoordinator(), gate = ReviewInterleaveGate(), count = ReviewInterleaveCounter()
    let first = try ReviewInterleaveFixture.confirmation(context)
    let task = Task {
      try await coordinator.submit(first, current: { await gate.suspend(); return context }, validate: {}, validateAnchor: { _ in },
        send: { _, context in await count.add("first"); return ReviewInterleaveFixture.receipt(context) }, readback: { receipt, _, _ in receipt })
    }
    defer { task.cancel(); Task { await gate.release() } }
    try await waitForGate(gate)
    let result = try await coordinator.submit(ReviewInterleaveFixture.confirmation(other), current: { other }, validate: {}, validateAnchor: { _ in },
      send: { _, context in await count.add("other"); return ReviewInterleaveFixture.receipt(context) }, readback: { receipt, _, _ in receipt })
    XCTAssertTrue(result.complete)
    let firstCount = await count.get("first"), otherCount = await count.get("other")
    XCTAssertEqual(firstCount, 0); XCTAssertEqual(otherCount, 1)
    await gate.release(); _ = try await task.value
  }

  func testTargetLockRemainsHeldWhileReceiptReadbackIsSuspended() async throws {
    let context = try ReviewInterleaveFixture.context(), coordinator = HostingReviewSubmissionCoordinator(), gate = ReviewInterleaveGate()
    let confirmation = try ReviewInterleaveFixture.confirmation(context)
    let task = Task {
      try await coordinator.submit(confirmation, current: { context }, validate: {}, validateAnchor: { _ in },
        send: { _, context in ReviewInterleaveFixture.receipt(context) }, readback: { receipt, _, _ in await gate.suspend(); return receipt })
    }
    defer { task.cancel(); Task { await gate.release() } }
    try await waitForGate(gate)
    do {
      _ = try await coordinator.submit(ReviewInterleaveFixture.confirmation(context), current: { context }, validate: {}, validateAnchor: { _ in },
        send: { _, context in XCTFail("POST during another receipt's readback"); return ReviewInterleaveFixture.receipt(context) }, readback: { receipt, _, _ in receipt })
      XCTFail("Readback must remain inside the shared critical section")
    } catch { XCTAssertEqual(error as? HostingReviewError, .alreadySubmitting) }
    await gate.release(); let result = try await task.value; XCTAssertTrue(result.complete)
  }

  func testCancellationDuringPreflightNeverEntersSend() async throws {
    let context = try ReviewInterleaveFixture.context(), gate = ReviewInterleaveGate(), count = ReviewInterleaveCounter()
    let confirmation = try ReviewInterleaveFixture.confirmation(context), coordinator = HostingReviewSubmissionCoordinator()
    let task = Task {
      try await coordinator.submit(confirmation, current: { await gate.suspend(); return context }, validate: {}, validateAnchor: { _ in },
        send: { _, context in await count.add(); return ReviewInterleaveFixture.receipt(context) }, readback: { receipt, _, _ in receipt })
    }
    defer { task.cancel(); Task { await gate.release() } }
    try await waitForGate(gate); task.cancel(); await gate.release()
    let result = try await task.value
    XCTAssertFalse(result.hasUnknown); XCTAssertEqual(result.results.first?.outcome, .failed(.cancelled))
    let sent = await count.get(), blocked = await coordinator.isBlocked(context.target)
    XCTAssertEqual(sent, 0); XCTAssertFalse(blocked)
  }

  func testDisconnectAfterPreflightStartsStopsBeforePOST() async throws {
    let context = try ReviewInterleaveFixture.context(), gate = ReviewInterleaveGate(), identity = ReviewInterleaveIdentity(), count = ReviewInterleaveCounter()
    let confirmation = try ReviewInterleaveFixture.confirmation(context)
    let task = Task {
      try await HostingReviewSubmissionCoordinator().submit(confirmation, current: { await gate.suspend(); return context },
        validate: { try await identity.validate() }, validateAnchor: { _ in },
        send: { _, context in await count.add(); return ReviewInterleaveFixture.receipt(context) }, readback: { receipt, _, _ in receipt })
    }
    defer { task.cancel(); Task { await gate.release() } }
    try await waitForGate(gate); await identity.disconnect(); await gate.release()
    let report = try await task.value
    XCTAssertFalse(report.hasUnknown); XCTAssertEqual(report.results.first?.outcome, .failed(.hosting(.accountChanged)))
    let sent = await count.get(); XCTAssertEqual(sent, 0)
  }

  func testDisconnectDuringSlowAnchorRevalidationStopsBeforePOST() async throws {
    let context = try ReviewInterleaveFixture.context(), anchor = try ReviewInterleaveFixture.anchor(context)
    let gate = ReviewInterleaveGate(), identity = ReviewInterleaveIdentity(), count = ReviewInterleaveCounter()
    let confirmation = try HostingReviewConfirmation(context: context, items: [HostingReviewSubmissionItem(mutation: .inline(body: "line", anchor: anchor))])
    let task = Task {
      try await HostingReviewSubmissionCoordinator().submit(confirmation, current: { context }, validate: { try await identity.validate() },
        validateAnchor: { _ in await gate.suspend() }, send: { _, context in await count.add(); return ReviewInterleaveFixture.receipt(context) }, readback: { receipt, _, _ in receipt })
    }
    defer { task.cancel(); Task { await gate.release() } }
    try await waitForGate(gate); await identity.disconnect(); await gate.release()
    let result = try await task.value; XCTAssertFalse(result.hasUnknown)
    let sent = await count.get(); XCTAssertEqual(sent, 0)
  }

  func testCancelledSendWithLateReceiptRetainsIDAndReconcilesWithoutAnotherPOST() async throws {
    let context = try ReviewInterleaveFixture.context(), gate = ReviewInterleaveGate(), count = ReviewInterleaveCounter()
    let confirmation = try ReviewInterleaveFixture.confirmation(context), coordinator = HostingReviewSubmissionCoordinator()
    let task = Task {
      try await coordinator.submit(confirmation, current: { context }, validate: {}, validateAnchor: { _ in },
        send: { _, context in await count.add(); await gate.suspend(); return ReviewInterleaveFixture.receipt(context) },
        readback: { receipt, _, _ in try Task.checkCancellation(); return receipt })
    }
    defer { task.cancel(); Task { await gate.release() } }
    try await waitForGate(gate); task.cancel(); await gate.release()
    let report = try await task.value
    guard case .unknown(let receipt?) = report.results[0].outcome else { return XCTFail("Late accepted write lost its stable receipt") }
    XCTAssertEqual(receipt.id, "100")
    let blocked = await coordinator.isBlocked(context.target); XCTAssertTrue(blocked)
    let recovered = try await coordinator.reconcile(confirmation.id, validate: {}, readback: { receipt, _, _ in receipt })
    XCTAssertTrue(recovered.complete)
    let sent = await count.get(); XCTAssertEqual(sent, 1)
  }

  func testCancelledSendWithoutReceiptStaysUnknownAndCannotUseBodyReadback() async throws {
    let context = try ReviewInterleaveFixture.context(), gate = ReviewInterleaveGate(), coordinator = HostingReviewSubmissionCoordinator()
    let confirmation = try ReviewInterleaveFixture.confirmation(context), count = ReviewInterleaveCounter()
    let task = Task {
      try await coordinator.submit(confirmation, current: { context }, validate: {}, validateAnchor: { _ in },
        send: { _, _ in await count.add(); await gate.suspend(); try Task.checkCancellation(); throw HostingError.networkFailure },
        readback: { receipt, _, _ in XCTFail("No receipt was received"); return receipt })
    }
    defer { task.cancel(); Task { await gate.release() } }
    try await waitForGate(gate); task.cancel(); await gate.release()
    let report = try await task.value; XCTAssertEqual(report.results.first?.outcome, .unknown(nil))
    let rechecked = try await coordinator.reconcile(confirmation.id, validate: {}, readback: { receipt, _, _ in XCTFail("Body/date cannot identify this POST"); return receipt })
    XCTAssertTrue(rechecked.hasUnknown)
    let sent = await count.get(); XCTAssertEqual(sent, 1)
  }

  func testConfirmedReadbackRemainsSubmittedWhenCancellationArrivesLate() async throws {
    let context = try ReviewInterleaveFixture.context(), gate = ReviewInterleaveGate(), coordinator = HostingReviewSubmissionCoordinator()
    let confirmation = try ReviewInterleaveFixture.confirmation(context)
    let task = Task {
      try await coordinator.submit(confirmation, current: { context }, validate: {}, validateAnchor: { _ in },
        send: { _, context in ReviewInterleaveFixture.receipt(context) },
        readback: { receipt, _, _ in await gate.suspend(); return receipt })
    }
    defer { task.cancel(); Task { await gate.release() } }
    try await waitForGate(gate); task.cancel(); await gate.release()
    let result = try await task.value; XCTAssertTrue(result.complete); XCTAssertFalse(result.hasUnknown)
    let blocked = await coordinator.isBlocked(context.target); XCTAssertFalse(blocked)
  }

  func testAccountSnapshotChangesAfterPossiblePOSTProducesUnknown() async throws {
    let context = try ReviewInterleaveFixture.context(), gate = ReviewInterleaveGate(), coordinator = HostingReviewSubmissionCoordinator()
    let confirmation = try ReviewInterleaveFixture.confirmation(context), count = ReviewInterleaveCounter()
    let task = Task {
      try await coordinator.submit(confirmation, current: { context }, validate: {}, validateAnchor: { _ in },
        send: { _, _ in await count.add(); await gate.suspend(); throw HostingError.accountChanged }, readback: { receipt, _, _ in receipt })
    }
    defer { task.cancel(); Task { await gate.release() } }
    try await waitForGate(gate); await gate.release()
    let result = try await task.value; XCTAssertTrue(result.hasUnknown)
    let blocked = await coordinator.isBlocked(context.target), sent = await count.get()
    XCTAssertTrue(blocked); XCTAssertEqual(sent, 1)
  }

  func testTargetChangesAfterPossiblePOSTProducesUnknown() async throws {
    let context = try ReviewInterleaveFixture.context(), coordinator = HostingReviewSubmissionCoordinator()
    let report = try await coordinator.submit(ReviewInterleaveFixture.confirmation(context), current: { context }, validate: {}, validateAnchor: { _ in },
      send: { _, _ in throw HostingReviewError.targetChanged }, readback: { receipt, _, _ in receipt })
    XCTAssertTrue(report.hasUnknown)
    let blocked = await coordinator.isBlocked(context.target); XCTAssertTrue(blocked)
  }

  func testReconcilingOldCompletedReportDoesNotUnlockNewUnknownAttempt() async throws {
    let context = try ReviewInterleaveFixture.context(), coordinator = HostingReviewSubmissionCoordinator()
    let old = try ReviewInterleaveFixture.confirmation(context), recent = try ReviewInterleaveFixture.confirmation(context)
    _ = try await coordinator.submit(old, current: { context }, validate: {}, validateAnchor: { _ in },
      send: { _, context in ReviewInterleaveFixture.receipt(context) }, readback: { receipt, _, _ in receipt })
    _ = try await coordinator.submit(recent, current: { context }, validate: {}, validateAnchor: { _ in },
      send: { _, _ in throw HostingError.networkFailure }, readback: { receipt, _, _ in receipt })
    let oldReport = try await coordinator.reconcile(old.id, validate: {}, readback: { receipt, _, _ in receipt })
    XCTAssertTrue(oldReport.complete)
    let blocked = await coordinator.isBlocked(context.target); XCTAssertTrue(blocked)
    do {
      _ = try await coordinator.submit(ReviewInterleaveFixture.confirmation(context), current: { context }, validate: {}, validateAnchor: { _ in },
        send: { _, context in XCTFail("The new unknown attempt was accidentally unlocked"); return ReviewInterleaveFixture.receipt(context) }, readback: { receipt, _, _ in receipt })
      XCTFail("A new ticket must remain blocked")
    } catch { XCTAssertEqual(error as? HostingReviewError, .resultUnknown) }
  }

  func testRecheckingAcknowledgedOldUnknownDoesNotUnlockLaterUnknown() async throws {
    let context = try ReviewInterleaveFixture.context(), coordinator = HostingReviewSubmissionCoordinator()
    let old = try ReviewInterleaveFixture.confirmation(context), recent = try ReviewInterleaveFixture.confirmation(context)
    _ = try await coordinator.submit(old, current: { context }, validate: {}, validateAnchor: { _ in },
      send: { _, context in ReviewInterleaveFixture.receipt(context) }, readback: { _, _, _ in throw HostingError.networkFailure })
    await coordinator.acknowledgePlatformCheck(context.target)
    _ = try await coordinator.submit(recent, current: { context }, validate: {}, validateAnchor: { _ in },
      send: { _, _ in throw HostingError.networkFailure }, readback: { receipt, _, _ in receipt })
    let rechecked = try await coordinator.reconcile(old.id, validate: {}, readback: { receipt, _, _ in receipt })
    XCTAssertTrue(rechecked.complete)
    let blocked = await coordinator.isBlocked(context.target); XCTAssertTrue(blocked)
  }

  func testReadingOldReportNeverAcknowledgesNewUnknown() async throws {
    let context = try ReviewInterleaveFixture.context(), coordinator = HostingReviewSubmissionCoordinator()
    let old = try ReviewInterleaveFixture.confirmation(context), recent = try ReviewInterleaveFixture.confirmation(context)
    _ = try await coordinator.submit(old, current: { context }, validate: {}, validateAnchor: { _ in },
      send: { _, _ in throw HostingError.permissionRequired }, readback: { receipt, _, _ in receipt })
    _ = try await coordinator.submit(recent, current: { context }, validate: {}, validateAnchor: { _ in },
      send: { _, _ in throw HostingError.networkFailure }, readback: { receipt, _, _ in receipt })
    let original = await coordinator.report(old.id), blocked = await coordinator.isBlocked(context.target)
    XCTAssertEqual(original?.results.first?.outcome, .failed(.hosting(.permissionRequired))); XCTAssertTrue(blocked)
  }

  func testReusingConfirmationUUIDWithDifferentBodyIsRejectedWithoutPOST() async throws {
    let context = try ReviewInterleaveFixture.context(), coordinator = HostingReviewSubmissionCoordinator(), count = ReviewInterleaveCounter()
    let original = try ReviewInterleaveFixture.confirmation(context, body: "first")
    _ = try await coordinator.submit(original, current: { context }, validate: {}, validateAnchor: { _ in },
      send: { _, context in await count.add(); return ReviewInterleaveFixture.receipt(context) }, readback: { receipt, _, _ in receipt })
    let changed = try ReviewInterleaveFixture.confirmation(context, id: original.id, body: "changed after confirmation")
    do {
      _ = try await coordinator.submit(changed, current: { context }, validate: {}, validateAnchor: { _ in },
        send: { _, context in await count.add(); return ReviewInterleaveFixture.receipt(context) }, readback: { receipt, _, _ in receipt })
      XCTFail("A changed payload reused another confirmation's success")
    } catch { XCTAssertEqual(error as? HostingReviewError, .targetChanged) }
    let sent = await count.get(); XCTAssertEqual(sent, 1)
  }

  func testReusingConfirmationUUIDForAnotherTargetIsRejected() async throws {
    let context = try ReviewInterleaveFixture.context(), other = try ReviewInterleaveFixture.context(accountID: context.target.accountID, number: 8)
    let coordinator = HostingReviewSubmissionCoordinator(), original = try ReviewInterleaveFixture.confirmation(context)
    _ = try await coordinator.submit(original, current: { context }, validate: {}, validateAnchor: { _ in },
      send: { _, context in ReviewInterleaveFixture.receipt(context) }, readback: { receipt, _, _ in receipt })
    do {
      _ = try await coordinator.submit(ReviewInterleaveFixture.confirmation(other, id: original.id), current: { other }, validate: {}, validateAnchor: { _ in },
        send: { _, context in XCTFail("A reused UUID submitted to another target"); return ReviewInterleaveFixture.receipt(context) }, readback: { receipt, _, _ in receipt })
      XCTFail("Another target inherited the old report")
    } catch { XCTAssertEqual(error as? HostingReviewError, .targetChanged) }
  }

  func testGitLabSameAnchorDraftItemsKeepDistinctIDsThroughPartialFailure() async throws {
    let context = try ReviewInterleaveFixture.context(.gitlab), anchor = try ReviewInterleaveFixture.anchor(context)
    let first = HostingReviewDraftComment(body: "first comment", anchor: anchor), second = HostingReviewDraftComment(body: "second comment", anchor: anchor)
    let draft = HostingReviewDraft(context: context, comments: [first, second]), confirmation = try HostingReviewConfirmation.draft(draft)
    XCTAssertEqual(confirmation.items.map(\.id), [first.id, second.id])
    let report = try await HostingReviewSubmissionCoordinator().submit(confirmation, current: { context }, validate: {}, validateAnchor: { _ in },
      send: { mutation, context in if case .inline("second comment", _) = mutation { throw HostingError.permissionRequired }; return ReviewInterleaveFixture.receipt(context) },
      readback: { receipt, _, _ in receipt })
    XCTAssertEqual(report.submittedCount, 1); XCTAssertEqual(report.results[1].id, second.id)
    XCTAssertEqual(report.results[1].outcome, .failed(.hosting(.permissionRequired)))
    var retained = draft
    let completedIDs = Set(report.results.compactMap { result -> UUID? in if case .submitted = result.outcome { result.id } else { nil } })
    retained.comments.removeAll { completedIDs.contains($0.id) }
    XCTAssertEqual(retained.comments, [second])
  }

  func testGitLabPartialUnknownStopsLaterItemsAndPreservesTheirSourceIDs() async throws {
    let context = try ReviewInterleaveFixture.context(.gitlab), anchor = try ReviewInterleaveFixture.anchor(context)
    let comments = ["first", "second", "third"].map { HostingReviewDraftComment(body: $0, anchor: anchor) }
    let confirmation = try HostingReviewConfirmation.draft(HostingReviewDraft(context: context, comments: comments))
    let report = try await HostingReviewSubmissionCoordinator().submit(confirmation, current: { context }, validate: {}, validateAnchor: { _ in },
      send: { mutation, context in if case .inline("second", _) = mutation { throw HostingError.networkFailure }; return ReviewInterleaveFixture.receipt(context) },
      readback: { receipt, _, _ in receipt })
    XCTAssertEqual(report.results.map(\.id), comments.map(\.id)); XCTAssertEqual(report.submittedCount, 1)
    XCTAssertEqual(report.results[1].outcome, .unknown(nil)); XCTAssertEqual(report.results[2].outcome, .notSent)
  }

  func testUnknownAttemptDoesNotBlockAnotherAccountOrRequest() async throws {
    let context = try ReviewInterleaveFixture.context(), sameAccountOtherRequest = try ReviewInterleaveFixture.context(accountID: context.target.accountID, number: 8)
    let anotherAccount = try ReviewInterleaveFixture.context(), coordinator = HostingReviewSubmissionCoordinator()
    _ = try await coordinator.submit(ReviewInterleaveFixture.confirmation(context), current: { context }, validate: {}, validateAnchor: { _ in },
      send: { _, _ in throw HostingError.networkFailure }, readback: { receipt, _, _ in receipt })
    for other in [sameAccountOtherRequest, anotherAccount] {
      let report = try await coordinator.submit(ReviewInterleaveFixture.confirmation(other), current: { other }, validate: {}, validateAnchor: { _ in },
        send: { _, context in ReviewInterleaveFixture.receipt(context) }, readback: { receipt, _, _ in receipt })
      XCTAssertTrue(report.complete)
    }
    let blocked = await coordinator.isBlocked(context.target); XCTAssertTrue(blocked)
  }

  func testTargetInvalidationKeepsOtherRepositoryAndFilePagesCached() async throws {
    let account = try ReviewInterleaveFixture.account(), binding = try ReviewInterleaveFixture.binding(account)
    let other = try ReviewInterleaveFixture.binding(account, repository: "owner/other"), cache = HostingRequestDetailCache(), count = ReviewInterleaveCounter()
    let keys = [("affected", ReviewInterleaveFixture.key(account, binding)),
      ("other-repo", ReviewInterleaveFixture.key(account, other)),
      ("files-page1", ReviewInterleaveFixture.key(account, binding, section: .files)),
      ("files-page2", ReviewInterleaveFixture.key(account, binding, section: .files, page: "2"))]
    for (name, key) in keys { try await cached(cache, key, counter: count, name: name) }
    await cache.invalidate(account: account, binding: binding, number: 7)
    for (name, key) in keys { try await cached(cache, key, counter: count, name: name) }
    for (name, _) in keys { let loads = await count.get(name); XCTAssertEqual(loads, name == "affected" ? 2 : 1, name) }
  }

  func testTargetInvalidationKeepsOtherRequestAndAccountCached() async throws {
    let account = try ReviewInterleaveFixture.account(), otherAccount = try ReviewInterleaveFixture.account()
    let binding = try ReviewInterleaveFixture.binding(account), otherBinding = try ReviewInterleaveFixture.binding(otherAccount)
    let cache = HostingRequestDetailCache(), count = ReviewInterleaveCounter()
    let keys = [("affected", ReviewInterleaveFixture.key(account, binding)),
      ("other-request", ReviewInterleaveFixture.key(account, binding, number: 8)),
      ("other-account", ReviewInterleaveFixture.key(otherAccount, otherBinding))]
    for (name, key) in keys { try await cached(cache, key, counter: count, name: name) }
    await cache.invalidate(account: account, binding: binding, number: 7)
    for (name, key) in keys { try await cached(cache, key, counter: count, name: name) }
    for (name, _) in keys { let loads = await count.get(name); XCTAssertEqual(loads, name == "affected" ? 2 : 1, name) }
  }

  func testTargetInvalidationRemovesAllReviewPagesAndOlderRevisions() async throws {
    let account = try ReviewInterleaveFixture.account(), binding = try ReviewInterleaveFixture.binding(account)
    let cache = HostingRequestDetailCache(), count = ReviewInterleaveCounter()
    let keys = [("page1", ReviewInterleaveFixture.key(account, binding)),
      ("page2", ReviewInterleaveFixture.key(account, binding, page: "2")),
      ("old-head", ReviewInterleaveFixture.key(account, binding, sha: String(repeating: "d", count: 40))),
      ("discussion", ReviewInterleaveFixture.key(account, binding, section: .conversations))]
    for (name, key) in keys { try await cached(cache, key, counter: count, name: name) }
    await cache.invalidate(account: account, binding: binding, number: 7)
    for (name, key) in keys { try await cached(cache, key, counter: count, name: name) }
    for (name, _) in keys { let loads = await count.get(name); XCTAssertEqual(loads, 2, name) }
  }

  func testCustomSectionInvalidationDoesNotEvictOtherTargetSections() async throws {
    let account = try ReviewInterleaveFixture.account(), binding = try ReviewInterleaveFixture.binding(account)
    let cache = HostingRequestDetailCache(), count = ReviewInterleaveCounter()
    let keys = [("reviews", ReviewInterleaveFixture.key(account, binding)),
      ("comments", ReviewInterleaveFixture.key(account, binding, section: .comments)),
      ("overview", ReviewInterleaveFixture.key(account, binding, section: .overview))]
    for (name, key) in keys { try await cached(cache, key, counter: count, name: name) }
    await cache.invalidate(account: account, binding: binding, number: 7, sections: [.comments])
    for (name, key) in keys { try await cached(cache, key, counter: count, name: name) }
    for (name, _) in keys { let loads = await count.get(name); XCTAssertEqual(loads, name == "comments" ? 2 : 1, name) }
  }

  func testInvalidatedFlightCannotRepopulateCacheWithUncooperativeLatePage() async throws {
    let account = try ReviewInterleaveFixture.account(), binding = try ReviewInterleaveFixture.binding(account)
    let cache = HostingRequestDetailCache(), key = ReviewInterleaveFixture.key(account, binding), gate = ReviewInterleaveGate(), count = ReviewInterleaveCounter()
    let pending = Task {
      try await cache.value(for: key) { await count.add(); await gate.suspend(); return .reviews(HostingPage(items: [], nextPage: nil)) }
    }
    defer { pending.cancel(); Task { await gate.release() } }
    try await waitForGate(gate)
    await cache.invalidate(account: account, binding: binding, number: 7); await gate.release()
    do { _ = try await pending.value; XCTFail("A stale in-flight page survived target invalidation") } catch is CancellationError {}
    try await cached(cache, key, counter: count, name: "fresh")
    let oldLoads = await count.get(), freshLoads = await count.get("fresh")
    XCTAssertEqual(oldLoads, 1); XCTAssertEqual(freshLoads, 1)
  }

  func testOtherRepositoryFlightSurvivesTargetInvalidation() async throws {
    let account = try ReviewInterleaveFixture.account(), binding = try ReviewInterleaveFixture.binding(account)
    let other = try ReviewInterleaveFixture.binding(account, repository: "owner/other"), cache = HostingRequestDetailCache()
    let key = ReviewInterleaveFixture.key(account, other), gate = ReviewInterleaveGate(), count = ReviewInterleaveCounter()
    let pending = Task {
      try await cache.value(for: key) { await count.add("other"); await gate.suspend(); return .reviews(HostingPage(items: [], nextPage: nil)) }
    }
    defer { pending.cancel(); Task { await gate.release() } }
    try await waitForGate(gate)
    await cache.invalidate(account: account, binding: binding, number: 7); await gate.release()
    _ = try await pending.value
    try await cached(cache, key, counter: count, name: "unexpected-reload")
    let loads = await count.get("other"), unexpected = await count.get("unexpected-reload")
    XCTAssertEqual(loads, 1); XCTAssertEqual(unexpected, 0)
  }

  func testSameTargetFileFlightSurvivesReviewInvalidation() async throws {
    let account = try ReviewInterleaveFixture.account(), binding = try ReviewInterleaveFixture.binding(account)
    let cache = HostingRequestDetailCache(), key = ReviewInterleaveFixture.key(account, binding, section: .files, page: "2")
    let gate = ReviewInterleaveGate(), count = ReviewInterleaveCounter()
    let pending = Task {
      try await cache.value(for: key) { await count.add("file"); await gate.suspend(); return .files(HostingPage(items: [], nextPage: nil)) }
    }
    defer { pending.cancel(); Task { await gate.release() } }
    try await waitForGate(gate)
    await cache.invalidate(account: account, binding: binding, number: 7); await gate.release()
    _ = try await pending.value
    _ = try await cache.value(for: key) { await count.add("unexpected-reload"); return .files(HostingPage(items: [], nextPage: nil)) }
    let loads = await count.get("file"), unexpected = await count.get("unexpected-reload")
    XCTAssertEqual(loads, 1); XCTAssertEqual(unexpected, 0)
  }
}
