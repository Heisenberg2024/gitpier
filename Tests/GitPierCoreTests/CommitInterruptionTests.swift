import XCTest

@testable import GitPierCore

extension GitServiceTests {
  private func blockingCommitHook(_ name: String = "reference-transaction") throws -> URL {
    let marker = directory.appendingPathComponent(".git/commit-hook-blocked")
    let hook = directory.appendingPathComponent(".git/hooks/" + name)
    try """
      #!/bin/sh
      \(name == "reference-transaction" ? "[ \"$1\" = committed ] || exit 0" : "")
      \(name == "reference-transaction" ? "changed=0; while read old new ref; do if [ \"$ref\" = refs/heads/main ] && [ \"$old\" != \"$new\" ]; then changed=1; fi; done; [ \"$changed\" = 1 ] || exit 0" : "")
      /usr/bin/git rev-parse --verify HEAD > .git/head-at-blocked-hook
      printf 'Synthetic Hook stdout before interruption\\n'
      printf 'Synthetic Hook stderr before interruption\\n' >&2
      printf 'Authorization: Bearer synthetic-hook-secret\\n' >&2
      if [ -n "${GITPIER_COMMIT_RECEIPT:-}" ] && [ ! -s "$GITPIER_COMMIT_RECEIPT" ]; then
        : > .git/blocked-before-receipt
      fi
      : > .git/commit-hook-blocked
      exec /bin/sleep 30
      """.write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    return marker
  }

  func testNativeReferenceTransactionTimeoutCanFollowACommittedRef() async throws {
    try await seed()
    try write("first.txt", "native timeout boundary\n")
    try await raw(["add", "--", "first.txt"])
    let before = try await git.resolveCommit("HEAD")
    let marker = try blockingCommitHook()
    do {
      _ = try await ProcessRunner().run(executable: "/usr/bin/git", arguments: ["commit", "-m", "native timeout"],
        directory: directory, environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"], timeout: 1)
      XCTFail("A blocked native committed hook must exceed the real process deadline")
    } catch GitPierError.timeout {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    let after = try await git.resolveCommit("HEAD")
    XCTAssertNotEqual(after, before, "Native Git already updated the ref before the timeout")
    let hookHead = try String(contentsOf: directory.appendingPathComponent(".git/head-at-blocked-hook"), encoding: .utf8)
      .trimmingCharacters(in: .newlines)
    XCTAssertEqual(after, hookHead)
  }

  func testCommitCancellationBeforeReceiptRequiresVerification() async throws {
    try await verifyCommitCancellation(hook: "reference-transaction", beforeReceipt: true)
  }

  func testCommitCancellationInPostCommitHookRetainsUnverifiedDiagnostics() async throws {
    try await verifyCommitCancellation(hook: "post-commit", beforeReceipt: false)
  }

  private func verifyCommitCancellation(hook: String, beforeReceipt: Bool) async throws {
    try await seed()
    try write("first.txt", "reviewed cancellation boundary\n")
    try await raw(["add", "--", "first.txt"])
    let expected = try await git.snapshot()
    let originalIndex = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    let marker = try blockingCommitHook(hook)
    let service: GitService = git
    let task = Task { try await service.commit(message: "fix: interrupted native completion", expected: expected) }
    defer { task.cancel() }
    for _ in 0..<200 {
      if FileManager.default.fileExists(atPath: marker.path) { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "The native hook must reach committed first")
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Interrupted completion requires explicit verification")
    } catch let error as CommitCompletionUnverified {
      XCTAssertTrue(error.diagnostic.contains("Synthetic Hook stderr"))
      XCTAssertTrue(error.diagnostic.contains("Synthetic Hook stdout"))
      XCTAssertTrue(error.diagnostic.contains(CancellationError().localizedDescription))
      XCTAssertFalse(error.diagnostic.contains("synthetic-hook-secret"))
    } catch { XCTFail("Do not report a possibly completed commit as an ordinary failure: \(error)") }
    let after = try await git.resolveCommit("HEAD")
    XCTAssertNotEqual(after, expected.head)
    XCTAssertEqual(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/blocked-before-receipt").path), beforeReceipt)
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), originalIndex)
  }

  func testCommitTimeoutAfterRefUpdateRequiresVerificationAndKeepsDiagnostics() async throws {
    try await verifyReviewedCommitTimeout(afterReferenceUpdate: true)
  }

  func testCommitTimeoutBeforeRefUpdateDoesNotInventCompletion() async throws {
    try await verifyReviewedCommitTimeout(afterReferenceUpdate: false)
  }

  private func verifyReviewedCommitTimeout(afterReferenceUpdate: Bool) async throws {
    try await seed()
    try write("first.txt", "reviewed timeout boundary\n")
    try await raw(["add", "--", "first.txt"])
    let expected = try await git.snapshot()
    let originalIndex = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    let marker = try blockingCommitHook(afterReferenceUpdate ? "reference-transaction" : "pre-commit")
    do {
      _ = try await git.commit(message: "fix: bounded native completion", expected: expected, timeout: 5)
      XCTFail("A deadline without completion proof must require verification")
    } catch let error as CommitCompletionUnverified {
      XCTAssertTrue(error.diagnostic.contains(GitPierError.timeout.localizedDescription))
      XCTAssertTrue(error.diagnostic.contains("Synthetic Hook stderr"))
      XCTAssertTrue(error.diagnostic.contains("Synthetic Hook stdout"))
      XCTAssertFalse(error.diagnostic.contains("synthetic-hook-secret"))
      XCTAssertTrue(error.localizedDescription.contains("History"))
    } catch { XCTFail("An interruption cannot prove the local commit failed: \(error)") }
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    let after = try await git.resolveCommit("HEAD")
    XCTAssertEqual(after != expected.head, afterReferenceUpdate)
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/blocked-before-receipt").path))
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), originalIndex)
  }
}
