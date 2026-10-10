import XCTest

@testable import GitPierCore

final class GitServiceTests: XCTestCase {
  var directory: URL!
  var git: GitService!
  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "GitPier-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    git = GitService(root: directory)
    _ = try await raw(["init", "-b", "main"])
    _ = try await raw(["config", "user.name", "GitPier Tests"])
    _ = try await raw(["config", "user.email", "tests@example.invalid"])
    _ = try await raw(["config", "commit.gpgsign", "false"])
    _ = try await raw([
      "config", "core.hooksPath", directory.appendingPathComponent(".git/hooks").path,
    ])
  }
  override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }
  @discardableResult func raw(_ args: [String], input: Data? = nil) async throws -> CommandResult {
    let result = try await ProcessRunner().run(
      executable: "/usr/bin/git", arguments: args, directory: directory,
      environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"], input: input)
    guard result.code == 0 else {
      throw GitPierError.command("test git", result.code, result.errorText)
    }
    return result
  }
  func write(_ path: String, _ contents: String) throws {
    let url = directory.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
  }
  func seed() async throws {
    try write("first.txt", "one\ntwo\nthree\n")
    try write("second.txt", "other\n")
    _ = try await raw(["add", "--", "first.txt", "second.txt"])
    _ = try await raw(["commit", "-m", "seed"])
  }
  func testUntrackedStagedAndUnbornUnstage() async throws {
    try write("中文 空格\n特殊.txt", "new")
    let status = try await git.status()
    XCTAssertEqual(status.untracked.count, 1)
    try await git.stage(status.files)
    let staged = try await git.status()
    XCTAssertEqual(staged.staged.count, 1)
    XCTAssertEqual(staged.untracked.count, 0)
    try await git.unstage(staged.files)
    let result = try await git.status()
    XCTAssertEqual(result.untracked.count, 1)
  }
  func testPreciseCommitPreservesUnselectedAndPartialContent() async throws {
    try await seed()
    try write("first.txt", "ONE\ntwo\nthree\n")
    let s = try await git.status()
    try await git.stage(s.files)
    try write("first.txt", "ONE\ntwo\nTHREE\n")
    try write("second.txt", "do not commit\n")
    let partial = try await git.status()
    XCTAssertTrue(partial.files.first { $0.path == "first.txt" }!.isPartial)
    let snapshot = try await git.snapshot()
    let commit = try await git.commit(message: "fix: partial", expected: snapshot)
    XCTAssertFalse(commit.hash.isEmpty)
    let content = try await raw(["show", "HEAD:first.txt"]).text
    XCTAssertEqual(content, "ONE\ntwo\nthree\n")
    let other = try await raw(["show", "HEAD:second.txt"]).text
    XCTAssertEqual(other, "other\n")
    let remaining = try await git.status()
    XCTAssertEqual(remaining.files.count, 2)
    XCTAssertEqual(remaining.staged.count, 0)
  }
  func testExternalIndexChangeBlocksCommit() async throws {
    try await seed()
    try write("first.txt", "one changed")
    try await git.stage(try await git.status().files)
    let expected = try await git.snapshot()
    try write("second.txt", "external")
    try await raw(["add", "--", "second.txt"])
    do {
      _ = try await git.commit(message: "fix: stale", expected: expected)
      XCTFail("Must reject stale Index")
    } catch GitPierError.indexChanged {}
    let head = try await raw(["log", "-1", "--format=%s"]).text
    XCTAssertEqual(head.trimmingCharacters(in: .whitespacesAndNewlines), "seed")
  }
  func testHookFailureLeavesIndexAndHeadIntact() async throws {
    try await seed()
    try write("first.txt", "new")
    try await git.stage(try await git.status().files)
    let expected = try await git.snapshot()
    let hook = directory.appendingPathComponent(".git/hooks/pre-commit")
    try "#!/bin/sh\necho 'intentional hook failure' >&2\nexit 1\n".write(
      to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    do {
      _ = try await git.commit(message: "fix: hook", expected: expected)
      XCTFail("Hook must fail")
    } catch { XCTAssertTrue(error.localizedDescription.contains("intentional hook failure")) }
    let after = try await git.snapshot()
    XCTAssertEqual(after.identity, expected.identity)
  }
  func testHookStagingUnreviewedContentIsBlocked() async throws {
    try await seed()
    try write("first.txt", "selected")
    try await git.stage(try await git.status().files)
    try write("second.txt", "unselected")
    let expected = try await git.snapshot()
    let hook = directory.appendingPathComponent(".git/hooks/pre-commit")
    try "#!/bin/sh\ngit add -- second.txt\n".write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    do {
      _ = try await git.commit(message: "fix: guarded", expected: expected)
      XCTFail("Hook tree change must be blocked")
    } catch { XCTAssertTrue(error.localizedDescription.contains("hook changed")) }
    let after = try await git.snapshot()
    XCTAssertEqual(after.identity, expected.identity)
  }
  func testIgnoredRenameDeletionAndLiteralPaths() async throws {
    try await seed()
    try write(".gitignore", "ignored.txt\n")
    try write("ignored.txt", "secret")
    try FileManager.default.moveItem(
      at: directory.appendingPathComponent("first.txt"),
      to: directory.appendingPathComponent("renamed 中文.txt"))
    try await raw(["add", "--", "first.txt", "renamed 中文.txt"])
    try FileManager.default.removeItem(at: directory.appendingPathComponent("second.txt"))
    try write(":(glob)*.txt", "literal")
    var status = try await git.status()
    XCTAssertFalse(status.files.contains { $0.path == "ignored.txt" })
    XCTAssertTrue(status.files.contains { $0.kind == .renamed && $0.originalPath == "first.txt" })
    XCTAssertTrue(status.files.contains { $0.kind == .deleted })
    let literal = status.files.first { $0.path == ":(glob)*.txt" }!
    try await git.stage([literal])
    status = try await git.status()
    XCTAssertTrue(status.files.first { $0.path == literal.path }!.isStaged)
    XCTAssertFalse(status.files.first { $0.path == "second.txt" }!.isStaged)
  }
  func testHunkStageAndUnstage() async throws {
    try write("long.txt", (1...50).map { "line \($0)" }.joined(separator: "\n") + "\n")
    try await raw(["add", "--", "long.txt"])
    try await raw(["commit", "-m", "seed"])
    try write(
      "long.txt",
      (1...50).map { $0 == 3 ? "first change" : $0 == 45 ? "second change" : "line \($0)" }.joined(
        separator: "\n") + "\n")
    let file = try await git.status().files[0]
    let diff = DiffParser.parse(try await git.patch(for: file, comparison: .unstaged))
    XCTAssertEqual(diff.hunks.count, 2)
    try await git.applyHunk(diff.hunks[0].patch, reverse: false, toIndex: true)
    let snapshot = try await git.snapshot()
    let content = try await raw(["show", ":long.txt"]).text
    XCTAssertTrue(content.contains("first change"))
    XCTAssertFalse(content.contains("second change"))
    let stagedDiff = DiffParser.parse(
      try await git.patch(for: try await git.status().files[0], comparison: .staged))
    try await git.applyHunk(
      stagedDiff.hunks[0].patch, reverse: true, toIndex: true, expected: snapshot)
    let after = try await git.snapshot()
    XCTAssertTrue(after.paths.isEmpty)
  }
  func testWorktreeMetadataAndIndependentState() async throws {
    try await seed()
    let worktree = directory.appendingPathComponent("linked")
    try await raw(["worktree", "add", "-b", "feature", worktree.path])
    let other = GitService(root: worktree)
    let root = try await other.validate()
    XCTAssertEqual(root.path, worktree.path)
    let dirs = try await other.metadataDirectories()
    XCTAssertEqual(dirs.count, 2)
    try "changed".write(
      to: worktree.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
    let linked = try await other.status()
    XCTAssertEqual(linked.branch, "feature")
    XCTAssertEqual(linked.files.count, 1)
    let primary = try await git.status()
    XCTAssertFalse(primary.files.contains { $0.path == "first.txt" })
  }
  func testHistoryBranchesStashTagsAndRemote() async throws {
    try await seed()
    try await git.createBranch("feature")
    let branches = try await git.branches()
    XCTAssertTrue(branches.contains { $0.name == "feature" })
    let history = try await git.history()
    XCTAssertEqual(history.count, 1)
    XCTAssertEqual(history[0].subject, "seed")
    let files = try await git.commitFiles(history[0].hash)
    XCTAssertEqual(files.count, 2)
    try write("first.txt", "stash")
    try await git.perform(["stash", "push", "-m", "test stash"])
    let stashes = try await git.stashes()
    XCTAssertEqual(stashes.count, 1)
    try await git.perform(["tag", "v0.1"])
    let tags = try await git.tags()
    XCTAssertEqual(tags, ["v0.1"])
    try await git.perform([
      "remote", "add", "origin", directory.appendingPathComponent("bare.git").path,
    ])
    let remotes = try await git.remotes()
    XCTAssertEqual(remotes[0].name, "origin")
  }
  func testEmptyTitleAndEmptyIndex() async throws {
    try await seed()
    let snapshot = try await git.snapshot()
    do {
      _ = try await git.commit(message: "", expected: snapshot)
      XCTFail()
    } catch {}
    do {
      _ = try await git.commit(message: "\nbody", expected: snapshot)
      XCTFail()
    } catch {}
    do {
      _ = try await git.commit(message: "fix: empty", expected: snapshot)
      XCTFail()
    } catch GitPierError.emptyIndex {}
  }
  func testConfigurationAndCredentialHostIsolation() throws {
    let store = ConfigurationStore(url: directory.appendingPathComponent("config/workspace.json"))
    var config = WorkspaceConfiguration()
    var a = RepositoryRecord(path: "/a")
    a.draft = "draft A"
    var b = RepositoryRecord(path: "/b")
    b.draft = "draft B"
    config.repositories = [a, b]
    try store.save(config)
    let restored = try store.load()
    XCTAssertEqual(restored.repositories[0].draft, "draft A")
    XCTAssertEqual(restored.repositories[1].draft, "draft B")
    let profile = CredentialProfile(name: "Account A", host: "github.com", username: "a")
    XCTAssertNil(
      AuthenticationContext.helperResponse(
        request: "protocol=https\nhost=evil.invalid\n", profile: profile, secret: "token"))
    XCTAssertTrue(
      AuthenticationContext.helperResponse(
        request: "protocol=https\nhost=github.com\n", profile: profile, secret: "token")!.contains(
          "username=a"))
    XCTAssertThrowsError(try InputValidation.remoteURL("https://user:secret@github.com/repo"))
  }
}
