import XCTest

@testable import GitPierCore

extension GitServiceTests {
  private func textConflict(path: String = "first.txt", style: String = "merge") async throws
    -> ConflictSnapshot
  {
    try await seed()
    if path != "first.txt" {
      try write(path, "base\n")
      try await raw(["add", "--", path])
      try await raw(["commit", "-m", "add literal path"])
    }
    try await raw(["config", "merge.conflictStyle", style])
    try await git.createBranch("incoming")
    try await git.switchBranch("incoming")
    try write(path, "incoming\n")
    try await raw(["add", "--", path])
    try await raw(["commit", "-m", "incoming"])
    try await git.switchBranch("main")
    try write(path, "current\n")
    try await raw(["add", "--", path])
    try await raw(["commit", "-m", "current"])
    _ = try await git.read(["merge", "incoming"], allowFailure: true)
    return try await git.conflictSnapshot(path)
  }
  func testConflictTextResolutionPreservesOtherPartialStagingAndCompletesMerge() async throws {
    let conflict = try await textConflict(style: "diff3")
    XCTAssertEqual(conflict.ours?.text, "current\n")
    XCTAssertEqual(conflict.theirs?.text, "incoming\n")
    XCTAssertEqual(conflict.base?.text, "one\ntwo\nthree\n")
    let result = ConflictMarkers.resolving(conflict.resultText!, block: 0, choice: .both)
    XCTAssertEqual(result, "current\nincoming\n")
    try write("second.txt", "external staged\n")
    try await raw(["add", "--", "second.txt"])
    try write("second.txt", "external unstaged\n")
    let unrelated = try await raw(["show", ":second.txt"]).stdout
    try await git.resolveConflict(conflict, resolution: .text(result))
    let state = try await git.status()
    XCTAssertFalse(state.files.contains(where: \.isConflicted))
    XCTAssertEqual(state.operation, .merge)
    let unrelatedAfter = try await raw(["show", ":second.txt"]).stdout
    XCTAssertEqual(unrelatedAfter, unrelated)
    XCTAssertTrue(state.files.first { $0.path == "second.txt" }!.isPartial)
    let review = try await git.reviewMerge()
    XCTAssertTrue(review.index.paths.contains("second.txt"))
    let committed = try await git.completeMerge(review)
    let parents = try await raw(["show", "-s", "--format=%P", committed.hash]).text.split(
      whereSeparator: \.isWhitespace)
    XCTAssertEqual(parents.count, 2)
    let merged = try await raw(["show", "HEAD:first.txt"]).text
    XCTAssertEqual(merged, result)
    let remainder = try String(
      contentsOf: directory.appendingPathComponent("second.txt"), encoding: .utf8)
    XCTAssertEqual(remainder, "external unstaged\n")
  }
  func testConflictCannotStageUnresolvedOrOrphanMarkers() async throws {
    let conflict = try await textConflict()
    for text in [conflict.resultText!, "manual\n>>>>>>> incoming\n"] {
      do {
        try await git.resolveConflict(conflict, resolution: .text(text))
        XCTFail("Markers must remain unresolved")
      } catch { XCTAssertTrue(error.localizedDescription.contains("conflict markers")) }
    }
    let state = try await git.status()
    XCTAssertTrue(state.files.contains(where: \.isConflicted))
    XCTAssertEqual(
      try Data(contentsOf: directory.appendingPathComponent(conflict.path)),
      conflict.workingContents)
  }
  func testConflictRefusesChangedWorktreeAndPreservesExternalContent() async throws {
    let conflict = try await textConflict()
    try write("first.txt", "external edit\n")
    do {
      try await git.resolveConflict(conflict, resolution: .text("reviewed\n"))
      XCTFail("Must refuse stale working content")
    } catch GitPierError.conflictChanged {}
    let content = try String(
      contentsOf: directory.appendingPathComponent("first.txt"), encoding: .utf8)
    XCTAssertEqual(content, "external edit\n")
  }
  func testConflictRefusesExternallyResolvedIndexAndAbortedOperation() async throws {
    let conflict = try await textConflict()
    try write("first.txt", "external resolution\n")
    try await raw(["add", "--", "first.txt"])
    do {
      try await git.resolveConflict(conflict, resolution: .ours)
      XCTFail("Must preserve another client's resolution")
    } catch GitPierError.conflictChanged {}
    try await git.perform(["merge", "--abort"])
    do {
      try await git.resolveConflict(conflict, resolution: .theirs)
      XCTFail("Must refuse an aborted conflict")
    } catch GitPierError.conflictChanged {}
  }
  func testConflictLiteralPathAndExecutableModeArePreserved() async throws {
    let path = "中文 [literal]\tfile.txt"
    let conflict = try await textConflict(path: path)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent(path).path)
    let fresh = try await git.conflictSnapshot(path)
    try await git.resolveConflict(fresh, resolution: .text("reviewed\n"))
    let mode =
      try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(path).path)[
        .posixPermissions] as? Int
    XCTAssertEqual(mode, 0o755)
    let entries = try await raw(["--literal-pathspecs", "ls-files", "--unmerged", "-z", "--", path])
      .stdout
    XCTAssertTrue(entries.isEmpty)
    XCTAssertEqual(conflict.path, path)
  }
  func testConflictRejectsEscapingSymlinkParent() async throws {
    let conflict = try await textConflict(path: "nested/file.txt")
    let outside = directory.appendingPathComponent(".git/outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try "protected\n".write(
      to: outside.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: directory.appendingPathComponent("nested"))
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent("nested"), withDestinationURL: outside)
    do {
      try await git.resolveConflict(conflict, resolution: .ours)
      XCTFail("Must not follow a replaced parent")
    } catch GitPierError.unsafePath {}
    let protected = try String(
      contentsOf: outside.appendingPathComponent("file.txt"), encoding: .utf8)
    XCTAssertEqual(protected, "protected\n")
  }
  func testBinaryConflictChoosesExactVersionWithoutTextDecoding() async throws {
    try await seed()
    let path = "binary.dat"
    try Data([0, 1, 2]).write(to: directory.appendingPathComponent(path))
    try await raw(["add", "--", path])
    try await raw(["commit", "-m", "binary base"])
    try await git.createBranch("incoming")
    try await git.switchBranch("incoming")
    let incoming = Data([0, 255, 3])
    try incoming.write(to: directory.appendingPathComponent(path))
    try await raw(["add", "--", path])
    try await raw(["commit", "-m", "binary incoming"])
    try await git.switchBranch("main")
    try Data([0, 128, 4]).write(to: directory.appendingPathComponent(path))
    try await raw(["add", "--", path])
    try await raw(["commit", "-m", "binary current"])
    _ = try await git.read(["merge", "incoming"], allowFailure: true)
    let conflict = try await git.conflictSnapshot(path)
    XCTAssertNil(conflict.resultText)
    try await git.resolveConflict(conflict, resolution: .theirs)
    let staged = try await raw(["show", ":" + path]).stdout
    XCTAssertEqual(staged, incoming)
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(path)), incoming)
  }
  func testModifyDeleteConflictCanAcceptDeletion() async throws {
    try await seed()
    try await git.createBranch("incoming")
    try await git.switchBranch("incoming")
    try write("first.txt", "incoming change\n")
    try await raw(["add", "--", "first.txt"])
    try await raw(["commit", "-m", "incoming"])
    try await git.switchBranch("main")
    try await raw(["rm", "--", "first.txt"])
    try await raw(["commit", "-m", "delete current"])
    _ = try await git.read(["merge", "incoming"], allowFailure: true)
    let conflict = try await git.conflictSnapshot("first.txt")
    XCTAssertNil(conflict.ours)
    try await git.resolveConflict(conflict, resolution: .ours)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("first.txt").path))
    let state = try await git.status()
    XCTAssertFalse(state.files.contains(where: \.isConflicted))
    _ = try await git.completeMerge(git.reviewMerge())
    let finished = try await git.status()
    XCTAssertNil(finished.operation)
  }
  func testMergeContinuationRefusesChangedReviewAndHookAddedContent() async throws {
    let conflict = try await textConflict()
    try await git.resolveConflict(conflict, resolution: .ours)
    let review = try await git.reviewMerge()
    try write("second.txt", "unreviewed\n")
    try await raw(["add", "--", "second.txt"])
    do {
      _ = try await git.completeMerge(review)
      XCTFail("Must review external Index changes")
    } catch GitPierError.indexChanged {}
    let current = try await git.reviewMerge()
    let hook = directory.appendingPathComponent(".git/hooks/pre-commit")
    try "#!/bin/sh\nprintf 'hook added\\n' > first.txt\ngit add -- first.txt\n".write(
      to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    do {
      _ = try await git.completeMerge(current)
      XCTFail("Must reject hook changes to the reviewed tree")
    } catch { XCTAssertTrue(error.localizedDescription.contains("hook changed")) }
    let state = try await git.status()
    XCTAssertEqual(state.operation, .merge)
    XCTAssertEqual(state.head, current.index.head)
  }
  func testMergeContinuationRefusesChangedParents() async throws {
    let conflict = try await textConflict()
    try await git.resolveConflict(conflict, resolution: .ours)
    let review = try await git.reviewMerge()
    try (review.index.head! + "\n").write(
      to: directory.appendingPathComponent(".git/MERGE_HEAD"), atomically: true, encoding: .utf8)
    do {
      _ = try await git.completeMerge(review)
      XCTFail("Must review changed merge parents")
    } catch GitPierError.conflictChanged {}
  }
  func testConflictManualEditKeepsCRLFLineEndings() async throws {
    _ = try await textConflict()
    let url = directory.appendingPathComponent("first.txt")
    let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(
      of: "\n", with: "\r\n")
    try text.write(to: url, atomically: true, encoding: .utf8)
    let review = try await git.conflictSnapshot("first.txt")
    do {
      try await git.resolveConflict(
        review, resolution: .text(String(repeating: "\n", count: ConflictSnapshot.textLimit)))
      XCTFail("CRLF expansion must stay within the editor limit")
    } catch GitPierError.outputLimit {}
    XCTAssertEqual(try Data(contentsOf: url), Data(text.utf8))
    try await git.resolveConflict(review, resolution: .text("manually typed\nnew line\n"))
    let saved = try Data(contentsOf: url)
    XCTAssertEqual(saved, Data("manually typed\r\nnew line\r\n".utf8))
  }
  func testResolvedMergeOffersAnotherRecoveryIfRemoteAdvancesBeforePush() async throws {
    try await seed()
    let bare = directory.appendingPathComponent(".git/recovery-remote.git")
    let peerRoot = directory.appendingPathComponent(".git/recovery-peer")
    try await raw(["init", "--bare", bare.path])
    try await raw(["remote", "add", "origin", bare.path])
    _ = try await git.network("push", remote: "origin", branch: "main")
    try await raw(["clone", "--branch", "main", bare.path, peerRoot.path])
    let peer = GitService(root: peerRoot)
    try await peer.perform(["config", "user.name", "Recovery Peer"])
    try await peer.perform(["config", "user.email", "peer@example.invalid"])
    try await peer.perform(["config", "commit.gpgsign", "false"])
    try "incoming\n".write(
      to: peerRoot.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
    try await peer.stage(peer.status().files)
    _ = try await peer.commit(message: "incoming", expected: peer.snapshot())
    _ = try await peer.network("push")
    try write("first.txt", "current\n")
    try await git.stage(git.status().files)
    _ = try await git.commit(message: "current", expected: git.snapshot())
    var target: PushRejection?
    do {
      _ = try await git.network("push")
      XCTFail()
    } catch let rejected as PushRejection { target = rejected }
    let original = try XCTUnwrap(target)
    do {
      _ = try await git.mergeAndPush(original)
      XCTFail()
    } catch { XCTAssertTrue(error.localizedDescription.contains("conflict")) }
    let file = try await git.conflictSnapshot("first.txt")
    try await git.resolveConflict(file, resolution: .text("current\nincoming\n"))
    let merge = try await git.completeMerge(git.reviewMerge())
    try "newer remote\n".write(
      to: peerRoot.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
    try await peer.stage(peer.status().files)
    _ = try await peer.commit(message: "newer remote", expected: peer.snapshot())
    _ = try await peer.network("push")
    var next: PushRejection?
    do {
      _ = try await git.pushCompletedMerge(original, head: merge.hash)
      XCTFail()
    } catch let rejected as PushRejection { next = rejected }
    let updated = try XCTUnwrap(next)
    XCTAssertEqual(updated.localHead, merge.hash)
    XCTAssertEqual(updated.remoteURL, original.remoteURL)
    XCTAssertEqual(updated.remoteReference, original.remoteReference)
    _ = try await git.mergeAndPush(updated)
    let remoteHead = try await raw(["--git-dir=" + bare.path, "rev-parse", "refs/heads/main"]).text
      .trimmingCharacters(in: .newlines)
    let state = try await git.status()
    XCTAssertEqual(state.head, remoteHead)
    XCTAssertEqual(state.ahead, 0)
  }
}

final class ConflictMarkersTests: XCTestCase {
  func testDiff3UnicodeCRLFMultipleBlocksAndNoFinalNewline() {
    let text =
      "😀 context\r\n<<<<<<< HEAD\r\ncurrent\r\n||||||| base\r\nbase\r\n=======\r\nincoming\r\n>>>>>>> incoming\r\ntail\r\n<<<<<<< HEAD\r\nsecond current\r\n=======\r\nsecond incoming\r\n>>>>>>> incoming"
    let blocks = ConflictMarkers.blocks(text)
    XCTAssertEqual(blocks.count, 2)
    XCTAssertEqual(blocks[0].ours, "current\r\n")
    XCTAssertEqual(blocks[0].range.location, "😀 context\r\n".utf16.count)
    let first = ConflictMarkers.resolving(text, block: 0, choice: .both)
    let final = ConflictMarkers.resolving(first, block: 0, choice: .theirs)
    XCTAssertEqual(final, "😀 context\r\ncurrent\r\nincoming\r\ntail\r\nsecond incoming\r\n")
    XCTAssertFalse(ConflictMarkers.containsMarkers(final))
  }
  func testCustomMarkersAndMarkdownUnderline() {
    let text = "<<< current\nours\n===\ntheirs\n>>> incoming\n"
    XCTAssertEqual(ConflictMarkers.blocks(text, size: 3).count, 1)
    XCTAssertEqual(ConflictMarkers.resolving(text, block: 0, choice: .ours, size: 3), "ours\n")
    XCTAssertTrue(ConflictMarkers.containsMarkers("<<<<<<< HEAD\nunclosed\n"))
    XCTAssertFalse(ConflictMarkers.containsMarkers("Heading\n=======\n"))
  }
}
