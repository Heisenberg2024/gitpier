import Darwin
import XCTest
@testable import GitPierCore

private actor ReviewWaiterProbe {
  private(set) var finished = false
  func finish() { finished = true }
}

private final class ReviewChunkProbe: @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var chunks = 0
  func waitForEntry() -> Bool { entered.wait(timeout: .now() + 10) == .success }
  var count: Int { lock.lock(); defer { lock.unlock() }; return chunks }
  func observe() {
    lock.lock(); chunks += 1; let first = chunks == 1; lock.unlock()
    if first { entered.signal(); _ = release.wait(timeout: .now() + 10) }
  }
}

extension TaskWorkspaceTests {
  func testCancellationDuringContentHashDoesNotReadTheRemainingFile() async throws {
    let task = try await create(), service = await child(task), probe = ReviewChunkProbe()
    let file = URL(fileURLWithPath: task.path).appendingPathComponent("large-review.bin")
    FileManager.default.createFile(atPath: file.path, contents: nil)
    let handle = try FileHandle(forWritingTo: file); try handle.truncate(atOffset: 64 * 1024 * 1024); try handle.close()
    await service.observeTaskReviewChunks { probe.observe() }
    let work = Task { try await service.taskWorkspaceReview(task) }
    let entered = await Task.detached { probe.waitForEntry() }.value
    work.cancel(); probe.release.signal()
    XCTAssertTrue(entered, "Cancel only after a real content chunk was read")
    do { _ = try await work.value; XCTFail("Content review cancellation must propagate") } catch is CancellationError {}
    for _ in 0..<300 { if await WorkspaceOperationBudget.shared.metrics().active == 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertLessThan(probe.count, 128, "Cancellation must stop hashing instead of consuming the remaining 64 MiB")
    let budget = await WorkspaceOperationBudget.shared.metrics(); XCTAssertEqual(budget.active, 0)
    await service.observeTaskReviewChunks(nil)
  }
  func blockingReview(_ task: TaskWorkspace) throws -> (GitService, URL, URL) {
    let pid = fixture.appendingPathComponent("review.pid"), release = fixture.appendingPathComponent("release-review")
    let wrapper = fixture.appendingPathComponent("blocking-review-git")
    let script = """
    #!/bin/sh
    case " $* " in
      *" status "*) printf '%s' "$$" > \(InputValidation.shellQuote(pid.path)); while [ ! -f \(InputValidation.shellQuote(release.path)) ]; do /bin/sleep 0.02; done;;
    esac
    exec /usr/bin/git "$@"
    """
    try Data(script.utf8).write(to: wrapper); XCTAssertEqual(chmod(wrapper.path, 0o700), 0)
    return (GitService(root: URL(fileURLWithPath: task.path), gitPath: wrapper.path), pid, release)
  }
  func testCancellingOnlyReviewWaiterReturnsPromptlyAndReleasesBudget() async throws {
    let task = try await create(), (service, pidFile, _) = try blockingReview(task), probe = ReviewWaiterProbe()
    let work = Task {
      do { _ = try await service.taskWorkspaceReview(task); await probe.finish(); return false }
      catch { await probe.finish(); if error is CancellationError { return true }; throw error }
    }
    for _ in 0..<300 { if FileManager.default.fileExists(atPath: pidFile.path) { break }; try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path))
    work.cancel()
    for _ in 0..<100 { if await probe.finished { break }; try await Task.sleep(for: .milliseconds(10)) }
    let immediate = await probe.finished
    XCTAssertTrue(immediate, "Cancelling a review must not await the abandoned scan")
    // Clean up a real blocked child even when exercising the buggy implementation.
    if !immediate, let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8)) { _ = kill(pid, SIGTERM) }
    let cancelled = try await work.value; XCTAssertTrue(cancelled)
    for _ in 0..<300 { if await WorkspaceOperationBudget.shared.metrics().active == 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
    let budget = await WorkspaceOperationBudget.shared.metrics(); XCTAssertEqual(budget.active, 0)
  }
  func testCancellingOneSharedReviewWaiterDoesNotCancelTheOther() async throws {
    let task = try await create(), (service, pidFile, release) = try blockingReview(task), probe = ReviewWaiterProbe()
    let first = Task { try await service.taskWorkspaceReview(task) }
    for _ in 0..<300 { if FileManager.default.fileExists(atPath: pidFile.path) { break }; try await Task.sleep(for: .milliseconds(10)) }
    let second = Task {
      do { _ = try await service.taskWorkspaceReview(task); await probe.finish(); return false }
      catch { await probe.finish(); if error is CancellationError { return true }; throw error }
    }
    try await Task.sleep(for: .milliseconds(40)); second.cancel()
    for _ in 0..<100 { if await probe.finished { break }; try await Task.sleep(for: .milliseconds(10)) }
    let immediate = await probe.finished
    XCTAssertTrue(immediate, "A cancelled subscriber must leave independently of the shared result")
    try Data().write(to: release)
    let receipt = try await first.value; XCTAssertEqual(receipt.head, task.baseCommit)
    let cancelled = try await second.value; XCTAssertTrue(cancelled)
  }
}
