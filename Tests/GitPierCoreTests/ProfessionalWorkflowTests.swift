import XCTest
@testable import GitPierCore

final class ProfessionalWorkflowTests: XCTestCase {
  var fixture: URL!
  var root: URL!
  var git: GitService!
  override func setUp() async throws {
    fixture = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-professional-" + UUID().uuidString)
    root = fixture.appendingPathComponent("main")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    git = GitService(root: root)
    try await raw(["init", "-b", "main"])
    try await raw(["config", "user.name", "Workflow Tests"])
    try await raw(["config", "user.email", "workflow@example.invalid"])
    try await raw(["config", "commit.gpgsign", "false"])
    try await raw(["config", "core.hooksPath", root.appendingPathComponent(".git/hooks").path])
    try write("file.swift", "let first = 1\nlet second = 2\n")
    try await raw(["add", "."])
    try await raw(["commit", "-m", "seed"])
  }
  override func tearDown() async throws { try? FileManager.default.removeItem(at: fixture) }
  @discardableResult func raw(_ args: [String]) async throws -> CommandResult {
    let result = try await ProcessRunner().run(executable: "/usr/bin/git", arguments: args, directory: root,
      environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
    guard result.code == 0 else { throw GitPierError.command("fixture", result.code, result.errorText) }
    return result
  }
  func write(_ path: String, _ text: String, in directory: URL? = nil) throws {
    try text.write(to: (directory ?? root).appendingPathComponent(path), atomically: true, encoding: .utf8)
  }
  func commit(_ text: String = "let first = 3\nlet second = 2\n", message: String = "change") async throws -> String {
    try write("file.swift", text); try await raw(["add", "file.swift"]); try await raw(["commit", "-m", message]); return try await git.status().head!
  }
  func rejected(_ action: () async throws -> Void, contains text: String? = nil) async {
    do { try await action(); XCTFail("Unsafe or invalid operation succeeded") }
    catch { if let text { XCTAssertTrue(error.localizedDescription.contains(text), error.localizedDescription) } }
  }
  func linked(_ path: String = "linked", branch: String = "topic") async throws -> (WorktreeOwnership, GitWorktree) {
    let owned = try await git.createWorktree(destination: fixture.appendingPathComponent(path), branch: branch, newBranch: true)
    let record = try await git.worktrees().first { $0.path == owned.path }!
    return (owned, record)
  }
  func testReflogRecoversResetCommitWithoutChangingIndexOrHEAD() async throws {
    let lost = try await commit()
    try await raw(["reset", "--hard", "HEAD~1"])
    try write("file.swift", "staged\n"); try await raw(["add", "file.swift"]); try write("file.swift", "unstaged\n")
    let before = try await git.reviewOperation()
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    let records = try await git.reflog()
    XCTAssertTrue(records.contains { $0.hash == lost })
    XCTAssertTrue(records.contains { $0.operation == "reset" })
    XCTAssertGreaterThan(records[0].date.timeIntervalSince1970, 1_000_000_000)
    try await git.recoverReflogCommit(lost, branch: "recovered")
    let recovered = try await git.resolveCommit("refs/heads/recovered")
    XCTAssertEqual(recovered, lost)
    let after = try await git.reviewOperation()
    XCTAssertEqual(before, after)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.swift"), encoding: .utf8), "unstaged\n")
  }
  func testReflogMissingObjectAndInvalidBranchDoNotWrite() async throws {
    let head = try await git.status().head!
    await rejected({ try await git.recoverReflogCommit(String(repeating: "a", count: 40), branch: "lost") }, contains: "unavailable")
    await rejected({ _ = try await git.commitDetail(String(repeating: "a", count: 40)) }, contains: "garbage collection")
    await rejected({ try await git.recoverReflogCommit(head, branch: "--bad") })
    await rejected({ try await git.recoverReflogCommit(head, branch: "main") })
    let branches = try await git.branches()
    XCTAssertEqual(branches.map(\.name), ["main"])
  }
  func testNativeReflogPaginationAndLiteralSearch() async throws {
    let head = try await git.status().head!
    let other = try await commit()
    for i in 0..<1001 { try await raw(["update-ref", "-m", "commit: [query] \(i)", "HEAD", i.isMultiple(of: 2) ? head : other]) }
    let first = try await git.reflog(count: 500)
    let second = try await git.reflog(skip: 500, count: 500)
    XCTAssertEqual(first.count, 500); XCTAssertEqual(second.count, 500)
    XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
    let filtered = try await git.reflog(count: 100, search: "[query]", operation: "commit")
    XCTAssertEqual(filtered.count, 100)
    XCTAssertTrue(filtered.allSatisfy { $0.message.contains("[query]") })
    let noMatches = try await git.reflog(search: "--not-a-command")
    XCTAssertTrue(noMatches.isEmpty)
  }
  func testBranchReflogAndUnsupportedRef() async throws {
    try await git.createBranch("topic")
    let log = try await git.reflog(reference: "refs/heads/topic")
    XCTAssertEqual(log.count, 1)
    XCTAssertTrue(log[0].selector.hasPrefix("refs/heads/topic@{"))
    await rejected({ _ = try await git.reflog(reference: "--all") })
  }
  func testWorktreeCreateExistingBranchAndRegister() async throws {
    try await git.createBranch("topic")
    try await raw(["tag", "topic"])
    let owned = try await git.createWorktree(destination: fixture.appendingPathComponent("existing"), branch: "topic")
    let records = try await git.worktrees()
    XCTAssertEqual(records.count, 2)
    XCTAssertTrue(records[0].main)
    XCTAssertEqual(records[1].branch, "refs/heads/topic")
    XCTAssertEqual(records[1].changeCount, 0)
    XCTAssertEqual(owned.commonDirectory, root.appendingPathComponent(".git").path)
  }
  func testWorktreeLockUnlockAndStaleReview() async throws {
    let (_, record) = try await linked()
    try await git.setWorktreeLock(record, locked: true, reason: "portable drive")
    let locked = try await git.worktrees()[1]
    XCTAssertTrue(locked.locked); XCTAssertEqual(locked.lockReason, "portable drive")
    await rejected({ try await git.setWorktreeLock(record, locked: false) }, contains: "changed")
    try await git.setWorktreeLock(locked, locked: false)
    let unlocked = try await git.worktrees()[1]
    XCTAssertFalse(unlocked.locked)
  }
  func testWorktreeSafeRemovalRetainsBranchAndMain() async throws {
    let (owned, record) = try await linked()
    let review = try await git.reviewWorktreeRemoval(record, ownership: owned)
    try await git.removeWorktree(review)
    XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
    let remaining = try await git.worktrees()
    XCTAssertEqual(remaining.count, 1)
    let branch = try await git.resolveCommit("refs/heads/topic")
    XCTAssertFalse(branch.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
  }
  func testWorktreeRejectsModifiedUntrackedAndIgnoredFiles() async throws {
    let (owned, record) = try await linked()
    let target = URL(fileURLWithPath: owned.path)
    try write("file.swift", "dirty\n", in: target)
    await rejected({ _ = try await git.reviewWorktreeRemoval(record, ownership: owned) }, contains: "modified")
    try write("file.swift", "let first = 1\nlet second = 2\n", in: target)
    try write("unknown.txt", "keep", in: target)
    await rejected({ _ = try await git.reviewWorktreeRemoval(record, ownership: owned) }, contains: "untracked")
    try FileManager.default.removeItem(at: target.appendingPathComponent("unknown.txt"))
    try await raw(["-C", target.path, "config", "core.excludesFile", fixture.appendingPathComponent("ignore").path])
    try "ignored.txt\n".write(to: fixture.appendingPathComponent("ignore"), atomically: true, encoding: .utf8)
    try write("ignored.txt", "keep", in: target)
    await rejected({ _ = try await git.reviewWorktreeRemoval(record, ownership: owned) }, contains: "ignored")
    XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("ignored.txt").path))
  }
  func testWorktreeRemovalRevalidatesAfterConfirmation() async throws {
    let (owned, record) = try await linked()
    let review = try await git.reviewWorktreeRemoval(record, ownership: owned)
    try write("file.swift", "external change", in: URL(fileURLWithPath: owned.path))
    await rejected({ try await git.removeWorktree(review) })
    XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))
  }
  func testWorktreeRejectsMainUnknownOwnershipAndExistingFolders() async throws {
    let (owned, record) = try await linked()
    let main = try await git.worktrees()[0]
    await rejected({ _ = try await git.reviewWorktreeRemoval(main, ownership: owned) }, contains: "main repository")
    await rejected({ _ = try await git.reviewWorktreeRemoval(record, ownership: WorktreeOwnership(path: owned.path, commonDirectory: owned.commonDirectory, gitDirectory: owned.gitDirectory + "-unknown")) })
    await rejected({ _ = try await git.createWorktree(destination: URL(fileURLWithPath: owned.path), branch: "other", newBranch: true) }, contains: "Existing")
    await rejected({ _ = try await git.createWorktree(destination: root.appendingPathComponent("nested"), branch: "other", newBranch: true) })
    let alias = root.path.replacingOccurrences(of: "/var/", with: "/private/var/") + "/nested-alias"
    await rejected({ _ = try await git.createWorktree(destination: URL(fileURLWithPath: alias), branch: "other-alias", newBranch: true) })
    await rejected({ _ = try await git.createWorktree(destination: fixture.appendingPathComponent("main-copy"), branch: "main") })
  }
  func testMissingAndPrunableWorktreeIsPreserved() async throws {
    let (owned, _) = try await linked()
    try FileManager.default.moveItem(at: URL(fileURLWithPath: owned.path), to: fixture.appendingPathComponent("moved"))
    let record = try await git.worktrees()[1]
    XCTAssertTrue(record.missing); XCTAssertTrue(record.prunable); XCTAssertNil(record.changeCount)
    XCTAssertEqual(record.path, owned.path)
    await rejected({ _ = try await git.reviewWorktreeRemoval(record, ownership: owned) })
    XCTAssertTrue(FileManager.default.fileExists(atPath: owned.gitDirectory))
  }
  func testMovedWorktreeRepairAndForeignRepositoryRefusal() async throws {
    let (owned, _) = try await linked()
    let moved = fixture.appendingPathComponent("moved")
    try FileManager.default.moveItem(at: URL(fileURLWithPath: owned.path), to: moved)
    let repaired = try await git.repairWorktree(at: moved)
    XCTAssertEqual(repaired.path, moved.path); XCTAssertEqual(repaired.gitDirectory, owned.gitDirectory)
    let list = try await git.worktrees()
    XCTAssertFalse(list[1].missing); XCTAssertEqual(list[1].path, moved.path)
    let foreign = fixture.appendingPathComponent("foreign")
    try await raw(["init", foreign.path])
    await rejected({ _ = try await git.repairWorktree(at: foreign) })
  }
  func testMultipleWorktreeIndexDraftLayoutAndConfigurationIndependence() async throws {
    let (owned, _) = try await linked()
    let linkedGit = GitService(root: URL(fileURLWithPath: owned.path))
    try write("file.swift", "main partial\n"); try await git.stage(try await git.status().files)
    try write("file.swift", "linked change\n", in: URL(fileURLWithPath: owned.path))
    let mainStatus = try await git.status(), otherStatus = try await linkedGit.status()
    XCTAssertEqual(mainStatus.staged.count, 1); XCTAssertEqual(otherStatus.staged.count, 0)
    let mainDirs = try await git.metadataDirectories(), otherDirs = try await linkedGit.metadataDirectories()
    XCTAssertNotEqual(mainDirs[0], otherDirs[0])
    let mainCommon = try await git.commonDirectory(), otherCommon = try await linkedGit.commonDirectory()
    XCTAssertEqual(mainCommon, otherCommon)
    var config = WorkspaceConfiguration()
    var a = RepositoryRecord(path: root.path), b = RepositoryRecord(path: owned.path)
    a.draft = "main draft"; b.draft = "linked draft"; b.layout.terminalHeight = 410
    config.repositories = [a, b]; config.ownedWorktrees = [owned]
    let store = ConfigurationStore(url: fixture.appendingPathComponent("workspace.json"))
    try store.save(config)
    let restored = try store.load()
    XCTAssertEqual(restored.repositories[0].draft, "main draft"); XCTAssertEqual(restored.repositories[1].draft, "linked draft")
    XCTAssertNotEqual(restored.repositories[0].id, restored.repositories[1].id)
    XCTAssertNotEqual(restored.repositories[0].layout.terminalHeight, restored.repositories[1].layout.terminalHeight)
    XCTAssertEqual(restored.ownedWorktrees, [owned])
  }
  func testCommonDirectoryConcurrentLifecycleWrites() async throws {
    let (owned, _) = try await linked()
    let other = GitService(root: URL(fileURLWithPath: owned.path))
    let primary = git!, firstPath = fixture.appendingPathComponent("first"), secondPath = fixture.appendingPathComponent("second")
    async let first = primary.createWorktree(destination: firstPath, branch: "parallel-first", newBranch: true)
    async let second = other.createWorktree(destination: secondPath, branch: "parallel-second", newBranch: true)
    let receipts = try await [first, second]
    XCTAssertEqual(receipts[0].commonDirectory, receipts[1].commonDirectory)
    let records = try await git.worktrees()
    XCTAssertEqual(records.count, 4)
  }
  func testBranchComparisonTipsMergeBaseCountsAndReadOnlyIndex() async throws {
    let base = try await git.status().head!
    try await git.createBranch("topic")
    let main = try await commit(message: "main only")
    try await git.switchBranch("topic")
    let topic = try await commit("let first = 1\nlet second = 4\n", message: "topic only")
    let before = try await git.reviewOperation()
    let direct = try await git.compareBranches(left: "refs/heads/main", right: "refs/heads/topic")
    let three = try await git.compareBranches(left: "refs/heads/main", right: "refs/heads/topic", mode: .mergeBase)
    XCTAssertEqual(direct.mergeBases, [base]); XCTAssertEqual(direct.leftOnlyCount, 1); XCTAssertEqual(direct.rightOnlyCount, 1)
    XCTAssertEqual(direct.leftOnly.map(\.hash), [main]); XCTAssertEqual(direct.rightOnly.map(\.hash), [topic])
    XCTAssertEqual(direct.diffBase, main); XCTAssertEqual(three.diffBase, base)
    let patch = try await git.commitPatch(three.rightHash, path: "file.swift", parent: three.diffBase)
    XCTAssertTrue(String(decoding: patch, as: UTF8.self).contains("+let second = 4"))
    let after = try await git.reviewOperation(); XCTAssertEqual(before, after)
  }
  func testRemoteTrackingComparisonAndNoImplicitFetch() async throws {
    let bare = fixture.appendingPathComponent("remote.git")
    try await raw(["init", "--bare", bare.path]); try await raw(["remote", "add", "origin", bare.path]); try await raw(["push", "origin", "main"])
    _ = try await commit()
    let result = try await git.compareBranches(left: "refs/heads/main", right: "refs/remotes/origin/main")
    XCTAssertEqual(result.leftOnlyCount, 1); XCTAssertEqual(result.rightOnlyCount, 0)
    let remoteTip = try await raw(["--git-dir=" + bare.path, "rev-parse", "refs/heads/main"]).text.trimmingCharacters(in: .newlines)
    XCTAssertEqual(result.rightHash, remoteTip)
    await rejected({ _ = try await git.compareBranches(left: "main", right: "--all") })
  }
  func testUnrelatedBranchesDirectComparisonAndThreePointError() async throws {
    try await raw(["checkout", "--orphan", "unrelated"]); try await raw(["commit", "-m", "orphan"])
    let result = try await git.compareBranches(left: "refs/heads/main", right: "refs/heads/unrelated")
    XCTAssertTrue(result.mergeBases.isEmpty); XCTAssertEqual(result.leftOnlyCount, 1); XCTAssertEqual(result.rightOnlyCount, 1)
    await rejected({ _ = try await git.compareBranches(left: "refs/heads/main", right: "refs/heads/unrelated", mode: .mergeBase) }, contains: "merge base")
  }
  func testFrozenComparisonCommitsAndMixedBranchTargetsProduceRealDiff() async throws {
    let base = try await git.resolveCommit("HEAD")
    let tip = try await commit(message: "snapshot comparison")
    _ = try await commit("let later = 99\n", message: "later branch tip")
    let frozen = try await git.compareBranchTargets(left: .commit(base), right: .commit(tip))
    XCTAssertEqual(frozen.leftHash, base); XCTAssertEqual(frozen.rightHash, tip)
    XCTAssertEqual(frozen.rightOnly.map(\.hash), [tip]); XCTAssertEqual(frozen.files.map(\.path), ["file.swift"])
    let patch = try await git.commitPatch(frozen.rightHash, path: "file.swift", parent: frozen.diffBase, localOnly: true)
    XCTAssertTrue(String(decoding: patch, as: UTF8.self).contains("+let first = 3"))
    let mixed = try await git.compareBranchTargets(left: .commit(tip), right: .branch("refs/heads/main"))
    XCTAssertEqual(mixed.rightOnlyCount, 1)
    await rejected({ _ = try await git.compareBranches(left: base, right: tip) }, contains: "local or remote-tracking")
    for bad in ["HEAD", String(base.prefix(8)), base + "~1", "--all", String(repeating: "z", count: 40)] {
      await rejected({ _ = try await git.compareBranchTargets(left: .commit(bad), right: .commit(tip)) }, contains: "full comparison commit")
    }
  }
  func testComparisonResolvesExactConfiguredUpstreamWithoutIndexReviewOrTagAmbiguity() async throws {
    let bare = fixture.appendingPathComponent("remote.git")
    try await raw(["init", "--bare", bare.path]); try await raw(["remote", "add", "origin", bare.path]); try await raw(["push", "-u", "origin", "main"])
    let upstream = try await git.resolveCommit("refs/remotes/origin/main")
    let head = try await commit()
    try await raw(["tag", "origin/main", head])
    try write("file.swift", "external partial\n"); try await raw(["add", "file.swift"]); try write("file.swift", "external unstaged\n")
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    let result = try await git.compareBranchTargets(left: .commit(head), right: .upstream(branch: "main", head: head, name: "origin/main"))
    XCTAssertEqual(result.rightHash, upstream); XCTAssertEqual(result.right, "refs/remotes/origin/main")
    XCTAssertEqual(result.leftOnlyCount, 1); XCTAssertEqual(result.rightOnlyCount, 0)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    await rejected({ _ = try await git.compareBranchTargets(left: .commit(head), right: .upstream(branch: "main", head: upstream, name: "origin/main")) })
    await rejected({ _ = try await git.compareBranchTargets(left: .commit(head), right: .upstream(branch: "main", head: head, name: "origin/wrong")) })
    try await raw(["config", "branch.main.remote", "."]); try await raw(["config", "branch.main.merge", "refs/heads/main"])
    let local = try await git.compareBranchTargets(left: .commit(head), right: .upstream(branch: "main", head: head, name: "main"))
    XCTAssertEqual(local.rightHash, head)
  }
  func testBlameTrackedWorkingChangesAndReadOnly() async throws {
    let seed = try await git.status().head!
    try write("file.swift", "let first = 99\nlet second = 2\n")
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    let page = try await git.blame(path: "file.swift")
    XCTAssertEqual(page.totalLines, 2); XCTAssertEqual(page.lines.count, 2)
    XCTAssertTrue(page.lines[0].uncommitted); XCTAssertEqual(page.lines[1].hash, seed)
    XCTAssertEqual(page.lines[1].author, "Workflow Tests")
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
  }
  func testBlameRenameFollowsOriginalCommitPathAndHistoricalContent() async throws {
    let seed = try await git.status().head!
    try await raw(["mv", "file.swift", "中文 renamed.swift"]); try await raw(["commit", "-m", "rename"])
    let tip = try await git.status().head!
    try write("中文 renamed.swift", "working content\n")
    let page = try await git.blame(path: "中文 renamed.swift", revision: tip)
    XCTAssertEqual(page.lines.map(\.hash), [seed, seed]); XCTAssertEqual(page.lines[0].originalPath, "file.swift")
    let commit = try await git.commitDetail(page.lines[0].hash); XCTAssertEqual(commit.hash, seed)
  }
  func testBlameLargeFilePaginationNewFileAndBinaryLimit() async throws {
    try write("large.swift", (0..<2001).map { "let line\($0) = \($0)\n" }.joined())
    try await raw(["add", "large.swift"]); try await raw(["commit", "-m", "large"])
    let first = try await git.blame(path: "large.swift"), next = try await git.blame(path: "large.swift", start: 401)
    XCTAssertEqual(first.lines.count, 400); XCTAssertEqual(next.lines.first?.line, 401); XCTAssertEqual(next.totalLines, 2001)
    try write("new.swift", "new\n")
    let new = try await git.blame(path: "new.swift"); XCTAssertTrue(new.lines.allSatisfy(\.uncommitted))
    try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary"))
    await rejected({ _ = try await git.blame(path: "binary") }, contains: "UTF-8")
    try Data(repeating: 65, count: 4 * 1024 * 1024 + 1).write(to: root.appendingPathComponent("oversized"))
    await rejected({ _ = try await git.blame(path: "oversized") }, contains: "limit")
  }
  func testBlameUnsafePathsSymlinksAndMissingRevision() async throws {
    await rejected({ _ = try await git.blame(path: "../outside") })
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("file.swift"))
    await rejected({ _ = try await git.blame(path: "link") })
    await rejected({ _ = try await git.blame(path: "file.swift", revision: String(repeating: "a", count: 40)) })
  }
  func testCancelledQueriesAndWritesCannotPublishOrMutate() async throws {
    let service = git!, cancelledPath = fixture.appendingPathComponent("cancelled")
    let task = Task { try await Task.sleep(for: .milliseconds(100)); return try await service.blame(path: "file.swift") }
    task.cancel()
    do { _ = try await task.value; XCTFail("Cancelled query completed") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
    let before = try await git.status().head!
    let write = Task { try await Task.sleep(for: .milliseconds(100)); return try await service.createWorktree(destination: cancelledPath, branch: "cancelled", newBranch: true) }
    write.cancel()
    do { _ = try await write.value; XCTFail("Cancelled write completed") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
    let after = try await git.status().head!; XCTAssertEqual(before, after)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("cancelled").path))
  }
  func testInFlightQueryCancellationTerminatesProcess() async throws {
    let script = fixture.appendingPathComponent("slow-git")
    try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let slow = GitService(root: root, gitPath: script.path)
    let began = Date()
    let query = Task { try await slow.reflog() }
    try await Task.sleep(for: .milliseconds(150))
    query.cancel()
    do { _ = try await query.value; XCTFail("In-flight query ignored cancellation") }
    catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
    XCTAssertLessThan(Date().timeIntervalSince(began), 4)
  }
  func testWorktreePathWithNewlineAndLockRemovalRefusal() async throws {
    let (owned, record) = try await linked("folder \n中文 \n")
    XCTAssertEqual(record.path, owned.path)
    let service = GitService(root: URL(fileURLWithPath: owned.path))
    let validated = try await service.validate()
    XCTAssertEqual(validated.path, owned.path)
    try await git.setWorktreeLock(record, locked: true)
    let locked = try await git.worktrees()[1]
    await rejected({ _ = try await git.reviewWorktreeRemoval(locked, ownership: owned) })
    XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))
  }
  func testRepairRefusesCopiedTreeWhileOriginalExists() async throws {
    let (owned, _) = try await linked()
    let copied = fixture.appendingPathComponent("copied")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: owned.path), to: copied)
    await rejected({ _ = try await git.repairWorktree(at: copied) }, contains: "still present")
    let records = try await git.worktrees()
    XCTAssertEqual(records.count, 2); XCTAssertEqual(records[1].path, owned.path)
  }
  func testRepairRejectsChangedRegistrationAfterReview() async throws {
    let (owned, _) = try await linked()
    let moved = fixture.appendingPathComponent("moved-reviewed")
    try FileManager.default.moveItem(at: URL(fileURLWithPath: owned.path), to: moved)
    let review = try await git.reviewWorktreeRepair(at: moved)
    let registration = URL(fileURLWithPath: owned.gitDirectory).appendingPathComponent("gitdir")
    try (fixture.appendingPathComponent("different/.git").path + "\n").write(to: registration, atomically: true, encoding: .utf8)
    await rejected({ _ = try await git.repairWorktree(review) })
    XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
  }
  func testComparisonBranchNamesRemainUnambiguousWithTagsAndRemoteRefs() async throws {
    let hash = try await git.status().head!
    try await raw(["tag", "main"])
    try await raw(["branch", "origin/main", hash])
    try await raw(["update-ref", "refs/remotes/origin/main", hash])
    let branches = try await git.branches()
    XCTAssertEqual(branches.filter { $0.name == "origin/main" }.count, 2)
    XCTAssertEqual(Set(branches.map(\.id)).count, branches.count)
    XCTAssertTrue(branches.contains { $0.name == "main" && !$0.remote })
    let comparison = try await git.compareBranches(left: "refs/heads/origin/main", right: "refs/remotes/origin/main")
    XCTAssertEqual(comparison.leftOnlyCount, 0); XCTAssertEqual(comparison.rightOnlyCount, 0)
    try await raw(["branch", "origin/tracked", hash])
    try await raw(["remote", "add", "origin", fixture.appendingPathComponent("unused.git").path])
    try await raw(["update-ref", "refs/remotes/origin/tracked", hash])
    try await git.switchBranch("origin/tracked", remote: true)
    let switched = try await git.status()
    XCTAssertEqual(switched.branch, "tracked")
    let upstream = try await raw(["rev-parse", "--symbolic-full-name", "@{upstream}"]).text.trimmingCharacters(in: .newlines)
    XCTAssertEqual(upstream, "refs/remotes/origin/tracked")
  }
  func testExternalReplacementCannotReuseGitPierRemovalOwnership() async throws {
    let (owned, _) = try await linked()
    XCTAssertNotNil(owned.creationID)
    try await raw(["worktree", "remove", owned.path])
    try await raw(["worktree", "add", owned.path, "topic"])
    let replacement = try await git.worktrees()[1]
    XCTAssertEqual(replacement.path, owned.path)
    await rejected({ _ = try await git.reviewWorktreeRemoval(replacement, ownership: owned) })
    let unknown = WorktreeOwnership(path: owned.path, commonDirectory: owned.commonDirectory, gitDirectory: owned.gitDirectory)
    await rejected({ _ = try await git.reviewWorktreeRemoval(replacement, ownership: unknown) })
    XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))
  }
  func testDetachedWorktreeRemovalRequiresRetainingReference() async throws {
    let (owned, _) = try await linked()
    let target = URL(fileURLWithPath: owned.path)
    try await raw(["-C", owned.path, "switch", "--detach"])
    try write("file.swift", "detached commit\n", in: target)
    try await raw(["-C", owned.path, "add", "file.swift"])
    try await raw(["-C", owned.path, "commit", "-m", "detached-only"])
    let record = try await git.worktrees()[1]
    XCTAssertTrue(record.branch.isEmpty)
    await rejected({ _ = try await git.reviewWorktreeRemoval(record, ownership: owned) }, contains: "recovery branch")
    try await git.recoverReflogCommit(record.head, branch: "retain-detached")
    let review = try await git.reviewWorktreeRemoval(record, ownership: owned)
    try await git.removeWorktree(review)
    let retained = try await git.resolveCommit("refs/heads/retain-detached")
    XCTAssertEqual(retained, record.head)
  }
  func testOldWorkspaceConfigurationMigrationAndQuotedPathParser() throws {
    let old = try JSONDecoder().decode(WorkspaceConfiguration.self, from: Data("{\"repositories\":[]}".utf8))
    XCTAssertTrue(old.ownedWorktrees.isEmpty)
    XCTAssertEqual(ProfessionalWorkflowParser.decodePath("\"a\\tfile\\n.swift\""), "a\tfile\n.swift")
  }
}
