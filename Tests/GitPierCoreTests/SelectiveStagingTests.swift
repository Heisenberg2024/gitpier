import XCTest
@testable import GitPierCore

extension GitServiceTests {
  private func linesReview(_ comparison: DiffComparison = .unstaged) async throws -> SelectiveStagingReview {
    let state = try await git.status()
    let file = try XCTUnwrap(state.files.first { $0.path == "first.txt" })
    let patch = try await git.patch(for: file, comparison: comparison)
    return try await git.reviewSelectiveStaging(file: file, comparison: comparison,
      expectedPatch: String(decoding: patch, as: UTF8.self), expectedIndex: git.snapshot())
  }
  private func lineIDs(_ review: SelectiveStagingReview, addition: [String] = [], deletion: [String] = []) -> Set<Int> {
    Set(review.document.hunks.flatMap(\.lines).filter {
      ($0.kind == .addition && addition.contains($0.text)) || ($0.kind == .deletion && deletion.contains($0.text))
    }.map(\.id))
  }
  private func assertIndex(_ text: String, path: String = "first.txt", file: StaticString = #filePath, line: UInt = #line) async throws {
    let actual = try await raw(["show", ":" + path]).text
    XCTAssertEqual(actual, text, file: file, line: line)
  }
  private func linesRejected(_ action: () async throws -> Void) async {
    do { try await action(); XCTFail("Expected selective staging rejection") } catch {}
  }
  private func interceptApplyCheck(_ body: String) async throws {
    let wrapper = directory.appendingPathComponent("git-check-wrapper")
    try ("#!/bin/sh\napply=0\ncheck=0\nfor arg in \"$@\"; do\n[ \"$arg\" = apply ] && apply=1\n[ \"$arg\" = --check ] && check=1\ndone\nif [ \"$apply\" = 1 ] && [ \"$check\" = 1 ]; then\n" + body + "\nfi\nexec /usr/bin/git \"$@\"\n")
      .write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    await git.configure(gitPath: wrapper.path, authEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
  }
  func testSelectedLinesSingleAdditionStageUnstageAndExternalPartialStaging() async throws {
    try await seed()
    try write("second.txt", "external staged\n"); try await raw(["add", "--", "second.txt"])
    try write("second.txt", "external staged\nexternal unstaged\n")
    try write("first.txt", "one\nADDED\ntwo\nthree\n")
    let review = try await linesReview()
    try await git.applySelectedLines(lineIDs(review, addition: ["ADDED"]), expected: review)
    try await assertIndex("one\nADDED\ntwo\nthree\n")
    try await assertIndex("external staged\n", path: "second.txt")
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("second.txt"), encoding: .utf8), "external staged\nexternal unstaged\n")
    let staged = try await linesReview(.staged)
    try await git.applySelectedLines(lineIDs(staged, addition: ["ADDED"]), expected: staged)
    try await assertIndex("one\ntwo\nthree\n")
    try await assertIndex("external staged\n", path: "second.txt")
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("first.txt"), encoding: .utf8), "one\nADDED\ntwo\nthree\n")
  }
  func testSelectedLinesSingleDeletion() async throws {
    try await seed(); try write("first.txt", "one\nthree\n")
    let review = try await linesReview()
    try await git.applySelectedLines(lineIDs(review, deletion: ["two"]), expected: review)
    try await assertIndex("one\nthree\n")
  }
  func testSelectedLinesPartialReplacementPreservesPairOrder() async throws {
    try await seed(); try write("first.txt", "ONE\nTWO\nthree\n")
    let review = try await linesReview()
    try await git.applySelectedLines(lineIDs(review, addition: ["ONE"], deletion: ["one"]), expected: review)
    try await assertIndex("ONE\ntwo\nthree\n")
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("first.txt"), encoding: .utf8), "ONE\nTWO\nthree\n")
  }
  func testSelectedLinesUnstagePartialReplacementAgainstCurrentIndex() async throws {
    try await seed(); try write("first.txt", "ONE\nTWO\nthree\n")
    try await raw(["add", "--", "first.txt"])
    let review = try await linesReview(.staged)
    try await git.applySelectedLines(lineIDs(review, addition: ["ONE"], deletion: ["one"]), expected: review)
    try await assertIndex("one\nTWO\nthree\n")
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("first.txt"), encoding: .utf8), "ONE\nTWO\nthree\n")
  }
  func testSelectedLinesMultipleHunksAndOffsets() async throws {
    try await seed()
    let original = (1...40).map { "line \($0)" }.joined(separator: "\n") + "\n"
    try write("first.txt", original); try await raw(["add", "--", "first.txt"]); try await raw(["commit", "-m", "long source"])
    let working = original.replacingOccurrences(of: "line 2\n", with: "line 2\ninserted\n")
      .replacingOccurrences(of: "line 30\n", with: "changed 30\n")
    try write("first.txt", working)
    let review = try await linesReview()
    XCTAssertEqual(review.document.hunks.count, 2)
    try await git.applySelectedLines(lineIDs(review, addition: ["inserted", "changed 30"], deletion: ["line 30"]), expected: review)
    try await assertIndex(working)
  }
  func testSelectedLinesExistingPartialFileContentIsPreserved() async throws {
    try await seed(); try write("first.txt", "ONE\ntwo\nthree\n")
    try await raw(["add", "--", "first.txt"])
    try write("first.txt", "ONE\nTWO\nTHREE\n")
    let review = try await linesReview()
    try await git.applySelectedLines(lineIDs(review, addition: ["THREE"], deletion: ["three"]), expected: review)
    try await assertIndex("ONE\ntwo\nTHREE\n")
  }
  func testSelectedLinesCRLFIsBytePreserving() async throws {
    try await seed(); try write("first.txt", "one\r\ntwo\r\nthree\r\n")
    try await raw(["add", "--", "first.txt"]); try await raw(["commit", "-m", "CRLF source"])
    try write("first.txt", "ONE\r\nTWO\r\nthree\r\n")
    let review = try await linesReview()
    try await git.applySelectedLines(lineIDs(review, addition: ["ONE\r"], deletion: ["one\r"]), expected: review)
    try await assertIndex("ONE\r\ntwo\r\nthree\r\n")
    let staged = try await linesReview(.staged)
    try await git.applySelectedLines(lineIDs(staged, addition: ["ONE\r"], deletion: ["one\r"]), expected: staged)
    try await assertIndex("one\r\ntwo\r\nthree\r\n")
  }
  func testSelectedLinesNoFinalNewline() async throws {
    try await seed(); try write("first.txt", "one\ntwo\nthree")
    try await raw(["add", "--", "first.txt"]); try await raw(["commit", "-m", "no final LF"])
    try write("first.txt", "one\ntwo\nTHREE")
    let review = try await linesReview()
    try await git.applySelectedLines(lineIDs(review, addition: ["THREE"], deletion: ["three"]), expected: review)
    try await assertIndex("one\ntwo\nTHREE")
    let staged = try await linesReview(.staged)
    try await git.applySelectedLines(lineIDs(staged, addition: ["THREE"], deletion: ["three"]), expected: staged)
    try await assertIndex("one\ntwo\nthree")
  }
  func testSelectedLinesEmptyFileAndFullContentDeletion() async throws {
    try await seed(); try write("first.txt", "")
    try await raw(["add", "--", "first.txt"]); try await raw(["commit", "-m", "empty source"])
    try write("first.txt", "first\nsecond\n")
    let review = try await linesReview()
    try await git.applySelectedLines(lineIDs(review, addition: ["first"]), expected: review)
    try await assertIndex("first\n")
    let staged = try await linesReview(.staged)
    try await git.applySelectedLines(lineIDs(staged, addition: ["first"]), expected: staged)
    try await assertIndex("")
  }
  func testSelectedLinesExternalIndexAndWorkingChangesAreRejected() async throws {
    try await seed(); try write("first.txt", "ONE\ntwo\nthree\n")
    let review = try await linesReview()
    try write("second.txt", "external\n"); try await raw(["add", "--", "second.txt"])
    let index = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    await linesRejected { try await self.git.applySelectedLines(self.lineIDs(review, addition: ["ONE"], deletion: ["one"]), expected: review) }
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), index)
    let fresh = try await linesReview(); try write("first.txt", "another edit\n")
    await linesRejected { try await self.git.applySelectedLines(self.lineIDs(fresh, addition: ["ONE"], deletion: ["one"]), expected: fresh) }
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("first.txt"), encoding: .utf8), "another edit\n")
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/index.lock").path))
  }
  func testSelectedLinesPreservesAnotherClientsIndexLock() async throws {
    try await seed(); try write("first.txt", "ONE\ntwo\nthree\n")
    let review = try await linesReview()
    try write(".git/index.lock", "other client lock")
    await linesRejected { try await self.git.applySelectedLines(self.lineIDs(review, addition: ["ONE"], deletion: ["one"]), expected: review) }
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(".git/index.lock"), encoding: .utf8), "other client lock")
    try await assertIndex("one\ntwo\nthree\n")
  }
  func testSelectedLinesEmptyInvalidSelectionAndCancellationAreReadOnly() async throws {
    try await seed(); try write("first.txt", "ONE\ntwo\nthree\n")
    let review = try await linesReview()
    let before = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    await linesRejected { try await self.git.applySelectedLines([], expected: review) }
    await linesRejected { try await self.git.applySelectedLines([99999], expected: review) }
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), before)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/index.lock").path))
  }
  func testSelectedLinesNativePatchCheckFailurePreservesIndex() async throws {
    try await seed(); try write("first.txt", "ONE\ntwo\nthree\n")
    let review = try await linesReview()
    let before = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    try await interceptApplyCheck("echo 'expected native apply check failure' >&2\nexit 1")
    await linesRejected { try await self.git.applySelectedLines(self.lineIDs(review, addition: ["ONE"], deletion: ["one"]), expected: review) }
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), before)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/index.lock").path))
  }
  func testSelectedLinesCancellationDuringNativeCheckPreservesIndex() async throws {
    try await seed(); try write("first.txt", "ONE\ntwo\nthree\n")
    let review = try await linesReview()
    let before = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    try await interceptApplyCheck("sleep 20")
    let service = git!, ids = lineIDs(review, addition: ["ONE"], deletion: ["one"])
    let task = Task { try await service.applySelectedLines(ids, expected: review) }
    try await Task.sleep(for: .milliseconds(350)); task.cancel()
    do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation result: \(error)") }
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), before)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/index.lock").path))
  }
  func testSelectedLinesModeRenameBinarySymlinkAndFilterBoundaries() async throws {
    try await seed(); try write("first.txt", "ONE\ntwo\nthree\n")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent("first.txt").path)
    await linesRejected { _ = try await self.linesReview() }
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: directory.appendingPathComponent("first.txt").path)
    try write(".gitattributes", "first.txt filter=complex\n")
    await linesRejected { _ = try await self.linesReview() }
    try FileManager.default.removeItem(at: directory.appendingPathComponent(".gitattributes"))
    try Data([0, 1, 2]).write(to: directory.appendingPathComponent("first.txt"))
    await linesRejected { _ = try await self.linesReview() }
    try await raw(["restore", "--", "first.txt"]); try await raw(["mv", "first.txt", "renamed.txt"])
    let renamedStatus = try await git.status()
    let file = try XCTUnwrap(renamedStatus.files.first { $0.path == "renamed.txt" })
    let patch = try await git.patch(for: file, comparison: .staged)
    await linesRejected { _ = try await self.git.reviewSelectiveStaging(file: file, comparison: .staged,
      expectedPatch: String(decoding: patch, as: UTF8.self), expectedIndex: self.git.snapshot()) }
    try await raw(["reset", "--hard", "HEAD"])
    try FileManager.default.removeItem(at: directory.appendingPathComponent("first.txt"))
    try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("first.txt").path, withDestinationPath: "second.txt")
    await linesRejected { _ = try await self.linesReview() }
  }
  func testSelectedLinesLargeAndMalformedPatchesAreRejected() throws {
    let malformed = DiffParser.parse(Data("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,4 +1,4 @@\n-old\n+new\n".utf8))
    XCTAssertThrowsError(try SelectivePatch.build(malformed, selected: [0, 1]))
    let huge = DiffParser.parse(Data(("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+" + String(repeating: "x", count: 2 * 1024 * 1024) + "\n").utf8))
    XCTAssertFalse(SelectivePatch.supported(huge))
    let submodule = DiffParser.parse(Data("diff --git a/x b/x\nindex 0000000..1111111 160000\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-Subproject commit old\n+Subproject commit new\n".utf8))
    XCTAssertFalse(SelectivePatch.supported(submodule))
  }
}
