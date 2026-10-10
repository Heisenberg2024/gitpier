import XCTest

@testable import GitPierCore

extension GitServiceTests {
  func testCommitSelectionAddsOnlyChosenUntrackedAndPreservesExternalIndex() async throws {
    try await seed()
    try write("chosen.txt", "chosen\n")
    try write("unchecked.txt", "keep untracked\n")
    try write("second.txt", "externally staged\n")
    try await raw(["add", "--", "second.txt"])
    let expected = try await git.snapshot()
    let file = try await git.status().files.first { $0.path == "chosen.txt" }!
    _ = try await git.commit(message: "feat: selected", expected: expected, selection: [file])
    let chosen = try await raw(["show", "HEAD:chosen.txt"]).text
    let untouched = try await raw(["show", "HEAD:second.txt"]).text
    let external = try await raw(["show", ":second.txt"]).text
    XCTAssertEqual(chosen, "chosen\n")
    XCTAssertEqual(untouched, "other\n")
    XCTAssertEqual(external, "externally staged\n")
    let remaining = try await git.status()
    XCTAssertTrue(remaining.untracked.contains { $0.path == "unchecked.txt" })
    XCTAssertEqual(remaining.staged.map(\.path), ["second.txt"])
  }

  func testCommitSelectionKeepsPartialContentAndExcludesOtherStaging() async throws {
    try await seed()
    try write("first.txt", "ONE\ntwo\nthree\n")
    try await raw(["add", "--", "first.txt"])
    try write("first.txt", "ONE\ntwo\nTHREE\n")
    try write("second.txt", "external\n")
    try await raw(["add", "--", "second.txt"])
    let expected = try await git.snapshot()
    let file = try await git.status().files.first { $0.path == "first.txt" }!
    XCTAssertTrue(file.isPartial)
    _ = try await git.commit(
      message: "fix: partial selection", expected: expected, selection: [file])
    let committed = try await raw(["show", "HEAD:first.txt"]).text
    let other = try await raw(["show", "HEAD:second.txt"]).text
    let after = try await git.snapshot()
    XCTAssertEqual(committed, "ONE\ntwo\nthree\n")
    XCTAssertEqual(other, "other\n")
    XCTAssertEqual(after.tree, expected.tree)
    let remaining = try await git.status()
    XCTAssertTrue(remaining.files.first { $0.path == "first.txt" }!.isUnstaged)
    XCTAssertEqual(remaining.staged.map(\.path), ["second.txt"])
  }

  func testUnbornSelectionLeavesOtherStagedFiles() async throws {
    try write("chosen.txt", "yes\n")
    try write("external.txt", "external\n")
    try await raw(["add", "--", "external.txt"])
    let expected = try await git.snapshot()
    let file = try await git.status().files.first { $0.path == "chosen.txt" }!
    _ = try await git.commit(
      message: "feat: initial selection", expected: expected, selection: [file])
    let paths = try await raw(["ls-tree", "--name-only", "HEAD"]).text
    XCTAssertEqual(paths, "chosen.txt\n")
    let remaining = try await git.status()
    XCTAssertEqual(remaining.staged.map(\.path), ["external.txt"])
  }

  func testSelectedCommitRejectsChangedReviewedPatchBeforeStaging() async throws {
    try await seed()
    try write("first.txt", "reviewed\n")
    let expected = try await git.snapshot()
    let file = try await git.status().files.first { $0.path == "first.txt" }!
    let reviewed = try await git.patch(for: file, comparison: .unstaged)
    try write("first.txt", "changed after review\n")
    do {
      _ = try await git.commit(
        message: "fix: stale review", expected: expected,
        selection: [file], reviewedPatches: [file.path: reviewed])
      XCTFail("Changed reviewed contents must be rejected")
    } catch { XCTAssertTrue(error.localizedDescription.contains("changed after review")) }
    let after = try await git.snapshot()
    XCTAssertEqual(after.identity, expected.identity)
  }

  func testSelectedCommitHookCannotAddExcludedContent() async throws {
    try await seed()
    try write("first.txt", "chosen\n")
    try write("second.txt", "excluded\n")
    try await raw(["add", "--", "second.txt"])
    let expected = try await git.snapshot()
    let file = try await git.status().files.first { $0.path == "first.txt" }!
    let hook = directory.appendingPathComponent(".git/hooks/pre-commit")
    try "#!/bin/sh\ngit add -- second.txt\n".write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    do {
      _ = try await git.commit(
        message: "fix: guarded selection", expected: expected, selection: [file])
      XCTFail("Hook-added excluded contents must be rejected")
    } catch { XCTAssertTrue(error.localizedDescription.contains("hook changed")) }
    let head = try await raw(["log", "-1", "--format=%s"]).text
    XCTAssertEqual(head.trimmingCharacters(in: .whitespacesAndNewlines), "seed")
    let retained = try await git.status()
    XCTAssertEqual(Set(retained.staged.map(\.path)), ["first.txt", "second.txt"])
  }
}
