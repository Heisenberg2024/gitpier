import XCTest
@testable import GitPierCore

final class OperationWorkflowProgressTests: XCTestCase {
  func testPushWaitsForObjectWritingAndRetainsProgressThroughRefresh() {
    var work = OperationWorkflowProgress(id: UUID(), kind: .push)
    XCTAssertEqual(work.indicatorValue, 0)
    work.advance(to: .execute)
    XCTAssertTrue(work.receive(.init(phase: .counting, fraction: 1), step: .execute))
    XCTAssertEqual(work.indicatorValue, 0)
    XCTAssertTrue(work.receive(.init(phase: .compressing, fraction: 1), step: .execute))
    XCTAssertEqual(work.indicatorValue, 0)
    XCTAssertTrue(work.receive(.init(phase: .writing, fraction: 0.24), step: .execute))
    XCTAssertEqual(work.indicatorValue, 0.24)
    XCTAssertTrue(work.receive(.init(phase: .writing, fraction: 0.76), step: .execute))
    XCTAssertTrue(work.receive(.init(phase: .resolving, fraction: 0.18), step: .execute))
    XCTAssertEqual(work.indicatorValue, 0.76)
    work.advance(to: .refresh)
    XCTAssertEqual(work.indicatorValue, 0.76)
    work.finish(.succeeded)
    XCTAssertEqual(work.indicatorValue, 1)
  }

  func testCommitAndPushOnlyFillsCompletelyAfterConfirmedSuccess() {
    var work = OperationWorkflowProgress(id: UUID(), kind: .commitAndPush)
    work.advance(to: .commit)
    XCTAssertEqual(work.indicatorValue, 0)
    work.advance(to: .pushTarget)
    work.advance(to: .push)
    XCTAssertTrue(work.receive(.init(phase: .writing, fraction: 1), step: .push))
    XCTAssertEqual(work.indicatorValue, 0.99)
    work.advance(to: .refresh)
    XCTAssertEqual(work.indicatorValue, 0.99)
    work.finish(.resultUnknown)
    XCTAssertEqual(work.indicatorValue, 0.99)
    work.confirmRemoteResult()
    XCTAssertEqual(work.indicatorValue, 1)
  }

  func testMergeAndPushIgnoresPreparatoryFetchAndStopsAtItsMeasuredPushValue() {
    var work = OperationWorkflowProgress(id: UUID(), kind: .mergeAndPush)
    work.advance(to: .execute)
    XCTAssertTrue(work.receive(.init(phase: .receiving, fraction: 0.95), step: .execute))
    XCTAssertEqual(work.indicatorValue, 0)
    work.advance(to: .commit)
    work.advance(to: .push)
    XCTAssertTrue(work.receive(.init(phase: .writing, fraction: 0.37), step: .push))
    work.finish(.failed)
    XCTAssertEqual(work.indicatorValue, 0.37)
  }

  func testFetchRetainsDownloadedFractionWhenResolvingAndWhenCancelled() {
    var work = OperationWorkflowProgress(id: UUID(), kind: .fetch)
    work.advance(to: .execute)
    XCTAssertTrue(work.receive(.init(phase: .counting, fraction: 1), step: .execute))
    XCTAssertEqual(work.indicatorValue, 0)
    XCTAssertTrue(work.receive(.init(phase: .receiving, fraction: 0.64), step: .execute))
    XCTAssertTrue(work.receive(.init(phase: .resolving, fraction: 0.2), step: .execute))
    XCTAssertEqual(work.indicatorValue, 0.64)
    work.advance(to: .refresh)
    XCTAssertEqual(work.indicatorValue, 0.64)
    work.finish(.cancelled)
    XCTAssertEqual(work.indicatorValue, 0.64)
    XCTAssertEqual(OperationWorkflowProgress(id: UUID(), kind: .fetch).indicatorValue, 0)
  }

  func testRefreshRemainsUnmeasuredUntilItsFinalResult() {
    var refresh = OperationWorkflowProgress(id: UUID(), kind: .git)
    XCTAssertNil(refresh.indicatorValue)
    refresh.finish(.succeeded)
    XCTAssertEqual(refresh.indicatorValue, 1)
    var failed = OperationWorkflowProgress(id: UUID(), kind: .git)
    failed.finish(.failed)
    XCTAssertEqual(failed.indicatorValue, 0)
  }

  func testInvalidAndStaleMeasurementsCannotAdvanceTheIndicator() {
    var work = OperationWorkflowProgress(id: UUID(), kind: .push)
    work.advance(to: .execute)
    for value in [Double.nan, .infinity, -0.5, 1.5] {
      XCTAssertFalse(work.receive(.init(phase: .writing, fraction: value), step: .execute))
    }
    XCTAssertEqual(work.indicatorValue, 0)
    XCTAssertTrue(work.receive(.init(phase: .writing, fraction: 0.2), step: .execute))
    XCTAssertFalse(work.receive(.init(phase: .writing, fraction: 0.1), step: .execute))
    work.advance(to: .refresh)
    XCTAssertFalse(work.receive(.init(phase: .writing, fraction: 0.9), step: .execute))
    XCTAssertEqual(work.indicatorValue, 0.2)
  }

  func testCommitAndPushKeepsCompletedStepsAcrossRealTransferAndRefresh() {
    let id = UUID()
    var work = OperationWorkflowProgress(id: id, kind: .commitAndPush)
    XCTAssertEqual(work.steps.map(\.kind), [.prepare, .commit, .pushTarget, .push, .refresh])
    work.advance(to: .commit)
    work.advance(to: .pushTarget)
    work.advance(to: .push)
    XCTAssertTrue(work.receive(.init(phase: .writing, fraction: 0.8), step: .push))
    XCTAssertFalse(work.receive(.init(phase: .writing, fraction: 0.2), step: .push))
    XCTAssertFalse(work.receive(.init(phase: .counting, fraction: 1), step: .push))
    XCTAssertEqual(work.transfer?.fraction, 0.8)
    work.advance(to: .refresh)
    XCTAssertFalse(work.receive(.init(phase: .writing, fraction: 1), step: .push))
    XCTAssertNil(work.transfer)
    XCTAssertEqual(work.steps.map(\.state), [.completed, .completed, .completed, .completed, .active])
    work.finish(.succeeded)
    XCTAssertEqual(work.outcome, .succeeded)
    XCTAssertEqual(work.id, id)
    XCTAssertTrue(work.steps.allSatisfy { $0.state == .completed })
  }

  func testSkippedAndInterruptedStagesStayDifferentFromCompleted() {
    var work = OperationWorkflowProgress(id: UUID(), kind: .commitAndPush)
    work.advance(to: .commit)
    work.advance(to: .pushTarget)
    work.advance(to: .refresh, previousCompleted: false)
    work.finish(.waitingForUser)
    XCTAssertEqual(work.steps.map(\.state), [.completed, .completed, .interrupted, .skipped, .completed])
    XCTAssertEqual(work.outcome, .waitingForUser)
    work.advance(to: .push)
    XCTAssertEqual(work.current, .refresh)
    XCTAssertFalse(work.receive(.init(phase: .writing, fraction: 1), step: .refresh))
  }

  func testTransferPercentIsScopedToGitPhaseAndNotAWorkflowResult() {
    var work = OperationWorkflowProgress(id: UUID(), kind: .clone)
    work.advance(to: .execute)
    XCTAssertFalse(work.receive(.init(phase: .receiving, fraction: .nan), step: .execute))
    XCTAssertTrue(work.receive(.init(phase: .receiving, fraction: 1), step: .execute))
    XCTAssertNil(work.outcome)
    XCTAssertEqual(work.steps[1].state, .active)
    XCTAssertTrue(work.receive(.init(phase: .resolving, fraction: 0.3), step: .execute))
    XCTAssertEqual(work.transfer?.phase, .resolving)
    work.finish(.cancelled)
    XCTAssertEqual(work.steps.map(\.state), [.completed, .interrupted, .skipped])
  }
}
