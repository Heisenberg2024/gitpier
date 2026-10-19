import XCTest
@testable import GitPierCore

final class ContextWorkflowTests: XCTestCase {
  func testRefreshKeepsKnownRiskVisibleWithoutOfferingWrites() {
    var input = clean(); input.refreshing = true
    input.status.files = [FileChange(path: "conflict", index: "U", worktree: "U", kind: .conflicted)]
    for activity in [ContextWorkflowAdvice.Kind.busy, .refreshing, .checkingRemote] {
      let advice = ContextWorkflowAdvice(activity)
      XCTAssertEqual(advice.displayLevel(in: input), .blocked)
      XCTAssertTrue(advice.actions.isEmpty)
    }
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(input).displayLevel(in: input), .blocked)
    XCTAssertTrue(ContextWorkflowAdvice.evaluate(input).actions.isEmpty)
    input.status.files = []; input.status.behind = 240
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(input).displayLevel(in: input), .attention)
    input.status.files = [FileChange(path: "dirty", index: ".", worktree: "M", kind: .modified)]
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(input).displayLevel(in: input), .warning)
    input.status.behind = 0
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(input).displayLevel(in: input), .normal)
  }
  func testFiveDisplayLevelsUseGitFactsWithoutChangingPermittedActions() {
    var value = clean()
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(value).displayLevel(in: value), .normal)
    value.status.ahead = 2
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(value).displayLevel(in: value), .suggestion)
    value.status.behind = 240
    let diverged = ContextWorkflowAdvice.evaluate(value)
    XCTAssertEqual(diverged.displayLevel(in: value), .attention)
    XCTAssertEqual(diverged.actions, [.compareIncoming, .mergeUpstream, .rebaseUpstream])
    value.status.ahead = 0
    let incoming = ContextWorkflowAdvice.evaluate(value)
    XCTAssertEqual(incoming.kind, .incoming)
    XCTAssertEqual(incoming.displayLevel(in: value), .attention)
    XCTAssertEqual(incoming.actions, [.compareIncoming, .reviewPull])
    value.status.files = [FileChange(path: "local", index: ".", worktree: "M", kind: .modified)]
    value.currentPage = "commit"
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(value).displayLevel(in: value), .warning)
    value.status.behind = 0
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(value).displayLevel(in: value), .normal)
    value.status.files = [FileChange(path: "conflict", index: "U", worktree: "U", kind: .conflicted)]
    for operation in [GitOperation.merge, .rebase, .cherryPick, .revert] {
      value.status.operation = operation
      let conflict = ContextWorkflowAdvice.evaluate(value)
      XCTAssertEqual(conflict.kind, .conflicts)
      XCTAssertEqual(conflict.displayLevel(in: value), .blocked)
      XCTAssertFalse(conflict.actions.contains(.reviewPull))
      XCTAssertFalse(conflict.actions.contains(.reviewPush))
      XCTAssertFalse(conflict.actions.contains(.mergeUpstream))
      value.status.files = []
      XCTAssertEqual(ContextWorkflowAdvice.evaluate(value).displayLevel(in: value), .blocked)
      value.status.files = [FileChange(path: "conflict", index: "U", worktree: "U", kind: .conflicted)]
    }
  }
  func testEveryKindHasAnExplicitDisplayMapping() {
    let value = clean()
    let mappings: [(ContextWorkflowAdvice.DisplayLevel, [ContextWorkflowAdvice.Kind])] = [
      (.normal, [.aligned, .localOnly, .addFiles, .busy, .refreshing, .checkingRemote]),
      (.suggestion, [.firstCommit, .stagedChanges, .localChanges, .noUpstream, .verifyRemote, .outgoing]),
      (.attention, [.incoming, .diverged, .unavailable, .stale, .authentication, .fetchFailed, .missingUpstream]),
      (.warning, [.detached, .preserveBeforeSync]), (.blocked, [.conflicts, .unfinishedOperation])
    ]
    for (level, kinds) in mappings {
      for kind in kinds { XCTAssertEqual(ContextWorkflowAdvice(kind).displayLevel(in: value), level, kind.rawValue) }
    }
    var outdated = value; outdated.status.behind = 240; outdated.remoteFresh = false
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(outdated).displayLevel(in: outdated), .attention)
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(outdated).actions, [.reviewFetch])
    outdated.status.ahead = 4; outdated.status.behind = 0
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(outdated).displayLevel(in: outdated), .attention)
  }
  private func clean() -> ContextWorkflowInput {
    var value = ContextWorkflowInput()
    value.status.head = String(repeating: "a", count: 40); value.status.branch = "feature/topic"
    value.status.upstream = "origin/feature/topic"; value.status.upstreamComparable = true
    value.remoteCount = 1; value.remotePhase = .upToDate; value.remoteFresh = true
    return value
  }
  func testCleanAlignedDoesNotOfferIrrelevantActions() {
    let advice = ContextWorkflowAdvice.evaluate(clean())
    XCTAssertEqual(advice.kind, .aligned); XCTAssertTrue(advice.actions.isEmpty)
  }
  func testDirtyAndPartialIndexAreReviewedBeforeSynchronization() {
    var value = clean(); value.status.ahead = 2; value.status.behind = 3
    value.status.files = [FileChange(path: "partial.txt", index: "M", worktree: "M", kind: .modified)]
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(value), ContextWorkflowAdvice(.preserveBeforeSync, [.reviewChanges]))
    value.status.behind = 0
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(value), ContextWorkflowAdvice(.stagedChanges, [.reviewChanges]))
    value.status.files = [FileChange(path: "new.txt", index: "?", worktree: "?", kind: .untracked)]
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(value), ContextWorkflowAdvice(.localChanges, [.reviewChanges]))
  }
  func testConflictsAndUnfinishedOperationsBlockUnrelatedSuggestions() {
    for operation in [GitOperation.merge, .rebase, .cherryPick, .revert] {
      var value = clean(); value.status.operation = operation; value.status.ahead = 4; value.status.behind = 5
      XCTAssertEqual(ContextWorkflowAdvice.evaluate(value), ContextWorkflowAdvice(.unfinishedOperation, [.continueOperation]))
      value.status.files = [FileChange(path: "conflict.txt", index: "U", worktree: "U", kind: .conflicted)]
      let actions: [ContextWorkflowAction] = operation == .rebase ? [.resolveConflicts, .continueOperation] : [.resolveConflicts]
      XCTAssertEqual(ContextWorkflowAdvice.evaluate(value), ContextWorkflowAdvice(.conflicts, actions))
    }
  }
  func testUnavailableBusyAndStaleStatesNeverSuggestWrites() {
    var value = clean(); value.status.ahead = 1
    value.available = false
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(value), ContextWorkflowAdvice(.unavailable, [.refresh]))
    value.refreshing = true
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(value), ContextWorkflowAdvice(.refreshing))
    value.busy = true
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(value), ContextWorkflowAdvice(.busy))
    value.busy = false; value.refreshing = false; value.available = true; value.stale = true
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(value), ContextWorkflowAdvice(.stale, [.refresh]))
  }
  func testDetachedAndUnbornHaveDifferentNextSteps() {
    var value = clean(); value.status.branch = "(detached)"
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(value), ContextWorkflowAdvice(.detached, [.createBranch]))
    value.retainingBranches = ["saved"]
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(value), ContextWorkflowAdvice(.detached, [.chooseBranch]))
    value.status.branch = "main"; value.status.head = nil
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(value), ContextWorkflowAdvice(.addFiles))
    value.status.files = [FileChange(path: "README", index: "?", worktree: "?", kind: .untracked)]
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(value), ContextWorkflowAdvice(.firstCommit, [.reviewChanges]))
  }
  func testNoRemoteAndNoUpstreamAreNotTreatedAsSafePushTargets() {
    var value = clean(); value.remoteCount = 0; value.status.upstream = nil
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(value), ContextWorkflowAdvice(.localOnly, [.addRemote]))
    value.remoteCount = 2
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(value), ContextWorkflowAdvice(.noUpstream, [.setUpstream, .reviewFetch]))
  }
  func testUnknownStaleFailedAndAuthenticatingRemoteNeverOfferPullPush() {
    for phase in [RemoteCheckPhase.notChecked, .failed, .authenticationRequired, .checking, .queued, .skipped] {
      var value = clean(); value.remotePhase = phase; value.remoteFresh = false; value.status.ahead = 3; value.status.behind = 2
      let advice = ContextWorkflowAdvice.evaluate(value)
      XCTAssertFalse(advice.actions.contains(.reviewPush)); XCTAssertFalse(advice.actions.contains(.reviewPull))
      XCTAssertFalse(advice.actions.contains(.mergeUpstream)); XCTAssertFalse(advice.actions.contains(.rebaseUpstream))
    }
    var value = clean(); value.remoteFresh = false
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(value), ContextWorkflowAdvice(.verifyRemote, [.reviewFetch]))
  }
  func testMissingUpstreamDoesNotBecomeAligned() {
    var value = clean(); value.status.upstreamComparable = false
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(value), ContextWorkflowAdvice(.missingUpstream, [.setUpstream, .reviewFetch]))
  }
  func testIncomingOutgoingAndDivergenceHaveDifferentReviewedActions() {
    var value = clean(); value.status.behind = 2
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(value), ContextWorkflowAdvice(.incoming, [.compareIncoming, .reviewPull]))
    value.status.behind = 0; value.status.ahead = 4
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(value), ContextWorkflowAdvice(.outgoing, [.compareOutgoing, .reviewPush]))
    value.status.behind = 3
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(value), ContextWorkflowAdvice(.diverged, [.compareIncoming, .mergeUpstream, .rebaseUpstream]))
  }
  func testWorktreeIdentityParticipatesInDisplayedContextEquality() {
    var first = clean(); first.repositoryID = UUID(); first.workingTree = "/repo/first"; first.linkedWorktree = true; first.filesystemIdentity = "1:100"
    var second = first; second.workingTree = "/repo/second"; second.repositoryID = UUID()
    XCTAssertNotEqual(first, second)
    second = first; second.filesystemIdentity = "1:101"; XCTAssertNotEqual(first, second)
  }
  func testRoutineReviewIsQuietOnCommitPageButNotDeclaredComplete() {
    for file in [FileChange(path: "a", index: ".", worktree: "M", kind: .modified),
                 FileChange(path: "a", index: "M", worktree: "M", kind: .modified),
                 FileChange(path: "a", index: "?", worktree: "?", kind: .untracked)] {
      var input = clean(); input.status.files = [file]
      let status = input.status, advice = ContextWorkflowAdvice.evaluate(input)
      XCTAssertEqual(advice.priority(in: input), .suggestion)
      XCTAssertEqual(advice.visibleActions(in: input), [.reviewChanges])
      input.currentPage = "commit"
      XCTAssertEqual(advice.priority(in: input), .normal)
      XCTAssertTrue(advice.visibleActions(in: input).isEmpty)
      XCTAssertTrue(advice.isReviewingChanges(input)); XCTAssertNotEqual(advice.kind, .aligned)
      XCTAssertEqual(input.status, status)
      input.currentPage = "history"
      XCTAssertEqual(advice.priority(in: input), .suggestion)
    }
  }
  func testImportantRiskRemainsVisibleOnTheRelevantPage() {
    var input = clean(); input.currentPage = "commit"; input.status.behind = 2
    input.status.files = [FileChange(path: "a", index: "M", worktree: "M", kind: .modified)]
    var advice = ContextWorkflowAdvice.evaluate(input)
    XCTAssertEqual(advice.priority(in: input), .risk); XCTAssertEqual(advice.visibleActions(in: input), [.reviewChanges])
    input.currentPage = "conflicts"; input.status.files = [FileChange(path: "a", index: "U", worktree: "U", kind: .conflicted)]
    advice = ContextWorkflowAdvice.evaluate(input)
    XCTAssertEqual(advice.priority(in: input), .risk); XCTAssertEqual(advice.visibleActions(in: input), [.resolveConflicts])
  }
  func testAllAdviceKindsHaveAnExplicitAttentionLevel() {
    let quiet: [ContextWorkflowAdvice.Kind] = [.aligned, .localOnly, .addFiles, .busy, .refreshing, .checkingRemote]
    let ordinary: [ContextWorkflowAdvice.Kind] = [.firstCommit, .stagedChanges, .localChanges, .noUpstream, .incoming, .outgoing, .verifyRemote]
    let risks: [ContextWorkflowAdvice.Kind] = [.conflicts, .unfinishedOperation, .detached, .preserveBeforeSync, .diverged, .unavailable, .stale, .authentication, .fetchFailed, .missingUpstream]
    let input = clean()
    for kind in quiet { XCTAssertEqual(ContextWorkflowAdvice(kind).priority(in: input), .normal, kind.rawValue) }
    for kind in ordinary { XCTAssertEqual(ContextWorkflowAdvice(kind).priority(in: input), .suggestion, kind.rawValue) }
    for kind in risks { XCTAssertEqual(ContextWorkflowAdvice(kind).priority(in: input), .risk, kind.rawValue) }
    var uncertain = input; uncertain.status.ahead = 1
    XCTAssertEqual(ContextWorkflowAdvice(.verifyRemote).priority(in: uncertain), .risk)
  }
  func testQuietLocalOnlyStateDoesNotInventSharingWork() {
    var input = clean(); input.remoteCount = 0; input.status.upstream = nil
    let advice = ContextWorkflowAdvice.evaluate(input)
    XCTAssertEqual(advice.priority(in: input), .normal)
    XCTAssertTrue(advice.visibleActions(in: input).isEmpty)
    XCTAssertEqual(advice.kind, .localOnly)
  }
  func testUnknownOrFailedRemoteDoesNotBecomeAnEmptySynchronizedState() {
    var input = clean(); input.currentPage = "commit"
    for phase in [RemoteCheckPhase.notChecked, .skipped, .failed, .authenticationRequired] {
      input.remotePhase = phase; input.remoteFresh = false
      let advice = ContextWorkflowAdvice.evaluate(input)
      XCTAssertNotEqual(advice.kind, .aligned); XCTAssertNotEqual(advice.priority(in: input), .normal)
      XCTAssertFalse(advice.visibleActions(in: input).isEmpty)
    }
  }

}

extension GitServiceTests {
  private func workflowRemote() async throws -> URL {
    try await seed()
    let bare = directory.appendingPathComponent(".git/workflow-remote.git")
    _ = try await raw(["init", "--bare", bare.path])
    _ = try await raw(["remote", "add", "origin", bare.path])
    _ = try await raw(["push", "-u", "origin", "HEAD"])
    return bare
  }
  func testContextWorkflowReviewIsLocalAndPreservesPartialIndex() async throws {
    _ = try await workflowRemote()
    try write("first.txt", "staged part\n"); try await git.stage(try await git.status().files)
    try write("first.txt", "staged part\nunstaged part\n")
    let index = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    let head = try await git.status().head
    let first = try await git.reviewContextWorkflow(), second = try await git.reviewContextWorkflow()
    XCTAssertEqual(first, second); XCTAssertEqual(first.status.staged.count, 1)
    XCTAssertTrue(first.status.files.first?.isPartial == true)
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), index)
    let after = try await git.status(); XCTAssertEqual(after.head, head)
    XCTAssertEqual(first.upstreamHash, head); XCTAssertTrue(first.singleBranchPush)
  }
  func testContextWorkflowRejectsChangedBranchBeforeQueuedCommand() async throws {
    _ = try await workflowRemote(); let review = try await git.reviewContextWorkflow()
    _ = try await raw(["switch", "-c", "other"])
    do { _ = try await git.perform(["branch", "must-not-exist"], context: review); XCTFail("Stale context was executed") } catch {}
    let branches = try await git.branches(); XCTAssertFalse(branches.contains { $0.name == "must-not-exist" })
  }
  func testContextWorkflowRejectsChangedIndexAndDirtyWorktree() async throws {
    _ = try await workflowRemote(); let review = try await git.reviewContextWorkflow()
    try write("first.txt", "external edit\n")
    do { _ = try await git.network("push", context: review); XCTFail("Dirty worktree reused the old review") } catch {}
    try await git.stage(try await git.status().files)
    do { try await git.createBranch("must-not-exist", context: review); XCTFail("Changed Index reused the old review") } catch {}
    let branches = try await git.branches(); XCTAssertFalse(branches.contains { $0.name == "must-not-exist" })
  }
  func testContextWorkflowRejectsRemoteConfigurationChangesBeforePush() async throws {
    _ = try await workflowRemote(); let review = try await git.reviewContextWorkflow()
    _ = try await raw(["config", "push.followTags", "true"])
    do { _ = try await git.network("push", context: review); XCTFail("Changed push rules were executed") } catch {}
    let fresh = try await git.reviewContextWorkflow(); XCTAssertFalse(fresh.singleBranchPush)
  }
  func testContextWorkflowRejectsTrackingTipChangesBeforePull() async throws {
    _ = try await workflowRemote(); let review = try await git.reviewContextWorkflow()
    try write("first.txt", "next commit\n"); try await git.stage(try await git.status().files)
    let next = try await git.commit(message: "next", expected: git.snapshot())
    _ = try await raw(["reset", "--hard", review.status.head!])
    _ = try await raw(["update-ref", review.upstreamReference!, next.hash])
    do { _ = try await git.network("pull", context: review); XCTFail("A changed tracking tip reused the old review") } catch {}
    let status = try await git.status(); XCTAssertEqual(status.head, review.status.head)
  }
  func testContextWorkflowRefusesBroadPushRules() async throws {
    _ = try await workflowRemote()
    for (key, value) in [("push.default", "matching"), ("push.followTags", "true"), ("push.recurseSubmodules", "on-demand"), ("remote.origin.mirror", "true"), ("remote.origin.push", "refs/heads/*:refs/heads/*")] {
      _ = try await raw(["config", key, value])
      let context = try await git.reviewContextWorkflow()
      XCTAssertFalse(context.singleBranchPush, key)
      do { _ = try await git.network("push", context: context); XCTFail("Broad push rule was executed: " + key) } catch {}
      _ = try await raw(["config", "--unset-all", key])
    }
  }
  func testContextWorkflowNormalPushUsesOriginalNetworkPath() async throws {
    let bare = try await workflowRemote()
    try write("first.txt", "reviewed push\n"); try await git.stage(try await git.status().files)
    let commit = try await git.commit(message: "reviewed", expected: git.snapshot())
    let context = try await git.reviewContextWorkflow()
    _ = try await git.network("push", context: context)
    let remote = try await raw(["--git-dir=" + bare.path, "rev-parse", "refs/heads/" + context.status.branch]).text.trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertEqual(remote, commit.hash)
  }
  func testContextWorkflowRejectsImplicitBooleanPushRules() async throws {
    _ = try await workflowRemote()
    let config = directory.appendingPathComponent(".git/config"), original = try Data(contentsOf: config)
    for body in ["\n[push]\n followTags\n", "\n[remote \"origin\"]\n mirror\n" ] {
      try (original + Data(body.utf8)).write(to: config)
      let context = try await git.reviewContextWorkflow()
      XCTAssertFalse(context.singleBranchPush)
    }
    try original.write(to: config)
  }
  func testContextWorkflowRejectsMultiplePullBranchesAndChangedRemoteURL() async throws {
    _ = try await workflowRemote()
    let review = try await git.reviewContextWorkflow()
    XCTAssertTrue(review.singleBranchPull)
    _ = try await raw(["config", "--add", "branch.main.merge", "refs/heads/other"])
    let multiple = try await git.reviewContextWorkflow()
    XCTAssertFalse(multiple.singleBranchPull)
    do { _ = try await git.network("pull", context: multiple); XCTFail("Multiple branches pulled") } catch {}
    _ = try await raw(["remote", "set-url", "origin", "/nonexistent-fixture-remote"])
    do { try await git.createBranch("stale-remote", context: review); XCTFail("Changed remote reused review") } catch {}
    let branches = try await git.branches(); XCTAssertFalse(branches.contains { $0.name == "stale-remote" })
  }
  func testContextWorkflowNormalPullUsesOriginalNetworkPath() async throws {
    _ = try await workflowRemote()
    let previous = try await git.status().head!
    try write("first.txt", "incoming fixture\n"); _ = try await raw(["add", "first.txt"])
    _ = try await raw(["commit", "-m", "incoming"]); _ = try await raw(["push"])
    let incoming = try await git.status().head!
    _ = try await raw(["reset", "--hard", previous])
    let review = try await git.reviewContextWorkflow()
    XCTAssertEqual(review.status.behind, 1)
    _ = try await git.network("pull", context: review)
    let after = try await git.status(); XCTAssertEqual(after.head, incoming)
  }
  func testContextWorkflowReviewCannotCrossLinkedWorktrees() async throws {
    try await seed()
    let review = try await git.reviewContextWorkflow()
    let linked = directory.appendingPathComponent("linked")
    _ = try await raw(["worktree", "add", "-b", "linked-branch", linked.path])
    let other = GitService(root: linked), otherReview = try await other.reviewContextWorkflow()
    XCTAssertEqual(review.commonDirectory, otherReview.commonDirectory)
    XCTAssertNotEqual(review.gitDirectory, otherReview.gitDirectory)
    XCTAssertNotEqual(review.workingTree, otherReview.workingTree)
    do { try await other.createBranch("wrong-target", context: review); XCTFail("Cross-worktree review used") } catch {}
    let branches = try await other.branches(); XCTAssertFalse(branches.contains { $0.name == "wrong-target" })
  }
  func testContextWorkflowRefusesReplacedWorkingTreeAtSamePath() async throws {
    try await seed(); let review = try await git.reviewContextWorkflow()
    let old = directory.appendingPathExtension("old")
    try FileManager.default.moveItem(at: directory, to: old)
    defer { try? FileManager.default.removeItem(at: old) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    _ = try await raw(["clone", old.path, "."])
    do { try await git.createBranch("replaced-root", context: review); XCTFail("Replaced root accepted") } catch {}
    let branches = try await git.branches(); XCTAssertFalse(branches.contains { $0.name == "replaced-root" })
  }

}
