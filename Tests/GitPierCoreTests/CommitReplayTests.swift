import XCTest
@testable import GitPierCore

final class CommitReplayTests: XCTestCase {
  var root: URL!
  var git: GitService!
  var base: String!
  var commits: [String] = []
  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-replay-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    git = GitService(root: root)
    await git.configure(gitPath: "/usr/bin/git", authEnvironment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
    try await raw(["init", "-b", "main"])
    try await raw(["config", "user.name", "Replay Tests"])
    try await raw(["config", "user.email", "replay@example.invalid"])
    try await raw(["config", "commit.gpgsign", "false"])
    try await raw(["config", "core.hooksPath", root.appendingPathComponent(".git/hooks").path])
    try write("base.txt", "base\n"); try await raw(["add", "."]); try await raw(["commit", "-m", "base"])
    base = try await head()
    try await raw(["switch", "-c", "source"])
    for i in 1...2 {
      try write("\(i).txt", "\(i)\n"); try await raw(["add", "."])
      try await raw(["commit", "-m", "change \(i)"]); commits.append(try await head())
    }
    try await raw(["switch", "main"])
  }
  override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }
  @discardableResult func raw(_ args: [String], failure: Bool = false) async throws -> CommandResult {
    let value = try await ProcessRunner().run(executable: "/usr/bin/git", arguments: args, directory: root,
      environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
    if !failure && value.code != 0 { throw GitPierError.command("fixture", value.code, value.errorText) }
    return value
  }
  func write(_ path: String, _ value: String) throws {
    try value.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
  }
  func head() async throws -> String { try await raw(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines) }
  func reject(_ action: () async throws -> Void) async {
    do { try await action(); XCTFail("Obsolete or unsafe replay was accepted") } catch {}
  }
  func testSequencerWithoutHeadMarkerRemainsAnOperation() async throws {
    let directory = root.appendingPathComponent(".git/sequencer")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try write(".git/sequencer/head", base + "\n")
    try write(".git/sequencer/todo", "pick \(commits[0]) change 1\npick \(commits[1]) change 2\n")
    let state = try await git.status()
    XCTAssertEqual(state.operation, .cherryPick, "Pending native sequencer must not appear idle")
    let review = try await git.reviewOperation()
    try write(".git/sequencer/todo", "revert \(commits[1]) change 2\n")
    let changed = try await git.reviewOperation()
    XCTAssertNotEqual(review, changed, "Changing sequencer todo must invalidate a confirmed operation")
    let record = RepositoryRecord(path: root.path, name: "Replay")
    let card = try await git.workspaceSnapshot(record)
    XCTAssertEqual(card.operation, .revert)
  }
  func testReviewedOrderIsTheNativeExecutionOrderAndCannotRepeat() async throws {
    let review = try await git.reviewCommitReplay(.cherryPick, commits: Array(commits.reversed()))
    XCTAssertEqual(review.commits.map(\.hash), Array(commits.reversed()))
    XCTAssertEqual(review.operation.head, base)
    try write("notes.txt", "keep\n")
    _ = try await git.executeCommitReplay(review)
    let history = try await git.history(count: 2)
    XCTAssertEqual(history.map(\.subject), ["change 1", "change 2"])
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("notes.txt"), encoding: .utf8), "keep\n")
    await reject { _ = try await self.git.executeCommitReplay(review) }
  }
  func testOrdinaryRevertCreatesANewCommit() async throws {
    try await raw(["cherry-pick", commits[0]])
    let before = try await head()
    let review = try await git.reviewCommitReplay(.revert, commits: [before])
    _ = try await git.executeCommitReplay(review)
    let state = try await git.status(), detail = try await git.commitDetail("HEAD")
    XCTAssertNil(state.operation); XCTAssertEqual(detail.parents, [before])
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("1.txt").path))
  }
  func replacementCommit() async throws -> String {
    try await raw(["switch", "-c", "replacement", base])
    try write("replacement.txt", "unexpected\n"); try await raw(["add", "."])
    try await raw(["commit", "-m", "replacement change"])
    let replacement = try await head()
    try await raw(["switch", "main"])
    return replacement
  }
  func testChangedReplacementMappingCannotChangeReviewedSource() async throws {
    let replacement = try await replacementCommit()
    let review = try await git.reviewCommitReplay(.cherryPick, commits: [commits[0]])
    try await raw(["replace", commits[0], replacement])
    await reject { _ = try await self.git.executeCommitReplay(review) }
    let after = try await head(); XCTAssertEqual(after, base)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("replacement.txt").path))
  }
  func testExistingReplacementIsReviewedAndAppliedWithNativeSemantics() async throws {
    let replacement = try await replacementCommit()
    try await raw(["replace", commits[0], replacement])
    let review = try await git.reviewCommitReplay(.cherryPick, commits: [commits[0]])
    XCTAssertEqual(review.commits[0].subject, "replacement change")
    _ = try await git.executeCommitReplay(review)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("replacement.txt"), encoding: .utf8), "unexpected\n")
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("1.txt").path))
  }
  func testChangedGraftOrShallowViewInvalidatesReplay() async throws {
    for path in [".git/info/grafts", ".git/shallow"] {
      let review = try await git.reviewCommitReplay(.cherryPick, commits: [commits[0]])
      try write(path, commits[0] + "\n")
      await reject { _ = try await self.git.executeCommitReplay(review) }
      try FileManager.default.removeItem(at: root.appendingPathComponent(path))
      let after = try await head(); XCTAssertEqual(after, base)
    }
  }
  func testCustomAncestryOverlayPathsAreBoundToTheirContents() async throws {
    for name in ["GIT_GRAFT_FILE", "GIT_SHALLOW_FILE"] {
      let path = root.appendingPathComponent(".git/custom-overlay").path
      try write(".git/custom-overlay", "")
      await git.configure(gitPath: "/usr/bin/git", authEnvironment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", name: path])
      let review = try await git.reviewCommitReplay(.cherryPick, commits: [commits[0]])
      try write(".git/custom-overlay", commits[0] + "\n")
      await reject { _ = try await self.git.executeCommitReplay(review) }
      try FileManager.default.removeItem(atPath: path)
    }
  }
  func testTreeAndBlobReplacementChangesAlsoInvalidateDiffAndExecution() async throws {
    let sourceTree = try await raw(["rev-parse", commits[0] + "^{tree}"]).text.trimmingCharacters(in: .newlines)
    let baseTree = try await raw(["rev-parse", base + "^{tree}"]).text.trimmingCharacters(in: .newlines)
    let sourceBlob = try await raw(["rev-parse", commits[0] + ":1.txt"]).text.trimmingCharacters(in: .newlines)
    let baseBlob = try await raw(["rev-parse", base + ":base.txt"]).text.trimmingCharacters(in: .newlines)
    for (original, replacement) in [(sourceTree, baseTree), (sourceBlob, baseBlob)] {
      let review = try await git.reviewCommitReplay(.cherryPick, commits: [commits[0]])
      try await git.validateCommitReplaySource(review)
      try await raw(["replace", original, replacement])
      await reject { try await self.git.validateCommitReplaySource(review) }
      await reject { _ = try await self.git.executeCommitReplay(review) }
      try await raw(["replace", "-d", original])
    }
  }
  func testRecoveryRejectsChangedObjectView() async throws {
    let replacement = try await replacementCommit()
    try write("1.txt", "conflict\n"); try await raw(["add", "."]); try await raw(["commit", "-m", "target"])
    _ = try await raw(["cherry-pick"] + commits, failure: true)
    let control = try await git.reviewSequencerControl(.abort)
    try await raw(["replace", commits[0], replacement])
    await reject { _ = try await self.git.controlSequencer(control) }
    let state = try await git.status(); XCTAssertEqual(state.operation, .cherryPick)
  }
  func testFinalRecoveryStatusCannotDropChangedStagedBlob() async throws {
    try write("1.txt", "conflict\n"); try await raw(["add", "."]); try await raw(["commit", "-m", "target"])
    let original = try await head()
    _ = try await raw(["cherry-pick"] + commits, failure: true)
    try write("1.txt", "reviewed resolution\n"); try await raw(["add", "1.txt"])
    let blob = try await git.read(["hash-object", "-w", "--stdin"], input: Data("unreviewed resolution\n".utf8)).text.trimmingCharacters(in: .newlines)
    let wrapper = root.appendingPathComponent(".git/recovery-git")
    try """
    #!/bin/sh
    if [ -f '\(root.path)/.git/recovery-armed' ]; then
      case " $* " in
        *" status "*)
          n=0
          if [ -f '\(root.path)/.git/recovery-count' ]; then n=$(cat '\(root.path)/.git/recovery-count'); fi
          n=$((n + 1)); echo "$n" > '\(root.path)/.git/recovery-count'
          if [ "$n" = 14 ]; then /usr/bin/git update-index --cacheinfo '100644,\(blob),1.txt'; fi
          ;;
      esac
    fi
    exec /usr/bin/git "$@"
    """.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    await git.configureExecutable(wrapper.path)
    let control = try await git.reviewSequencerControl(.continue)
    try write(".git/recovery-armed", "yes")
    await reject { _ = try await self.git.controlSequencer(control) }
    let after = try await head(); XCTAssertEqual(after, original)
    let staged = try await raw(["show", ":1.txt"]).text
    XCTAssertEqual(staged, "unreviewed resolution\n", "Rejection must preserve the external Index edit")
  }
  func testInvalidEmptyDuplicateAndMergeCherryPickPlansDoNotWrite() async throws {
    for ids in [[], ["HEAD"], [commits[0], commits[0]], Array(repeating: commits[0], count: 201)] {
      await reject { _ = try await self.git.reviewCommitReplay(.cherryPick, commits: ids) }
    }
    await reject { _ = try await self.git.reviewCommitReplay(.revert, commits: self.commits) }
    try await raw(["merge", "--no-ff", "--no-edit", "source"])
    let merge = try await head()
    await reject { _ = try await self.git.reviewCommitReplay(.cherryPick, commits: [merge]) }
    let review = try await git.reviewCommitReplay(.revert, commits: [merge])
    XCTAssertEqual(review.parents.count, 2)
    await reject { _ = try await self.git.executeCommitReplay(review) }
    _ = try await git.executeCommitReplay(review, mainline: 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("2.txt").path))
  }
  func testStaleBranchHeadAndPartialIndexAreRejected() async throws {
    let review = try await git.reviewCommitReplay(.cherryPick, commits: commits)
    try await raw(["switch", "-c", "other"])
    await reject { _ = try await self.git.executeCommitReplay(review) }
    try await raw(["switch", "main"])
    try write("base.txt", "staged\n"); try await raw(["add", "base.txt"])
    try write("base.txt", "unstaged\n")
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    await reject { _ = try await self.git.executeCommitReplay(review) }
    await reject { _ = try await self.git.reviewCommitReplay(.cherryPick, commits: self.commits) }
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("base.txt"), encoding: .utf8), "unstaged\n")
    try await raw(["reset", "--hard", base]); try await raw(["commit", "--allow-empty", "-m", "concurrent"])
    await reject { _ = try await self.git.executeCommitReplay(review) }
  }
  func testConflictContinueUsesSequencerAndKeepsRemainingCommits() async throws {
    try write("1.txt", "conflict\n"); try await raw(["add", "."]); try await raw(["commit", "-m", "target"])
    let review = try await git.reviewCommitReplay(.cherryPick, commits: commits)
    await reject { _ = try await self.git.executeCommitReplay(review) }
    let sequence = try await git.sequencerState()
    XCTAssertEqual(sequence?.operation, .cherryPick); XCTAssertEqual(sequence?.currentHash, commits[0])
    XCTAssertEqual(sequence?.remaining.count, 2)
    await reject { _ = try await self.git.reviewSequencerControl(.continue) }
    try write("1.txt", "resolved\n"); try await raw(["add", "1.txt"])
    let control = try await git.reviewSequencerControl(.continue)
    _ = try await git.controlSequencer(control)
    let state = try await git.status()
    XCTAssertNil(state.operation)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("2.txt").path))
  }
  func testSkipAndAbortAndEmptyResultsRemainExplicit() async throws {
    try await raw(["merge", "--ff-only", commits[0]])
    let target = try await head()
    let review = try await git.reviewCommitReplay(.cherryPick, commits: commits)
    XCTAssertTrue(review.alreadyReachable.contains(commits[0]))
    await reject { _ = try await self.git.executeCommitReplay(review) }
    let pending = try await git.sequencerState(); XCTAssertEqual(pending?.operation, .cherryPick)
    let skip = try await git.reviewSequencerControl(.skip)
    _ = try await git.controlSequencer(skip)
    let finished = try await git.sequencerState(); XCTAssertNil(finished)
    try await raw(["reset", "--hard", target])
    let retry = try await git.reviewCommitReplay(.cherryPick, commits: commits)
    await reject { _ = try await self.git.executeCommitReplay(retry) }
    let abort = try await git.reviewSequencerControl(.abort)
    _ = try await git.controlSequencer(abort)
    let after = try await head(); XCTAssertEqual(after, target)
  }
  func testRecoveryRejectsChangedWorkingContentAndWrongOperation() async throws {
    try await raw(["cherry-pick", commits[0]])
    _ = try await raw(["cherry-pick", commits[0], commits[1]], failure: true)
    let abort = try await git.reviewSequencerControl(.abort)
    try write("notes.txt", "external\n")
    await reject { _ = try await self.git.controlSequencer(abort) }
    await reject { _ = try await self.git.perform(["revert", "--abort"], expected: abort.state.review) }
    let skip = try await git.reviewSequencerControl(.skip)
    try write(".git/sequencer/todo", "pick \(commits[1]) changed\n")
    await reject { _ = try await self.git.controlSequencer(skip) }
  }
  func testHookAndSigningFailuresPreserveRecovery() async throws {
    try write(".git/hooks/prepare-commit-msg", "#!/bin/sh\necho replay-hook-rejected >&2\nexit 1\n")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent(".git/hooks/prepare-commit-msg").path)
    let review = try await git.reviewCommitReplay(.cherryPick, commits: commits)
    await reject { _ = try await self.git.executeCommitReplay(review) }
    let recovery = try await git.sequencerState(); XCTAssertNotNil(recovery)
    try FileManager.default.removeItem(at: root.appendingPathComponent(".git/hooks/prepare-commit-msg"))
    _ = try await git.controlSequencer(git.reviewSequencerControl(.abort))
    try await raw(["config", "commit.gpgsign", "true"]); try await raw(["config", "gpg.program", "/usr/bin/false"])
    let signed = try await git.reviewCommitReplay(.cherryPick, commits: commits)
    await reject { _ = try await self.git.executeCommitReplay(signed) }
    let signingRecovery = try await git.sequencerState(); XCTAssertNotNil(signingRecovery)
    let enabled = try await raw(["config", "--get", "commit.gpgsign"]).text
    XCTAssertEqual(enabled.trimmingCharacters(in: .newlines), "true")
  }
  func testReviewCannotCrossWorktreesOrChangedExecutable() async throws {
    let review = try await git.reviewCommitReplay(.cherryPick, commits: commits)
    let path = root.deletingLastPathComponent().appendingPathComponent("GitPier-replay-linked-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: path) }
    try await raw(["worktree", "add", "-b", "linked", path.path])
    let other = GitService(root: path)
    await reject { _ = try await other.executeCommitReplay(review) }
    await git.configureExecutable("/usr/bin/false")
    await reject { _ = try await self.git.executeCommitReplay(review) }
  }
  func testRootCommitCanBeAppliedWithoutGuessingAParent() async throws {
    try await raw(["switch", "--orphan", "root-source"])
    try write("root.txt", "root\n"); try await raw(["add", "."]); try await raw(["commit", "-m", "root change"])
    let rootCommit = try await head()
    try await raw(["switch", "main"])
    let review = try await git.reviewCommitReplay(.cherryPick, commits: [rootCommit])
    XCTAssertTrue(review.commits[0].parents.isEmpty)
    _ = try await git.executeCommitReplay(review)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("root.txt"), encoding: .utf8), "root\n")
  }
  func testSingleRevertConflictContinuesUsingRevertControls() async throws {
    try await raw(["merge", "--ff-only", commits[0]])
    try write("1.txt", "later\n"); try await raw(["add", "."]); try await raw(["commit", "-m", "later"])
    let review = try await git.reviewCommitReplay(.revert, commits: [commits[0]])
    await reject { _ = try await self.git.executeCommitReplay(review) }
    let stopped = try await git.sequencerState()
    XCTAssertEqual(stopped?.operation, .revert); XCTAssertEqual(stopped?.currentHash, commits[0])
    try await raw(["rm", "1.txt"])
    let control = try await git.reviewSequencerControl(.continue)
    _ = try await git.controlSequencer(control)
    let finished = try await git.status()
    XCTAssertNil(finished.operation); XCTAssertTrue(finished.files.isEmpty)
  }
  func testSingleRevertCanSkipOrAbortWithoutApplyingTheInverse() async throws {
    try await raw(["merge", "--ff-only", commits[0]])
    try write("1.txt", "later\n"); try await raw(["add", "."]); try await raw(["commit", "-m", "later"])
    let original = try await head()
    for action in [SequencerControl.skip, .abort] {
      let review = try await git.reviewCommitReplay(.revert, commits: [commits[0]])
      await reject { _ = try await self.git.executeCommitReplay(review) }
      let control = try await git.reviewSequencerControl(action)
      _ = try await git.controlSequencer(control)
      let state = try await git.status()
      XCTAssertEqual(state.head, original); XCTAssertNil(state.operation); XCTAssertTrue(state.files.isEmpty)
      XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("1.txt"), encoding: .utf8), "later\n")
    }
  }
  func testConcurrentConfirmationExecutesOnlyOnce() async throws {
    let review = try await git.reviewCommitReplay(.cherryPick, commits: commits)
    let service = git!
    let results = await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<2 { group.addTask { do { _ = try await service.executeCommitReplay(review); return true } catch { return false } } }
      var results: [Bool] = []; for await result in group { results.append(result) }; return results
    }
    XCTAssertEqual(results.filter { $0 }.count, 1)
    let history = try await git.history(); XCTAssertEqual(history.count, 3)
  }
  func testWorkingChangeDuringFinalStatusReadRefusesReplay() async throws {
    let wrapper = root.appendingPathComponent(".git/replay-git")
    let script = """
    #!/bin/sh
    if [ -f '\(root.path)/.git/armed' ]; then
      case " $* " in
        *" status "*)
          n=0
          if [ -f '\(root.path)/.git/status-count' ]; then n=$(cat '\(root.path)/.git/status-count'); fi
          n=$((n + 1))
          echo "$n" > '\(root.path)/.git/status-count'
          if [ "$n" = 5 ]; then echo concurrent > '\(root.path)/base.txt'; fi
          ;;
      esac
    fi
    exec /usr/bin/git "$@"
    """
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    await git.configureExecutable(wrapper.path)
    let review = try await git.reviewCommitReplay(.cherryPick, commits: commits)
    try write(".git/armed", "yes")
    await reject { _ = try await self.git.executeCommitReplay(review) }
    let after = try await head(); XCTAssertEqual(after, base)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("base.txt"), encoding: .utf8), "concurrent\n")
  }
  func testObjectViewReadsCannotReopenTheFinalCleanGate() async throws {
    let wrapper = root.appendingPathComponent(".git/object-view-git")
    try """
    #!/bin/sh
    if [ -f '\(root.path)/.git/object-view-armed' ]; then
      case " $* " in
        *" rev-parse --git-path shallow "*)
          n=0
          if [ -f '\(root.path)/.git/object-view-count' ]; then n=$(cat '\(root.path)/.git/object-view-count'); fi
          n=$((n + 1)); echo "$n" > '\(root.path)/.git/object-view-count'
          if [ "$n" = 2 ]; then echo concurrent > '\(root.path)/base.txt'; fi
          ;;
      esac
    fi
    exec /usr/bin/git "$@"
    """.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    await git.configureExecutable(wrapper.path)
    let review = try await git.reviewCommitReplay(.cherryPick, commits: commits)
    try write(".git/object-view-armed", "yes")
    await reject { _ = try await self.git.executeCommitReplay(review) }
    let after = try await head(); XCTAssertEqual(after, base)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("base.txt"), encoding: .utf8), "concurrent\n")
  }
  func testOversizedAndLinkedOperationMetadataIsRefused() async throws {
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/sequencer"), withIntermediateDirectories: false)
    try Data(repeating: 65, count: 2 * 1024 * 1024 + 1).write(to: root.appendingPathComponent(".git/sequencer/todo"))
    await reject { _ = try await self.git.reviewOperation() }
    try FileManager.default.removeItem(at: root.appendingPathComponent(".git/sequencer"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".git/CHERRY_PICK_HEAD"), withDestinationURL: root.appendingPathComponent("base.txt"))
    await reject { _ = try await self.git.reviewOperation() }
  }
  func testRepositoryReplacementAtSamePathInvalidatesReview() async throws {
    let review = try await git.reviewCommitReplay(.cherryPick, commits: commits)
    let backup = root.deletingLastPathComponent().appendingPathComponent("GitPier-replay-backup-" + UUID().uuidString)
    try FileManager.default.moveItem(at: root, to: backup)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.moveItem(at: backup, to: root)
    }
    let result = try await ProcessRunner().run(executable: "/usr/bin/git", arguments: ["clone", "--no-hardlinks", backup.path, root.path], directory: backup,
      environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
    XCTAssertEqual(result.code, 0)
    await reject { _ = try await self.git.executeCommitReplay(review) }
    let after = try await head(); XCTAssertEqual(after, base)
  }
  func metadataCommit(_ message: String, parents: [String]) async throws -> String {
    let tree = try await raw(["rev-parse", base + "^{tree}"]).text.trimmingCharacters(in: .newlines)
    let arguments = ["commit-tree", tree] + parents.flatMap { ["-p", $0] }
    return try await git.read(arguments, input: Data(message.utf8)).text.trimmingCharacters(in: .newlines)
  }
  func testOversizedCommitMetadataCannotExhaustReviewMemory() async throws {
    let hash = try await metadataCommit("large\n\n" + String(repeating: "a", count: 1024 * 1024), parents: [base])
    await reject { _ = try await self.git.reviewCommitReplay(.cherryPick, commits: [hash]) }
    let after = try await head(); XCTAssertEqual(after, base)
  }
  func testAggregateCommitMetadataHasAReviewBudget() async throws {
    var hashes: [String] = []
    for index in 0..<10 {
      hashes.append(try await metadataCommit("large \(index)\n\n" + String(repeating: "a", count: 900 * 1024), parents: [base]))
    }
    await reject { _ = try await self.git.reviewCommitReplay(.cherryPick, commits: hashes) }
    let after = try await head(); XCTAssertEqual(after, base)
  }
  func testExtremeMergeParentCountRequiresTerminalReview() async throws {
    var parents: [String] = []
    for index in 0..<65 { parents.append(try await metadataCommit("parent \(index)\n", parents: [base])) }
    let hash = try await metadataCommit("extreme merge\n", parents: parents)
    await reject { _ = try await self.git.reviewCommitReplay(.revert, commits: [hash]) }
    let after = try await head(); XCTAssertEqual(after, base)
  }
  func testLinkedGitPointerChangeDuringFinalStatusReadIsRefused() async throws {
    let linked = root.deletingLastPathComponent().appendingPathComponent("GitPier-replay-binding-" + UUID().uuidString)
    let other = root.deletingLastPathComponent().appendingPathComponent("GitPier-replay-other-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: linked); try? FileManager.default.removeItem(at: other) }
    try await raw(["worktree", "add", "-b", "bound", linked.path, base])
    try await raw(["clone", "--no-hardlinks", "--branch", "bound", root.path, other.path])
    let destination = GitService(root: other)
    await destination.configure(gitPath: "/usr/bin/git", authEnvironment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
    try await destination.perform(["config", "user.name", "Binding"])
    try await destination.perform(["config", "user.email", "binding@example.invalid"])
    try await destination.perform(["config", "commit.gpgsign", "false"])
    let wrapper = root.appendingPathComponent(".git/pointer-git")
    try """
    #!/bin/sh
    if [ -f '\(root.path)/.git/pointer-armed' ]; then
      case " $* " in
        *" status "*)
          n=0
          if [ -f '\(root.path)/.git/pointer-count' ]; then n=$(cat '\(root.path)/.git/pointer-count'); fi
          n=$((n + 1)); echo "$n" > '\(root.path)/.git/pointer-count'
          if [ "$n" = 5 ]; then printf 'gitdir: %s\\n' '\(other.path)/.git' > '\(linked.path)/.git'; fi
          ;;
      esac
    fi
    exec /usr/bin/git "$@"
    """.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    let service = GitService(root: linked)
    await service.configure(gitPath: wrapper.path, authEnvironment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
    let review = try await service.reviewCommitReplay(.cherryPick, commits: commits)
    try write(".git/pointer-armed", "yes")
    await reject { _ = try await service.executeCommitReplay(review) }
    let after = try await destination.status().head; XCTAssertEqual(after, base)
  }
}
