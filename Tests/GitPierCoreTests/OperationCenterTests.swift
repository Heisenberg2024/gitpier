import XCTest
@testable import GitPierCore

final class OperationCenterTests: XCTestCase {
  func testDuplicateBeginIsIdempotent() {
    var history = OperationCenterHistory(); let record = WorkflowOperationRecord(kind: .clone)
    XCTAssertTrue(history.insert(record)); XCTAssertFalse(history.insert(record)); XCTAssertEqual(history.records.count, 1)
  }
  func testOldAndEqualRevisionsAreRejected() {
    var history = OperationCenterHistory(); var record = WorkflowOperationRecord(kind: .fetch)
    history.insert(record); record.revision = 2; record.state = .running
    XCTAssertTrue(history.update(record)); XCTAssertFalse(history.update(record))
    record.revision = 1; record.state = .queued; XCTAssertFalse(history.update(record))
    XCTAssertEqual(history.records[0].state, .running)
  }
  func testTerminalResultCannotBeRevivedOrChangedByLateProgress() {
    for result in [WorkflowOperationState.succeeded, .failed, .cancelled, .needsAttention, .resultUnknown] {
      var history = OperationCenterHistory(); var record = WorkflowOperationRecord(kind: .push)
      history.insert(record); record.state = result; record.revision = 1; record.canCancel = true
      XCTAssertTrue(history.update(record)); record.state = .running; record.revision = 2
      XCTAssertFalse(history.update(record)); XCTAssertFalse(history.records[0].canCancel)
    }
  }
  func testIdentityCannotBeReassigned() {
    var history = OperationCenterHistory(); let record = WorkflowOperationRecord(kind: .commit, repositoryID: UUID())
    history.insert(record)
    var other = WorkflowOperationRecord(id: record.id, kind: .push, repositoryID: record.repositoryID, startedAt: record.startedAt)
    other.revision = 1; XCTAssertFalse(history.update(other))
    other = WorkflowOperationRecord(id: record.id, kind: .commit, repositoryID: UUID(), startedAt: record.startedAt)
    other.revision = 1; XCTAssertFalse(history.update(other))
  }
  func testHistoryBoundsKeepAllActiveAndUnknown() {
    var history = OperationCenterHistory(recentLimit: 10)
    let active = WorkflowOperationRecord(kind: .clone, state: .running)
    let unknown = WorkflowOperationRecord(kind: .review, state: .resultUnknown, recovery: .reviewJournal)
    history.insert(active); history.insert(unknown)
    for _ in 0..<100 { history.insert(WorkflowOperationRecord(kind: .fetch, state: .succeeded)) }
    XCTAssertEqual(history.records.count, 12)
    XCTAssertTrue(history.records.contains { $0.id == active.id }); XCTAssertTrue(history.records.contains { $0.id == unknown.id })
  }
  func testAutomaticFetchCoalescingDoesNotEraseManualOrActiveWork() {
    let repository = UUID(); var history = OperationCenterHistory()
    history.insert(WorkflowOperationRecord(kind: .automaticFetch, repositoryID: repository, state: .succeeded))
    history.insert(WorkflowOperationRecord(kind: .automaticFetch, repositoryID: repository, state: .running))
    history.insert(WorkflowOperationRecord(kind: .batchFetch, repositoryID: repository, state: .succeeded))
    history.coalesceAutomatic(repositoryID: repository)
    XCTAssertEqual(history.records.count, 2)
  }
  func testJournalReadbackIsTheOnlyUnknownResolutionPath() {
    var history = OperationCenterHistory(); var unknown = WorkflowOperationRecord(kind: .review, state: .resultUnknown, recovery: .reviewJournal)
    history.insert(unknown); unknown.state = .succeeded; unknown.revision = 1
    XCTAssertFalse(history.update(unknown)); history.reconcileReview(unknown)
    XCTAssertEqual(history.records[0].state, .succeeded)
  }
  func testJournalReconciliationRefusesGitOperations() {
    var history = OperationCenterHistory()
    history.reconcileReview(WorkflowOperationRecord(kind: .push, state: .succeeded, recovery: .reviewJournal))
    XCTAssertTrue(history.records.isEmpty)
  }
  func testCancellationIsNotCompletionOrRollback() {
    var history = OperationCenterHistory(); var record = WorkflowOperationRecord(kind: .push, state: .running, canCancel: true)
    history.insert(record); record.cancellationRequested = true; record.canCancel = false; record.revision = 1
    history.update(record)
    XCTAssertEqual(history.records[0].state, .running); XCTAssertNil(history.records[0].completedAt)
    record.state = .succeeded; record.revision = 2; history.update(record)
    XCTAssertEqual(history.records[0].state, .succeeded)
  }
  func testProgressIsBoundedAndNonfiniteValuesIgnored() {
    var history = OperationCenterHistory(); var record = WorkflowOperationRecord(kind: .fetch)
    history.insert(record)
    for (input, expected) in [(Double.infinity, nil), (-1.0, Optional(0.0)), (2.0, Optional(1.0))] {
      record.revision += 1; record.progress = input; history.update(record)
      XCTAssertEqual(history.records[0].progress, expected)
    }
  }
  func testMultipleRepositoriesHaveIndependentIdentities() {
    var history = OperationCenterHistory(); let repo = UUID()
    let records = [WorkflowOperationRecord(kind: .push, repositoryID: repo), WorkflowOperationRecord(kind: .pull, repositoryID: repo), WorkflowOperationRecord(kind: .fetch, repositoryID: UUID())]
    records.forEach { history.insert($0) }; XCTAssertEqual(Set(history.records.map(\.id)).count, 3)
  }
}
