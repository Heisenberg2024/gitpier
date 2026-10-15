import XCTest
@testable import GitPierCore

private actor SnapshotProbe {
  var calls: [UUID] = []
  var active = 0
  var peak = 0
  var gates: [CheckedContinuation<Void, Never>] = []
  var startedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  var paused = false
  init(paused: Bool = false) { self.paused = paused }
  func load(_ record: RepositoryRecord) async throws -> WorkspaceSnapshot {
    calls.append(record.id); active += 1; peak = max(peak, active)
    for (count, waiter) in startedWaiters where calls.count >= count { waiter.resume() }
    startedWaiters.removeAll { calls.count >= $0.0 }
    if paused { await withCheckedContinuation { gates.append($0) } }
    else { try? await Task.sleep(for: .milliseconds(15)) }
    active -= 1
    var status = RepositoryStatus(); status.branch = "scan-\(calls.count)"
    return WorkspaceSnapshot(record: record, status: status, gitDirectory: record.path + "/.git", commonDirectory: record.path + "/.git")
  }
  func started(_ count: Int) async {
    if calls.count >= count { return }
    await withCheckedContinuation { startedWaiters.append((count, $0)) }
  }
  func release() { if !gates.isEmpty { gates.removeFirst().resume() } }
  func values() -> (Int, Int, [UUID]) { (calls.count, peak, calls) }
}

final class WorkspaceStatusTests: XCTestCase {
  var fixture: URL!
  var root: URL!
  var git: GitService!
  var record: RepositoryRecord!
  override func setUp() async throws {
    fixture = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-workspace-" + UUID().uuidString)
    root = fixture.appendingPathComponent("main")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    git = GitService(root: root); record = RepositoryRecord(path: root.path)
    try await raw(["init", "-b", "main"])
    try await raw(["config", "user.name", "Workspace Tests"])
    try await raw(["config", "user.email", "workspace@example.invalid"])
    try await raw(["config", "commit.gpgsign", "false"])
    try await raw(["config", "core.hooksPath", root.appendingPathComponent(".git/hooks").path])
    try write("file.txt", "seed\n"); try await raw(["add", "file.txt"]); try await raw(["commit", "-m", "seed"])
  }
  override func tearDown() async throws { try? FileManager.default.removeItem(at: fixture) }
  @discardableResult func raw(_ args: [String]) async throws -> CommandResult {
    let result = try await ProcessRunner().run(executable: "/usr/bin/git", arguments: args, directory: root,
      environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
    guard result.code == 0 else { throw GitPierError.command("fixture", result.code, result.errorText) }; return result
  }
  func write(_ path: String, _ text: String) throws { try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
  func testSnapshotCountsAndPartialIndexBytesRemainUnchanged() async throws {
    try write("file.txt", "staged\n"); try await raw(["add", "file.txt"]); try write("file.txt", "working\n")
    try write("未跟踪 [literal].txt", "untracked\n")
    let index = root.appendingPathComponent(".git/index"); let before = try Data(contentsOf: index)
    let value = try await git.workspaceSnapshot(record)
    XCTAssertEqual(value.tracked, 1); XCTAssertEqual(value.staged, 1); XCTAssertEqual(value.untracked, 1)
    XCTAssertEqual(value.branch, "main"); XCTAssertNotNil(value.head); XCTAssertNil(value.upstream)
    XCTAssertFalse(value.isWorktree); XCTAssertFalse(value.detached); XCTAssertTrue(value.modified)
    XCTAssertEqual(try Data(contentsOf: index), before)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8), "working\n")
  }
  func testLocalScanNeverFetchesAndAvoidsDiffTreeAndHistory() async throws {
    let log = fixture.appendingPathComponent("commands")
    let wrapper = fixture.appendingPathComponent("git-wrapper")
    try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(log.path)'\nexec /usr/bin/git \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    try await raw(["remote", "add", "origin", "https://example.invalid/never-contact.git"])
    let service = GitService(root: root, gitPath: wrapper.path)
    let value = try await service.workspaceSnapshot(record)
    XCTAssertEqual(value.remoteNames, ["origin"])
    let commands = try String(contentsOf: log, encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }
    XCTAssertEqual(commands.count, 6)
    for command in commands { XCTAssertFalse(["fetch", "diff", "write-tree", "log"].contains { command.contains($0) }, command) }
  }
  func testIncrementalHEADBranchAndIndexUpdates() async throws {
    let first = try await git.workspaceSnapshot(record)
    try await raw(["switch", "-c", "topic"]); try write("file.txt", "second\n"); try await raw(["add", "file.txt"])
    let second = try await git.workspaceSnapshot(record)
    XCTAssertEqual(second.branch, "topic"); XCTAssertEqual(second.staged, 1); XCTAssertEqual(second.head, first.head)
    try await raw(["commit", "-m", "second"]); try await raw(["checkout", "--detach"])
    let third = try await git.workspaceSnapshot(record)
    XCTAssertTrue(third.detached); XCTAssertEqual(third.staged, 0); XCTAssertNotEqual(third.head, first.head)
  }
  func testLinkedWorktreeSharedIdentityAndIndependentCounts() async throws {
    let linked = fixture.appendingPathComponent("linked ")
    try await raw(["worktree", "add", "-b", "linked", linked.path])
    let secondRecord = RepositoryRecord(path: linked.path)
    try "dirty\n".write(to: linked.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    let first = try await git.workspaceSnapshot(record)
    let second = try await GitService(root: linked).workspaceSnapshot(secondRecord)
    XCTAssertEqual(first.commonDirectory, second.commonDirectory); XCTAssertTrue(second.isWorktree)
    XCTAssertEqual(second.branch, "linked"); XCTAssertEqual(second.tracked, 1); XCTAssertEqual(first.tracked, 0)
  }
  func testMissingInvalidAndGitFailureAreDistinct() async throws {
    let missing = RepositoryRecord(path: fixture.appendingPathComponent("missing").path)
    let invalidPath = fixture.appendingPathComponent("empty"); try FileManager.default.createDirectory(at: invalidPath, withIntermediateDirectories: true)
    let invalid = RepositoryRecord(path: invalidPath.path)
    for (value, expected) in [(missing, WorkspaceFailureKind.missingDirectory), (invalid, .invalidRepository)] {
      do { _ = try await GitService(root: URL(fileURLWithPath: value.path)).workspaceSnapshot(value); XCTFail() }
      catch let failure as WorkspaceFailure { XCTAssertEqual(failure.kind, expected) }
    }
    let broken = GitService(root: root, gitPath: "/usr/bin/false")
    do { _ = try await broken.workspaceSnapshot(record); XCTFail() }
    catch let failure as WorkspaceFailure { XCTAssertEqual(failure.kind, .gitQuery) }
  }
  func testConflictAndUnfinishedOperation() async throws {
    try await raw(["switch", "-c", "topic"]); try write("file.txt", "topic\n"); try await raw(["add", "."]); try await raw(["commit", "-m", "topic"])
    try await raw(["switch", "main"]); try write("file.txt", "main\n"); try await raw(["add", "."]); try await raw(["commit", "-m", "main"])
    _ = try await git.read(["merge", "topic"], allowFailure: true)
    let value = try await git.workspaceSnapshot(record)
    XCTAssertEqual(value.conflicts, 1); XCTAssertEqual(value.operation, .merge)
  }
  func testPermissionDeniedIsNotReportedAsMissing() async throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
    do { _ = try await git.workspaceSnapshot(record); XCTFail() }
    catch let failure as WorkspaceFailure { XCTAssertEqual(failure.kind, .permissionDenied) }
  }
  func testDeletedNestedGitMetadataCannotFallBackToParentRepository() async throws {
    let nested = root.appendingPathComponent("nested"); try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try await raw(["-C", nested.path, "init", "-b", "nested"])
    let service = GitService(root: nested), value = RepositoryRecord(path: nested.path)
    let first = try await service.workspaceSnapshot(value); XCTAssertEqual(first.branch, "nested")
    try FileManager.default.removeItem(at: nested.appendingPathComponent(".git"))
    do { _ = try await service.workspaceSnapshot(value); XCTFail() }
    catch let failure as WorkspaceFailure { XCTAssertEqual(failure.kind, .invalidRepository) }
  }
  func testAheadBehindUsesLocalTrackingRefsUntilExplicitFetch() async throws {
    let remote = fixture.appendingPathComponent("remote.git"), peer = fixture.appendingPathComponent("peer")
    try await raw(["clone", "--bare", root.path, remote.path]); try await raw(["remote", "add", "origin", remote.path])
    try await raw(["fetch", "origin"]); try await raw(["branch", "--set-upstream-to=origin/main", "main"])
    try await raw(["clone", remote.path, peer.path])
    for (key, value) in [("user.name", "Peer Fixture"), ("user.email", "peer@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", peer.appendingPathComponent(".git/hooks").path)] {
      try await raw(["-C", peer.path, "config", key, value])
    }
    try "remote\n".write(to: peer.appendingPathComponent("remote.txt"), atomically: true, encoding: .utf8)
    try await raw(["-C", peer.path, "add", "."]); try await raw(["-C", peer.path, "commit", "-m", "remote"]); try await raw(["-C", peer.path, "push", "origin", "main"])
    let outdated = try await git.workspaceSnapshot(record)
    XCTAssertEqual(outdated.upstream, "origin/main"); XCTAssertEqual(outdated.behind, 0)
    try write("local.txt", "local\n"); try await raw(["add", "."]); try await raw(["commit", "-m", "local"])
    try await raw(["fetch", "origin"])
    let divergent = try await git.workspaceSnapshot(record); XCTAssertEqual(divergent.ahead, 1); XCTAssertEqual(divergent.behind, 1)
  }
  func testBoundedConcurrencyAndRepeatedRequestsCoalesce() async {
    let probe = SnapshotProbe()
    let service = WorkspaceStatusService(concurrency: 3, loader: { try await probe.load($0) })
    let records = (0..<20).map { RepositoryRecord(path: "/fixture/\($0)") }
    await service.reconcile(records)
    await service.request(records.map(\.id)); await service.request(records.map(\.id), priority: .userInitiated)
    await service.waitUntilIdle()
    let (count, peak, _) = await probe.values(); XCTAssertEqual(count, 20); XCTAssertLessThanOrEqual(peak, 3)
    let entries = await service.current(); XCTAssertEqual(entries.values.filter { $0.state == .fresh }.count, 20)
    await service.request(records.map(\.id)); await service.waitUntilIdle()
    let cached = await probe.values(); XCTAssertEqual(cached.0, 20)
    await service.shutdown()
  }
  func testVisibleRequestJumpsAheadOfPendingBackgroundWork() async {
    let probe = SnapshotProbe(paused: true)
    let service = WorkspaceStatusService(concurrency: 1, loader: { try await probe.load($0) })
    let records = (0..<3).map { RepositoryRecord(path: "/fixture/\($0)") }
    await service.reconcile(records); await service.request(records.map(\.id)); await probe.started(1)
    await service.request([records[2].id], priority: .visible); await probe.release(); await probe.started(2)
    let order = await probe.values(); XCTAssertEqual(order.2[1], records[2].id)
    await probe.release(); await probe.started(3); await probe.release(); await service.waitUntilIdle()
  }
  func testSupersededCancelledResultCannotOverwriteNewSnapshot() async {
    let probe = SnapshotProbe(paused: true)
    let service = WorkspaceStatusService(concurrency: 1, loader: { try await probe.load($0) })
    await service.reconcile([record]); await service.request([record.id]); await probe.started(1)
    await service.request([record.id], force: true); await probe.release(); await probe.started(2)
    let interim = await service.current(); XCTAssertNil(interim[record.id]?.snapshot)
    await probe.release(); await service.waitUntilIdle()
    let final = await service.current(); XCTAssertEqual(final[record.id]?.snapshot?.branch, "scan-2")
    let counts = await probe.values(); XCTAssertEqual(counts.1, 1)
  }
  func testRemovalAndShutdownRejectLateUncancellableResults() async {
    let probe = SnapshotProbe(paused: true)
    let service = WorkspaceStatusService(concurrency: 1, loader: { try await probe.load($0) })
    await service.reconcile([record]); await service.request([record.id]); await probe.started(1)
    await service.reconcile([]); await probe.release(); await service.waitUntilIdle()
    let removed = await service.current(); XCTAssertTrue(removed.isEmpty)
    await service.reconcile([record]); await service.request([record.id]); await probe.started(2)
    await service.shutdown(); await probe.release(); await service.waitUntilIdle()
    let stopped = await service.current(); XCTAssertNil(stopped[record.id]?.snapshot)
  }
  func testSingleFailureRetainsCacheAndDoesNotBlockOtherRecords() async {
    let probe = SnapshotProbe()
    let service = WorkspaceStatusService(loader: { value in
      if value.name == "fail" { throw WorkspaceFailure(.gitQuery, "https://user:secret@example.invalid failed") }
      return try await probe.load(value)
    })
    await service.reconcile([record]); await service.request([record.id]); await service.waitUntilIdle()
    var changed = record!; changed.name = "fail"
    let other = RepositoryRecord(path: "/fixture/other")
    await service.reconcile([changed, other]); await service.request([changed.id, other.id], force: true); await service.waitUntilIdle()
    let values = await service.current()
    XCTAssertEqual(values[changed.id]?.state, .failed); XCTAssertNotNil(values[changed.id]?.snapshot)
    XCTAssertFalse(values[changed.id]?.failure?.summary.contains("secret") ?? true)
    XCTAssertEqual(values[other.id]?.state, .fresh)
    await service.invalidate([changed.id])
    let stale = await service.current()
    XCTAssertNil(stale[changed.id]?.usable)
    XCTAssertTrue(WorkspaceFilter.unavailable.matches(stale[changed.id]!))
    XCTAssertEqual(WorkspaceSummary([stale[changed.id]!]).scanned, 1)
  }
  func testFailedEntriesDoNotRepeatedlyScanOnConfigurationSaves() async {
    let probe = SnapshotProbe()
    let service = WorkspaceStatusService(loader: { record in
      _ = try await probe.load(record)
      throw WorkspaceFailure(.gitQuery, "Unavailable")
    })
    await service.reconcile([record]); await service.request([record.id]); await service.waitUntilIdle()
    for _ in 0..<5 { await service.reconcile([record]); await service.request([record.id]) }
    await service.waitUntilIdle(); let count = await probe.values(); XCTAssertEqual(count.0, 1)
    await service.request([record.id], force: true); await service.waitUntilIdle()
    let retry = await probe.values(); XCTAssertEqual(retry.0, 2)
  }
  func testOlderGitPartialCloneCannotImplicitlyFetchWhileOrdinaryRepositoriesRemainSupported() async throws {
    let wrapper = fixture.appendingPathComponent("old-git"), log = fixture.appendingPathComponent("old-git-commands")
    try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(log.path)'\ncase \"$*\" in *--version*) echo 'git version 2.39.3'; exit 0;; esac\nexec /usr/bin/git \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    let service = GitService(root: root, gitPath: wrapper.path)
    _ = try await service.workspaceSnapshot(record)
    try await raw(["config", "remote.origin.promisor", "true"])
    try Data().write(to: log)
    do { _ = try await service.workspaceSnapshot(record); XCTFail() }
    catch let failure as WorkspaceFailure { XCTAssertTrue(failure.summary.contains("Git 2.43")) }
    do { _ = try await service.workspaceSearch(record: record, query: "seed", kinds: [.commit]); XCTFail() }
    catch let failure as WorkspaceFailure { XCTAssertTrue(failure.summary.contains("Git 2.43")) }
    let commands = try String(contentsOf: log, encoding: .utf8)
    XCTAssertFalse(commands.contains("status ")); XCTAssertFalse(commands.contains(" log ")); XCTAssertFalse(commands.contains("fetch "))
    try await raw(["config", "--unset", "remote.origin.promisor"])
    let config = root.appendingPathComponent(".git/config")
    try (Data(contentsOf: config) + Data("\n[remote \"no-value\"]\n\tpromisor\n".utf8)).write(to: config)
    do { _ = try await service.workspaceSnapshot(record); XCTFail() }
    catch let failure as WorkspaceFailure { XCTAssertTrue(failure.summary.contains("Git 2.43")) }
  }
  func testOldConfigurationTasksCannotResurrectRemovedOrMovedEntries() async {
    let probe = SnapshotProbe()
    let service = WorkspaceStatusService(loader: { try await probe.load($0) })
    await service.reconcile([record], revision: 1)
    await service.reconcile([], revision: 2)
    await service.reconcile([record], revision: 1)
    let removed = await service.current(); XCTAssertTrue(removed.isEmpty)
    var moved = record!; moved.path = "/fixture/new-path"
    await service.reconcile([moved], revision: 3)
    await service.reconcile([record], revision: 2)
    await service.request([record.id]); await service.waitUntilIdle()
    let current = await service.current(); XCTAssertEqual(current[record.id]?.snapshot?.path, moved.path)
  }
  func testSummaryNeverCountsUnscannedAsCleanOrNoUpstreamAsSynced() {
    var first = WorkspaceEntry(record: record)
    let unknown = WorkspaceEntry(record: RepositoryRecord(path: "/unknown"))
    var state = RepositoryStatus(); state.ahead = 2; state.behind = 3
    first.snapshot = WorkspaceSnapshot(record: record, status: state, gitDirectory: "g", commonDirectory: "g"); first.state = .fresh
    let summary = WorkspaceSummary([first, unknown])
    XCTAssertEqual(summary.total, 2); XCTAssertEqual(summary.scanned, 1); XCTAssertEqual(summary.fresh, 1)
    XCTAssertEqual(summary.unknownPhysical, 1); XCTAssertEqual(summary.counts[.ahead], 0); XCTAssertEqual(summary.counts[.behind], 0)
    XCTAssertFalse(WorkspaceFilter.modified.matches(unknown)); XCTAssertFalse(WorkspaceFilter.unavailable.matches(unknown))
  }
  func testAllFiltersShareSummaryRulesAndPhysicalRepositoryCounts() {
    var value = record!; value.favorite = true; value.group = "Engineering"
    var state = RepositoryStatus(); state.upstream = "origin/main"; state.ahead = 1; state.behind = 2
    state.files = [FileChange(path: "conflict", index: "U", worktree: "U", kind: .conflicted), FileChange(path: "staged", index: "M", worktree: ".", kind: .modified)]
    var first = WorkspaceEntry(record: value); first.state = .fresh
    first.snapshot = WorkspaceSnapshot(record: value, status: state, gitDirectory: "common", commonDirectory: "common")
    let other = RepositoryRecord(path: "/linked")
    var second = WorkspaceEntry(record: other); second.state = .stale
    second.snapshot = WorkspaceSnapshot(record: other, status: state, gitDirectory: "linked", commonDirectory: "common")
    let summary = WorkspaceSummary([first, second]); XCTAssertEqual(summary.physicalRepositories, 1)
    for filter in WorkspaceFilter.allCases {
      XCTAssertEqual(summary.counts[filter], [first, second].filter { filter.matches($0) }.count)
    }
    XCTAssertTrue([WorkspaceFilter.modified, .staged, .ahead, .behind, .conflicts, .favorites].allSatisfy { $0.matches(first) })
  }
}
