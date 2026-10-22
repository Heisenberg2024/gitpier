import XCTest
@testable import GitPierCore

final class MergeRevertTests: XCTestCase {
  var root: URL!
  var git: GitService!
  var merge: String!
  var mainParent: String!
  var topicParent: String!
  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-merge-revert-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    git = GitService(root: root)
    await git.configure(gitPath: "/usr/bin/git", authEnvironment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
    try await raw(["init", "-b", "main"])
    try await raw(["config", "user.name", "Merge Revert Tests"])
    try await raw(["config", "user.email", "revert@example.invalid"])
    try await raw(["config", "commit.gpgsign", "false"])
    try await raw(["config", "core.hooksPath", root.appendingPathComponent(".git/hooks").path])
    try write("base.txt", "base\n")
    try await raw(["add", "base.txt"]); try await raw(["commit", "-m", "base"])
    try await raw(["switch", "-c", "topic"])
    try write("topic.txt", "topic\n")
    try await raw(["add", "topic.txt"]); try await raw(["commit", "-m", "topic change"])
    topicParent = try await hash()
    try await raw(["switch", "main"])
    try write("main.txt", "main\n")
    try await raw(["add", "main.txt"]); try await raw(["commit", "-m", "main change"])
    mainParent = try await hash()
    try await raw(["merge", "--no-ff", "--no-edit", "topic"])
    merge = try await hash()
  }
  override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }
  @discardableResult func raw(_ args: [String]) async throws -> CommandResult {
    let result = try await ProcessRunner().run(executable: "/usr/bin/git", arguments: args, directory: root,
      environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
    guard result.code == 0 else { throw GitPierError.command("fixture", result.code, result.errorText) }
    return result
  }
  func write(_ path: String, _ text: String) throws {
    try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
  }
  func hash() async throws -> String { try await raw(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines) }
  func rejected(_ action: () async throws -> Void) async {
    do { try await action(); XCTFail("Unsafe merge revert succeeded") } catch {}
  }
  func testSelectedMainlineCreatesANewCommitWithTheSelectedParentsTree() async throws {
    for mainline in [1, 2] {
      let review = try await git.reviewMergeRevert(merge)
      XCTAssertEqual(review.parents.map(\.hash), [mainParent!, topicParent!])
      _ = try await git.revertMerge(review, mainline: mainline)
      let newHead = try await hash()
      let detail = try await git.commitDetail(newHead)
      XCTAssertNotEqual(newHead, merge)
      XCTAssertEqual(detail.parents, [merge!])
      XCTAssertEqual(FileManager.default.fileExists(atPath: root.appendingPathComponent("main.txt").path), mainline == 1)
      XCTAssertEqual(FileManager.default.fileExists(atPath: root.appendingPathComponent("topic.txt").path), mainline == 2)
      let state = try await git.status()
      XCTAssertTrue(state.files.isEmpty); XCTAssertNil(state.operation)
      try await raw(["reset", "--hard", merge])
    }
  }
  func testReviewAndRevertPreserveUntrackedContent() async throws {
    try write("notes.txt", "private work\n")
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    let review = try await git.reviewMergeRevert(merge)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    let before = try await hash(); XCTAssertEqual(before, merge)
    _ = try await git.revertMerge(review, mainline: 1)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("notes.txt"), encoding: .utf8), "private work\n")
    let untracked = try await git.status().untracked.map(\.path)
    XCTAssertEqual(untracked, ["notes.txt"])
  }
  func testOctopusMergeUsesTheExplicitThirdParent() async throws {
    try await raw(["switch", "-c", "third", mainParent])
    try write("third.txt", "third\n"); try await raw(["add", "third.txt"])
    try await raw(["commit", "-m", "third parent"])
    let third = try await hash()
    try await raw(["switch", "main"]); try await raw(["reset", "--hard", mainParent])
    try await raw(["merge", "--no-ff", "--no-edit", "topic", "third"])
    let octopus = try await hash(), review = try await git.reviewMergeRevert(octopus)
    XCTAssertEqual(review.parents.map(\.hash), [mainParent!, topicParent!, third])
    _ = try await git.revertMerge(review, mainline: 3)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("topic.txt").path))
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("third.txt"), encoding: .utf8), "third\n")
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("main.txt"), encoding: .utf8), "main\n")
  }
  func testVisibleIndexSnapshotMustStillMatchBeforePreparingReview() async throws {
    let snapshot = try await git.snapshot()
    try write("base.txt", "external staging\n"); try await raw(["add", "base.txt"])
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    do {
      _ = try await git.reviewMergeRevert(merge, expectedIndex: snapshot)
      XCTFail("An obsolete visible Index snapshot was accepted")
    } catch GitPierError.indexChanged {} catch { XCTFail("Unexpected error: \(error)") }
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
  }
  func testInvalidParentsAndNonMergeTargetsDoNotWrite() async throws {
    let review = try await git.reviewMergeRevert(merge)
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    for parent in [-1, 0, 3] { await rejected { _ = try await self.git.revertMerge(review, mainline: parent) } }
    await rejected { _ = try await self.git.reviewMergeRevert(self.mainParent) }
    await rejected { _ = try await self.git.reviewMergeRevert("HEAD") }
    let after = try await hash(); XCTAssertEqual(after, merge)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
  }
  func testChangedHeadAndChangedBranchInvalidateReview() async throws {
    let review = try await git.reviewMergeRevert(merge)
    try await raw(["switch", "-c", "other"])
    await rejected { _ = try await self.git.revertMerge(review, mainline: 1) }
    try await raw(["switch", "main"])
    try await raw(["commit", "--allow-empty", "-m", "later"])
    let later = try await hash()
    await rejected { _ = try await self.git.revertMerge(review, mainline: 1) }
    let after = try await hash(); XCTAssertEqual(after, later)
  }
  func testPartialIndexAndUnstagedEditsAreNotOverwritten() async throws {
    let review = try await git.reviewMergeRevert(merge)
    try write("base.txt", "staged\n"); try await raw(["add", "base.txt"])
    try write("base.txt", "unstaged\n")
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    await rejected { _ = try await self.git.revertMerge(review, mainline: 1) }
    await rejected { _ = try await self.git.reviewMergeRevert(self.merge) }
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("base.txt"), encoding: .utf8), "unstaged\n")
    try await raw(["reset", "--hard", merge])
    let cleanReview = try await git.reviewMergeRevert(merge)
    try write("base.txt", "working only\n")
    await rejected { _ = try await self.git.revertMerge(cleanReview, mainline: 1) }
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("base.txt"), encoding: .utf8), "working only\n")
  }
  func testReviewCannotBeUsedInAnotherRepository() async throws {
    let review = try await git.reviewMergeRevert(merge)
    let clone = root.appendingPathComponent(".git/clone")
    try await raw(["clone", root.path, clone.path])
    let other = GitService(root: clone)
    await rejected { _ = try await other.revertMerge(review, mainline: 1) }
    let state = try await other.status(); XCTAssertEqual(state.head, merge)
  }
  func testExecutableChangesInvalidateReviewBeforeLaunchingGit() async throws {
    let review = try await git.reviewMergeRevert(merge)
    await git.configureExecutable("/nonexistent/gitpier-test-git")
    await rejected { _ = try await self.git.revertMerge(review, mainline: 1) }
    let after = try await hash(); XCTAssertEqual(after, merge)
  }
  // Pause the last clean-status read after the operation comparison, then make a real
  // external change. The sixth status belongs to revertMerge, not its preparation.
  func gatedReview() async throws -> MergeRevertReview {
    let wrapper = root.appendingPathComponent(".git/revert-git")
    try """
    #!/bin/sh
    if [ "$1" = "--no-pager" ] && [ "$2" = "status" ] && [ -f .git/revert-gate-armed ]; then
      count=0
      if [ -f .git/revert-gate-count ]; then read -r count < .git/revert-gate-count; fi
      count=$((count + 1))
      printf '%s\\n' "$count" > .git/revert-gate-count
      if [ "$count" -eq 6 ]; then
        touch .git/revert-gate-entered
        attempts=0
        while [ ! -f .git/revert-gate-release ]; do
          attempts=$((attempts + 1))
          if [ "$attempts" -ge 3000 ]; then exit 84; fi
          sleep 0.01
        done
      fi
    fi
    exec /usr/bin/git "$@"
    """.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    await git.configureExecutable(wrapper.path)
    let review = try await git.reviewMergeRevert(merge)
    try write(".git/revert-gate-armed", "")
    return review
  }
  func waitForRevertGate() async throws {
    for _ in 0..<1000 {
      if FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/revert-gate-entered").path) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("The final clean-status gate was not reached")
    throw GitPierError.invalidInput("Missing merge-revert gate")
  }
  func assertStaleRevert(_ pending: Task<String, Error>) async {
    do { _ = try await pending.value; XCTFail("The last status accepted a stale merge-revert review") }
    catch GitPierError.indexChanged {} catch { XCTFail("Unexpected error: \(error)") }
  }
  func testHeadChangeDuringTheLastCleanCheckIsRejected() async throws {
    let review = try await gatedReview(), git = self.git!
    let pending = Task { try await git.revertMerge(review, mainline: 1) }
    defer { try? write(".git/revert-gate-release", "") }
    try await waitForRevertGate()
    try await raw(["commit", "--allow-empty", "-m", "external during final check"])
    let external = try await hash(), index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    try write(".git/revert-gate-release", "")
    await assertStaleRevert(pending)
    let after = try await hash(); XCTAssertEqual(after, external)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
  }
  func testBranchChangeDuringTheLastCleanCheckIsRejected() async throws {
    let review = try await gatedReview(), git = self.git!
    let pending = Task { try await git.revertMerge(review, mainline: 1) }
    defer { try? write(".git/revert-gate-release", "") }
    try await waitForRevertGate()
    try await raw(["switch", "-c", "external-during-final-check"])
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    try write(".git/revert-gate-release", "")
    await assertStaleRevert(pending)
    let after = try await hash(); XCTAssertEqual(after, merge)
    let state = try await git.status(); XCTAssertEqual(state.branch, "external-during-final-check")
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
  }
  func testExecutableChangeDuringTheLastCleanCheckCannotRunRevert() async throws {
    let review = try await gatedReview(), git = self.git!
    let pending = Task { try await git.revertMerge(review, mainline: 1) }
    defer { try? write(".git/revert-gate-release", "") }
    try await waitForRevertGate()
    let replacement = root.appendingPathComponent(".git/replacement-git")
    try """
    #!/bin/sh
    if [ "$1" = "--no-pager" ] && [ "$2" = "revert" ]; then touch .git/unreviewed-revert; fi
    exec /usr/bin/git "$@"
    """.write(to: replacement, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: replacement.path)
    await git.configureExecutable(replacement.path)
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    try write(".git/revert-gate-release", "")
    await assertStaleRevert(pending)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/unreviewed-revert").path))
    let after = try await hash(); XCTAssertEqual(after, merge)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
  }
  func testCommitHookRemainsEnabled() async throws {
    let review = try await git.reviewMergeRevert(merge)
    let hook = root.appendingPathComponent(".git/hooks/prepare-commit-msg")
    try "#!/bin/sh\ntouch .git/revert-hook-ran\nexit 23\n".write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    await rejected { _ = try await self.git.revertMerge(review, mainline: 1) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/revert-hook-ran").path))
    let after = try await hash(); XCTAssertEqual(after, merge)
  }
  func testSigningRemainsEnabled() async throws {
    let signer = root.appendingPathComponent(".git/test-signer")
    try "#!/bin/sh\ntouch .git/revert-signing-ran\nexit 1\n".write(to: signer, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: signer.path)
    try await raw(["config", "gpg.program", signer.path]); try await raw(["config", "commit.gpgsign", "true"])
    try await raw(["config", "user.signingkey", "fixture-key"])
    let review = try await git.reviewMergeRevert(merge)
    await rejected { _ = try await self.git.revertMerge(review, mainline: 1) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/revert-signing-ran").path))
    let after = try await hash(); XCTAssertEqual(after, merge)
  }
  func testConflictedRevertCanBeResolvedAndContinued() async throws {
    try write("topic.txt", "later topic work\n"); try await raw(["add", "topic.txt"])
    try await raw(["commit", "-m", "later topic edit"])
    let later = try await hash(), review = try await git.reviewMergeRevert(merge)
    await rejected { _ = try await self.git.revertMerge(review, mainline: 1) }
    let state = try await git.status()
    XCTAssertEqual(state.head, later); XCTAssertEqual(state.operation, .revert)
    XCTAssertEqual(state.files.filter(\.isConflicted).map(\.path), ["topic.txt"])
    await rejected { _ = try await self.git.reviewMergeRevert(self.merge) }
    try await git.resolveConflict(git.conflictSnapshot("topic.txt"), resolution: .delete)
    _ = try await git.perform(["revert", "--continue"])
    let completed = try await git.status()
    XCTAssertNil(completed.operation); XCTAssertTrue(completed.files.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("topic.txt").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("main.txt").path))
  }
}
