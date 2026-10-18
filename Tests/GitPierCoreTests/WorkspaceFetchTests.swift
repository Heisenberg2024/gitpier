import XCTest
@testable import GitPierCore

private actor FetchProbe {
  var count = 0
  var peak = 0
  var active = 0
  var held: [CheckedContinuation<Void, Never>] = []
  var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
  let pause: Bool
  init(pause: Bool = false) { self.pause = pause }
  func run(_ target: WorkspaceFetchTarget) async throws -> String {
    count += 1; active += 1; peak = max(peak, active)
    for (n, waiter) in waiters where n <= count { waiter.resume() }; waiters.removeAll { $0.0 <= count }
    if pause { await withCheckedContinuation { held.append($0) } }
    else { try? await Task.sleep(for: .milliseconds(15)) }
    active -= 1
    try Task.checkCancellation()
    if target.remote.name == "bad" { throw GitPierError.invalidInput("https://user:secret@example.invalid authentication failed") }
    return "done"
  }
  func started(_ n: Int) async { if count >= n { return }; await withCheckedContinuation { waiters.append((n, $0)) } }
  func release() { for value in held { value.resume() }; held.removeAll() }
  func values() -> (Int, Int) { (count, peak) }
}

final class WorkspaceFetchTests: XCTestCase {
  var root: URL!
  var fixture: URL!
  var git: GitService!
  var record: RepositoryRecord!
  override func setUp() async throws {
    fixture = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-batch-fetch-" + UUID().uuidString)
    root = fixture.appendingPathComponent("main"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    git = GitService(root: root); record = RepositoryRecord(path: root.path)
    try await raw(["init", "-b", "main"])
    try await raw(["config", "user.name", "Batch Tests"]); try await raw(["config", "user.email", "batch@example.invalid"])
    try await raw(["config", "commit.gpgsign", "false"]); try await raw(["config", "core.hooksPath", root.appendingPathComponent(".git/hooks").path])
    try "seed\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try await raw(["add", "."]); try await raw(["commit", "-m", "seed"])
    let remote = fixture.appendingPathComponent("remote.git")
    try await raw(["init", "--bare", remote.path]); try await raw(["remote", "add", "origin", remote.path]); try await raw(["push", "-u", "origin", "main"])
  }
  override func tearDown() async throws { try? FileManager.default.removeItem(at: fixture) }
  @discardableResult func raw(_ args: [String]) async throws -> CommandResult {
    let result = try await ProcessRunner().run(executable: "/usr/bin/git", arguments: args, directory: root,
      environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
    guard result.code == 0 else { throw GitPierError.command("fixture", result.code, result.errorText) }; return result
  }
  func target(_ name: String = "origin", common: String = "common") -> WorkspaceFetchTarget {
    let remote = GitRemote(name: name, fetchURL: "fixture", pushURL: "fixture", configuredFetchURLs: ["fixture"], configuredPushURLs: [], configurationID: "fixture")
    return WorkspaceFetchTarget(record: record, commonDirectory: common, remote: remote, configurationIdentity: "fixture")
  }
  func testAttemptScopedCancelCannotCancelANewerRetry() async throws {
    let probe = FetchProbe(pause: true)
    let coordinator = BatchFetchCoordinator(concurrency: 1, executor: { try await probe.run($0) })
    let target = target()
    await coordinator.submit([target]); await probe.started(1)
    let firstJobs = await coordinator.current(); let first = try XCTUnwrap(firstJobs.first)
    await probe.release(); await coordinator.waitUntilIdle()
    await coordinator.submit([target]); await probe.started(2)
    let secondJobs = await coordinator.current(); let second = try XCTUnwrap(secondJobs.first)
    XCTAssertNotEqual(first.attemptID, second.attemptID)
    await coordinator.cancel([target.id], expectedAttempts: [target.id: first.attemptID])
    await probe.release(); await coordinator.waitUntilIdle()
    let finished = await coordinator.current()
    XCTAssertEqual(finished.first?.state, .succeeded)
  }
  func testAttemptScopedCancelStillCancelsItsCurrentAttempt() async throws {
    let probe = FetchProbe(pause: true)
    let coordinator = BatchFetchCoordinator(concurrency: 1, executor: { try await probe.run($0) })
    let target = target()
    await coordinator.submit([target]); await probe.started(1)
    let currentJobs = await coordinator.current(); let current = try XCTUnwrap(currentJobs.first)
    await coordinator.cancel([target.id], expectedAttempts: [target.id: current.attemptID])
    await probe.release(); await coordinator.waitUntilIdle()
    let finished = await coordinator.current()
    XCTAssertEqual(finished.first?.state, .cancelled)
  }
  func testReviewedFetchPreservesHEADWorkingTreeIndexAndFETCHHEAD() async throws {
    try "staged\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8); try await raw(["add", "file.txt"])
    try "working\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    let index = root.appendingPathComponent(".git/index"), fetchHead = root.appendingPathComponent(".git/FETCH_HEAD")
    try Data("external fetch head\n".utf8).write(to: fetchHead)
    let before = try Data(contentsOf: index); let state = try await git.status()
    let reviewed = try await git.reviewWorkspaceFetch(record)
    XCTAssertEqual(reviewed.count, 1)
    _ = try await git.workspaceFetch(reviewed[0])
    let after = try await git.status(); XCTAssertEqual(state, after); XCTAssertEqual(try Data(contentsOf: index), before)
    XCTAssertEqual(try String(contentsOf: fetchHead, encoding: .utf8), "external fetch head\n")
  }
  func testChangedRemoteURLOrRefspecRequiresNewReview() async throws {
    let targets = try await git.reviewWorkspaceFetch(record)
    try await raw(["config", "remote.origin.fetch", "+refs/heads/other:refs/remotes/origin/other"])
    do { _ = try await git.workspaceFetch(targets[0]); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
    let next = try await git.reviewWorkspaceFetch(record)
    try await raw(["remote", "set-url", "origin", fixture.appendingPathComponent("removed.git").path])
    do { _ = try await git.workspaceFetch(next[0]); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
  }
  func testWorktreeTargetsDeduplicateByPhysicalRepositoryAndRemote() async throws {
    let linked = fixture.appendingPathComponent("linked")
    try await raw(["worktree", "add", "-b", "topic", linked.path])
    let second = RepositoryRecord(path: linked.path)
    let first = try await git.reviewWorkspaceFetch(record)
    let other = try await GitService(root: linked).reviewWorkspaceFetch(second)
    let merged = WorkspaceFetchTarget.deduplicated(first + other)
    XCTAssertEqual(merged.count, 1); XCTAssertEqual(merged[0].repositoryIDs, [record.id, second.id])
  }
  func testNoRemoteAndFailedTransportRetainLocalState() async throws {
    try await raw(["remote", "remove", "origin"])
    let none = try await git.reviewWorkspaceFetch(record); XCTAssertTrue(none.isEmpty)
    try await raw(["remote", "add", "bad", fixture.appendingPathComponent("missing.git").path])
    let state = try await git.status(); let target = try await git.reviewWorkspaceFetch(record)[0]
    do { _ = try await git.workspaceFetch(target); XCTFail() } catch { XCTAssertFalse(error is CancellationError) }
    let after = try await git.status(); XCTAssertEqual(state, after)
  }
  func testPartialFailureBoundedQueueAndRetry() async {
    let probe = FetchProbe(pause: true)
    let service = BatchFetchCoordinator(executor: { try await probe.run($0) })
    let targets = (0..<10).map { target($0 == 3 ? "bad" : "origin", common: "common-\($0)") }
    await service.submit(targets); await probe.started(2)
    // Keep both workers held until duplicate admission has been checked. A short sleep in
    // the executor does not guarantee that the first jobs are still active on a busy runner.
    await service.submit(targets)
    for batch in 1...5 { await probe.started(batch * 2); await probe.release() }
    await service.waitUntilIdle()
    let jobs = await service.current(); XCTAssertEqual(jobs.filter { $0.state == .succeeded }.count, 9); XCTAssertEqual(jobs.filter { $0.state == .failed }.count, 1)
    XCTAssertFalse(jobs[3].summary.contains("secret"))
    let stats = await probe.values(); XCTAssertEqual(stats.0, 10); XCTAssertLessThanOrEqual(stats.1, 2)
    await service.submit([targets[3]]); await probe.started(11); await probe.release(); await service.waitUntilIdle()
    let retry = await probe.values(); XCTAssertEqual(retry.0, 11)
  }
  func testAllFailedJobsAreIndependent() async {
    let service = BatchFetchCoordinator(executor: { _ in throw GitPierError.invalidInput("Connection interrupted") })
    await service.submit((0..<4).map { target(common: "\($0)") }); await service.waitUntilIdle()
    let jobs = await service.current(); XCTAssertEqual(jobs.filter { $0.state == .failed }.count, 4)
  }
  func testCancelPendingAndRunningAndRejectDuplicateSubmission() async {
    let probe = FetchProbe(pause: true)
    let service = BatchFetchCoordinator(concurrency: 1, executor: { try await probe.run($0) })
    let targets = (0..<5).map { target(common: "\($0)") }
    await service.submit(targets); await probe.started(1); await service.submit(targets)
    await service.cancel(); await probe.release(); await service.waitUntilIdle()
    let jobs = await service.current(); XCTAssertEqual(jobs.filter { $0.state == .cancelled }.count, 5)
    let stats = await probe.values(); XCTAssertEqual(stats.0, 1)
  }
  func testSSHAuthenticationFailureUsesExistingTransportAndRedaction() async throws {
    let ssh = fixture.appendingPathComponent("ssh-fixture")
    try "#!/bin/sh\nprintf 'Permission denied (publickey).\\n' >&2\nexit 1\n".write(to: ssh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
    try await raw(["config", "core.sshCommand", ssh.path]); try await raw(["remote", "set-url", "origin", "ssh://git@example.invalid/repository.git"])
    let value = try await git.reviewWorkspaceFetch(record)[0]
    do { _ = try await git.workspaceFetch(value); XCTFail() }
    catch { XCTAssertTrue(error.localizedDescription.contains("Permission denied")) }
  }
  func testCancellingRealNetworkProcessReleasesWriteQueue() async throws {
    let marker = fixture.appendingPathComponent("started"), ssh = fixture.appendingPathComponent("slow-ssh")
    try "#!/bin/sh\ntouch '\(marker.path)'\nsleep 30\nexit 1\n".write(to: ssh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
    try await raw(["config", "core.sshCommand", ssh.path]); try await raw(["remote", "set-url", "origin", "ssh://git@example.invalid/repository.git"])
    let value = try await git.reviewWorkspaceFetch(record)[0], service = git!
    let task = Task { try await service.workspaceFetch(value) }
    for _ in 0..<150 where !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path)); task.cancel()
    do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    try await git.createBranch("after-cancel")
    let branches = try await git.branches(); XCTAssertTrue(branches.contains { $0.name == "after-cancel" })
  }
  func testCancelledSnapshotAndSharedMetadataWaitersDoNotWaitForNetworkWrite() async throws {
    let marker = fixture.appendingPathComponent("started-queue"), ssh = fixture.appendingPathComponent("queue-ssh")
    try "#!/bin/sh\ntouch '\(marker.path)'\nsleep 30\nexit 1\n".write(to: ssh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
    try await raw(["config", "core.sshCommand", ssh.path]); try await raw(["remote", "set-url", "origin", "ssh://git@example.invalid/repository.git"])
    let linked = fixture.appendingPathComponent("linked-queue"); try await raw(["worktree", "add", "-b", "linked-queue", linked.path])
    let value = try await git.reviewWorkspaceFetch(record)[0], service = git!, mainRecord = record!
    let other = GitService(root: linked), otherRecord = RepositoryRecord(path: linked.path)
    let network = Task { try await service.workspaceFetch(value) }
    for _ in 0..<150 where !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    let same = Task { try await service.workspaceSnapshot(mainRecord) }
    let shared = Task { try await other.workspaceSnapshot(otherRecord) }
    try await Task.sleep(for: .milliseconds(75))
    let start = Date(); same.cancel(); shared.cancel()
    do { _ = try await same.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    do { _ = try await shared.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    network.cancel(); _ = try? await network.value
    try await service.createBranch("after-queued-cancel")
  }
}

extension WorkspaceFetchTests {
  func testAutomaticFetchPreservesPartialIndexWorkingFilesFetchHeadAndAvoidsTagsAndPrune() async throws {
    try await raw(["tag", "remote-only"]); try await raw(["push", "origin", "refs/tags/remote-only"])
    try await raw(["tag", "-d", "remote-only"])
    let head = try await raw(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    try await raw(["update-ref", "refs/remotes/origin/keep", head])
    try await raw(["config", "fetch.prune", "true"]); try await raw(["config", "fetch.pruneTags", "true"])
    try "staged\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try await raw(["add", "file.txt"])
    try "working\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    let index = root.appendingPathComponent(".git/index"), fetchHead = root.appendingPathComponent(".git/FETCH_HEAD")
    try Data("external\n".utf8).write(to: fetchHead)
    let before = try Data(contentsOf: index), state = try await git.status()
    let target = try await git.upstreamFetchTarget(record)!
    let result = try await git.checkedWorkspaceFetch(target, automatic: true)
    XCTAssertFalse(result.referencesUpdated)
    XCTAssertEqual(try Data(contentsOf: index), before)
    XCTAssertEqual(try String(contentsOf: fetchHead, encoding: .utf8), "external\n")
    let after = try await git.status(); XCTAssertEqual(after, state)
    let tags = try await raw(["tag", "--list"]).text; XCTAssertFalse(tags.contains("remote-only"))
    _ = try await raw(["rev-parse", "--verify", "refs/remotes/origin/keep"])
  }
  func testAutomaticFetchRejectsMirrorAndUnsafeRefspecsBeforeTransport() async throws {
    for refspec in ["+refs/*:refs/*", "+refs/heads/*:refs/heads/*", "+refs/heads/main:refs/tags/main", "+refs/heads/*:refs/remotes/another/*"] {
      try await raw(["config", "remote.origin.fetch", refspec])
      let target = try await git.reviewWorkspaceFetch(record)[0]
      do { _ = try await git.checkedWorkspaceFetch(target, automatic: true); XCTFail(refspec) }
      catch { guard case AutomaticFetchError.skipped = error else { return XCTFail(error.localizedDescription) } }
    }
    try await raw(["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"])
    try await raw(["config", "remote.origin.mirror", "true"])
    let target = try await git.reviewWorkspaceFetch(record)[0]
    do { _ = try await git.checkedWorkspaceFetch(target, automatic: true); XCTFail() }
    catch { XCTAssertTrue(error.localizedDescription.contains("Mirror")) }
  }
  func testLocalSnapshotSelectsGitDefaultRemoteWithoutUpstream() async throws {
    try await raw(["remote", "add", "unused", fixture.appendingPathComponent("missing.git").path])
    let snapshot = try await git.workspaceSnapshot(record)
    XCTAssertEqual(snapshot.remoteTarget?.remote.name, "origin")
    try await raw(["branch", "--unset-upstream"])
    let noUpstream = try await git.workspaceSnapshot(record)
    XCTAssertEqual(noUpstream.remoteTarget?.remote.name, "origin"); XCTAssertNil(noUpstream.upstream)
    try await raw(["checkout", "--detach"])
    let detached = try await git.upstreamFetchTarget(record)
    XCTAssertEqual(detached?.remote.name, "origin")
    try await raw(["remote", "remove", "origin"])
    let single = try await git.upstreamFetchTarget(record)
    XCTAssertEqual(single?.remote.name, "unused")
    try await raw(["remote", "add", "ambiguous", fixture.appendingPathComponent("other.git").path])
    let ambiguous = try await git.upstreamFetchTarget(record)
    XCTAssertNil(ambiguous)
  }
  func testWorktreeUpstreamsDeduplicateButDifferentRemoteIdentitiesDoNot() async throws {
    let linked = fixture.appendingPathComponent("auto-linked")
    try await raw(["worktree", "add", "-b", "auto-topic", linked.path])
    let other = GitService(root: linked), otherRecord = RepositoryRecord(path: linked.path)
    _ = try await other.perform(["branch", "--set-upstream-to", "origin/main"])
    let first = try await git.upstreamFetchTarget(record)!, second = try await other.upstreamFetchTarget(otherRecord)!
    XCTAssertEqual(first.id, second.id)
    try await raw(["remote", "add", "second", fixture.appendingPathComponent("remote.git").path])
    try await raw(["fetch", "second"])
    _ = try await other.perform(["branch", "--set-upstream-to", "second/main"])
    let changed = try await other.upstreamFetchTarget(otherRecord)!
    XCTAssertNotEqual(first.id, changed.id)
    XCTAssertEqual(WorkspaceFetchTarget.deduplicated([first, second, changed]).count, 2)
  }
  func testAutomaticFetchDetectsUpdatedReferencesAndConfigIdentityInvalidation() async throws {
    let remote = fixture.appendingPathComponent("remote.git")
    let head = try await raw(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    try await raw(["update-ref", "refs/remotes/origin/main", head + "~0"])
    let target = try await git.upstreamFetchTarget(record)!
    let tree = try await raw(["rev-parse", "HEAD^{tree}"]).text.trimmingCharacters(in: .newlines)
    let commit = try await ProcessRunner().run(executable: "/usr/bin/git", arguments: ["commit-tree", tree, "-p", head], directory: root,
      environment: ["GIT_AUTHOR_NAME":"Test", "GIT_AUTHOR_EMAIL":"test@example.invalid", "GIT_COMMITTER_NAME":"Test", "GIT_COMMITTER_EMAIL":"test@example.invalid"], input: Data("remote update\n".utf8))
    try await raw(["push", remote.path, commit.text.trimmingCharacters(in: .newlines) + ":refs/heads/main"])
    let result = try await git.checkedWorkspaceFetch(target, automatic: true)
    XCTAssertTrue(result.referencesUpdated)
    let state = try await git.status(); XCTAssertEqual(state.behind, 1)
    try await raw(["config", "remote.origin.url", fixture.appendingPathComponent("changed.git").path])
    do { _ = try await git.checkedWorkspaceFetch(target, automatic: true); XCTFail() }
    catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
  }
  func testCoordinatorReportsAcceptanceAndRejectsAfterShutdown() async {
    let probe = FetchProbe()
    let coordinator = BatchFetchCoordinator(executor: { try await probe.run($0) })
    let value = target()
    let first = await coordinator.submit([value]); XCTAssertEqual(first.accepted, [value.id])
    await coordinator.waitUntilIdle(); await coordinator.shutdown()
    let rejected = await coordinator.submit([value]); XCTAssertTrue(rejected.accepted.isEmpty); XCTAssertEqual(rejected.rejected, [value.id])
  }
  func testManualAdmissionCancelsAutomaticAndBlocksFurtherAutomaticWork() async {
    // Every CI run exercises repeated handoffs without relying on which actor runs first.
    for iteration in 0..<128 {
      let probe = FetchProbe(pause: true)
      let cancelled = expectation(description: "Automatic Fetch cancelled, handoff \(iteration)")
      let coordinator = BatchFetchCoordinator(executor: { target in
        try await withTaskCancellationHandler {
          try await probe.run(target)
        } onCancel: {
          cancelled.fulfill()
        }
      })
      let value = target()
      await coordinator.submit([value], automatic: true); await probe.started(1)
      let manual = Task { await coordinator.beginManualOperation() }
      // Creating the manual Task is not an admission barrier. Do not release the fake
      // transport until the coordinator has actually requested cancellation.
      await fulfillment(of: [cancelled], timeout: 5)
      await probe.release(); await manual.value
      let rejected = await coordinator.submit([target(common: "other")], automatic: true)
      XCTAssertTrue(rejected.accepted.isEmpty, "Handoff \(iteration)")
      let jobs = await coordinator.current(); XCTAssertEqual(jobs[0].state, .cancelled, "Handoff \(iteration)")
      await coordinator.endManualOperation()
      await coordinator.shutdown()
      guard jobs[0].state == .cancelled else { return }
    }
  }
  func testManualAdmissionPreservesAutomaticFetchThatAlreadyFinished() async {
    let probe = FetchProbe()
    let coordinator = BatchFetchCoordinator(executor: { try await probe.run($0) })
    await coordinator.submit([target()], automatic: true); await coordinator.waitUntilIdle()
    await coordinator.beginManualOperation()
    let jobs = await coordinator.current(); XCTAssertEqual(jobs[0].state, .succeeded)
    let rejected = await coordinator.submit([target(common: "other")], automatic: true)
    XCTAssertTrue(rejected.accepted.isEmpty)
    await coordinator.endManualOperation()
    let accepted = await coordinator.submit([target(common: "other")], automatic: true)
    XCTAssertFalse(accepted.accepted.isEmpty)
    await coordinator.waitUntilIdle(); await coordinator.shutdown()
  }
  func testAutomaticCustomSSHUsesTheOriginalCommand() async throws {
    try await raw(["config", "core.sshCommand", "/usr/bin/false"])
    // An SSH-only setting must not disable an unrelated file/HTTPS transport.
    let local = try await git.upstreamFetchTarget(record)!
    _ = try await git.checkedWorkspaceFetch(local, automatic: true)
    try await raw(["remote", "set-url", "origin", "ssh://git@example.invalid/repo.git"])
    let value = try await git.upstreamFetchTarget(record)!
    do { _ = try await git.checkedWorkspaceFetch(value, automatic: true); XCTFail() }
    catch { XCTAssertFalse(error is AutomaticFetchError); XCTAssertEqual(AuthenticationFailure.classify(error), .networkFailure) }
  }
}

extension WorkspaceFetchTests {
  func testBackgroundInvokesConfiguredCredentialHelperButDisablesAskpass() async throws {
    let marker = fixture.appendingPathComponent("interactive-helper-was-run")
    let wrapper = fixture.appendingPathComponent("git-background-fixture")
    let source = """
    #!/bin/sh
    for task_arg in "$@"; do
      if [ "$task_arg" = fetch ]; then
        [ "$GIT_TERMINAL_PROMPT" = 0 ] || exit 90
        [ "$GIT_ASKPASS" = /usr/bin/false ] || exit 91
        [ "$SSH_ASKPASS_REQUIRE" = never ] || exit 92
        printf 'protocol=https\\nhost=example.invalid\\n\\n' | /usr/bin/git credential fill >/dev/null
        exit $?
      fi
    done
    exec /usr/bin/git "$@"
    """
    try source.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    let unsafe = "!touch " + InputValidation.shellQuote(marker.path) + "; exit 1"
    try await raw(["config", "credential.helper", unsafe])
    try await raw(["config", "credential.https://example.invalid.helper", unsafe])
    try await raw(["remote", "set-url", "origin", "https://example.invalid/repository.git"])
    let service = GitService(root: root, gitPath: wrapper.path)
    let target = try await service.upstreamFetchTarget(record)!
    let coordinator = BatchFetchCoordinator(checkedExecutor: { target, automatic in
      try await service.checkedWorkspaceFetch(target, automatic: automatic)
    })
    await coordinator.submit([target], automatic: true); await coordinator.waitUntilIdle()
    let jobs = await coordinator.current()
    XCTAssertEqual(jobs[0].phase, .authenticationRequired, jobs[0].summary)
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "Background Fetch did not reuse the configured native helper")
  }
  func testSSHBackgroundRetainsOriginalCommandAndOptions() async throws {
    let capture = fixture.appendingPathComponent("ssh-arguments")
    let ssh = fixture.appendingPathComponent("noninteractive-ssh")
    let source = "#!/bin/sh\nprintf '%s\\n' \"$@\" >> " + InputValidation.shellQuote(capture.path) + "\nprintf 'Permission denied (publickey).\\n' >&2\nexit 1\n"
    try source.write(to: ssh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
    try await raw(["remote", "set-url", "origin", "ssh://git@example.invalid/repository.git"])
    await git.configure(gitPath: "/usr/bin/git", authEnvironment: ["GIT_SSH_COMMAND": InputValidation.shellQuote(ssh.path) + " -oStrictHostKeyChecking=yes -oUseKeychain=yes", "GIT_SSH_VARIANT": "ssh"])
    let target = try await git.upstreamFetchTarget(record)!
    do { _ = try await git.checkedWorkspaceFetch(target, automatic: true); XCTFail() } catch {}
    let args = try String(contentsOf: capture, encoding: .utf8)
    XCTAssertTrue(args.contains("StrictHostKeyChecking=yes")); XCTAssertFalse(args.contains("StrictHostKeyChecking=no"))
    XCTAssertTrue(args.contains("UseKeychain=yes")); XCTAssertFalse(args.contains("UseKeychain=no"))
  }
}

extension WorkspaceFetchTests {
  func testAutomaticDefersWhileSameWorktreeOrCommonDirectoryWriteIsRunning() async throws {
    let linked = fixture.appendingPathComponent("auto-busy-linked")
    try await raw(["worktree", "add", "-b", "auto-busy", linked.path])
    let other = GitService(root: linked), otherRecord = RepositoryRecord(path: linked.path)
    _ = try await other.perform(["branch", "--set-upstream-to", "origin/main"])
    let second = try await other.upstreamFetchTarget(otherRecord)!
    let marker = fixture.appendingPathComponent("manual-started"), ssh = fixture.appendingPathComponent("manual-ssh")
    try "#!/bin/sh\ntouch '\(marker.path)'\nsleep 30\nexit 1\n".write(to: ssh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
    try await raw(["config", "core.sshCommand", ssh.path]); try await raw(["remote", "set-url", "origin", "ssh://git@example.invalid/repository.git"])
    let main = try await git.reviewWorkspaceFetch(record)[0], service = git!
    let manual = Task { try await service.workspaceFetch(main) }
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(for: .milliseconds(20)) }
    let start = Date()
    for (service, target) in [(service, main), (other, second)] {
      do { _ = try await service.checkedWorkspaceFetch(target, automatic: true); XCTFail() }
      catch { guard case AutomaticFetchError.skipped = error else { manual.cancel(); return XCTFail(error.localizedDescription) } }
    }
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    manual.cancel(); _ = try? await manual.value
    _ = try await git.status()
  }
  func testManualAllDoesNotVerifySkippedOrChangedRemote() async throws {
    for flag in ["skipFetchAll", "skipDefaultUpdate"] {
      let reviewed = try await git.reviewWorkspaceFetch(record)
      try await raw(["config", "remote.origin." + flag, "true"])
      let updated = try await git.reviewWorkspaceFetch(record)
      let all = await git.confirmedManualFetchTargets(updated, all: true); XCTAssertTrue(all.isEmpty)
      let explicit = await git.confirmedManualFetchTargets(updated, all: false); XCTAssertEqual(explicit.count, 1)
      let changed = await git.confirmedManualFetchTargets(reviewed, all: false); XCTAssertTrue(changed.isEmpty)
      try await raw(["config", "remote.origin." + flag, "false"])
    }
  }
}

extension WorkspaceFetchTests {
  func testAutomaticPreflightRejectsOldPartialCloneGitBeforeImplicitTransport() async throws {
    let wrapper = fixture.appendingPathComponent("old-partial-git"), marker = fixture.appendingPathComponent("transport-started")
    let script = """
    #!/bin/sh
    if [ "$1" = --version ]; then printf 'git version 2.42.0\\n'; exit 0; fi
    for task_arg in "$@"; do
      if [ "$task_arg" = fetch ]; then touch \(InputValidation.shellQuote(marker.path)); exit 90; fi
    done
    exec /usr/bin/git "$@"
    """
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    try await raw(["config", "remote.origin.promisor", "true"])
    let service = GitService(root: root, gitPath: wrapper.path), target = try await service.upstreamFetchTarget(record)!
    do { _ = try await service.checkedWorkspaceFetch(target, automatic: true); XCTFail() }
    catch { XCTAssertTrue(error.localizedDescription.contains("2.43"), error.localizedDescription) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }
}


extension WorkspaceFetchTests {
  func testAutomaticFetchDelegatesConfiguredRemoteHelpersToNativeGit() async throws {
    for option in ["vcs", "uploadpack"] {
      try await raw(["config", "remote.origin." + option, "unsupported-helper"])
      let target = try await git.upstreamFetchTarget(record)!
      do { _ = try await git.checkedWorkspaceFetch(target, automatic: true); XCTFail() }
      catch { XCTAssertFalse(error is AutomaticFetchError); XCTAssertEqual(AuthenticationFailure.classify(error), .networkFailure) }
      try await raw(["config", "--unset", "remote.origin." + option])
    }
  }
}
