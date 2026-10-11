import XCTest

@testable import GitPierCore

extension GitServiceTests {
  private func pushFixture() async throws -> (bare: URL, peer: URL) {
    try await seed()
    let fixtures = directory.appendingPathComponent(".git/fixtures")
    let bare = fixtures.appendingPathComponent("remote.git")
    let peer = fixtures.appendingPathComponent("peer")
    try await raw(["init", "--bare", bare.path])
    try await raw(["remote", "add", "origin", bare.path])
    _ = try await git.network("push", remote: "origin", branch: "main")
    try await raw(["clone", "--branch", "main", bare.path, peer.path])
    for (key, value) in [("user.name", "Peer"), ("user.email", "peer@example.invalid"),
      ("commit.gpgsign", "false"), ("core.hooksPath", peer.appendingPathComponent(".git/hooks").path)]
    { try await raw(["-C", peer.path, "config", key, value]) }
    return (bare, peer)
  }
  private func advancePeer(_ peer: URL, path: String = "second.txt", text: String = "remote change\n") async throws -> String {
    try text.write(to: peer.appendingPathComponent(path), atomically: true, encoding: .utf8)
    try await raw(["-C", peer.path, "add", "--", path])
    try await raw(["-C", peer.path, "commit", "-m", "remote change"])
    try await raw(["-C", peer.path, "push", "origin", "main"])
    return try await raw(["-C", peer.path, "rev-parse", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  private func localPushCommit() async throws -> String {
    try write("first.txt", "local change\n")
    try await git.stage(try await git.status().files.filter { $0.path == "first.txt" })
    return try await git.commit(message: "local change", expected: git.snapshot()).hash
  }
  private func rejectedPush(remote: String? = nil, branch: String? = nil) async throws -> PushRejection {
    do {
      _ = try await git.network("push", remote: remote, branch: branch)
      XCTFail("Remote divergence must reject push")
      throw GitPierError.invalidInput("Expected rejected push")
    } catch let rejection as PushRejection { return rejection }
  }
  private func remoteHead(_ bare: URL, branch: String = "main") async throws -> String {
    try await raw(["--git-dir=" + bare.path, "rev-parse", "refs/heads/" + branch]).text
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
  func testRejectedPushFetchesMergesAndPushesWithoutRepeatingLocalCommit() async throws {
    let fixture = try await pushFixture()
    let remote = try await advancePeer(fixture.peer)
    let local = try await localPushCommit()
    for (key, value) in [("pull.rebase", "true"), ("pull.ff", "only"), ("merge.ff", "only"), ("merge.autoStash", "true")] {
      try await raw(["config", key, value])
    }
    let rejection = try await rejectedPush()
    XCTAssertEqual(rejection.localHead, local)
    XCTAssertEqual(rejection.remoteURL, fixture.bare.path)
    XCTAssertEqual(rejection.remoteReference, "refs/heads/main")
    let before = try await git.status()
    XCTAssertEqual(before.head, local)
    let remoteBefore = try await remoteHead(fixture.bare)
    XCTAssertEqual(remoteBefore, remote)
    let fetchHead = directory.appendingPathComponent(".git/FETCH_HEAD")
    let externalFetch = Data("another client's fetch state\n".utf8)
    try externalFetch.write(to: fetchHead)
    _ = try await git.mergeAndPush(rejection)
    let after = try await git.status()
    let remoteAfter = try await remoteHead(fixture.bare)
    XCTAssertEqual(remoteAfter, after.head)
    let parents = try await raw(["show", "-s", "--format=%P", "HEAD"]).text.split(whereSeparator: \.isWhitespace).map(String.init)
    XCTAssertEqual(parents, [local, remote])
    let first = try await raw(["show", "HEAD:first.txt"]).text
    let second = try await raw(["show", "HEAD:second.txt"]).text
    XCTAssertEqual(first, "local change\n")
    XCTAssertEqual(second, "remote change\n")
    let subjects = try await raw(["log", "--format=%s"]).text.split(separator: "\n")
    XCTAssertEqual(subjects.filter { $0 == "local change" }.count, 1)
    XCTAssertNil(after.operation)
    XCTAssertEqual(after.ahead, 0)
    XCTAssertEqual(after.behind, 0)
    XCTAssertEqual(try Data(contentsOf: fetchHead), externalFetch)
    let temporaryRefs = try await raw(["for-each-ref", "--format=%(refname)", "refs/gitpier/push-recovery"]).text
    XCTAssertTrue(temporaryRefs.isEmpty)
  }
  func testMergeConflictStopsPushAndPreservesLocalCommit() async throws {
    let fixture = try await pushFixture()
    let remote = try await advancePeer(fixture.peer, path: "first.txt", text: "conflicting remote\n")
    let local = try await localPushCommit()
    let rejection = try await rejectedPush()
    do {
      _ = try await git.mergeAndPush(rejection)
      XCTFail("Conflicts must stop push")
    } catch { XCTAssertTrue(error.localizedDescription.contains("conflict")) }
    let state = try await git.status()
    XCTAssertEqual(state.operation, .merge)
    XCTAssertTrue(state.files.contains(where: \.isConflicted))
    XCTAssertEqual(state.head, local)
    let remoteAfter = try await remoteHead(fixture.bare)
    XCTAssertEqual(remoteAfter, remote)
  }
  func testMergeRecoveryRefusesPartialStagingWithoutChangingIndex() async throws {
    let fixture = try await pushFixture()
    _ = try await advancePeer(fixture.peer)
    _ = try await localPushCommit()
    let rejection = try await rejectedPush()
    try write("first.txt", "staged remainder\n")
    try await raw(["add", "--", "first.txt"])
    try write("first.txt", "unstaged remainder\n")
    let before = try await git.snapshot()
    do {
      _ = try await git.mergeAndPush(rejection)
      XCTFail("Must preserve uncommitted tracked changes")
    } catch { XCTAssertTrue(error.localizedDescription.contains("Commit or stash")) }
    let after = try await git.snapshot()
    XCTAssertEqual(before.identity, after.identity)
    XCTAssertEqual(before.patch, after.patch)
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("first.txt"), encoding: .utf8), "unstaged remainder\n")
    let state = try await git.status()
    XCTAssertTrue(state.files.first { $0.path == "first.txt" }!.isPartial)
  }
  func testMergeRecoveryRefusesChangedHEAD() async throws {
    let fixture = try await pushFixture()
    _ = try await advancePeer(fixture.peer)
    _ = try await localPushCommit()
    let rejection = try await rejectedPush()
    try await raw(["commit", "--allow-empty", "-m", "external commit"])
    let before = try await git.status()
    do {
      _ = try await git.mergeAndPush(rejection)
      XCTFail("Must review new HEAD before merging")
    } catch { XCTAssertTrue(error.localizedDescription.contains("HEAD changed")) }
    let after = try await git.status()
    XCTAssertEqual(after, before)
  }
  func testNonFastForwardAfterFetchAlsoOffersRecovery() async throws {
    let fixture = try await pushFixture()
    _ = try await advancePeer(fixture.peer)
    _ = try await localPushCommit()
    _ = try await git.network("fetch")
    let rejection = try await rejectedPush()
    XCTAssertTrue(rejection.diagnostic.contains("non-fast-forward"))
    _ = try await git.mergeAndPush(rejection)
    let remoteAfter = try await remoteHead(fixture.bare)
    let state = try await git.status()
    XCTAssertEqual(remoteAfter, state.head)
  }
  func testRecoveryFetchesPushURLInsteadOfFetchURLAndSetsNamedUpstream() async throws {
    let fixture = try await pushFixture()
    let destination = directory.appendingPathComponent(".git/fixtures/push.git")
    try await raw(["clone", "--bare", fixture.bare.path, destination.path])
    try await raw(["-C", fixture.peer.path, "remote", "set-url", "origin", destination.path])
    let remote = try await advancePeer(fixture.peer)
    try await raw(["--git-dir=" + destination.path, "branch", "release", remote])
    try await raw(["remote", "set-url", "--push", "origin", destination.path])
    _ = try await localPushCommit()
    let originalFetchHead = try await remoteHead(fixture.bare)
    let rejection = try await rejectedPush(remote: "origin", branch: "release")
    XCTAssertEqual(rejection.remoteReference, "refs/heads/release")
    _ = try await git.mergeAndPush(rejection)
    let state = try await git.status()
    let pushedHead = try await remoteHead(destination, branch: "release")
    let fetchHead = try await remoteHead(fixture.bare)
    XCTAssertEqual(pushedHead, state.head)
    XCTAssertEqual(fetchHead, originalFetchHead)
    XCTAssertEqual(state.upstream, "origin/release")
  }
  func testServerPolicyRejectionDoesNotOfferMergeRecovery() async throws {
    let fixture = try await pushFixture()
    _ = try await localPushCommit()
    let hook = fixture.bare.appendingPathComponent("hooks/pre-receive")
    try "#!/bin/sh\necho 'policy: fetch first' >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    do {
      _ = try await git.network("push")
      XCTFail("Hook must refuse push")
    } catch is PushRejection { XCTFail("Server policy must not be treated as divergence") }
    catch { XCTAssertTrue(error.localizedDescription.contains("policy")) }
  }
  func testMergeHooksRemainEnabledAndFailureStopsPush() async throws {
    let fixture = try await pushFixture()
    let remote = try await advancePeer(fixture.peer)
    _ = try await localPushCommit()
    let rejection = try await rejectedPush()
    let hook = directory.appendingPathComponent(".git/hooks/pre-merge-commit")
    try "#!/bin/sh\necho 'merge hook rejected' >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    do {
      _ = try await git.mergeAndPush(rejection)
      XCTFail("Merge hooks must remain enabled")
    } catch { XCTAssertTrue(error.localizedDescription.contains("merge hook rejected")) }
    let remoteAfter = try await remoteHead(fixture.bare)
    let state = try await git.status()
    XCTAssertEqual(remoteAfter, remote)
    XCTAssertEqual(state.operation, .merge)
  }
  func testRecoveryFetchesRemoteCommitsAddedAfterConfirmationWasOffered() async throws {
    let fixture = try await pushFixture()
    _ = try await advancePeer(fixture.peer)
    _ = try await localPushCommit()
    let rejection = try await rejectedPush()
    let latest = try await advancePeer(fixture.peer, text: "newer remote change\n")
    _ = try await git.mergeAndPush(rejection)
    let ancestor = try await raw(["merge-base", "--is-ancestor", latest, "HEAD"])
    XCTAssertEqual(ancestor.code, 0)
    let mergedContent = try await raw(["show", "HEAD:second.txt"]).text
    XCTAssertEqual(mergedContent, "newer remote change\n")
  }
  func testRecoveryRefusesDifferentBranchEvenWithSameHEAD() async throws {
    let fixture = try await pushFixture()
    _ = try await advancePeer(fixture.peer)
    _ = try await localPushCommit()
    let rejection = try await rejectedPush()
    try await git.createBranch("other")
    try await git.switchBranch("other")
    let before = try await git.status()
    do {
      _ = try await git.mergeAndPush(rejection)
      XCTFail("Confirmation applies only to the original branch")
    } catch { XCTAssertTrue(error.localizedDescription.contains("branch or HEAD changed")) }
    let after = try await git.status()
    XCTAssertEqual(after, before)
  }
}
