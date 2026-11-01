import XCTest
@testable import GitPierCore

final class BranchHealthTests: XCTestCase {
  var fixture: CommitReplayTests!
  override func setUp() async throws { fixture = CommitReplayTests(); try await fixture.setUp() }
  override func tearDown() async throws { try await fixture.tearDown(); fixture = nil }
  func testDefaultTargetUsesExistingRemoteHEADForMainAndMasterOnly() async throws {
    try await fixture.raw(["remote", "add", "origin", "https://example.invalid/no-network"])
    for name in ["main", "master"] {
      if name == "master" { try await fixture.raw(["branch", "-m", "main", "master"]) }
      try await fixture.raw(["update-ref", "refs/remotes/origin/" + name, fixture.base])
      try await fixture.raw(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/" + name])
      let value = try await fixture.git.branchHealth()
      XCTAssertEqual(value.suggestedTargetReference, "refs/heads/" + name)
      XCTAssertTrue(value.availableTargets.allSatisfy { $0.hasPrefix("refs/heads/") })
      XCTAssertNil(value.targetReference, "Suggestion must not silently analyze a target")
    }
    try await fixture.raw(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/missing"])
    let missing = try await fixture.git.branchHealth()
    XCTAssertNil(missing.suggestedTargetReference)
    try await fixture.raw(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"])
    let absent = try await fixture.git.branchHealth()
    XCTAssertNil(absent.suggestedTargetReference, "Do not guess master or main")
  }
  func testSyncStatesAgreeAcrossHealthDashboardAndWorkflowAfterRefUpdates() async throws {
    try await fixture.raw(["remote", "add", "origin", "https://example.invalid/no-network"])
    try await fixture.raw(["config", "branch.main.remote", "origin"])
    try await fixture.raw(["config", "branch.main.merge", "refs/heads/main"])
    // Two independent descendants of base: local +3, tracking +4.
    for _ in 1...3 { try await fixture.raw(["commit", "--allow-empty", "-m", "local"]) }
    let local = try await fixture.head()
    try await fixture.raw(["switch", "-c", "tracking", fixture.base])
    var tracking = [fixture.base!]
    for _ in 1...4 {
      try await fixture.raw(["commit", "--allow-empty", "-m", "tracking"])
      tracking.append(try await fixture.head())
    }
    try await fixture.raw(["switch", "main"])
    let scenarios: [(String, String, BranchSyncState)] = [
      (local, local, .synced), (local, fixture.base, .ahead(3)),
      (fixture.base, tracking[2], .behind(2)), (fixture.commits[1], tracking[4], .diverged(ahead: 2, behind: 4))
    ]
    let record = RepositoryRecord(path: fixture.root.path)
    for (tip, upstream, expected) in scenarios {
      try await fixture.raw(["reset", "--hard", tip])
      try await fixture.raw(["update-ref", "refs/remotes/origin/main", upstream])
      let health = try await fixture.git.branchHealth().branches.first { $0.current }
      let status = try await fixture.git.status(localOnly: true)
      let dashboard = try await fixture.git.workspaceSnapshot(record)
      XCTAssertEqual(health?.syncState, expected); XCTAssertEqual(status.syncState, expected)
      XCTAssertEqual(dashboard.syncState, expected)
      var input = ContextWorkflowInput(); input.status = status; input.remoteCount = 1
      input.remoteFresh = true; input.remotePhase = .upToDate
      let expectedAdvice: ContextWorkflowAdvice.Kind = expected == .synced ? .aligned : expected == .ahead(3) ? .outgoing : expected == .behind(2) ? .incoming : .diverged
      XCTAssertEqual(ContextWorkflowAdvice.evaluate(input).kind, expectedAdvice)
    }
    try await fixture.raw(["update-ref", "-d", "refs/remotes/origin/main"])
    let missing = try await fixture.git.branchHealth().branches.first { $0.current }
    let missingStatus = try await fixture.git.status(localOnly: true)
    XCTAssertEqual(missing?.syncState, .unknown); XCTAssertEqual(missingStatus.syncState, .unknown)
    try await fixture.raw(["config", "--unset", "branch.main.remote"])
    try await fixture.raw(["config", "--unset", "branch.main.merge"])
    let unbound = try await fixture.git.branchHealth().branches.first { $0.current }
    XCTAssertEqual(unbound?.syncState, .noUpstream)
  }
  func testEquivalentCherryPickIsNotMergedAncestry() async throws {
    try await fixture.raw(["cherry-pick", fixture.commits[0]])
    try await fixture.raw(["commit", "--amend", "-m", "equivalent patch, different commit"])
    let value = try await fixture.git.branchHealth(mergedInto: "refs/heads/main")
    XCTAssertEqual(value.branches.first { $0.name == "source" }?.mergedIntoTarget, false)
    do { _ = try await fixture.git.branchHealth(mergedInto: "refs/heads/nonexistent"); XCTFail("Missing target accepted") } catch {}
    try await fixture.raw(["reset", "--hard", fixture.base])
    try await fixture.raw(["merge", "--squash", "source"])
    try await fixture.raw(["commit", "-m", "squashed equivalent content"])
    let squashed = try await fixture.git.branchHealth(mergedInto: "refs/heads/main")
    XCTAssertEqual(squashed.branches.first { $0.name == "source" }?.mergedIntoTarget, false)
  }
  func testAmbiguousRemoteDefaultsRequireSelectionUnlessCurrentRemoteDisambiguates() async throws {
    for (remote, name) in [("one", "main"), ("two", "source")] {
      try await fixture.raw(["remote", "add", remote, "https://example.invalid/no-network"])
      try await fixture.raw(["update-ref", "refs/remotes/" + remote + "/" + name, fixture.base])
      try await fixture.raw(["symbolic-ref", "refs/remotes/" + remote + "/HEAD", "refs/remotes/" + remote + "/" + name])
    }
    let ambiguous = try await fixture.git.branchHealth()
    XCTAssertNil(ambiguous.suggestedTargetReference)
    try await fixture.raw(["config", "branch.main.remote", "two"])
    try await fixture.raw(["config", "branch.main.merge", "refs/heads/source"])
    let preferred = try await fixture.git.branchHealth()
    XCTAssertEqual(preferred.suggestedTargetReference, "refs/heads/source")
  }
  func testLocalFetchUpdatesAllThreeConsumersWithoutReusingOldCounts() async throws {
    try await fixture.raw(["remote", "add", "origin", fixture.root.path])
    try await fixture.raw(["config", "remote.origin.fetch", "+refs/heads/source:refs/remotes/origin/main"])
    try await fixture.raw(["config", "branch.main.remote", "origin"])
    try await fixture.raw(["config", "branch.main.merge", "refs/heads/source"])
    try await fixture.raw(["update-ref", "refs/remotes/origin/main", fixture.base])
    let before = try await fixture.git.branchHealth().branches.first { $0.current }
    XCTAssertEqual(before?.syncState, .synced)
    try await fixture.raw(["fetch", "origin"])
    let after = try await fixture.git.branchHealth().branches.first { $0.current }
    let state = try await fixture.git.status(localOnly: true)
    let dashboard = try await fixture.git.workspaceSnapshot(RepositoryRecord(path: fixture.root.path))
    XCTAssertEqual(after?.syncState, .behind(2)); XCTAssertEqual(state.syncState, .behind(2))
    XCTAssertEqual(dashboard.syncState, .behind(2))
    var input = ContextWorkflowInput(); input.status = state; input.remoteCount = 1
    input.remoteFresh = true; input.remotePhase = .referencesUpdated
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(input).kind, .incoming)
    input.remoteFresh = false
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(input).actions, [.reviewFetch])
    input.status.operation = .merge
    XCTAssertEqual(ContextWorkflowAdvice.evaluate(input).kind, .unfinishedOperation)
  }
  func testIncompleteDataCannotBePromotedToSynced() {
    XCTAssertEqual(BranchSyncState(upstream: "origin/main", comparable: false, ahead: 0, behind: 0), .unknown)
    XCTAssertEqual(BranchSyncState(upstream: "origin/main", comparable: true, ahead: nil, behind: 0), .unknown)
    XCTAssertEqual(BranchSyncState(upstream: "origin/main", comparable: true, ahead: -1, behind: 0), .unknown)
    XCTAssertEqual(RepositoryStatus().syncState, .unknown)
  }
  func testLocalHealthHasExplicitMergeTargetAndDoesNotWriteIndex() async throws {
    let index = try Data(contentsOf: fixture.root.appendingPathComponent(".git/index"))
    let noTarget = try await fixture.git.branchHealth()
    XCTAssertTrue(noTarget.branches.allSatisfy { $0.mergedIntoTarget == nil })
    let health = try await fixture.git.branchHealth(mergedInto: "refs/heads/main")
    XCTAssertEqual(health.targetReference, "refs/heads/main"); XCTAssertEqual(health.targetHash, fixture.base)
    XCTAssertEqual(health.branches.first { $0.name == "main" }?.mergedIntoTarget, true)
    XCTAssertEqual(health.branches.first { $0.name == "source" }?.mergedIntoTarget, false)
    XCTAssertEqual(health.branches.first { $0.name == "main" }?.worktreePaths, [fixture.root.path])
    XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(".git/index")), index)
  }
  func testDivergenceAndMissingUpstreamUseOnlyLocalRefs() async throws {
    try await fixture.raw(["remote", "add", "origin", "https://example.invalid/no-network"])
    try await fixture.raw(["update-ref", "refs/remotes/origin/main", fixture.commits[1]])
    try await fixture.raw(["config", "branch.main.remote", "origin"])
    try await fixture.raw(["config", "branch.main.merge", "refs/heads/main"])
    try fixture.write("local.txt", "local\n"); try await fixture.raw(["add", "."])
    try await fixture.raw(["commit", "-m", "local"])
    let health = try await fixture.git.branchHealth()
    let branch = try XCTUnwrap(health.branches.first { $0.name == "main" })
    XCTAssertEqual(branch.upstream, "refs/remotes/origin/main"); XCTAssertEqual(branch.upstreamExists, true)
    XCTAssertEqual(branch.ahead, 1); XCTAssertEqual(branch.behind, 2); XCTAssertTrue(branch.diverged)
    try await fixture.raw(["update-ref", "-d", "refs/remotes/origin/main"])
    let missing = try await fixture.git.branchHealth().branches.first { $0.name == "main" }
    XCTAssertEqual(missing?.upstreamExists, false); XCTAssertNil(missing?.ahead); XCTAssertNil(missing?.behind)
  }
  func testDetachedHeadAndLinkedOccupancyAndActivity() async throws {
    let linked = fixture.root.deletingLastPathComponent().appendingPathComponent("GitPier-health-linked-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: linked) }
    try await fixture.raw(["worktree", "add", linked.path, "source"])
    try await fixture.raw(["switch", "--detach", fixture.base])
    let health = try await fixture.git.branchHealth()
    XCTAssertTrue(health.detached); XCTAssertEqual(health.head, fixture.base)
    let source = try XCTUnwrap(health.branches.first { $0.name == "source" })
    XCTAssertEqual(source.worktreePaths, [linked.path]); XCTAssertNotNil(source.lastCommit)
    XCTAssertFalse(source.inactive(asOf: Date(timeIntervalSince1970: 0)))
    XCTAssertTrue(source.inactive(asOf: Date.distantFuture))
  }
  func testCustomFetchNamespaceIsAnExistingUpstream() async throws {
    try await fixture.raw(["remote", "add", "origin", "https://example.invalid/no-network"])
    try await fixture.raw(["config", "remote.origin.fetch", "+refs/heads/*:refs/tracking/origin/*"])
    try await fixture.raw(["config", "branch.main.remote", "origin"])
    try await fixture.raw(["config", "branch.main.merge", "refs/heads/main"])
    try await fixture.raw(["update-ref", "refs/tracking/origin/main", fixture.base])
    let value = try await fixture.git.branchHealth().branches.first { $0.name == "main" }
    XCTAssertEqual(value?.upstream, "refs/tracking/origin/main")
    XCTAssertEqual(value?.upstreamExists, true); XCTAssertEqual(value?.ahead, 0); XCTAssertEqual(value?.behind, 0)
    let record = RepositoryRecord(path: fixture.root.path)
    let first = try await fixture.git.branchHealth(record: record)
    let target = try await fixture.git.upstreamFetchTarget(record)
    XCTAssertEqual(first.fetchTargetID, target?.id); XCTAssertEqual(first.fetchRemoteName, "origin")
    try await fixture.raw(["config", "remote.origin.fetch", "+refs/heads/*:refs/other/origin/*"])
    let changed = try await fixture.git.branchHealth(record: record)
    XCTAssertNotEqual(first.fetchTargetID, changed.fetchTargetID, "Same remote URL with a new refspec must not reuse Fetch provenance")
  }
  func testInvalidTargetIsRefusedAndUnfinishedOperationIsReported() async throws {
    do { _ = try await fixture.git.branchHealth(mergedInto: "HEAD~1"); XCTFail("Moving expression accepted as a merge target") } catch {}
    try await fixture.raw(["cherry-pick", fixture.commits[0]])
    _ = try await fixture.raw(["cherry-pick", fixture.commits[0]], failure: true)
    let health = try await fixture.git.branchHealth()
    XCTAssertEqual(health.operation, .cherryPick)
  }
  func testUnbornHeadIsNotReportedAsDetached() async throws {
    try await fixture.raw(["symbolic-ref", "HEAD", "refs/heads/unborn"])
    let value = try await fixture.git.branchHealth()
    XCTAssertNil(value.head); XCTAssertEqual(value.currentBranch, "unborn"); XCTAssertFalse(value.detached)
  }
  func testShallowHistoryDoesNotProveUnmergedAncestry() async throws {
    let clone = fixture.root.deletingLastPathComponent().appendingPathComponent("GitPier-health-shallow-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: clone) }
    try await fixture.raw(["clone", "--depth=1", "--no-local", "--branch", "source", "file://" + fixture.root.path, clone.path])
    let service = GitService(root: clone)
    await service.configure(gitPath: "/usr/bin/git", authEnvironment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
    try await service.perform(["config", "user.name", "Health"]); try await service.perform(["config", "user.email", "health@example.invalid"])
    try await service.perform(["config", "commit.gpgsign", "false"])
    try await service.perform(["branch", "target"])
    try await service.perform(["commit", "--allow-empty", "-m", "later"])
    let value = try await service.branchHealth(mergedInto: "refs/heads/target")
    XCTAssertTrue(value.shallow)
    XCTAssertNil(value.branches.first { $0.name == "source" }?.mergedIntoTarget)
    XCTAssertEqual(value.branches.first { $0.name == "target" }?.mergedIntoTarget, true)
  }
  func testNonUTF8ReferencesAreRefusedBeforeLossyIdentityCollisions() async throws {
    // APFS rejects invalid-byte filenames; packed refs can still arrive from
    // another platform without creating such directory entries on this Mac.
    var bytes = Data("# pack-refs with: peeled fully-peeled sorted\n".utf8)
    for byte: UInt8 in [254, 255] {
      bytes.append(Data((fixture.base + " refs/heads/invalid-").utf8)); bytes.append(byte); bytes.append(10)
    }
    try bytes.write(to: fixture.root.appendingPathComponent(".git/packed-refs"))
    do { _ = try await fixture.git.branchHealth(); XCTFail("Lossy ref identities were accepted") } catch {}
  }
}
