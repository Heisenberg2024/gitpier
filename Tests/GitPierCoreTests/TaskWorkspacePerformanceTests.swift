import Darwin
import XCTest
@testable import GitPierCore

extension TaskWorkspaceTests {
  func testMultipleTaskReviewsShareTheGlobalBudgetWhileWaitingOnRealGit() async throws {
    let markers = fixture.appendingPathComponent("review-markers"), release = fixture.appendingPathComponent("release-all-reviews")
    try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: false)
    let wrapper = fixture.appendingPathComponent("budget-review-git")
    let script = """
    #!/bin/sh
    case " $* " in
      *" status "*) touch \(InputValidation.shellQuote(markers.path))/"$$"; while [ ! -f \(InputValidation.shellQuote(release.path)) ]; do /bin/sleep 0.02; done;;
    esac
    exec /usr/bin/git "$@"
    """
    try Data(script.utf8).write(to: wrapper); XCTAssertEqual(chmod(wrapper.path, 0o700), 0)
    var works: [Task<TaskWorkspaceReview, Error>] = []
    for n in 0..<4 {
      let task = try await create("budget-\(n)"), directory = URL(fileURLWithPath: task.path)
      for file in 0..<16 { try write("change-\(file).txt", String(repeating: "changed\n", count: 1024), directory: directory) }
      let service = GitService(root: directory, gitPath: wrapper.path)
      works.append(Task { try await service.taskWorkspaceReview(task) })
    }
    for _ in 0..<300 {
      if try FileManager.default.contentsOfDirectory(atPath: markers.path).count >= 3 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(50))
    let running = try FileManager.default.contentsOfDirectory(atPath: markers.path).count
    let budget = await WorkspaceOperationBudget.shared.metrics()
    // Release every real child before assertions, including on a buggy unlimited implementation.
    try Data().write(to: release)
    XCTAssertEqual(running, 3); XCTAssertEqual(budget.active, 3)
    for work in works { let receipt = try await work.value; XCTAssertEqual(receipt.fingerprint.count, 64) }
  }
  func testConcurrentReviewRefreshesShareOneContentScanAndRevalidateNextTime() async throws {
    let task = try await create(), directory = URL(fileURLWithPath: task.path)
    for n in 0..<30 { try write("changed-\(n).txt", String(repeating: "content\n", count: 3000), directory: directory) }
    let log = fixture.appendingPathComponent("review-commands"), wrapper = fixture.appendingPathComponent("review-git")
    try Data(("#!/bin/sh\nprintf '%s\\n' probe >> " + InputValidation.shellQuote(log.path) + "\nexec /usr/bin/git \"$@\"\n").utf8).write(to: wrapper)
    XCTAssertEqual(chmod(wrapper.path, 0o700), 0)
    let service = GitService(root: directory, gitPath: wrapper.path)
    let first = try await service.taskWorkspaceReview(task)
    let single = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count
    try Data().write(to: log)
    let requests = (0..<8).map { _ in Task { try await service.taskWorkspaceReview(task) } }
    for request in requests { let receipt = try await request.value; XCTAssertEqual(receipt.fingerprint, first.fingerprint) }
    let concurrent = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count
    XCTAssertLessThanOrEqual(concurrent, single + 2, "Concurrent refreshes must share one heavy scan")
    let changed = directory.appendingPathComponent("changed-0.txt")
    let modified = try FileManager.default.attributesOfItem(atPath: changed.path)[.modificationDate]!
    try write("changed-0.txt", String(repeating: "changed\n", count: 3000), directory: directory)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: changed.path)
    let updated = try await service.taskWorkspaceReview(task)
    XCTAssertNotEqual(updated.fingerprint, first.fingerprint, "A completed scan must never become an mtime-only cache")
  }
  func testReviewRejectsLargeFilesAndInvalidatesPermissionsAndReplacement() async throws {
    let task = try await create(), directory = URL(fileURLWithPath: task.path), service = await child(task)
    let file = directory.appendingPathComponent("file.txt")
    try write("file.txt", "review content\n", directory: directory)
    let first = try await service.taskWorkspaceReview(task)
    XCTAssertEqual(chmod(file.path, 0o755), 0)
    let permissions = try await service.taskWorkspaceReview(task)
    XCTAssertNotEqual(first.fingerprint, permissions.fingerprint)
    let huge = directory.appendingPathComponent("huge.bin")
    FileManager.default.createFile(atPath: huge.path, contents: nil)
    let handle = try FileHandle(forWritingTo: huge); try handle.truncate(atOffset: 64 * 1024 * 1024 + 1); try handle.close()
    do { _ = try await service.taskWorkspaceReview(task); XCTFail("Do not scan beyond review budget") } catch TaskWorkspaceError.capacity {}
    try FileManager.default.removeItem(at: huge)
    try FileManager.default.moveItem(at: file, to: directory.appendingPathComponent("saved.txt"))
    try write("file.txt", "replacement\n", directory: directory)
    let replacement = try await service.taskWorkspaceReview(task)
    XCTAssertNotEqual(permissions.fingerprint, replacement.fingerprint)
  }
}
