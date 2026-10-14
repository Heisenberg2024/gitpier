import XCTest
@testable import GitPierCore

extension GitServiceTests {
  private func requireRebaseState(_ service: GitService) async throws -> RebaseState {
    let state = try await service.rebaseState()
    return try XCTUnwrap(state)
  }
  private func rebaseHeadEquals(_ expected: String?, file: StaticString = #filePath, line: UInt = #line) async throws {
    let head = try await git.resolveCommit("HEAD")
    XCTAssertEqual(head, expected, file: file, line: line)
  }
  private func assertNoRebase(_ service: GitService, file: StaticString = #filePath, line: UInt = #line) async throws {
    let state = try await service.rebaseState()
    XCTAssertNil(state, file: file, line: line)
  }
  private func rebaseFixture() async throws -> InteractiveRebaseCandidate {
    try await seed()
    let base = try await git.resolveCommit("HEAD")
    for name in ["a", "b", "c"] {
      try write(name + ".txt", name + "\n")
      try await raw(["add", "--", name + ".txt"])
      try await raw(["commit", "-m", name.uppercased()])
    }
    return try await git.interactiveRebaseCandidate(upstream: base)
  }
  private func conflictingRebase() async throws -> InteractiveRebasePlan {
    try await seed()
    let base = try await git.resolveCommit("HEAD")
    for text in ["A", "B"] {
      try write("first.txt", text + "\ntwo\nthree\n")
      try await raw(["add", "--", "first.txt"])
      try await raw(["commit", "-m", text])
    }
    let candidate = try await git.interactiveRebaseCandidate(upstream: base)
    return InteractiveRebasePlan(candidate: candidate, steps: [
      RebaseStep(commit: candidate.commits[1]), RebaseStep(commit: candidate.commits[0], action: .drop)])
  }
  private func rebaseRejected(_ action: () async throws -> Void) async {
    do { try await action(); XCTFail("Expected rebase rejection") } catch {}
  }
  func testInteractiveRebasePickAndNativeReflog() async throws {
    let candidate = try await rebaseFixture()
    let tree = try await raw(["rev-parse", "HEAD^{tree}"]).text
    _ = try await git.startInteractiveRebase(InteractiveRebasePlan(candidate: candidate))
    let finalTree = try await raw(["rev-parse", "HEAD^{tree}"]).text
    XCTAssertEqual(finalTree, tree)
    let reflog = try await raw(["reflog", "--format=%gs"]).text
    XCTAssertTrue(reflog.contains("rebase (finish)"))
    try await assertNoRebase(git)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/gitpier-rebase-messages.json").path))
  }
  func testInteractiveRebaseRewordSquashFixupUsesLiteralMessages() async throws {
    let candidate = try await rebaseFixture()
    var plan = InteractiveRebasePlan(candidate: candidate)
    plan.steps[0].action = .reword; plan.steps[0].message = "new A"
    plan.steps[1].action = .squash
    plan.steps[1].message = "combined\n\n$(touch injected) 'quoted' ; literal"
    plan.steps[2].action = .fixup
    _ = try await git.startInteractiveRebase(plan)
    let history = try await git.history()
    XCTAssertEqual(history.count, 2)
    XCTAssertEqual(history[0].subject, "combined")
    XCTAssertTrue(history[0].body.contains("$(touch injected)"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("injected").path))
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("c.txt"), encoding: .utf8), "c\n")
  }
  func testInteractiveRebaseFixupPreservesLeaderMessage() async throws {
    let candidate = try await rebaseFixture()
    var plan = InteractiveRebasePlan(candidate: candidate)
    plan.steps[0].action = .reword; plan.steps[0].message = "leader"
    plan.steps[1].action = .fixup; plan.steps[2].action = .fixup
    _ = try await git.startInteractiveRebase(plan)
    let history = try await git.history()
    XCTAssertEqual(history[0].subject, "leader"); XCTAssertEqual(history.count, 2)
  }
  func testInteractiveRebaseDropAndReorder() async throws {
    let candidate = try await rebaseFixture()
    let plan = InteractiveRebasePlan(candidate: candidate, steps: [
      RebaseStep(commit: candidate.commits[2]), RebaseStep(commit: candidate.commits[1], action: .drop),
      RebaseStep(commit: candidate.commits[0])])
    _ = try await git.startInteractiveRebase(plan)
    let history = try await git.history()
    XCTAssertEqual(history.map(\.subject), ["A", "C", "seed"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("b.txt").path))
  }
  func testInteractiveRebaseRejectsDuplicateAndLeadingFixupBeforeWriting() async throws {
    let candidate = try await rebaseFixture()
    var plan = InteractiveRebasePlan(candidate: candidate)
    plan.steps[0].action = .fixup
    await rebaseRejected { _ = try await self.git.startInteractiveRebase(plan) }
    plan.steps[0] = plan.steps[1]
    await rebaseRejected { _ = try await self.git.startInteractiveRebase(plan) }
    let head = try await git.resolveCommit("HEAD")
    XCTAssertEqual(head, candidate.review.head)
  }
  func testInteractiveRebaseRejectsExternalHeadAndIndexAndDirtyTree() async throws {
    let candidate = try await rebaseFixture()
    try write("external.txt", "preserve\n")
    try await raw(["add", "--", "external.txt"])
    let index = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    await rebaseRejected { _ = try await self.git.startInteractiveRebase(InteractiveRebasePlan(candidate: candidate)) }
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), index)
    try await raw(["commit", "-m", "external"])
    let head = try await git.resolveCommit("HEAD")
    await rebaseRejected { _ = try await self.git.startInteractiveRebase(InteractiveRebasePlan(candidate: candidate)) }
    try await rebaseHeadEquals(head)
    try write("a.txt", "dirty\n")
    await rebaseRejected { _ = try await self.git.interactiveRebaseCandidate(upstream: candidate.upstream) }
  }
  func testInteractiveRebaseSharedWarningAndCancelIsReadOnly() async throws {
    let candidate = try await rebaseFixture()
    try await raw(["update-ref", "refs/remotes/origin/main", "HEAD"])
    let index = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    let shared = try await git.interactiveRebaseCandidate(upstream: candidate.upstream)
    XCTAssertEqual(shared.sharedCommits, Set(shared.commits.map(\.hash)))
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), index)
    try await rebaseHeadEquals(candidate.review.head)
    await rebaseRejected { _ = try await self.git.startInteractiveRebase(InteractiveRebasePlan(candidate: candidate)) }
  }
  func testInteractiveRebaseRejectsMergeHistory() async throws {
    let candidate = try await rebaseFixture()
    try await raw(["branch", "side", candidate.upstream])
    try await raw(["switch", "side"]); try write("side.txt", "side")
    try await raw(["add", "--", "side.txt"]); try await raw(["commit", "-m", "side"])
    try await raw(["switch", "main"]); try await raw(["merge", "--no-ff", "side", "-m", "merge"])
    await rebaseRejected { _ = try await self.git.interactiveRebaseCandidate(upstream: candidate.upstream) }
  }
  func testInteractiveRebasePreRebaseAndMessageHooksRemainEnabled() async throws {
    let candidate = try await rebaseFixture()
    let hook = directory.appendingPathComponent(".git/hooks/pre-rebase")
    try "#!/bin/sh\necho expected-pre-rebase >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    await rebaseRejected { _ = try await self.git.startInteractiveRebase(InteractiveRebasePlan(candidate: candidate)) }
    try await rebaseHeadEquals(candidate.review.head)
    try FileManager.default.removeItem(at: hook)
    let next = try await git.interactiveRebaseCandidate(upstream: candidate.upstream)
    let messageHook = directory.appendingPathComponent(".git/hooks/commit-msg")
    try "#!/bin/sh\necho expected-commit-msg >&2\nexit 1\n".write(to: messageHook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: messageHook.path)
    var plan = InteractiveRebasePlan(candidate: next); plan.steps[0].action = .reword
    await rebaseRejected { _ = try await self.git.startInteractiveRebase(plan) }
    let state = try await requireRebaseState(git)
    try FileManager.default.removeItem(at: messageHook)
    _ = try await git.controlRebase(.abort, expected: state)
    try await rebaseHeadEquals(candidate.review.head)
  }
  func testInteractiveRebaseSigningFailureRemainsRecoverable() async throws {
    let candidate = try await rebaseFixture()
    try await raw(["config", "commit.gpgsign", "true"])
    try await raw(["config", "gpg.program", "/usr/bin/false"])
    var plan = InteractiveRebasePlan(candidate: candidate); plan.steps[0].action = .reword
    await rebaseRejected { _ = try await self.git.startInteractiveRebase(plan) }
    let state = try await requireRebaseState(git)
    _ = try await git.controlRebase(.abort, expected: state)
    try await rebaseHeadEquals(candidate.review.head)
  }
  func testInteractiveRebaseConflictRestartContinue() async throws {
    let plan = try await conflictingRebase()
    await rebaseRejected { _ = try await self.git.startInteractiveRebase(plan) }
    let restarted = GitService(root: directory)
    let paused = try await requireRebaseState(restarted)
    XCTAssertEqual(paused.originalHead, plan.candidate.review.head)
    XCTAssertFalse(paused.todo.isEmpty)
    try write("first.txt", "B\ntwo\nthree\n")
    try await raw(["add", "--", "first.txt"])
    let ready = try await requireRebaseState(restarted)
    _ = try await restarted.controlRebase(.continue, expected: ready, message: "resolved B")
    try await assertNoRebase(restarted)
    let resumedHistory = try await restarted.history()
    XCTAssertEqual(resumedHistory[0].subject, "resolved B")
  }
  func testInteractiveRebaseConflictSkip() async throws {
    let plan = try await conflictingRebase()
    await rebaseRejected { _ = try await self.git.startInteractiveRebase(plan) }
    let state = try await requireRebaseState(git)
    _ = try await git.controlRebase(.skip, expected: state)
    try await rebaseHeadEquals(plan.candidate.upstream)
    try await assertNoRebase(git)
  }
  func testInteractiveRebaseConflictAbortAndExternalStateRejection() async throws {
    let plan = try await conflictingRebase()
    await rebaseRejected { _ = try await self.git.startInteractiveRebase(plan) }
    let state = try await requireRebaseState(git)
    let todo = directory.appendingPathComponent(".git/rebase-merge/git-rebase-todo")
    let contents = try String(contentsOf: todo, encoding: .utf8)
    try (contents + "\n# external review\n").write(to: todo, atomically: true, encoding: .utf8)
    await rebaseRejected { _ = try await self.git.controlRebase(.abort, expected: state) }
    let fresh = try await requireRebaseState(git)
    _ = try await git.controlRebase(.abort, expected: fresh)
    try await rebaseHeadEquals(plan.candidate.review.head)
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("first.txt"), encoding: .utf8), "B\ntwo\nthree\n")
  }
  func testInteractiveRebaseControlsRejectChangedWorkingFile() async throws {
    let plan = try await conflictingRebase()
    await rebaseRejected { _ = try await self.git.startInteractiveRebase(plan) }
    let state = try await requireRebaseState(git)
    try write("first.txt", "external edit\n")
    await rebaseRejected { _ = try await self.git.controlRebase(.skip, expected: state) }
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("first.txt"), encoding: .utf8), "external edit\n")
    let fresh = try await requireRebaseState(git)
    _ = try await git.controlRebase(.abort, expected: fresh)
  }
  func testInteractiveRebaseMultipleSuccessivePlans() async throws {
    let candidate = try await rebaseFixture()
    var first = InteractiveRebasePlan(candidate: candidate)
    first.steps[0].action = .reword; first.steps[0].message = "first rewrite"
    _ = try await git.startInteractiveRebase(first)
    let next = try await git.interactiveRebaseCandidate(upstream: candidate.upstream)
    var second = InteractiveRebasePlan(candidate: next)
    second.steps[2].action = .reword; second.steps[2].message = "second rewrite"
    _ = try await git.startInteractiveRebase(second)
    let history = try await git.history()
    XCTAssertEqual(history.map(\.subject), ["second rewrite", "B", "first rewrite", "seed"])
  }
  func testInteractiveRebaseRestartPreservesRemainingMessagesAfterConflict() async throws {
    let first = try await conflictingRebase()
    for name in ["c", "d"] {
      try write(name + ".txt", name + "\n")
      try await raw(["add", "--", name + ".txt"]); try await raw(["commit", "-m", name])
    }
    let candidate = try await git.interactiveRebaseCandidate(upstream: first.candidate.upstream)
    let plan = InteractiveRebasePlan(candidate: candidate, steps: [
      RebaseStep(commit: candidate.commits[1]), RebaseStep(commit: candidate.commits[0], action: .drop),
      RebaseStep(commit: candidate.commits[2], action: .reword, message: "reviewed C"),
      RebaseStep(commit: candidate.commits[3], action: .squash, message: "reviewed C and D")])
    await rebaseRejected { _ = try await self.git.startInteractiveRebase(plan) }
    try write("first.txt", "B\ntwo\nthree\n")
    try await raw(["add", "--", "first.txt"])
    let restarted = GitService(root: directory)
    let state = try await requireRebaseState(restarted)
    _ = try await restarted.controlRebase(.continue, expected: state)
    let history = try await restarted.history()
    XCTAssertEqual(history.map(\.subject), ["reviewed C and D", "B", "seed"])
  }
  func testInteractiveRebaseCorruptMessagePlanStillAllowsNativeAbort() async throws {
    let plan = try await conflictingRebase()
    await rebaseRejected { _ = try await self.git.startInteractiveRebase(plan) }
    try write(".git/gitpier-rebase-messages.json", "corrupt data")
    let state = try await requireRebaseState(git)
    await rebaseRejected { _ = try await self.git.controlRebase(.continue, expected: state) }
    _ = try await git.controlRebase(.abort, expected: state)
    try await rebaseHeadEquals(plan.candidate.review.head)
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(".git/gitpier-rebase-messages.json"), encoding: .utf8), "corrupt data")
  }
}
