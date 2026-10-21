import Darwin
import XCTest
@testable import GitPierCore

extension TaskWorkspaceTests {
  // Fail after real Git has created the worktree, without touching user repositories.
  func creationService(blockMarker: Bool = false, failBefore: Bool = false, failAfter: Bool = false, cancellationSignal: URL? = nil) throws -> GitService {
    let script = fixture.appendingPathComponent("creation-git")
    let path = fixture.appendingPathComponent("partial").path
    let body = """
    #!/bin/sh
    case " $* " in
      *" worktree add "*)
        \(failBefore ? "exit 42" : "")
        /usr/bin/git "$@" || exit $?
        \(failAfter ? "exit 43" : "")
        \(cancellationSignal.map { "touch " + InputValidation.shellQuote($0.path) + "; exec /bin/sleep 30" } ?? "")
        \(blockMarker ? "mkdir \"$(/usr/bin/git -C " + InputValidation.shellQuote(path) + " rev-parse --absolute-git-dir)/gitpier-creation-id\"" : "")
        exit 0;;
    esac
    exec /usr/bin/git "$@"
    """
    try Data(body.utf8).write(to: script); XCTAssertEqual(chmod(script.path, 0o700), 0)
    return GitService(root: root, gitPath: script.path)
  }
  func testMarkerFailureReportsPartialCreationAndPreservesIndexAndFiles() async throws {
    try write("file.txt", "staged\n"); try await raw(["add", "file.txt"]); try write("file.txt", "unstaged\n")
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    let path = fixture.appendingPathComponent("partial")
    let service = try creationService(blockMarker: true)
    do {
      _ = try await service.createTaskWorkspace(name: "Partial", repositoryID: UUID(), destination: path, branch: "partial")
      XCTFail("Marker write must fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains(path.path), "A partial creation error must identify the worktree that remains on disk")
    }
    XCTAssertEqual(try String(contentsOf: path.appendingPathComponent("file.txt"), encoding: .utf8), "one\ntwo\n")
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    let branch = try await raw(["show-ref", "--verify", "refs/heads/partial"])
    XCTAssertEqual(branch.code, 0)
  }
  func testFailureBeforeGitCreationLeavesNoWorktreeOrBranch() async throws {
    let service = try creationService(failBefore: true), path = fixture.appendingPathComponent("partial")
    await rejected { _ = try await service.createTaskWorkspace(name: "Partial", repositoryID: UUID(), destination: path, branch: "partial") }
    XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    let refs = try await raw(["for-each-ref", "--format=%(refname)"])
    XCTAssertFalse(refs.text.contains("refs/heads/partial"))
  }
  func testCapturedCreationSurvivesRestartAndResumesWithOriginalIdentity() async throws {
    let metadata = fixture.appendingPathComponent("pending-tasks"), path = fixture.appendingPathComponent("partial")
    var store: TaskWorkspaceStore? = TaskWorkspaceStore(root: metadata)
    let service = try creationService(blockMarker: true)
    await rejected { _ = try await service.createTaskWorkspace(name: "Partial", repositoryID: UUID(), destination: path, branch: "partial", registration: store!) }
    let before = try await store!.pendingCreations()
    XCTAssertEqual(before.count, 1); XCTAssertNotNil(before.first?.workspace)
    let captured = try XCTUnwrap(before.first), workspace = try XCTUnwrap(captured.workspace)
    let marker = URL(fileURLWithPath: workspace.binding.ownership.gitDirectory).appendingPathComponent("gitpier-creation-id")
    // Remove only the empty fault-injection directory, not user data.
    try FileManager.default.removeItem(at: marker)
    try write("keep.txt", "untracked remains", directory: path)
    store = nil
    let reopened = TaskWorkspaceStore(root: metadata)
    let pending = try await reopened.pendingCreations(); XCTAssertEqual(pending, before)
    let recovered = try await git.resumeTaskWorkspaceCreation(captured)
    try await reopened.save(recovered)
    let records = try await reopened.records(), remaining = try await reopened.pendingCreations()
    XCTAssertEqual(records, [workspace]); XCTAssertTrue(remaining.isEmpty)
    _ = try await child(workspace).validateTaskWorkspace(workspace)
    XCTAssertEqual(try String(contentsOf: path.appendingPathComponent("keep.txt"), encoding: .utf8), "untracked remains")
  }
  func testMetadataWriteFailureRetainsRecoverableTaskAndRepeatedSaveIsSafe() async throws {
    let metadata = fixture.appendingPathComponent("pending-tasks"), store = TaskWorkspaceStore(root: metadata)
    let task = try await git.createTaskWorkspace(name: "Recover", repositoryID: UUID(), destination: fixture.appendingPathComponent("recover"), branch: "recover", registration: store)
    let blocked = metadata.appendingPathComponent(task.id.uuidString + ".json")
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
    await rejected { try await store.save(task) }
    let pending = try await store.pendingCreations(); XCTAssertEqual(pending.first?.workspace, task)
    try FileManager.default.removeItem(at: blocked)
    let recovered = try await git.resumeTaskWorkspaceCreation(try XCTUnwrap(pending.first))
    try await store.save(recovered)
    let records = try await store.records(); XCTAssertEqual(records, [task])
    await rejected { try await store.save(task) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: task.path + "/file.txt"))
  }
  func testCreationReservationRejectsDuplicatesAndUnsafeMetadataBeforeGit() async throws {
    let metadata = fixture.appendingPathComponent("pending-tasks"), store = TaskWorkspaceStore(root: metadata)
    let path = fixture.appendingPathComponent("reserved")
    let task = try await git.createTaskWorkspace(name: "Reserved", repositoryID: UUID(), destination: path, branch: "reserved", registration: store)
    await rejected { _ = try await self.git.createTaskWorkspace(name: "Duplicate", repositoryID: UUID(), destination: path, branch: "duplicate", registration: store) }
    let refs = try await raw(["for-each-ref", "--format=%(refname)"])
    XCTAssertFalse(refs.text.contains("refs/heads/duplicate"))
    let unsafe = fixture.appendingPathComponent("unsafe-metadata")
    try FileManager.default.createSymbolicLink(at: unsafe, withDestinationURL: metadata)
    let unsafeStore = TaskWorkspaceStore(root: unsafe)
    await rejected { _ = try await self.git.createTaskWorkspace(name: "Unsafe", repositoryID: UUID(), destination: self.fixture.appendingPathComponent("unsafe-task"), branch: "unsafe-task", registration: unsafeStore) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("unsafe-task").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: task.path + "/file.txt"))
  }
  func testRecoveryRejectsReplacementAndMarkerTamperingWithoutDeletingEitherTree() async throws {
    let store = TaskWorkspaceStore(root: fixture.appendingPathComponent("pending-tasks"))
    let task = try await git.createTaskWorkspace(name: "Original", repositoryID: UUID(), destination: fixture.appendingPathComponent("original"), branch: "original", registration: store)
    let creations = try await store.pendingCreations()
    let pending = try XCTUnwrap(creations.first)
    let marker = URL(fileURLWithPath: task.binding.ownership.gitDirectory).appendingPathComponent("gitpier-creation-id")
    try Data(UUID().uuidString.utf8).write(to: marker)
    await rejected { _ = try await self.git.resumeTaskWorkspaceCreation(pending) }
    let moved = fixture.appendingPathComponent("moved-original")
    try FileManager.default.moveItem(atPath: task.path, toPath: moved.path)
    try FileManager.default.createDirectory(atPath: task.path, withIntermediateDirectories: false)
    await rejected { _ = try await self.git.resumeTaskWorkspaceCreation(pending) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("file.txt").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: task.path))
  }
  func testConcurrentSameDestinationHasOneCreationAndCancellationDoesNotDeleteIt() async throws {
    let store = TaskWorkspaceStore(root: fixture.appendingPathComponent("pending-tasks")), path = fixture.appendingPathComponent("concurrent")
    let service = git!
    let works = (0..<2).map { n in Task { try await service.createTaskWorkspace(name: "Task \(n)", repositoryID: UUID(), destination: path, branch: "concurrent-\(n)", registration: store) } }
    var successes = 0
    for work in works { if case .success = await work.result { successes += 1 } }
    XCTAssertEqual(successes, 1)
    let pending = try await store.pendingCreations(); XCTAssertEqual(pending.count, 1)
    let cancelledPath = fixture.appendingPathComponent("cancelled")
    let cancelled = Task { try Task.checkCancellation(); return try await service.createTaskWorkspace(name: "Cancelled", repositoryID: UUID(), destination: cancelledPath, branch: "cancelled", registration: store) }
    cancelled.cancel(); _ = await cancelled.result
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("cancelled").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent("file.txt").path))
  }
  func testPostGitFailureRecoversAsUnownedAndForgettingPreservesEverything() async throws {
    let service = try creationService(failAfter: true), path = fixture.appendingPathComponent("partial")
    let store = TaskWorkspaceStore(root: fixture.appendingPathComponent("pending-tasks"))
    await rejected { _ = try await service.createTaskWorkspace(name: "Partial", repositoryID: UUID(), destination: path, branch: "partial", registration: store) }
    let pending = try await store.pendingCreations()
    XCTAssertEqual(pending.count, 1); XCTAssertNil(pending.first?.workspace)
    let creation = try XCTUnwrap(pending.first)
    await rejected { _ = try await self.git.resumeTaskWorkspaceCreation(creation) }
    try await store.forgetCreation(creation)
    let remaining = try await store.pendingCreations(); XCTAssertTrue(remaining.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent("file.txt").path))
    let trees = try await git.worktrees(includeStatus: false)
    let tree = try XCTUnwrap(trees.first { $0.path == path.path })
    let external = try await git.associateTaskWorkspace(name: "External", repositoryID: UUID(), worktree: tree)
    XCTAssertFalse(external.binding.managed)
  }
  func testCancellationAfterGitCreationPreservesPartialRecordBranchAndIndex() async throws {
    let signal = fixture.appendingPathComponent("git-created"), service = try creationService(cancellationSignal: signal)
    let path = fixture.appendingPathComponent("partial"), store = TaskWorkspaceStore(root: fixture.appendingPathComponent("pending-tasks"))
    let originalIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    let work = Task { try await service.createTaskWorkspace(name: "Cancelled after Git", repositoryID: UUID(), destination: path, branch: "partial", registration: store) }
    for _ in 0..<300 {
      if FileManager.default.fileExists(atPath: signal.path) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: signal.path)); work.cancel()
    if case .success = await work.result { XCTFail("Cancelled creation cannot report success") }
    let pending = try await store.pendingCreations(); XCTAssertEqual(pending.count, 1); XCTAssertNil(pending.first?.workspace)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), originalIndex)
    XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent("file.txt").path))
    let branch = try await raw(["show-ref", "--verify", "refs/heads/partial"]); XCTAssertEqual(branch.code, 0)
  }
  func testMetadataCapacityRefusesBeforeGitAndPreservesExistingRecords() async throws {
    let metadata = fixture.appendingPathComponent("full-metadata")
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    for _ in 0...TaskWorkspaceStore.maximumRecords {
      let file = metadata.appendingPathComponent(UUID().uuidString + ".json")
      try Data("{}".utf8).write(to: file); XCTAssertEqual(chmod(file.path, 0o600), 0)
    }
    let store = TaskWorkspaceStore(root: metadata), destination = fixture.appendingPathComponent("over-capacity")
    do { _ = try await git.createTaskWorkspace(name: "Capacity", repositoryID: UUID(), destination: destination, branch: "capacity", registration: store); XCTFail("No Git write after capacity failure") }
    catch TaskWorkspaceError.capacity {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: metadata.path).filter { $0.hasSuffix(".json") }.count, 513)
  }
  func testCorruptPendingCreationStopsRecoveryBeforeRewritingActiveTasks() async throws {
    let metadata = fixture.appendingPathComponent("pending-tasks")
    var task = try await create()
    task.agent = TaskAgentSession(taskID: task.id, executablePath: "/bin/echo", executableVersion: "codex-cli 1.0.0")
    task.agent?.state = .running; task.status = .running
    var owner: TaskWorkspaceStore? = TaskWorkspaceStore(root: metadata)
    try await owner!.save(task)
    let file = metadata.appendingPathComponent(task.id.uuidString + ".json"), bytes = try Data(contentsOf: file)
    let corrupt = metadata.appendingPathComponent(UUID().uuidString + ".creation")
    try Data("{}".utf8).write(to: corrupt); XCTAssertEqual(chmod(corrupt.path, 0o600), 0)
    owner = nil
    let reopened = TaskWorkspaceStore(root: metadata)
    await rejected { _ = try await reopened.recover() }
    XCTAssertEqual(try Data(contentsOf: file), bytes)
    XCTAssertEqual(try Data(contentsOf: corrupt), Data("{}".utf8))
  }
}
