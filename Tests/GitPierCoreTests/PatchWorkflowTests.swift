import XCTest
@testable import GitPierCore

extension GitServiceTests {
  private func ordinaryPatch() async throws -> Data {
    try await seed(); try write("first.txt", "ONE\ntwo\nthree\n")
    let file = try await git.status().files[0]
    let patch = try await git.exportFilePatch(file, comparison: .unstaged)
    try await raw(["restore", "--", "first.txt"])
    return patch
  }
  private func patchRejected(_ action: () async throws -> Void) async {
    do { try await action(); XCTFail("Expected patch rejection") } catch {}
  }
  func testPatchWorkingImportPreviewsAndPreservesPartialIndex() async throws {
    let patch = try await ordinaryPatch()
    try write("second.txt", "external staged\n"); try await raw(["add", "--", "second.txt"])
    try write("second.txt", "external staged\nexternal working\n")
    let index = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    let review = try await git.reviewPatchImport(patch)
    XCTAssertEqual(review.files.map(\.path), ["first.txt"])
    XCTAssertEqual(review.files[0].additions, 1); XCTAssertEqual(review.files[0].deletions, 1)
    _ = try await git.applyImportedPatch(review)
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("first.txt"), encoding: .utf8), "ONE\ntwo\nthree\n")
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), index)
    let staged = try await raw(["show", ":second.txt"]).text
    XCTAssertEqual(staged, "external staged\n")
  }
  func testPatchIndexImportIsSeparateAndLeavesWorkingFileUntouched() async throws {
    let patch = try await ordinaryPatch()
    let review = try await git.reviewPatchImport(patch, target: .index)
    _ = try await git.applyImportedPatch(review)
    let content = try await raw(["show", ":first.txt"]).text
    XCTAssertEqual(content, "ONE\ntwo\nthree\n")
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("first.txt"), encoding: .utf8), "one\ntwo\nthree\n")
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/index.lock").path))
  }
  func testPatchPreviewCancelIsReadOnly() async throws {
    let patch = try await ordinaryPatch()
    let index = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    let head = try await git.resolveCommit("HEAD")
    _ = try await git.reviewPatchImport(patch)
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), index)
    let after = try await git.resolveCommit("HEAD"); XCTAssertEqual(after, head)
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("first.txt"), encoding: .utf8), "one\ntwo\nthree\n")
  }
  func testPatchMalformedAndInapplicableAreRejectedWithoutWrites() async throws {
    let patch = try await ordinaryPatch()
    await patchRejected { _ = try await self.git.reviewPatchImport(Data("not a patch".utf8)) }
    try write("first.txt", "different source\n")
    await patchRejected { _ = try await self.git.reviewPatchImport(patch) }
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("first.txt"), encoding: .utf8), "different source\n")
  }
  func testPatchExternalWorkIndexAndHeadChangesRejectOldReview() async throws {
    let patch = try await ordinaryPatch()
    let review = try await git.reviewPatchImport(patch)
    try write("first.txt", "external\n")
    await patchRejected { _ = try await self.git.applyImportedPatch(review) }
    try await raw(["restore", "--", "first.txt"])
    let refreshed = try await git.reviewPatchImport(patch)
    try write("second.txt", "external\n"); try await raw(["add", "--", "second.txt"])
    await patchRejected { _ = try await self.git.applyImportedPatch(refreshed) }
    try await raw(["commit", "-m", "external"])
    await patchRejected { _ = try await self.git.applyImportedPatch(refreshed) }
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("first.txt"), encoding: .utf8), "one\ntwo\nthree\n")
  }
  func testPatchRejectsTraversalGitMetadataAndSubmoduleConfiguration() async throws {
    try await seed()
    for path in ["../outside.txt", ".git/config", ".GIT/config", ".gitmodules", "dir/.git/config"] {
      let data = Data("diff --git a/\(path) b/\(path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1 @@\n+payload\n".utf8)
      await patchRejected { _ = try await self.git.reviewPatchImport(data) }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("outside.txt").path))
  }
  func testPatchRejectsSymlinkParentsAndEmbeddedRepositories() async throws {
    try await seed()
    let external = directory.deletingLastPathComponent().appendingPathComponent("GitPier-patch-outside-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: external) }
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link"), withDestinationURL: external)
    let linkPatch = Data("diff --git a/link/new.txt b/link/new.txt\nnew file mode 100644\n--- /dev/null\n+++ b/link/new.txt\n@@ -0,0 +1 @@\n+new\n".utf8)
    await patchRejected { _ = try await self.git.reviewPatchImport(linkPatch) }
    try await raw(["init", "nested"])
    let nestedPatch = Data("diff --git a/nested/new.txt b/nested/new.txt\nnew file mode 100644\n--- /dev/null\n+++ b/nested/new.txt\n@@ -0,0 +1 @@\n+new\n".utf8)
    await patchRejected { _ = try await self.git.reviewPatchImport(nestedPatch) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: external.appendingPathComponent("new.txt").path))
  }
  func testPatchLiteralBinaryRoundTrip() async throws {
    try await seed()
    let binary = Data([0, 1, 2, 3, 0, 255])
    try binary.write(to: directory.appendingPathComponent("first.txt"))
    let file = try await git.status().files[0]
    let patch = try await git.exportFilePatch(file, comparison: .unstaged)
    XCTAssertTrue(String(decoding: patch, as: UTF8.self).contains("GIT binary patch"))
    try await raw(["restore", "--", "first.txt"])
    let review = try await git.reviewPatchImport(patch)
    XCTAssertTrue(review.files[0].binary)
    _ = try await git.applyImportedPatch(review)
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("first.txt")), binary)
  }
  func testPatchCommitDiffAndEmailFormatsStayDistinct() async throws {
    try await seed()
    let hash = try await git.resolveCommit("HEAD")
    let diff = try await git.exportCommitPatch(hash)
    XCTAssertTrue(String(decoding: diff, as: UTF8.self).hasPrefix("diff --git "))
    let email = try await git.exportCommitPatch(hash, format: .commitEmail)
    XCTAssertTrue(String(decoding: email, as: UTF8.self).hasPrefix("From " ))
    await patchRejected { _ = try await self.git.reviewPatchImport(email) }
    let index = try await git.snapshot()
    XCTAssertTrue(index.paths.isEmpty)
  }
  func testPatchRangeExportUsesFixedEndpoints() async throws {
    try await seed(); let base = try await git.resolveCommit("HEAD")
    try write("first.txt", "ONE\ntwo\nthree\n"); try await raw(["add", "--", "first.txt"]); try await raw(["commit", "-m", "change"])
    let tip = try await git.resolveCommit("HEAD")
    let diff = try await git.exportRangePatch(from: base, to: tip)
    XCTAssertTrue(String(decoding: diff, as: UTF8.self).contains("+ONE"))
    let email = try await git.exportRangePatch(from: base, to: tip, format: .commitEmail)
    XCTAssertTrue(String(decoding: email, as: UTF8.self).contains("Subject: [PATCH] change"))
  }
  func testPatchPathsWithSpacesUnicodeAndNewlines() async throws {
    try await seed()
    let path = "space 中文\nfile.txt"
    try write(path, "old\n"); try await raw(["add", "--", path]); try await raw(["commit", "-m", "unusual path"])
    try write(path, "new\n")
    let file = try await git.status().files.first { $0.path == path }!
    let patch = try await git.exportFilePatch(file, comparison: .unstaged)
    try await raw(["restore", "--", path])
    let review = try await git.reviewPatchImport(patch)
    XCTAssertEqual(review.files.map(\.path), [path])
    _ = try await git.applyImportedPatch(review)
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(path), encoding: .utf8), "new\n")
  }
  func testPatchRejectsOversizedBinaryDeltasAndUnsupportedMetadata() throws {
    XCTAssertThrowsError(try PatchParser.sections(Data(repeating: 97, count: PatchParser.limit + 1)))
    for metadata in ["new file mode 120000", "new file mode 160000", "rename from old\nrename to new", "copy from old\ncopy to new"] {
      XCTAssertThrowsError(try PatchParser.sections(Data("diff --git a/old b/new\n\(metadata)\n".utf8)))
    }
    XCTAssertThrowsError(try PatchParser.sections(Data("diff --git a/x b/x\nGIT binary patch\nliteral 999999999\n".utf8)))
    XCTAssertThrowsError(try PatchParser.sections(Data("diff --git a/x b/x\nGIT binary patch\ndelta 10\n".utf8)))
  }
}
