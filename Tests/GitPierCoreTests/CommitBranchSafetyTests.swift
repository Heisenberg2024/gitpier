import XCTest

@testable import GitPierCore

extension GitServiceTests {
  func testCommitRejectsSameHashBranchSwitchFromOriginalHook() async throws {
    try await seed()
    try await raw(["branch", "other"])
    try write("first.txt", "selected\n")
    try await raw(["add", "--", "first.txt"])
    let expected = try await git.snapshot()
    let index = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    let hook = directory.appendingPathComponent(".git/hooks/pre-commit")
    try "#!/bin/sh\n/usr/bin/git symbolic-ref HEAD refs/heads/other\n".write(
      to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    do {
      _ = try await git.commit(message: "fix: reject branch switch", expected: expected)
      XCTFail("A same-hash branch switch must invalidate the commit")
    } catch { XCTAssertTrue(error.localizedDescription.contains("branch changed")) }
    let main = try await raw(["rev-parse", "refs/heads/main"]).text.trimmingCharacters(in: .newlines)
    let other = try await raw(["rev-parse", "refs/heads/other"]).text.trimmingCharacters(in: .newlines)
    let branch = try await raw(["symbolic-ref", "HEAD"]).text.trimmingCharacters(in: .newlines)
    XCTAssertEqual(main, expected.head)
    XCTAssertEqual(other, expected.head)
    XCTAssertEqual(branch, "refs/heads/other", "Do not undo an external branch switch")
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), index)
  }

  func testCommitHeadReferenceGateAllowsDetachedHEAD() async throws {
    try await seed()
    try await raw(["checkout", "--detach"])
    try write("first.txt", "selected\n")
    try await raw(["add", "--", "first.txt"])
    let expected = try await git.snapshot()
    let result = try await git.commit(message: "fix: detached fixture", expected: expected)
    let head = try await raw(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    XCTAssertEqual(result.hash, head)
    XCTAssertNotEqual(head, expected.head)
    let state = try await git.status()
    XCTAssertEqual(state.branch, "(detached)")
  }

  func testCommitHeadReferenceGatePreservesBranchNamesStartingWithRefs() async throws {
    try await seed()
    try await raw(["checkout", "-b", "refs/notes/fixture"])
    try write("first.txt", "selected\n")
    try await raw(["add", "--", "first.txt"])
    let expected = try await git.snapshot()
    let result = try await git.commit(message: "fix: exact branch reference", expected: expected)
    let head = try await raw(["rev-parse", "refs/heads/refs/notes/fixture"]).text.trimmingCharacters(in: .newlines)
    XCTAssertEqual(result.hash, head)
    let state = try await git.status()
    XCTAssertEqual(state.branch, "refs/notes/fixture")
  }
}
