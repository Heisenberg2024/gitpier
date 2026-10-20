import Darwin
import XCTest
@testable import GitPierCore

final class TaskWorkspaceTests: XCTestCase {
  var fixture: URL!
  var root: URL!
  var git: GitService!
  override func setUp() async throws {
    fixture = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("GitPier-tasks-" + UUID().uuidString)
    root = fixture.appendingPathComponent("main")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    git = GitService(root: root)
    try await raw(["init", "-b", "main"])
    try await raw(["config", "user.name", "Task Tests"])
    try await raw(["config", "user.email", "tasks@example.invalid"])
    try await raw(["config", "commit.gpgsign", "false"])
    try await raw(["config", "core.hooksPath", root.appendingPathComponent(".git/hooks").path])
    try write("file.txt", "one\ntwo\n")
    try await raw(["add", "file.txt"]); try await raw(["commit", "-m", "seed"])
  }
  override func tearDown() { if let fixture { try? FileManager.default.removeItem(at: fixture) } }
  @discardableResult func raw(_ arguments: [String], directory: URL? = nil) async throws -> CommandResult {
    let result = try await ProcessRunner().run(executable: "/usr/bin/git", arguments: arguments, directory: directory ?? root,
      environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
    guard result.code == 0 else { throw GitPierError.command("fixture", result.code, result.errorText) }; return result
  }
  func write(_ path: String, _ content: String, directory: URL? = nil) throws {
    try Data(content.utf8).write(to: (directory ?? root).appendingPathComponent(path))
  }
  func create(_ branch: String = "task-one", destination: URL? = nil, base: String = "HEAD") async throws -> TaskWorkspace {
    try await git.createTaskWorkspace(name: "Test Task", repositoryID: UUID(), destination: destination ?? fixture.appendingPathComponent(branch), branch: branch, startAt: base)
  }
  func child(_ task: TaskWorkspace) async -> GitService { await GitServiceRegistry.shared.service(for: URL(fileURLWithPath: task.path)) }
  func rejected(_ action: () async throws -> Void) async {
    do { try await action(); XCTFail("Operation should have been refused") } catch {}
  }
  func testCreateCapturesBaselineIdentityAndNoMainIndexChanges() async throws {
    try write("file.txt", "staged\n"); try await raw(["add", "file.txt"]); try write("file.txt", "unstaged\n")
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    let task = try await create()
    XCTAssertTrue(task.binding.managed); XCTAssertNotNil(task.binding.ownership.creationID)
    XCTAssertEqual(task.branch, "refs/heads/task-one"); XCTAssertEqual(task.repositoryRoot, root.path)
    let state = try await child(task).taskWorkspaceSnapshot(task)
    XCTAssertEqual(state.head, task.baseCommit); XCTAssertFalse(state.hasChanges)
    XCTAssertTrue(state.status.files.isEmpty); XCTAssertNil(task.agent)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
  }
  func testBranchPathAndBaselineConflictsPreserveExistingFiles() async throws {
    let task = try await create()
    await rejected { _ = try await self.create("task-one", destination: self.fixture.appendingPathComponent("other")) }
    await rejected { _ = try await self.create("new-branch", destination: URL(fileURLWithPath: task.path)) }
    await rejected { _ = try await self.create("--bad") }
    await rejected { _ = try await self.create("missing-base", base: String(repeating: "a", count: 40)) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: task.path + "/file.txt"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("missing-base").path))
  }
  func testNestedAndSymlinkDestinationsAreRejected() async throws {
    await rejected { _ = try await self.create("nested", destination: self.root.appendingPathComponent("nested")) }
    let link = fixture.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture)
    await rejected { _ = try await self.create("linked", destination: link.appendingPathComponent("linked")) }
  }
  func testSystemTemporaryAliasAndRepeatedSeparatorsAreAccepted() async throws {
    let path = fixture.path.replacingOccurrences(of: "/private/var/", with: "/var/") + "//alias-task"
    let task = try await create("alias-task", destination: URL(fileURLWithPath: path))
    _ = try await child(task).validateTaskWorkspace(task)
  }
  func testInvalidNameDoesNotCreateWorktree() async throws {
    await rejected { _ = try await self.git.createTaskWorkspace(name: "  ", repositoryID: UUID(), destination: self.fixture.appendingPathComponent("invalid"), branch: "invalid") }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("invalid").path))
  }
  func testUnfinishedOperationBlocksCreation() async throws {
    let head = try await git.resolveCommit("HEAD")
    try write(".git/MERGE_HEAD", head + "\n")
    await rejected { _ = try await self.create() }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("task-one").path))
  }
  func testConcurrentTasksHaveIndependentBranchesAndDirectories() async throws {
    let service = git!, firstPath = fixture.appendingPathComponent("first"), secondPath = fixture.appendingPathComponent("second")
    async let first = service.createTaskWorkspace(name: "First", repositoryID: UUID(), destination: firstPath, branch: "first")
    async let second = service.createTaskWorkspace(name: "Second", repositoryID: UUID(), destination: secondPath, branch: "second")
    let tasks = try await [first, second]
    XCTAssertNotEqual(tasks[0].id, tasks[1].id); XCTAssertNotEqual(tasks[0].path, tasks[1].path)
    XCTAssertEqual(tasks[0].commonDirectory, tasks[1].commonDirectory)
    for task in tasks { _ = try await child(task).validateTaskWorkspace(task) }
  }
  func testExternalAssociationDoesNotGrantManagedOwnership() async throws {
    let path = fixture.appendingPathComponent("external")
    try await raw(["worktree", "add", "-b", "external", path.path])
    let tree = try await git.worktrees(includeStatus: false).first { $0.path == path.path }!
    let task = try await git.associateTaskWorkspace(name: "External", repositoryID: UUID(), worktree: tree)
    XCTAssertFalse(task.binding.managed); XCTAssertNil(task.binding.ownership.creationID)
    await rejected { _ = try await self.git.reviewWorktreeRemoval(tree, ownership: task.binding.ownership) }
    _ = try await child(task).validateTaskWorkspace(task)
  }
  func testMarkerAloneDoesNotGrantManagedOwnership() async throws {
    let owned = try await create()
    let tree = try await git.worktrees(includeStatus: false).first { $0.path == owned.path }!
    let external = try await git.associateTaskWorkspace(name: "Associated", repositoryID: UUID(), worktree: tree)
    XCTAssertFalse(external.binding.managed)
    let managed = try await git.associateTaskWorkspace(name: "Managed", repositoryID: UUID(), worktree: tree, receipt: owned.binding.ownership)
    XCTAssertTrue(managed.binding.managed)
  }
  func testReviewIncludesAgentCommitsIndexWorktreeUntrackedAndDeletion() async throws {
    let task = try await create(), directory = URL(fileURLWithPath: task.path)
    try write("file.txt", "committed\ntwo\n", directory: directory)
    try await raw(["add", "file.txt"], directory: directory); try await raw(["commit", "-m", "Agent local commit"], directory: directory)
    try write("file.txt", "staged\ntwo\n", directory: directory); try await raw(["add", "file.txt"], directory: directory)
    try write("file.txt", "staged\nunstaged\n", directory: directory); try write("new.txt", "new\n", directory: directory)
    let index = try Data(contentsOf: URL(fileURLWithPath: task.binding.ownership.gitDirectory).appendingPathComponent("index"))
    let state = try await child(task).taskWorkspaceSnapshot(task)
    XCTAssertEqual(state.comparison.rightOnlyCount, 1)
    XCTAssertEqual(state.comparison.rightOnly.first?.subject, "Agent local commit")
    XCTAssertEqual(state.comparison.files.map(\.path), ["file.txt"])
    XCTAssertEqual(state.status.staged.count, 1); XCTAssertEqual(state.status.untracked.count, 1)
    XCTAssertTrue(state.status.files.first { $0.path == "file.txt" }!.isPartial)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: task.binding.ownership.gitDirectory).appendingPathComponent("index")), index)
    try FileManager.default.removeItem(at: directory.appendingPathComponent("file.txt"))
    let deleted = try await child(task).taskWorkspaceSnapshot(task)
    XCTAssertEqual(deleted.status.files.first { $0.path == "file.txt" }?.worktree, "D")
  }
  func testMissingMovedAndReplacedDirectoryAreUnavailable() async throws {
    let task = try await create(), destination = fixture.appendingPathComponent("moved")
    try FileManager.default.moveItem(atPath: task.path, toPath: destination.path)
    await rejected { _ = try await self.child(task).validateTaskWorkspace(task) }
    try FileManager.default.createDirectory(atPath: task.path, withIntermediateDirectories: false)
    await rejected { _ = try await self.child(task).validateTaskWorkspace(task) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("file.txt").path))
  }
  func testBranchSwitchAndMarkerReplacementInvalidateTask() async throws {
    let task = try await create(), directory = URL(fileURLWithPath: task.path)
    try await raw(["checkout", "-b", "other"], directory: directory)
    await rejected { _ = try await self.child(task).validateTaskWorkspace(task) }
    try await raw(["checkout", "task-one"], directory: directory)
    try Data(UUID().uuidString.utf8).write(to: URL(fileURLWithPath: task.binding.ownership.gitDirectory).appendingPathComponent("gitpier-creation-id"))
    await rejected { _ = try await self.child(task).validateTaskWorkspace(task) }
  }
  func testArchiveAndReopenAreMetadataOnly() async throws {
    var task = try await create()
    try write("new.txt", "preserve", directory: URL(fileURLWithPath: task.path))
    try task.setArchived(true); XCTAssertTrue(task.archived); XCTAssertEqual(task.status, .archived)
    try task.setArchived(false); XCTAssertEqual(task.status, .ready)
    XCTAssertTrue(FileManager.default.fileExists(atPath: task.path + "/new.txt"))
  }
  func testActiveSessionBlocksArchiveAndRecoveryNeverResumes() async throws {
    var task = try await create()
    task.agent = TaskAgentSession(taskID: task.id, executablePath: "/usr/bin/fixture", executableVersion: "codex-cli 1.0.0")
    task.status = .running
    XCTAssertThrowsError(try task.setArchived(true))
    let store = TaskWorkspaceStore(root: fixture.appendingPathComponent("tasks"))
    try await store.save(task)
    let recovered = try await store.recover()
    XCTAssertEqual(recovered[0].status, .interrupted); XCTAssertEqual(recovered[0].agent?.state, .interrupted)
    XCTAssertNotNil(recovered[0].agent?.endedAt)
    let again = try await store.recover(); XCTAssertEqual(again, recovered)
    XCTAssertTrue(FileManager.default.fileExists(atPath: task.path + "/file.txt"))
  }
  func testStorePermissionsRoundTripAndStaleUpdate() async throws {
    let task = try await create(), path = fixture.appendingPathComponent("tasks")
    let store = TaskWorkspaceStore(root: path); try await store.save(task)
    let records = try await store.records(); XCTAssertEqual(records, [task])
    for (url, mode) in [(path, 0o700), (path.appendingPathComponent(task.id.uuidString + ".json"), 0o600)] {
      XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue & 0o777, mode)
    }
    var archived = task; try archived.setArchived(true); try await store.save(archived, replacing: task)
    await rejected { try await store.save(task, replacing: task) }
    let current = try await store.records(); XCTAssertEqual(current, [archived])
  }
  func testStoreCorruptionAndFutureVersionPreserveOriginalBytes() async throws {
    let task = try await create(), path = fixture.appendingPathComponent("tasks")
    let store = TaskWorkspaceStore(root: path); try await store.save(task)
    let file = path.appendingPathComponent(task.id.uuidString + ".json")
    let original = try Data(contentsOf: file)
    for bytes in [Data("{broken".utf8), Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "\"version\":1", with: "\"version\":999").utf8)] {
      try bytes.write(to: file)
      await rejected { _ = try await store.recover() }
      await rejected { try await store.save(task, replacing: task) }
      XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
  }
  func testStoreSymlinkAndDuplicatePathAreRefused() async throws {
    let task = try await create(), path = fixture.appendingPathComponent("tasks")
    let store = TaskWorkspaceStore(root: path); try await store.save(task)
    let other = try TaskWorkspace(name: "Duplicate", repositoryID: UUID(), repositoryRoot: task.repositoryRoot,
      binding: task.binding, branch: task.branch, baseCommit: task.baseCommit)
    await rejected { try await store.save(other) }
    let file = path.appendingPathComponent(task.id.uuidString + ".json"), original = try Data(contentsOf: file)
    let saved = fixture.appendingPathComponent("saved.json"); try FileManager.default.moveItem(at: file, to: saved)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: saved)
    await rejected { _ = try await store.records() }; await rejected { try await store.save(task) }
    XCTAssertEqual(try Data(contentsOf: saved), original)
  }
  func testVersionZeroMigratesOnlyOnExplicitSave() async throws {
    let task = try await create(), path = fixture.appendingPathComponent("tasks")
    let store = TaskWorkspaceStore(root: path); try await store.save(task)
    let file = path.appendingPathComponent(task.id.uuidString + ".json")
    let versionZero = String(decoding: try Data(contentsOf: file), as: UTF8.self).replacingOccurrences(of: "\"version\":1", with: "\"version\":0")
    try Data(versionZero.utf8).write(to: file)
    let loaded = try await store.records(); XCTAssertEqual(loaded, [task])
    XCTAssertEqual(try Data(contentsOf: file), Data(versionZero.utf8))
    try await store.save(task, replacing: task)
    XCTAssertTrue(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("\"version\":1"))
  }
  func testMovedTaskRebindsOnlyAfterNormalRepairAndKeepsOwnership() async throws {
    let task = try await create(), moved = fixture.appendingPathComponent("moved")
    try FileManager.default.moveItem(atPath: task.path, toPath: moved.path)
    let review = try await git.reviewWorktreeRepair(at: moved)
    let ownership = try await git.repairWorktree(review)
    let service = await GitServiceRegistry.shared.service(for: moved)
    let repaired = try await service.relocateTaskWorkspace(task, ownership: ownership)
    XCTAssertEqual(repaired.id, task.id); XCTAssertEqual(repaired.baseCommit, task.baseCommit)
    XCTAssertEqual(repaired.binding.directoryIdentity, task.binding.directoryIdentity)
    XCTAssertTrue(repaired.binding.managed); XCTAssertEqual(repaired.path, ownership.path)
    _ = try await service.validateTaskWorkspace(repaired)
    let replacement = try await create("replacement")
    await rejected { _ = try await self.child(replacement).relocateTaskWorkspace(task, ownership: replacement.binding.ownership) }
  }
  func testOtherRepositoryCannotSupplyTaskIdentity() async throws {
    let first = try await create(), second = try await create("second")
    await rejected { _ = try await self.child(second).validateTaskWorkspace(first) }
    await rejected { _ = try await self.git.validateTaskWorkspace(first) }
  }
  func testConflictSnapshotDoesNotHideIndexStages() async throws {
    let task = try await create(), directory = URL(fileURLWithPath: task.path)
    try await raw(["checkout", "-b", "conflict-peer"], directory: directory)
    try write("file.txt", "peer\n", directory: directory)
    try await raw(["add", "file.txt"], directory: directory); try await raw(["commit", "-m", "peer"], directory: directory)
    try await raw(["checkout", "task-one"], directory: directory)
    try write("file.txt", "task\n", directory: directory)
    try await raw(["add", "file.txt"], directory: directory); try await raw(["commit", "-m", "task"], directory: directory)
    let merge = try await ProcessRunner().run(executable: "/usr/bin/git", arguments: ["merge", "conflict-peer"], directory: directory,
      environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
    XCTAssertEqual(merge.code, 1)
    let before = try Data(contentsOf: URL(fileURLWithPath: task.binding.ownership.gitDirectory).appendingPathComponent("index"))
    let snapshot = try await child(task).taskWorkspaceSnapshot(task)
    XCTAssertEqual(snapshot.status.operation, .merge); XCTAssertTrue(snapshot.status.files.contains(where: \.isConflicted))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: task.binding.ownership.gitDirectory).appendingPathComponent("index")), before)
  }
  func testStoreRejectsHardlinksUnsafePermissionsAndOversizedRecords() async throws {
    let task = try await create(), path = fixture.appendingPathComponent("tasks")
    let store = TaskWorkspaceStore(root: path); try await store.save(task)
    let file = path.appendingPathComponent(task.id.uuidString + ".json"), bytes = try Data(contentsOf: file)
    XCTAssertEqual(chmod(file.path, 0o644), 0)
    await rejected { _ = try await store.records() }
    XCTAssertEqual(chmod(file.path, 0o600), 0)
    let linked = fixture.appendingPathComponent("linked.json")
    try FileManager.default.linkItem(at: file, to: linked)
    await rejected { _ = try await store.records() }
    XCTAssertEqual(try Data(contentsOf: linked), bytes)
    try FileManager.default.removeItem(at: linked)
    try Data(repeating: 32, count: 131073).write(to: file)
    await rejected { _ = try await store.records() }
    XCTAssertEqual(try Data(contentsOf: file).count, 131073)
  }
  func testRecordLimitFailsWithoutDeletingRecords() async throws {
    let path = fixture.appendingPathComponent("full-tasks")
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    for _ in 0...TaskWorkspaceStore.maximumRecords {
      let file = path.appendingPathComponent(UUID().uuidString + ".json")
      try Data("{}".utf8).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    let store = TaskWorkspaceStore(root: path)
    do { _ = try await store.records(); XCTFail("Record capacity should reject") }
    catch TaskWorkspaceError.capacity {}
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path.path).filter { $0.hasSuffix(".json") }.count, TaskWorkspaceStore.maximumRecords + 1)
  }
  func testReviewFingerprintChangesForSameStatusContentIndexAndHEAD() async throws {
    let task = try await create(), directory = URL(fileURLWithPath: task.path), service = await child(task)
    try write("file.txt", "first unstaged\n", directory: directory)
    let first = try await service.taskWorkspaceReview(task)
    let status = try await service.status(localOnly: true)
    try write("file.txt", "other unstaged\n", directory: directory)
    let second = try await service.taskWorkspaceReview(task)
    let unchangedStatus = try await service.status(localOnly: true)
    XCTAssertEqual(status, unchangedStatus); XCTAssertNotEqual(first.fingerprint, second.fingerprint)
    try await raw(["add", "file.txt"], directory: directory)
    let staged = try await service.taskWorkspaceReview(task)
    XCTAssertNotEqual(staged.fingerprint, second.fingerprint)
    try await raw(["commit", "-m", "review fingerprint"], directory: directory)
    let committed = try await service.taskWorkspaceReview(task)
    XCTAssertNotEqual(committed.head, first.head); XCTAssertNotEqual(committed.fingerprint, staged.fingerprint)
    var reviewed = task; reviewed.review = committed; reviewed.status = .reviewed
    let store = TaskWorkspaceStore(root: fixture.appendingPathComponent("tasks")); try await store.save(reviewed)
    let restored = try await store.records(); XCTAssertEqual(restored.first?.review, committed)
  }
  func testRemovalRefusesRecreatedDirectoryWithIdenticalGitPointerAndFiles() async throws {
    let task = try await create(), tree = try await git.worktrees(includeStatus: false).first { $0.path == task.path }!
    let review = try await git.reviewWorktreeRemoval(tree, ownership: task.binding.ownership)
    let saved = fixture.appendingPathComponent("saved-original")
    try FileManager.default.moveItem(atPath: task.path, toPath: saved.path)
    try FileManager.default.createDirectory(atPath: task.path, withIntermediateDirectories: false)
    for file in try FileManager.default.contentsOfDirectory(atPath: saved.path) {
      try FileManager.default.copyItem(atPath: saved.appendingPathComponent(file).path, toPath: task.path + "/" + file)
    }
    await rejected { try await self.git.removeWorktree(review) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: task.path + "/file.txt"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: saved.appendingPathComponent("file.txt").path))
  }
  func testDirtySubmoduleCannotProduceAReviewReceipt() async throws {
    let module = fixture.appendingPathComponent("module")
    try FileManager.default.createDirectory(at: module, withIntermediateDirectories: false)
    try await raw(["init", "-b", "main"], directory: module)
    try await raw(["config", "user.name", "Task Tests"], directory: module)
    try await raw(["config", "user.email", "tasks@example.invalid"], directory: module)
    try await raw(["config", "commit.gpgsign", "false"], directory: module)
    try write("nested.txt", "original\n", directory: module)
    try await raw(["add", "nested.txt"], directory: module)
    try await raw(["commit", "-m", "module"], directory: module)
    let task = try await create(), directory = URL(fileURLWithPath: task.path), service = await child(task)
    try await raw(["-c", "protocol.file.allow=always", "submodule", "add", "--", module.path, "nested"], directory: directory)
    try await raw(["commit", "-m", "add submodule"], directory: directory)
    _ = try await service.taskWorkspaceReview(task)
    try write("nested.txt", "first dirty\n", directory: directory.appendingPathComponent("nested"))
    let first = try await service.status(localOnly: true)
    await rejected { _ = try await service.taskWorkspaceReview(task) }
    try write("nested.txt", "other dirty\n", directory: directory.appendingPathComponent("nested"))
    let second = try await service.status(localOnly: true)
    XCTAssertEqual(first, second)
    await rejected { _ = try await service.taskWorkspaceReview(task) }
  }
  func testStoreLifetimeLeasePreventsSecondOwnerFromRecoveringLiveMetadata() async throws {
    var task = try await create()
    task.agent = TaskAgentSession(taskID: task.id, executablePath: "/bin/echo", executableVersion: "codex-cli 1.0.0")
    task.agent?.state = .running; task.status = .running
    let path = fixture.appendingPathComponent("tasks")
    var owner: TaskWorkspaceStore? = TaskWorkspaceStore(root: path)
    try await owner!.save(task)
    let second = TaskWorkspaceStore(root: path)
    do { _ = try await second.recover(); XCTFail("Second owner must not recover a live session") }
    catch TaskWorkspaceError.inUse {}
    let current = try await owner!.records(); XCTAssertEqual(current, [task])
    owner = nil
    let recovered = try await second.recover()
    XCTAssertEqual(recovered.first?.agent?.state, .interrupted)
  }
  func testMultipleRepositoriesRemainIndependentAndInvalidRepositoryCreatesNothing() async throws {
    let first = try await create("shared-name"), other = fixture.appendingPathComponent("other-repository")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
    let service = GitService(root: other)
    await rejected { _ = try await service.createTaskWorkspace(name: "Invalid", repositoryID: UUID(), destination: self.fixture.appendingPathComponent("invalid-task"), branch: "invalid-task") }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("invalid-task").path))
    try await raw(["init", "-b", "main"], directory: other)
    try await raw(["config", "user.name", "Task Tests"], directory: other)
    try await raw(["config", "user.email", "tasks@example.invalid"], directory: other)
    try await raw(["config", "commit.gpgsign", "false"], directory: other)
    try await raw(["commit", "--allow-empty", "-m", "other repository"], directory: other)
    let second = try await service.createTaskWorkspace(name: "Other", repositoryID: UUID(), destination: fixture.appendingPathComponent("other-task"), branch: "shared-name")
    XCTAssertEqual(first.branch, second.branch); XCTAssertNotEqual(first.commonDirectory, second.commonDirectory)
    XCTAssertNotEqual(first.repositoryID, second.repositoryID); XCTAssertNotEqual(first.repositoryRoot, second.repositoryRoot)
    let store = TaskWorkspaceStore(root: fixture.appendingPathComponent("tasks"))
    try await store.save(first); try await store.save(second)
    let records = try await store.records(); XCTAssertEqual(Set(records.map(\.id)), [first.id, second.id])
    _ = try await child(first).taskWorkspaceSnapshot(first)
    _ = try await child(second).taskWorkspaceSnapshot(second)
  }
}
