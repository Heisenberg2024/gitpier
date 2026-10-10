import XCTest

@testable import GitPierCore

extension GitServiceTests {
  func testPushNamedRemoteBranchUsesCurrentHEAD() async throws {
    try await seed()
    let bare = directory.appendingPathComponent("remote.git")
    try await raw(["init", "--bare", bare.path])
    try await raw(["remote", "add", "origin", bare.path])
    try await git.createBranch("release")
    try write("first.txt", "current HEAD\n")
    try await git.stage(try await git.status().files)
    let current = try await git.commit(message: "fix: current", expected: git.snapshot())
    _ = try await git.network("push", remote: "origin", branch: "release")
    let remote = try await raw(["--git-dir=" + bare.path, "rev-parse", "refs/heads/release"]).text
      .trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertEqual(remote, current.hash)
    let status = try await git.status()
    XCTAssertEqual(status.upstream, "origin/release")
  }
  func testStaleStashOrdinalCannotDropAnotherEntry() async throws {
    try await seed()
    try write("first.txt", "first stash\n")
    try await git.perform(["stash", "push", "-m", "first"])
    let first = try await git.stashes()[0]
    try write("first.txt", "second stash\n")
    try await git.perform(["stash", "push", "-m", "second"])
    do {
      _ = try await git.stashOperation("drop", stash: first)
      XCTFail()
    } catch { XCTAssertTrue(error.localizedDescription.contains("stash list changed")) }
    let current = try await git.stashes()
    XCTAssertEqual(current.count, 2)
    _ = try await git.stashOperation("pop", stash: current[0])
    let remaining = try await git.stashes()
    XCTAssertEqual(remaining.count, 1)
    XCTAssertEqual(remaining[0].hash, first.hash)
  }
}
