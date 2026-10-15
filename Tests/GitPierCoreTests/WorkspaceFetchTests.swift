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
    let probe = FetchProbe()
    let service = BatchFetchCoordinator(executor: { try await probe.run($0) })
    let targets = (0..<10).map { target($0 == 3 ? "bad" : "origin", common: "common-\($0)") }
    await service.submit(targets); await service.submit(targets); await service.waitUntilIdle()
    let jobs = await service.current(); XCTAssertEqual(jobs.filter { $0.state == .succeeded }.count, 9); XCTAssertEqual(jobs.filter { $0.state == .failed }.count, 1)
    XCTAssertFalse(jobs[3].summary.contains("secret"))
    let stats = await probe.values(); XCTAssertEqual(stats.0, 10); XCTAssertLessThanOrEqual(stats.1, 2)
    await service.submit([targets[3]]); await service.waitUntilIdle()
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
