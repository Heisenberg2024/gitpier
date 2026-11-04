import XCTest
@testable import GitPierCore

final class OperationWorkflowProgressTests: XCTestCase {
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
