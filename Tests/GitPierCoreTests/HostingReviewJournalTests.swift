import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import GitPierCore

private enum JournalFixture {
  static let sha = String(repeating: "a", count: 40)
  static func context(account: UUID = UUID(), repository: String = "private/project", repositoryID: String = "101", requestID: String = "202", provider: HostingProvider = .gitlab, userID: String = "42", instanceURL: String? = nil) throws -> HostingReviewContext {
    HostingReviewContext(target: HostingReviewTarget(instance: try HostingInstance(provider: provider, url: instanceURL ?? (provider == .github ? "https://github.com" : "https://code.example")),
      accountID: account, userID: userID, repository: repository, repositoryID: repositoryID, requestNumber: 7, requestID: requestID),
      revision: HostingReviewRevision(headSHA: sha, baseSHA: String(repeating: "b", count: 40), startSHA: String(repeating: "c", count: 40), diffID: "303"),
      capabilities: Set(HostingReviewCapability.allCases), state: "opened", authorID: "77")
  }
  static func confirmation(_ context: HostingReviewContext, id: UUID = UUID(), count: Int = 1) throws -> HostingReviewConfirmation {
    try HostingReviewConfirmation(id: id, context: context,
      items: (0..<count).map { HostingReviewSubmissionItem(mutation: .comment(body: "private comment \($0) TOKEN_DO_NOT_STORE")) })
  }
  static func receipt(_ context: HostingReviewContext, id: String = "100") -> HostingReviewReceipt {
    HostingReviewReceipt(id: id, state: .commented, authorID: context.target.userID, commitSHA: context.revision.headSHA)
  }
}
private final class JournalCheckpoint: @unchecked Sendable {
  private let lock = NSLock()
  private var failures: Set<String> = []
  private var unconditionalFailures: Set<String> = []
  private var failurePhase: String?
  private var phase: String?
  private var observed: [String] = []
  func fail(_ stages: Set<String>, after phase: String? = nil) {
    lock.lock(); defer { lock.unlock() }; failures = stages; failurePhase = phase; self.phase = nil; unconditionalFailures = []
  }
  func failAlways(_ stages: Set<String>) { lock.lock(); defer { lock.unlock() }; unconditionalFailures = stages }
  func events() -> [String] { lock.lock(); defer { lock.unlock() }; return observed }
  func clearEvents() { lock.lock(); defer { lock.unlock() }; observed = [] }
  func check(_ stage: String) throws {
    lock.lock(); defer { lock.unlock() }
    observed.append(stage)
    if ["prepare", "possiblySent", "receipt", "submittedAndVerified", "resultUnknown", "manuallyAcknowledged", "definitelyFailedBeforeSend", "definitelyRejected"].contains(stage) { phase = stage }
    if unconditionalFailures.contains(stage) || failures.contains(stage) && (failurePhase == nil || failurePhase == phase) { throw HostingReviewJournalError.unavailable }
  }
}
private actor JournalCounter {
  private var value = 0
  func next() -> Int { value += 1; return value }
  func count() -> Int { value }
}
private actor JournalGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var heldOnce = false
  func hold() async { await withCheckedContinuation { continuation = $0 } }
  func holdOnce() async { guard !heldOnce else { return }; heldOnce = true; await hold() }
  func waiting() -> Bool { continuation != nil }
  func release() { continuation?.resume(); continuation = nil }
}
private actor JournalRedirectTransport: HostingTransport {
  private let status: Int
  private var methods: [String] = []
  init(status: Int) { self.status = status }
  func send(_ request: URLRequest, limit: Int) async throws -> HostingHTTPResponse {
    methods.append(request.httpMethod ?? "")
    return HostingHTTPResponse(data: Data(), status: status, headers: ["location": "https://redirect.example/accepted"])
  }
  func sentMethods() -> [String] { methods }
}

@MainActor final class HostingReviewJournalTests: XCTestCase {
  private func root() throws -> URL {
    let result = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-review-journal-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    addTeardownBlock { try FileManager.default.removeItem(at: result) }
    return result
  }
  private func submit(_ coordinator: HostingReviewSubmissionCoordinator, _ confirmation: HostingReviewConfirmation,
    send: HostingReviewSubmissionCoordinator.Send? = nil,
    readback: HostingReviewSubmissionCoordinator.Readback? = nil) async throws -> HostingReviewSubmissionReport {
    let context = confirmation.context
    return try await coordinator.submit(confirmation, current: { context }, validate: {}, validateAnchor: { _ in },
      send: send ?? { _, context in JournalFixture.receipt(context) }, readback: readback ?? { receipt, _, _ in receipt })
  }
  private func raw(_ root: URL, _ id: UUID) throws -> Data { try Data(contentsOf: root.appendingPathComponent(id.uuidString + ".json")) }
  private func replace(_ root: URL, _ id: UUID, data: Data) throws {
    let url = root.appendingPathComponent(id.uuidString + ".json")
    try data.write(to: url); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  private func waitForGate(_ gate: JournalGate) async throws {
    for _ in 0..<1_000 { if await gate.waiting() { return }; try await Task.sleep(for: .milliseconds(2)) }
    XCTFail("The private-content test did not reach its controlled suspension point")
    throw HostingError.networkFailure
  }

  func testPrivatePermissionsAndMinimalMetadataExcludeBodiesDiffPathsAndHashes() throws {
    let root = try root(), context = try JournalFixture.context(), anchor = try HostingDiffAnchor.make(context: context,
      file: HostingChangedFile(path: "sensitive-source.swift", kind: "modified", patch: "@@ -1 +1 @@\n-secretOld\n+secretNew\n"),
      document: DiffParser.parse(Data("@@ -1 +1 @@\n-secretOld\n+secretNew\n".utf8)), lineID: 1, side: .new)
    let body = "short secret comment TOKEN_DO_NOT_STORE"
    let confirmation = try HostingReviewConfirmation(context: context, items: [HostingReviewSubmissionItem(mutation: .inline(body: body, anchor: anchor))])
    let journal = HostingReviewOperationJournal(root: root)
    try journal.prepare(confirmation)
    let bytes = try raw(root, confirmation.id), text = String(decoding: bytes, as: UTF8.self)
    for forbidden in [body, "TOKEN_DO_NOT_STORE", "private/project", "sensitive-source.swift", "secretNew", "secretOld", anchor.patchID, anchor.hunkID,
      SHA256.hash(data: Data(body.utf8)).map({ String(format: "%02x", $0) }).joined()] {
      XCTAssertFalse(text.contains(forbidden), forbidden)
    }
    let directoryMode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
    let fileMode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(confirmation.id.uuidString + ".json").path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(directoryMode?.intValue, 0o700); XCTAssertEqual(fileMode?.intValue, 0o600)
    XCTAssertEqual(try journal.records().first?.operation.kind, .inline)
  }

  func testCrashAfterIntentBeforePOSTRecoversConservativeUnknownWithoutSending() async throws {
    let root = try root(), journal = HostingReviewOperationJournal(root: root), context = try JournalFixture.context()
    let confirmation = try JournalFixture.confirmation(context, count: 3)
    try journal.prepare(confirmation)
    try journal.update(confirmationID: confirmation.id, itemID: confirmation.items[0].id, state: .possiblySent)
    let coordinator = HostingReviewSubmissionCoordinator(journal: HostingReviewOperationJournal(root: root))
    let records = try await coordinator.recoveredOperations()
    XCTAssertEqual(records.filter(\.isUnresolved).count, 1); XCTAssertEqual(records.filter { $0.state == .notSent }.count, 2)
    let blocked = await coordinator.isBlocked(context.target); XCTAssertTrue(blocked)
    do { _ = try await submit(coordinator, JournalFixture.confirmation(context), send: { _, _ in XCTFail("Restart must not POST"); throw HostingError.networkFailure }); XCTFail() }
    catch { XCTAssertEqual(error as? HostingReviewError, .resultUnknown) }
    XCTAssertEqual(try journal.records().count, 3)
  }

  func testPreparedUnsentBatchDoesNotPretendToRestoreDraftOrBlockNewConfirmation() async throws {
    let journal = HostingReviewOperationJournal(root: try root()), context = try JournalFixture.context()
    let confirmation = try JournalFixture.confirmation(context, count: 2)
    try journal.prepare(confirmation)
    let coordinator = HostingReviewSubmissionCoordinator(journal: journal)
    let blocked = await coordinator.isBlocked(context.target); XCTAssertFalse(blocked)
    XCTAssertTrue(try journal.records().allSatisfy { $0.state == .notSent && $0.receipt == nil })
    do { _ = try await submit(coordinator, confirmation); XCTFail("A consumed confirmation must never be reused after restart") }
    catch { XCTAssertEqual(error as? HostingReviewError, .alreadySubmitted) }
    let report = try await submit(coordinator, JournalFixture.confirmation(context)); XCTAssertTrue(report.complete)
  }

  func testIntentIsDurableBeforeSendAndReceiptBeforeReadback() async throws {
    let journal = HostingReviewOperationJournal(root: try root()), confirmation = try JournalFixture.confirmation(JournalFixture.context())
    let coordinator = HostingReviewSubmissionCoordinator(journal: journal)
    let report = try await submit(coordinator, confirmation, send: { _, context in
      let records = try journal.records(); XCTAssertEqual(records.count, 1); XCTAssertTrue(records[0].isUnresolved); XCTAssertNil(records[0].receipt)
      return JournalFixture.receipt(context)
    }, readback: { receipt, _, _ in
      let records = try journal.records(); XCTAssertEqual(records[0].receipt?.id, receipt.id); XCTAssertTrue(records[0].isUnresolved)
      return receipt
    })
    XCTAssertTrue(report.complete); XCTAssertEqual(try journal.records()[0].state, .submittedAndVerified)
  }

  func testPrepareAndIntentFailuresNeverPOST() async throws {
    for stage in ["prepare", "possiblySent"] {
      let checkpoint = JournalCheckpoint(); checkpoint.fail([stage])
      let journal = HostingReviewOperationJournal(root: try root(), checkpoint: { try checkpoint.check($0) })
      let confirmation = try JournalFixture.confirmation(JournalFixture.context())
      let report = try await submit(HostingReviewSubmissionCoordinator(journal: journal), confirmation,
        send: { _, _ in XCTFail("POST despite journal failure at \(stage)"); throw HostingError.networkFailure })
      guard case .failed(.journal(.unavailable)) = report.results[0].outcome else { return XCTFail("Expected a distinct persistence failure") }
      XCTAssertTrue(try journal.records().allSatisfy { $0.state == .notSent })
    }
  }

  func testReceiptSurvivesReadbackFailureAndRestart() async throws {
    let root = try root(), journal = HostingReviewOperationJournal(root: root), context = try JournalFixture.context()
    let report = try await submit(HostingReviewSubmissionCoordinator(journal: journal), JournalFixture.confirmation(context),
      readback: { _, _, _ in throw HostingError.networkFailure })
    XCTAssertTrue(report.hasUnknown)
    let record = try XCTUnwrap(HostingReviewOperationJournal(root: root).records().first)
    XCTAssertEqual(record.receipt?.id, "100"); XCTAssertEqual(record.state, .resultUnknown)
    let coordinator = HostingReviewSubmissionCoordinator(journal: journal)
    let blocked = await coordinator.isBlocked(context.target); XCTAssertTrue(blocked)
  }

  func testReceiptWriteFailureKeepsUnknownIntentAndStopsReadback() async throws {
    let checkpoint = JournalCheckpoint(); checkpoint.fail(["receipt", "resultUnknown"])
    let journal = HostingReviewOperationJournal(root: try root(), checkpoint: { try checkpoint.check($0) })
    let confirmation = try JournalFixture.confirmation(JournalFixture.context()), coordinator = HostingReviewSubmissionCoordinator(journal: journal)
    let report = try await submit(coordinator, confirmation, readback: { _, _, _ in XCTFail("Do not continue after losing the receipt checkpoint"); throw HostingError.networkFailure })
    guard case .unknown(let receipt) = report.results[0].outcome else { return XCTFail() }
    XCTAssertEqual(receipt?.id, "100"); XCTAssertNil(try journal.records().first?.receipt)
    let blocked = await coordinator.isBlocked(confirmation.context.target); XCTAssertTrue(blocked)
  }

  func testSuccessfulReadbackWithFailedFinalPersistenceIsStillUnknown() async throws {
    let checkpoint = JournalCheckpoint(); checkpoint.fail(["submittedAndVerified"])
    let journal = HostingReviewOperationJournal(root: try root(), checkpoint: { try checkpoint.check($0) })
    let confirmation = try JournalFixture.confirmation(JournalFixture.context()), coordinator = HostingReviewSubmissionCoordinator(journal: journal)
    let report = try await submit(coordinator, confirmation)
    XCTAssertTrue(report.hasUnknown); XCTAssertEqual(report.submittedCount, 0)
    let record = try XCTUnwrap(journal.records().first); XCTAssertTrue(record.isUnresolved); XCTAssertEqual(record.receipt?.id, "100")
    let restarted = HostingReviewSubmissionCoordinator(journal: journal)
    let blocked = await restarted.isBlocked(confirmation.context.target); XCTAssertTrue(blocked)
  }

  func testIncompleteReceiptMetadataStillPersistsStableIDBeforeReadback() async throws {
    let journal = HostingReviewOperationJournal(root: try root()), confirmation = try JournalFixture.confirmation(JournalFixture.context())
    let report = try await submit(HostingReviewSubmissionCoordinator(journal: journal), confirmation,
      send: { _, _ in HostingReviewReceipt(id: "987", authorID: "", commitSHA: "malformed") }, readback: { receipt, _, _ in
        XCTAssertEqual(try journal.records().first?.receipt?.id, "987")
        XCTAssertEqual(receipt.id, "987"); throw HostingReviewError.readbackRequired
      })
    XCTAssertTrue(report.hasUnknown); XCTAssertEqual(try journal.records().first?.receipt?.id, "987")
  }

  func testFiveIndependentWritesPreserveTwoSuccessOneUnknownTwoUnsent() async throws {
    let journal = HostingReviewOperationJournal(root: try root()), count = JournalCounter()
    let confirmation = try JournalFixture.confirmation(JournalFixture.context(), count: 5)
    let report = try await submit(HostingReviewSubmissionCoordinator(journal: journal), confirmation, send: { _, context in
      let index = await count.next()
      if index == 3 { throw HostingError.networkFailure }
      return JournalFixture.receipt(context, id: String(index))
    })
    XCTAssertEqual(report.submittedCount, 2); XCTAssertTrue(report.hasUnknown)
    let records = try journal.records()
    XCTAssertEqual(records.filter { $0.state == .submittedAndVerified }.count, 2)
    XCTAssertEqual(records.filter(\.isUnresolved).count, 1)
    XCTAssertEqual(records.filter { $0.state == .notSent }.count, 2)
    let sent = await count.count(); XCTAssertEqual(sent, 3)
  }

  func testKnownServerRejectionIsDistinctFromUnsentAndUnknown() async throws {
    let journal = HostingReviewOperationJournal(root: try root()), confirmation = try JournalFixture.confirmation(JournalFixture.context(), count: 2)
    let report = try await submit(HostingReviewSubmissionCoordinator(journal: journal), confirmation,
      send: { _, _ in throw HostingError.permissionRequired })
    guard case .failed(.hosting(.permissionRequired)) = report.results[0].outcome else { return XCTFail() }
    let records = try journal.records()
    XCTAssertEqual(records.filter { $0.state == .definitelyRejected }.count, 1)
    XCTAssertEqual(records.filter { $0.state == .notSent }.count, 1); XCTAssertFalse(records.contains(where: \.isUnresolved))
  }

  func testPOSTRedirectRemainsUnknownAcrossRestartWithoutFollowingOrRepeatingPOST() async throws {
    for status in [302, 303] {
      let journal = HostingReviewOperationJournal(root: try root()), context = try JournalFixture.context()
      let transport = JournalRedirectTransport(status: status), http = HostingHTTPClient(transport: transport)
      let send: HostingReviewSubmissionCoordinator.Send = { _, context in
        _ = try await http.request(instance: context.target.instance, path: "projects/101/merge_requests/7/discussions",
          method: "POST", body: Data("{\"body\":\"synthetic\"}".utf8))
        return JournalFixture.receipt(context)
      }
      let report = try await submit(HostingReviewSubmissionCoordinator(journal: journal), JournalFixture.confirmation(context),
        send: send, readback: { _, _, _ in XCTFail("A redirect has no verified receipt"); throw HostingError.invalidResponse })
      guard case .unknown(nil) = report.results[0].outcome else { return XCTFail("HTTP \(status) does not prove that a POST had no effect") }
      let record = try XCTUnwrap(journal.records().first)
      XCTAssertEqual(record.state, .resultUnknown); XCTAssertNil(record.receipt)
      let restarted = HostingReviewSubmissionCoordinator(journal: journal)
      let blocked = await restarted.isBlocked(context.target); XCTAssertTrue(blocked)
      do {
        _ = try await submit(restarted, JournalFixture.confirmation(context), send: send)
        XCTFail("A fresh ticket bypassed a persisted redirected POST")
      } catch { XCTAssertEqual(error as? HostingReviewError, .resultUnknown) }
      let methods = await transport.sentMethods()
      XCTAssertEqual(methods, ["POST"], "HTTP \(status) must neither follow Location nor retry the write")
    }
  }

  func testMultipleAccountsPreserveRecordsAndOnlyMatchingStableTargetIsBlocked() async throws {
    let journal = HostingReviewOperationJournal(root: try root()), first = try JournalFixture.context(), second = try JournalFixture.context(userID: "43")
    _ = try await submit(HostingReviewSubmissionCoordinator(journal: journal), JournalFixture.confirmation(first), send: { _, _ in throw HostingError.networkFailure })
    let coordinator = HostingReviewSubmissionCoordinator(journal: journal)
    let alias = try JournalFixture.context(account: first.target.accountID, repository: "PRIVATE/PROJECT")
    let aliasBlocked = await coordinator.isBlocked(alias.target), otherBlocked = await coordinator.isBlocked(second.target)
    XCTAssertTrue(aliasBlocked); XCTAssertFalse(otherBlocked)
    let report = try await submit(coordinator, JournalFixture.confirmation(second)); XCTAssertTrue(report.complete)
    XCTAssertEqual(try journal.records().count, 2)
    let firstOnly = try await coordinator.recoveredOperations(accountID: first.target.accountID)
    XCTAssertEqual(firstOnly.count, 1); XCTAssertTrue(firstOnly[0].identity.matches(alias.target))
  }

  func testAcknowledgementMustPersistBeforeUnblockingAndNeverResendsOldTicket() async throws {
    let checkpoint = JournalCheckpoint(), root = try root(), context = try JournalFixture.context()
    let journal = HostingReviewOperationJournal(root: root, checkpoint: { try checkpoint.check($0) }), coordinator = HostingReviewSubmissionCoordinator(journal: journal)
    let confirmation = try JournalFixture.confirmation(context)
    _ = try await submit(coordinator, confirmation, send: { _, _ in throw HostingError.networkFailure })
    checkpoint.fail(["manuallyAcknowledged"])
    do { try await coordinator.acknowledgePlatformCheck(context.target); XCTFail() } catch { XCTAssertEqual(error as? HostingReviewJournalError, .unavailable) }
    let failedAckBlocked = await coordinator.isBlocked(context.target); XCTAssertTrue(failedAckBlocked)
    XCTAssertTrue(try HostingReviewOperationJournal(root: root).records()[0].isUnresolved)
    checkpoint.fail([]); try await coordinator.acknowledgePlatformCheck(context.target)
    XCTAssertEqual(try journal.records()[0].state, .manuallyAcknowledged)
    let blocked = await coordinator.isBlocked(context.target); XCTAssertFalse(blocked)
    let old = try await submit(coordinator, confirmation, send: { _, _ in XCTFail("Acknowledgement must not replay"); throw HostingError.networkFailure })
    XCTAssertTrue(old.hasUnknown)
    let new = try await submit(coordinator, JournalFixture.confirmation(context)); XCTAssertTrue(new.complete)
  }

  func testSingleRecoveredAcknowledgementDoesNotClearAnotherUnknownOperation() async throws {
    let journal = HostingReviewOperationJournal(root: try root()), context = try JournalFixture.context(), confirmation = try JournalFixture.confirmation(context, count: 2)
    try journal.prepare(confirmation)
    for item in confirmation.items { try journal.update(confirmationID: confirmation.id, itemID: item.id, state: .resultUnknown) }
    let coordinator = HostingReviewSubmissionCoordinator(journal: journal), records = try journal.records()
    try await coordinator.ackRecoveredOperation(records[0].id)
    let blocked = await coordinator.isBlocked(context.target); XCTAssertTrue(blocked)
    XCTAssertEqual(try journal.records().filter(\.isUnresolved).count, 1)
  }

  func testRecoveredMetadataInspectionRequiresStableReceiptAndDoesNotUnblock() async throws {
    let journal = HostingReviewOperationJournal(root: try root()), context = try JournalFixture.context()
    _ = try await submit(HostingReviewSubmissionCoordinator(journal: journal), JournalFixture.confirmation(context), readback: { _, _, _ in throw HostingError.networkFailure })
    let coordinator = HostingReviewSubmissionCoordinator(journal: journal), record = try XCTUnwrap(journal.records().first)
    let receipt = try await coordinator.inspectRecoveredReceipt(record.id, validate: {}, readback: { recovered in
      XCTAssertTrue(recovered.identity.matches(context.target)); return JournalFixture.receipt(context)
    })
    XCTAssertEqual(receipt.id, "100")
    let blocked = await coordinator.isBlocked(context.target); XCTAssertTrue(blocked)
    do { _ = try await coordinator.inspectRecoveredReceipt(record.id, validate: {}, readback: { _ in HostingReviewReceipt(id: "different", authorID: "42") }); XCTFail() }
    catch { XCTAssertEqual(error as? HostingReviewError, .readbackRequired) }
    try await coordinator.ackRecoveredOperation(record.id)
    let afterAck = await coordinator.isBlocked(context.target); XCTAssertFalse(afterAck)
  }

  func testRecoveredWithoutReceiptCannotBeResolvedByBodyOrTime() async throws {
    let journal = HostingReviewOperationJournal(root: try root()), context = try JournalFixture.context()
    _ = try await submit(HostingReviewSubmissionCoordinator(journal: journal), JournalFixture.confirmation(context), send: { _, _ in throw HostingError.networkFailure })
    let coordinator = HostingReviewSubmissionCoordinator(journal: journal), record = try XCTUnwrap(journal.records().first)
    do { _ = try await coordinator.inspectRecoveredReceipt(record.id, validate: {}, readback: { _ in XCTFail("No receipt means no identifying GET"); throw HostingError.notFound }); XCTFail() }
    catch { XCTAssertEqual(error as? HostingReviewError, .readbackRequired) }
  }

  func testCorruptAndUnsupportedJournalsFailClosedAndPreserveOriginalBytes() async throws {
    for incompatible in [false, true] {
      let root = try root(), journal = HostingReviewOperationJournal(root: root), context = try JournalFixture.context(), confirmation = try JournalFixture.confirmation(context)
      try journal.prepare(confirmation)
      let original = try raw(root, confirmation.id)
      let bytes = incompatible ? Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "\"version\":1", with: "\"version\":99").utf8) : Data("{broken".utf8)
      try replace(root, confirmation.id, data: bytes)
      let coordinator = HostingReviewSubmissionCoordinator(journal: journal)
      do { _ = try await coordinator.recoveredOperations(); XCTFail() }
      catch { XCTAssertEqual(error as? HostingReviewJournalError, incompatible ? .unsupportedSchema : .corrupt) }
      let blocked = await coordinator.isBlocked(context.target), failed = await coordinator.recoveryFailure()
      XCTAssertTrue(blocked); XCTAssertTrue(failed)
      do { _ = try await submit(coordinator, JournalFixture.confirmation(context), send: { _, _ in XCTFail("Corrupt recovery must fail closed"); throw HostingError.networkFailure }); XCTFail() } catch {}
      XCTAssertEqual(try raw(root, confirmation.id), bytes)
    }
  }

  func testUnsafeFilePermissionsSymlinkAndHardLinkAreRejected() throws {
    for unsafe in ["permissions", "symlink", "hardlink"] {
      let root = try root(), journal = HostingReviewOperationJournal(root: root), confirmation = try JournalFixture.confirmation(JournalFixture.context())
      try journal.prepare(confirmation)
      let file = root.appendingPathComponent(confirmation.id.uuidString + ".json"), other = root.appendingPathComponent("other")
      if unsafe == "permissions" { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
      else if unsafe == "symlink" {
        try FileManager.default.moveItem(at: file, to: other); try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
      } else { XCTAssertEqual(link(file.path, other.path), 0) }
      XCTAssertThrowsError(try journal.records(), unsafe)
    }
  }

  func testSymlinkDirectoryIsRejectedWithoutFollowingIt() throws {
    let root = try root(), destination = root.appendingPathComponent("real"), alias = root.appendingPathComponent("alias")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: destination)
    XCTAssertThrowsError(try HostingReviewOperationJournal(root: alias).records())
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
  }

  func testOversizedFileAndRecordArrayAreRejectedWithoutTruncatingEvidence() throws {
    let root = try root(), journal = HostingReviewOperationJournal(root: root), confirmation = try JournalFixture.confirmation(JournalFixture.context())
    try journal.prepare(confirmation)
    let original = try raw(root, confirmation.id)
    let oversized = Data(repeating: 0x20, count: 131_073)
    try replace(root, confirmation.id, data: oversized); XCTAssertThrowsError(try journal.records())
    XCTAssertEqual(try raw(root, confirmation.id), oversized)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
    let record = try XCTUnwrap((object["records"] as? [[String: Any]])?.first)
    object["records"] = Array(repeating: record, count: 53)
    let tooMany = try JSONSerialization.data(withJSONObject: object)
    try replace(root, confirmation.id, data: tooMany); XCTAssertThrowsError(try journal.records())
    XCTAssertEqual(try raw(root, confirmation.id), tooMany)
  }

  func testInterruptedTemporaryWriteIsNotMistakenForSentIntent() throws {
    let root = try root(), journal = HostingReviewOperationJournal(root: root)
    try Data("interrupted private write".utf8).write(to: root.appendingPathComponent(".write-" + UUID().uuidString))
    XCTAssertTrue(try journal.records().isEmpty)
  }

  func testExplicitPruningKeepsUnresolvedBatchesAndOtherAccountEvidence() async throws {
    let journal = HostingReviewOperationJournal(root: try root()), first = try JournalFixture.context(), other = try JournalFixture.context(userID: "43")
    _ = try await submit(HostingReviewSubmissionCoordinator(journal: journal), JournalFixture.confirmation(first), send: { _, _ in throw HostingError.networkFailure })
    _ = try await submit(HostingReviewSubmissionCoordinator(journal: journal), JournalFixture.confirmation(other))
    XCTAssertEqual(try journal.records().count, 2)
    try journal.pruneCompletedRecords()
    let records = try journal.records(); XCTAssertEqual(records.count, 1); XCTAssertTrue(records[0].isUnresolved)
    XCTAssertEqual(records[0].identity.accountID, first.target.accountID)
  }

  func testSeparateCoordinatorsCannotBypassDurableStableTargetBarrier() async throws {
    let journal = HostingReviewOperationJournal(root: try root()), context = try JournalFixture.context(), gate = JournalGate(), count = JournalCounter()
    let first = HostingReviewSubmissionCoordinator(journal: journal), second = HostingReviewSubmissionCoordinator(journal: journal)
    let confirmation = try JournalFixture.confirmation(context)
    let task = Task {
      try await submit(first, confirmation, send: { _, context in _ = await count.next(); await gate.hold(); return JournalFixture.receipt(context) })
    }
    defer { task.cancel(); Task { await gate.release() } }
    for _ in 0..<1_000 { if await gate.waiting() { break }; try await Task.sleep(for: .milliseconds(2)) }
    let waiting = await gate.waiting(); XCTAssertTrue(waiting)
    do { _ = try await submit(second, JournalFixture.confirmation(context), send: { _, _ in XCTFail("Second coordinator bypassed durable intent"); throw HostingError.networkFailure }); XCTFail() }
    catch { XCTAssertEqual(error as? HostingReviewError, .resultUnknown) }
    await gate.release(); let report = try await task.value; XCTAssertTrue(report.complete)
    let sent = await count.count(); XCTAssertEqual(sent, 1)
  }

  func testReceiptPreservesMoreThanOneHundredExistingReviewersAcrossRestartInspection() async throws {
    let journal = HostingReviewOperationJournal(root: try root()), context = try JournalFixture.context(provider: .github)
    let existing = (1...150).map { HostingReviewer(id: String($0), login: "reviewer\($0)") }
    let selection = HostingReviewerSelection(context: context, reviewers: [HostingReviewer(id: "9999", login: "selected")], existingReviewers: existing)
    let confirmation = try HostingReviewConfirmation(context: context, items: [HostingReviewSubmissionItem(mutation: .requestReviewers(selection))])
    let receipt = HostingReviewReceipt(id: context.target.requestID, authorID: context.target.userID,
      commitSHA: context.revision.headSHA, requestedReviewerIDs: existing.map(\.id) + ["9999"])
    _ = try await submit(HostingReviewSubmissionCoordinator(journal: journal), confirmation, send: { _, _ in receipt },
      readback: { _, _, _ in throw HostingError.networkFailure })
    let record = try XCTUnwrap(journal.records().first)
    XCTAssertEqual(record.receipt?.requestedReviewerIDs.count, 151)
    XCTAssertEqual(Set(record.receipt?.requestedReviewerIDs ?? []), Set(receipt.requestedReviewerIDs))
    XCTAssertTrue(record.receipt?.requestedReviewerIDs.contains("9999") == true)
    let restarted = HostingReviewSubmissionCoordinator(journal: journal)
    let evidence = try await restarted.inspectRecoveredReceipt(record.id, validate: {}, readback: { _ in receipt })
    XCTAssertEqual(Set(evidence.requestedReviewerIDs), Set(receipt.requestedReviewerIDs))
    let blocked = await restarted.isBlocked(context.target); XCTAssertTrue(blocked)
  }

  func testReviewerReceiptAboveBoundFailsClosedInsteadOfTruncating() throws {
    let journal = HostingReviewOperationJournal(root: try root()), context = try JournalFixture.context(), confirmation = try JournalFixture.confirmation(context)
    try journal.prepare(confirmation)
    try journal.update(confirmationID: confirmation.id, itemID: confirmation.items[0].id, state: .possiblySent)
    let receipt = HostingReviewReceipt(id: "987", authorID: "42", requestedReviewerIDs: (1...1001).map(String.init))
    XCTAssertThrowsError(try journal.update(confirmationID: confirmation.id, itemID: confirmation.items[0].id, state: .possiblySent, receipt: receipt))
    let record = try XCTUnwrap(journal.records().first)
    XCTAssertTrue(record.isUnresolved); XCTAssertNil(record.receipt)
  }

  func testDurableCreationSynchronizesNewChainAndExistingRetryAfterFailure() throws {
    let parent = try root(), nested = parent.appendingPathComponent("support/GitPier/ReviewOperations"), checkpoint = JournalCheckpoint()
    checkpoint.fail(["namespaceSync"])
    XCTAssertThrowsError(try HostingPrivateDirectory(nested, durableCreation: true, durabilityCheckpoint: { try checkpoint.check($0) }))
    XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path), "A sync failure can leave newly created directory entries behind")
    checkpoint.fail([]); checkpoint.clearEvents()
    let retried = try HostingPrivateDirectory(nested, durableCreation: true, durabilityCheckpoint: { try checkpoint.check($0) })
    retried.closeDirectory()
    let retryEvents = checkpoint.events()
    XCTAssertGreaterThanOrEqual(retryEvents.count, 3); XCTAssertTrue(retryEvents.allSatisfy { $0 == "namespaceSync" })
    checkpoint.clearEvents()
    let existing = try HostingPrivateDirectory(nested, durableCreation: true, durabilityCheckpoint: { try checkpoint.check($0) })
    existing.closeDirectory()
    XCTAssertEqual(checkpoint.events(), retryEvents, "Existing paths must finish the same ancestor sync work as a mkdir/EEXIST retry")
  }

  func testNamespaceSyncFailureNeverPOSTsAndRetryOfCreatedPathCanComplete() async throws {
    let nested = try root().appendingPathComponent("new/support/ReviewOperations"), checkpoint = JournalCheckpoint(), count = JournalCounter()
    let journal = HostingReviewOperationJournal(root: nested, checkpoint: { try checkpoint.check($0) }), context = try JournalFixture.context()
    checkpoint.fail(["namespaceSync"])
    do {
      _ = try await submit(HostingReviewSubmissionCoordinator(journal: journal), JournalFixture.confirmation(context), send: { _, context in
        _ = await count.next(); return JournalFixture.receipt(context)
      })
      XCTFail("An unsynced namespace authorized a POST")
    } catch { XCTAssertEqual(error as? HostingReviewJournalError, .unavailable) }
    let beforeRetry = await count.count(); XCTAssertEqual(beforeRetry, 0)
    checkpoint.fail([])
    let completed = try await submit(HostingReviewSubmissionCoordinator(journal: journal), JournalFixture.confirmation(context), send: { _, context in
      _ = await count.next(); return JournalFixture.receipt(context)
    })
    XCTAssertTrue(completed.complete)
    let afterRetry = await count.count(); XCTAssertEqual(afterRetry, 1)
  }

  func testIntentRequiresFileSyncRenameDirectorySyncAndDriveBarrierBeforePOST() async throws {
    let checkpoint = JournalCheckpoint(), journal = HostingReviewOperationJournal(root: try root(), checkpoint: { try checkpoint.check($0) })
    let confirmation = try JournalFixture.confirmation(JournalFixture.context())
    let report = try await submit(HostingReviewSubmissionCoordinator(journal: journal), confirmation, send: { _, context in
      XCTAssertEqual(Array(checkpoint.events().suffix(6)), ["possiblySent", "fileValidated", "fileSync", "rename", "directorySync", "fullSync"])
      return JournalFixture.receipt(context)
    })
    XCTAssertTrue(report.complete, "The real local filesystem must support checked F_FULLFSYNC to authorize this synthetic POST")
  }

  func testEveryIntentDurabilityCheckpointFailureStopsPOSTWithoutFallback() async throws {
    for stage in ["fileValidated", "fileSync", "rename", "directorySync", "fullSync"] {
      let checkpoint = JournalCheckpoint(); checkpoint.fail([stage], after: "possiblySent")
      let journal = HostingReviewOperationJournal(root: try root(), checkpoint: { try checkpoint.check($0) }), context = try JournalFixture.context()
      let report = try await submit(HostingReviewSubmissionCoordinator(journal: journal), JournalFixture.confirmation(context), send: { _, _ in
        XCTFail("POST despite a failed \(stage) intent barrier"); throw HostingError.networkFailure
      })
      guard case .failed(.journal(.unavailable)) = report.results[0].outcome else { return XCTFail("Missing persistence failure at \(stage)") }
      let records = try journal.records()
      XCTAssertEqual(records.count, 1)
      if stage == "directorySync" || stage == "fullSync" {
        XCTAssertTrue(records[0].isUnresolved, "A rename may already be visible even though the durability barrier failed")
        let restarted = HostingReviewSubmissionCoordinator(journal: journal)
        let blocked = await restarted.isBlocked(context.target); XCTAssertTrue(blocked)
      } else { XCTAssertEqual(records[0].state, .notSent) }
    }
  }

  func testFullSyncRejectsUmaskRestrictedIntentInIsolatedProcess() async throws {
    let probe = "GITPIER_REVIEW_UMASK_PROBE"
    if ProcessInfo.processInfo.environment[probe] == "1" {
      let directory = try HostingPrivateDirectory(root(), durableCreation: true); defer { directory.closeDirectory() }
      // The process-wide mask changes only in this disposable XCTest child, and
      // only around synchronous file IO. The parent suite never changes umask.
      let previous = umask(0o777)
      do {
        defer { umask(previous) }
        XCTAssertThrowsError(try directory.write(Data("intent".utf8), name: "unreadable.json", fullSync: true))
      }
      XCTAssertNil(try directory.read("unreadable.json"))
      FileHandle.standardOutput.write(Data("Review umask probe completed\n".utf8))
      return
    }
    let result = try await ProcessRunner().run(executable: "/usr/bin/xcrun", arguments: ["xctest", "-XCTest",
      "GitPierCoreTests.HostingReviewJournalTests/testFullSyncRejectsUmaskRestrictedIntentInIsolatedProcess",
      Bundle(for: HostingReviewJournalTests.self).bundleURL.path], directory: nil, environment: [probe: "1"], timeout: 30)
    XCTAssertEqual(result.code, 0, result.errorText + result.text)
    XCTAssertTrue(result.text.contains("Review umask probe completed"))
  }

  func testDurableCreationBoundsRetainedAncestorDescriptorsBeforeCreatingChain() throws {
    let parent = try root(), nested = parent.appendingPathComponent(Array(repeating: "x", count: 129).joined(separator: "/"))
    XCTAssertThrowsError(try HostingPrivateDirectory(nested, durableCreation: true))
    XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("x").path))
  }

  func testHelperDefaultModeDoesNotOptExistingCredentialUsersIntoNewBarriers() throws {
    let directory = try HostingPrivateDirectory(root(), durabilityCheckpoint: { _ in XCTFail("Default directory mode changed"); throw HostingError.storageFailure })
    defer { directory.closeDirectory() }
    let data = Data("synthetic compatibility bytes".utf8)
    try directory.write(data, name: "default.json", durabilityCheckpoint: { _ in XCTFail("Default write mode changed"); throw HostingError.storageFailure })
    XCTAssertEqual(try directory.read("default.json"), data)
  }

  func testPostRenameAcknowledgementFailureKeepsRecoveredUnknownAndRejectsPruningUntilRetry() async throws {
    for barrier in ["directorySync", "fullSync"] {
      let checkpoint = JournalCheckpoint(), root = try root(), context = try JournalFixture.context(), count = JournalCounter()
      let journal = HostingReviewOperationJournal(root: root, checkpoint: { try checkpoint.check($0) })
      _ = try await submit(HostingReviewSubmissionCoordinator(journal: journal), JournalFixture.confirmation(context), send: { _, _ in
        _ = await count.next(); throw HostingError.networkFailure
      })
      // Start with no process-memory uncertain map: this is the restart path.
      let restarted = HostingReviewSubmissionCoordinator(journal: journal), record = try XCTUnwrap(journal.records().first)
      checkpoint.fail([barrier], after: "manuallyAcknowledged")
      do { try await restarted.ackRecoveredOperation(record.id); XCTFail() }
      catch { XCTAssertEqual(error as? HostingReviewJournalError, .unavailable) }
      XCTAssertEqual(try journal.records().first?.state, .manuallyAcknowledged, "rename may be visible even though its barrier failed")
      let visible = try await restarted.recoveredOperations(), blocked = await restarted.isBlocked(context.target)
      XCTAssertEqual(visible.first?.state, .resultUnknown); XCTAssertTrue(blocked)
      do { try await restarted.pruneCompletedOperations(); XCTFail("Pending acknowledgement evidence was pruned") }
      catch { XCTAssertEqual(error as? HostingReviewError, .resultUnknown) }
      XCTAssertFalse(try raw(root, record.confirmationID).isEmpty)
      do { _ = try await submit(restarted, JournalFixture.confirmation(context), send: { _, _ in _ = await count.next(); throw HostingError.networkFailure }); XCTFail() }
      catch { XCTAssertEqual(error as? HostingReviewError, .resultUnknown) }
      checkpoint.fail([])
      try await restarted.ackRecoveredOperation(record.id)
      let afterRetry = try await restarted.recoveredOperations(), stillBlocked = await restarted.isBlocked(context.target)
      XCTAssertEqual(afterRetry.first?.state, .manuallyAcknowledged); XCTAssertFalse(stillBlocked)
      let sent = await count.count(); XCTAssertEqual(sent, 1)
    }
  }

  func testTargetAcknowledgementRetryDoesNotRewritePreviouslyCheckedHistory() async throws {
    let checkpoint = JournalCheckpoint(), root = try root(), context = try JournalFixture.context()
    let journal = HostingReviewOperationJournal(root: root, checkpoint: { try checkpoint.check($0) }), coordinator = HostingReviewSubmissionCoordinator(journal: journal)
    let original = try JournalFixture.confirmation(context)
    _ = try await submit(coordinator, original, send: { _, _ in throw HostingError.networkFailure })
    try await coordinator.acknowledgePlatformCheck(context.target)
    let historicalBytes = try raw(root, original.id)
    let current = try JournalFixture.confirmation(context)
    _ = try await submit(coordinator, current, send: { _, _ in throw HostingError.networkFailure })
    checkpoint.fail(["fullSync"], after: "manuallyAcknowledged")
    do { try await coordinator.acknowledgePlatformCheck(context.target); XCTFail() } catch {}
    checkpoint.fail([]); checkpoint.clearEvents()
    try await coordinator.acknowledgePlatformCheck(context.target)
    XCTAssertEqual(checkpoint.events().filter { $0 == "manuallyAcknowledged" }.count, 1)
    XCTAssertEqual(try raw(root, original.id), historicalBytes)
    let blocked = await coordinator.isBlocked(context.target); XCTAssertFalse(blocked)
  }

  func testPostRenameVerifiedBarrierFailureRemainsUnknownAndCannotBePrunedAsCompleted() async throws {
    let checkpoint = JournalCheckpoint(), root = try root(), context = try JournalFixture.context()
    let journal = HostingReviewOperationJournal(root: root, checkpoint: { try checkpoint.check($0) }), coordinator = HostingReviewSubmissionCoordinator(journal: journal)
    checkpoint.fail(["fullSync"], after: "submittedAndVerified"); checkpoint.failAlways(["resultUnknown"])
    let confirmation = try JournalFixture.confirmation(context), report = try await submit(coordinator, confirmation)
    XCTAssertTrue(report.hasUnknown); XCTAssertEqual(try journal.records().first?.state, .submittedAndVerified)
    let recovered = try await coordinator.recoveredOperations(), blocked = await coordinator.isBlocked(context.target)
    XCTAssertEqual(recovered.first?.state, .resultUnknown); XCTAssertTrue(blocked)
    checkpoint.fail([])
    // Explicit housekeeping can remove another completed batch, while the local
    // unknown overlay keeps this barrier-failed batch even if disk looks terminal.
    let other = try JournalFixture.context(userID: "43")
    _ = try await submit(coordinator, JournalFixture.confirmation(other))
    try await coordinator.pruneCompletedOperations()
    XCTAssertEqual(try journal.records().count, 1); XCTAssertFalse(try raw(root, confirmation.id).isEmpty)
    try await coordinator.acknowledgePlatformCheck(context.target)
    let afterAck = await coordinator.isBlocked(context.target); XCTAssertFalse(afterAck)
    XCTAssertEqual(try journal.records().first?.state, .manuallyAcknowledged)
  }

  func testSuccessfulFullReconciliationCanResolveFailedAcknowledgementBarrier() async throws {
    let checkpoint = JournalCheckpoint(), context = try JournalFixture.context(), count = JournalCounter()
    let journal = HostingReviewOperationJournal(root: try root(), checkpoint: { try checkpoint.check($0) }), coordinator = HostingReviewSubmissionCoordinator(journal: journal)
    let confirmation = try JournalFixture.confirmation(context)
    _ = try await submit(coordinator, confirmation, send: { _, context in _ = await count.next(); return JournalFixture.receipt(context) },
      readback: { _, _, _ in throw HostingError.networkFailure })
    let record = try XCTUnwrap(journal.records().first)
    checkpoint.fail(["fullSync"], after: "manuallyAcknowledged")
    do { try await coordinator.ackRecoveredOperation(record.id); XCTFail() } catch {}
    checkpoint.fail([])
    let reconciled = try await coordinator.reconcile(confirmation.id, validate: {}, readback: { receipt, _, _ in receipt })
    XCTAssertTrue(reconciled.complete)
    let recovered = try await coordinator.recoveredOperations(), blocked = await coordinator.isBlocked(context.target)
    XCTAssertEqual(recovered.first?.state, .submittedAndVerified); XCTAssertFalse(blocked)
    try await coordinator.pruneCompletedOperations(); XCTAssertTrue(try journal.records().isEmpty)
    let sent = await count.count(); XCTAssertEqual(sent, 1)
  }

  func testDurableAcknowledgementConvergesDespitePostWriteRecoveryReadFailure() async throws {
    for targetWide in [false, true] {
      let checkpoint = JournalCheckpoint(), context = try JournalFixture.context(), count = JournalCounter()
      let journal = HostingReviewOperationJournal(root: try root(), checkpoint: { try checkpoint.check($0) }), coordinator = HostingReviewSubmissionCoordinator(journal: journal)
      _ = try await submit(coordinator, JournalFixture.confirmation(context), send: { _, _ in _ = await count.next(); throw HostingError.networkFailure })
      let record = try XCTUnwrap(journal.records().first)
      checkpoint.fail(["namespaceSync"], after: "manuallyAcknowledged")
      do {
        if targetWide { try await coordinator.acknowledgePlatformCheck(context.target) }
        else { try await coordinator.ackRecoveredOperation(record.id) }
        XCTFail("The post-write recovery read was not interrupted")
      } catch { XCTAssertEqual(error as? HostingReviewJournalError, .unavailable) }
      checkpoint.fail([])
      let recovered = try await coordinator.recoveredOperations(), blocked = await coordinator.isBlocked(context.target)
      XCTAssertEqual(recovered.first?.state, .manuallyAcknowledged)
      XCTAssertFalse(blocked, "A successful durable acknowledgement must not be stranded by a later display read failure")
      let sent = await count.count(); XCTAssertEqual(sent, 1)
    }
  }

  func testSingleDurableAcknowledgementReadFailureKeepsOtherUnknownInSameConfirmation() async throws {
    let checkpoint = JournalCheckpoint(), context = try JournalFixture.context()
    let journal = HostingReviewOperationJournal(root: try root(), checkpoint: { try checkpoint.check($0) }), confirmation = try JournalFixture.confirmation(context, count: 2)
    try journal.prepare(confirmation)
    for item in confirmation.items { try journal.update(confirmationID: confirmation.id, itemID: item.id, state: .resultUnknown) }
    let coordinator = HostingReviewSubmissionCoordinator(journal: journal), records = try journal.records()
    // First create the in-process uncertain key through a failed barrier on this
    // recovered coordinator, then let the explicit retry save but fail its reload.
    checkpoint.fail(["fullSync"], after: "manuallyAcknowledged")
    do { try await coordinator.ackRecoveredOperation(records[0].id); XCTFail() } catch {}
    checkpoint.fail(["namespaceSync"], after: "manuallyAcknowledged")
    do { try await coordinator.ackRecoveredOperation(records[0].id); XCTFail() }
    catch { XCTAssertEqual(error as? HostingReviewJournalError, .unavailable) }
    checkpoint.fail([])
    let recovered = try await coordinator.recoveredOperations(), blocked = await coordinator.isBlocked(context.target)
    XCTAssertEqual(recovered.map(\.state), [.manuallyAcknowledged, .resultUnknown]); XCTAssertTrue(blocked)
    try await coordinator.ackRecoveredOperation(records[1].id)
    let resolved = await coordinator.isBlocked(context.target); XCTAssertFalse(resolved)
  }

  func testDiscardPrivateCompletedReportsKeepsConsumedTicketsWithoutJournalAndIsolatesAccounts() async throws {
    let coordinator = HostingReviewSubmissionCoordinator(), context = try JournalFixture.context(), other = try JournalFixture.context(userID: "43")
    let first = try JournalFixture.confirmation(context), second = try JournalFixture.confirmation(other)
    _ = try await submit(coordinator, first); _ = try await submit(coordinator, second)
    await coordinator.discardPrivateContent(accountID: context.target.accountID)
    let discarded = await coordinator.report(first.id), retained = await coordinator.report(second.id)
    XCTAssertNil(discarded); XCTAssertNotNil(retained)
    do { _ = try await submit(coordinator, first, send: { _, _ in XCTFail("A discarded cached report allowed the ticket to POST again"); throw HostingError.networkFailure }); XCTFail() }
    catch { XCTAssertEqual(error as? HostingReviewError, .alreadySubmitted) }
    let fresh = try JournalFixture.confirmation(context), freshReport = try await submit(coordinator, fresh)
    XCTAssertTrue(freshReport.complete, "Discard affects existing tickets, not a later explicitly confirmed submission")
    await coordinator.discardPrivateContent()
    let secondAfterStop = await coordinator.report(second.id), freshAfterStop = await coordinator.report(fresh.id)
    XCTAssertNil(secondAfterStop); XCTAssertNil(freshAfterStop)
    do { _ = try await submit(coordinator, second); XCTFail() }
    catch { XCTAssertEqual(error as? HostingReviewError, .alreadySubmitted) }
  }

  func testDiscardDuringPreflightKeepsActiveLockAndStopsBeforePOST() async throws {
    let journal = HostingReviewOperationJournal(root: try root()), coordinator = HostingReviewSubmissionCoordinator(journal: journal)
    let context = try JournalFixture.context(), confirmation = try JournalFixture.confirmation(context), gate = JournalGate()
    let task = Task {
      try await coordinator.submit(confirmation, current: { await gate.holdOnce(); return context }, validate: {}, validateAnchor: { _ in },
        send: { _, _ in XCTFail("A discarded preflight started a POST"); throw HostingError.networkFailure }, readback: { receipt, _, _ in receipt })
    }
    defer { task.cancel(); Task { await gate.release() } }
    try await waitForGate(gate)
    await coordinator.discardPrivateContent(accountID: context.target.accountID)
    do { _ = try await submit(coordinator, JournalFixture.confirmation(context)); XCTFail("Discard removed the active target lock") }
    catch { XCTAssertEqual(error as? HostingReviewError, .alreadySubmitting) }
    await gate.release()
    do { _ = try await task.value; XCTFail("A discarded task returned its private report") }
    catch { XCTAssertEqual(error as? HostingError, .accountChanged) }
    let report = await coordinator.report(confirmation.id); XCTAssertNil(report)
    XCTAssertTrue(try journal.records().isEmpty)
    do { _ = try await submit(coordinator, confirmation); XCTFail() }
    catch { XCTAssertEqual(error as? HostingReviewError, .alreadySubmitted) }
  }

  func testDiscardDuringPOSTStillJournalsLateReceiptWithoutRestoringPrivateReport() async throws {
    let journal = HostingReviewOperationJournal(root: try root()), coordinator = HostingReviewSubmissionCoordinator(journal: journal)
    let context = try JournalFixture.context(), confirmation = try JournalFixture.confirmation(context), gate = JournalGate(), count = JournalCounter()
    let task = Task {
      try await submit(coordinator, confirmation, send: { _, context in
        _ = await count.next(); await gate.hold(); return JournalFixture.receipt(context, id: "7001")
      }, readback: { _, _, _ in XCTFail("Private-content discard must stop a new body/anchor readback"); throw HostingError.networkFailure })
    }
    defer { task.cancel(); Task { await gate.release() } }
    try await waitForGate(gate)
    await coordinator.discardPrivateContent(accountID: context.target.accountID)
    await gate.release()
    do { _ = try await task.value; XCTFail("A discarded POST returned its private payload") }
    catch { XCTAssertEqual(error as? HostingError, .accountChanged) }
    let report = await coordinator.report(confirmation.id), blocked = await coordinator.isBlocked(context.target)
    XCTAssertNil(report); XCTAssertTrue(blocked)
    let record = try XCTUnwrap(journal.records().first)
    XCTAssertEqual(record.state, .resultUnknown); XCTAssertEqual(record.receipt?.id, "7001")
    do { _ = try await coordinator.reconcile(confirmation.id, validate: {}, readback: { _, _, _ in XCTFail("No private context may survive discard"); throw HostingError.networkFailure }); XCTFail() }
    catch { XCTAssertEqual(error as? HostingReviewError, .targetChanged) }
    _ = try await coordinator.inspectRecoveredReceipt(record.id, validate: {}, readback: { _ in JournalFixture.receipt(context, id: "7001") })
    let sent = await count.count(); XCTAssertEqual(sent, 1)
  }

  func testDiscardDuringReadbackNeverRestoresOrReturnsPrivateReport() async throws {
    let journal = HostingReviewOperationJournal(root: try root()), coordinator = HostingReviewSubmissionCoordinator(journal: journal)
    let context = try JournalFixture.context(), confirmation = try JournalFixture.confirmation(context), gate = JournalGate()
    let task = Task {
      try await submit(coordinator, confirmation, readback: { receipt, _, _ in await gate.hold(); return receipt })
    }
    defer { task.cancel(); Task { await gate.release() } }
    try await waitForGate(gate)
    await coordinator.discardPrivateContent()
    await gate.release()
    do { _ = try await task.value; XCTFail("A discarded readback returned a private report") }
    catch { XCTAssertEqual(error as? HostingError, .accountChanged) }
    let cached = await coordinator.report(confirmation.id), blocked = await coordinator.isBlocked(context.target)
    XCTAssertNil(cached); XCTAssertTrue(blocked)
    XCTAssertEqual(try journal.records().first?.state, .resultUnknown)
    XCTAssertEqual(try journal.records().first?.receipt?.id, "100")
  }

  func testDiscardDuringFullReconciliationKeepsOnlyMetadataRecovery() async throws {
    let journal = HostingReviewOperationJournal(root: try root()), coordinator = HostingReviewSubmissionCoordinator(journal: journal)
    let context = try JournalFixture.context(), confirmation = try JournalFixture.confirmation(context), gate = JournalGate()
    _ = try await submit(coordinator, confirmation, readback: { _, _, _ in throw HostingError.networkFailure })
    let task = Task {
      try await coordinator.reconcile(confirmation.id, validate: {}, readback: { receipt, _, _ in await gate.hold(); return receipt })
    }
    defer { task.cancel(); Task { await gate.release() } }
    try await waitForGate(gate)
    await coordinator.discardPrivateContent(accountID: context.target.accountID)
    await gate.release()
    do { _ = try await task.value; XCTFail("Late reconciliation resurrected a private report") }
    catch { XCTAssertEqual(error as? HostingError, .accountChanged) }
    let report = await coordinator.report(confirmation.id); XCTAssertNil(report)
    let recovered = try await coordinator.recoveredOperations()
    XCTAssertEqual(recovered.first?.state, .resultUnknown)
    do { _ = try await coordinator.reconcile(confirmation.id, validate: {}, readback: { receipt, _, _ in receipt }); XCTFail() }
    catch { XCTAssertEqual(error as? HostingReviewError, .targetChanged) }
  }

  func testDiscardPreservesExactPartialUnknownOverlayAndOtherAccountReport() async throws {
    let checkpoint = JournalCheckpoint(), journal = HostingReviewOperationJournal(root: try root(), checkpoint: { try checkpoint.check($0) })
    let coordinator = HostingReviewSubmissionCoordinator(journal: journal), context = try JournalFixture.context(), other = try JournalFixture.context(userID: "43"), count = JournalCounter()
    let otherConfirmation = try JournalFixture.confirmation(other)
    _ = try await submit(coordinator, otherConfirmation)
    let confirmation = try JournalFixture.confirmation(context, count: 5)
    let report = try await submit(coordinator, confirmation, send: { _, context in
      JournalFixture.receipt(context, id: String(await count.next()))
    }, readback: { receipt, _, _ in
      if receipt.id == "3" { checkpoint.fail(["fullSync"], after: "submittedAndVerified"); checkpoint.failAlways(["resultUnknown"]) }
      return receipt
    })
    XCTAssertEqual(report.submittedCount, 2); XCTAssertTrue(report.hasUnknown)
    checkpoint.fail([])
    XCTAssertEqual(try journal.records().filter { $0.confirmationID == confirmation.id }.map(\.state),
      [.submittedAndVerified, .submittedAndVerified, .submittedAndVerified, .notSent, .notSent])
    await coordinator.discardPrivateContent(accountID: context.target.accountID)
    let discarded = await coordinator.report(confirmation.id), retained = await coordinator.report(otherConfirmation.id)
    XCTAssertNil(discarded); XCTAssertNotNil(retained)
    let recovered = try await coordinator.recoveredOperations(accountID: context.target.accountID)
    XCTAssertEqual(recovered.map(\.state), [.submittedAndVerified, .submittedAndVerified, .resultUnknown, .notSent, .notSent])
    try await coordinator.pruneCompletedOperations()
    XCTAssertEqual(try journal.records().count, 5, "Only the other completed account batch may be pruned")
    try await coordinator.acknowledgePlatformCheck(context.target)
    let unblocked = await coordinator.isBlocked(context.target); XCTAssertFalse(unblocked)
  }

  func testCancelledBeforeActorEntryNeverCachesPayloadConsumesTicketOrPOSTs() async throws {
    for withJournal in [false, true] {
      let journal: HostingReviewOperationJournal? = withJournal ? HostingReviewOperationJournal(root: try root()) : nil
      let coordinator = HostingReviewSubmissionCoordinator(journal: journal), context = try JournalFixture.context()
      let confirmation = try JournalFixture.confirmation(context), gate = JournalGate(), count = JournalCounter()
      let task = Task {
        await gate.hold()
        return try await coordinator.submit(confirmation, current: { XCTFail("Cancelled entry performed preflight"); return context }, validate: {}, validateAnchor: { _ in },
          send: { _, context in _ = await count.next(); return JournalFixture.receipt(context) }, readback: { receipt, _, _ in receipt })
      }
      defer { task.cancel(); Task { await gate.release() } }
      try await waitForGate(gate)
      task.cancel(); await gate.release()
      do { _ = try await task.value; XCTFail("An already cancelled caller entered the coordinator") }
      catch is CancellationError {}
      let cached = await coordinator.report(confirmation.id), sentBeforeRetry = await count.count()
      XCTAssertNil(cached); XCTAssertEqual(sentBeforeRetry, 0)
      XCTAssertTrue(try journal?.records().isEmpty ?? true)
      let retry = try await submit(coordinator, confirmation, send: { _, context in _ = await count.next(); return JournalFixture.receipt(context) })
      XCTAssertTrue(retry.complete, "A ticket cancelled before actor entry must remain unconsumed")
      let sent = await count.count(); XCTAssertEqual(sent, 1)
    }
  }

  func testReconnectWithNewLocalUUIDRemainsBlockedAfterRestartAndCannotAcknowledgeOldUUID() async throws {
    let journal = HostingReviewOperationJournal(root: try root()), old = try JournalFixture.context()
    let original = try JournalFixture.confirmation(old)
    _ = try await submit(HostingReviewSubmissionCoordinator(journal: journal), original,
      readback: { _, _, _ in throw HostingError.networkFailure })
    let record = try XCTUnwrap(journal.records().first)
    let reconnected = try JournalFixture.context(repository: "PRIVATE/PROJECT")
    XCTAssertNotEqual(old.target.accountID, reconnected.target.accountID)
    XCTAssertFalse(record.identity.matches(reconnected.target))
    XCTAssertTrue(record.identity.matchesRemoteWriteTarget(reconnected.target))
    let restarted = HostingReviewSubmissionCoordinator(journal: journal)
    let blocked = await restarted.isBlocked(reconnected.target)
    let localRecords = try await restarted.recoveredOperations(accountID: reconnected.target.accountID)
    XCTAssertTrue(blocked); XCTAssertTrue(localRecords.isEmpty, "Write barriers do not transfer account ownership")
    do { _ = try await submit(restarted, JournalFixture.confirmation(reconnected), send: { _, _ in XCTFail("Reconnect bypassed the previous unknown write"); throw HostingError.networkFailure }); XCTFail() }
    catch { XCTAssertEqual(error as? HostingReviewError, .resultUnknown) }
    do { try await restarted.acknowledgePlatformCheck(reconnected.target); XCTFail("The new local account must not acknowledge the previous account's record") }
    catch { XCTAssertEqual(error as? HostingReviewError, .resultUnknown) }
    let transport = JournalRedirectTransport(status: 200), client = HostingAPIClient(http: HostingHTTPClient(transport: transport))
    let account = HostingAccount(id: reconnected.target.accountID, instance: reconnected.target.instance,
      user: HostingUser(stableID: reconnected.target.userID, login: "reconnected"), kind: .pat, scopes: [])
    do {
      _ = try await client.readRecoveredReviewReceipt(record: record, context: reconnected, account: account, token: HostingToken(accessToken: "synthetic-only"))
      XCTFail("Receipt inspection must retain strict local-account identity")
    } catch { XCTAssertEqual(error as? HostingReviewError, .targetChanged) }
    let methods = await transport.sentMethods(); XCTAssertTrue(methods.isEmpty)
    XCTAssertEqual(try journal.records().first?.identity.accountID, old.target.accountID)
    XCTAssertEqual(try journal.records().first?.state, .resultUnknown)
    try await restarted.ackRecoveredOperation(record.id)
    let resolved = await restarted.isBlocked(reconnected.target); XCTAssertFalse(resolved)
    XCTAssertEqual(try journal.records().first?.identity.accountID, old.target.accountID)
  }

  func testReconnectedUUIDCannotBypassActiveWriteDomainAcrossSharedAndSeparateCoordinators() async throws {
    for mode in 0..<3 {
      let journal: HostingReviewOperationJournal? = mode == 0 ? nil : HostingReviewOperationJournal(root: try root())
      let first = HostingReviewSubmissionCoordinator(journal: journal)
      let second = mode == 2 ? HostingReviewSubmissionCoordinator(journal: journal) : first
      let old = try JournalFixture.context(), reconnected = try JournalFixture.context(repository: "PRIVATE/PROJECT")
      let differentUser = try JournalFixture.context(userID: "43"), gate = JournalGate(), count = JournalCounter()
      let original = try JournalFixture.confirmation(old)
      let task = Task {
        try await submit(first, original, send: { _, context in
          _ = await count.next(); await gate.hold(); return JournalFixture.receipt(context)
        })
      }
      defer { task.cancel(); Task { await gate.release() } }
      try await waitForGate(gate)
      do { _ = try await submit(second, JournalFixture.confirmation(reconnected), send: { _, _ in XCTFail("The same remote write domain sent through a new local UUID"); throw HostingError.networkFailure }); XCTFail() }
      catch { XCTAssertEqual(error as? HostingReviewError, mode == 2 ? .resultUnknown : .alreadySubmitting) }
      let independent = try await submit(second, JournalFixture.confirmation(differentUser))
      XCTAssertTrue(independent.complete, "A different stable user must retain an independent write domain")
      await gate.release()
      let completed = try await task.value, sent = await count.count()
      XCTAssertTrue(completed.complete); XCTAssertEqual(sent, 1)
    }
  }

  func testJournalPreparationAndIntentCannotBypassUnknownUsingNewLocalUUID() throws {
    let journal = HostingReviewOperationJournal(root: try root()), old = try JournalFixture.context()
    let reconnected = try JournalFixture.context(repository: "PRIVATE/PROJECT")
    let first = try JournalFixture.confirmation(old), second = try JournalFixture.confirmation(reconnected)
    // Two preflights may prepare before either process claims its durable send intent.
    try journal.prepare(first); try journal.prepare(second)
    try journal.update(confirmationID: first.id, itemID: first.items[0].id, state: .possiblySent)
    XCTAssertThrowsError(try journal.update(confirmationID: second.id, itemID: second.items[0].id, state: .possiblySent)) {
      XCTAssertEqual($0 as? HostingReviewError, .resultUnknown)
    }
    XCTAssertThrowsError(try journal.prepare(JournalFixture.confirmation(reconnected))) {
      XCTAssertEqual($0 as? HostingReviewError, .resultUnknown)
    }
    let records = try journal.records()
    XCTAssertEqual(records.first { $0.confirmationID == first.id }?.state, .resultUnknown)
    XCTAssertEqual(records.first { $0.confirmationID == second.id }?.state, .notSent)
  }

  func testRemoteWriteBarrierKeepsDifferentStableUsersInstancesAndProvidersIndependent() async throws {
    let journal = HostingReviewOperationJournal(root: try root()), coordinator = HostingReviewSubmissionCoordinator(journal: journal)
    let old = try JournalFixture.context()
    _ = try await submit(coordinator, JournalFixture.confirmation(old), send: { _, _ in throw HostingError.networkFailure })
    let independent = [try JournalFixture.context(userID: "43"),
      try JournalFixture.context(instanceURL: "https://other.code.example"),
      try JournalFixture.context(provider: .gitea)]
    for context in independent {
      let blocked = await coordinator.isBlocked(context.target); XCTAssertFalse(blocked)
      let report = try await submit(coordinator, JournalFixture.confirmation(context)); XCTAssertTrue(report.complete)
    }
    let originalStillBlocked = await coordinator.isBlocked(old.target); XCTAssertTrue(originalStillBlocked)
  }

  func testMixedLocalUUIDAcknowledgementsKeepStrictOwnershipAfterFailedBarrier() async throws {
    let checkpoint = JournalCheckpoint(), journal = HostingReviewOperationJournal(root: try root(), checkpoint: { try checkpoint.check($0) })
    let first = try JournalFixture.context(), second = try JournalFixture.context()
    let a = try JournalFixture.confirmation(first), b = try JournalFixture.confirmation(second)
    // Simulate historical records created before the reconnect-domain barrier existed.
    try journal.prepare(a); try journal.prepare(b)
    try journal.update(confirmationID: a.id, itemID: a.items[0].id, state: .resultUnknown)
    try journal.update(confirmationID: b.id, itemID: b.items[0].id, state: .resultUnknown)
    let coordinator = HostingReviewSubmissionCoordinator(journal: journal)
    checkpoint.fail(["fullSync"], after: "manuallyAcknowledged")
    do { try await coordinator.acknowledgePlatformCheck(first.target); XCTFail("The failed barrier must retain a strict-owner pending acknowledgement") }
    catch { XCTAssertEqual(error as? HostingReviewJournalError, .unavailable) }
    checkpoint.fail([])
    do { try await coordinator.acknowledgePlatformCheck(second.target); XCTFail("Acknowledging one local UUID cannot clear the other UUID's pending barrier") }
    catch { XCTAssertEqual(error as? HostingReviewError, .resultUnknown) }
    let aRecords = try await coordinator.recoveredOperations(accountID: first.target.accountID)
    let bRecords = try await coordinator.recoveredOperations(accountID: second.target.accountID)
    XCTAssertEqual(aRecords.map(\.state), [.resultUnknown]); XCTAssertEqual(bRecords.map(\.state), [.manuallyAcknowledged])
    let secondBlocked = await coordinator.isBlocked(second.target); XCTAssertTrue(secondBlocked)
    do { try await coordinator.acknowledgePlatformCheck(second.target); XCTFail("An empty strict-owner retry must report the remaining cross-UUID barrier") }
    catch { XCTAssertEqual(error as? HostingReviewError, .resultUnknown) }
    await coordinator.discardPrivateContent(accountID: second.target.accountID)
    try await coordinator.acknowledgePlatformCheck(first.target)
    let firstBlocked = await coordinator.isBlocked(first.target), finallyUnblocked = await coordinator.isBlocked(second.target)
    XCTAssertFalse(firstBlocked); XCTAssertFalse(finallyUnblocked)
    XCTAssertTrue(try journal.records().allSatisfy { $0.state == .manuallyAcknowledged })
  }
}
