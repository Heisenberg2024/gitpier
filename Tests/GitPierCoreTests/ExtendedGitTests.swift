import XCTest

@testable import GitPierCore

extension GitServiceTests {
  func testInitialCommitAndAmend() async throws {
    try write("initial.txt", "initial\n")
    try await git.stage(try await git.status().files)
    let first = try await git.commit(message: "feat: initial", expected: git.snapshot())
    try write("initial.txt", "updated\n")
    try await git.stage(try await git.status().files)
    let amended = try await git.commit(
      message: "feat: amended", expected: git.snapshot(), amend: true)
    XCTAssertNotEqual(first.hash, amended.hash)
    let history = try await git.history()
    XCTAssertEqual(history.count, 1)
    XCTAssertEqual(history[0].subject, "feat: amended")
  }
  func testCommitPushSuccessAndFailureDoNotChangeLocalCommit() async throws {
    try await seed()
    let bare = directory.appendingPathComponent("remote.git")
    try await raw(["init", "--bare", bare.path])
    try await raw(["remote", "add", "origin", bare.path])
    _ = try await git.network("push", remote: "origin", branch: "main")
    try write("first.txt", "new commit\n")
    try await git.stage(try await git.status().files)
    let commit = try await git.commit(message: "fix: push", expected: git.snapshot())
    _ = try await git.network("push")
    let remoteHash = try await raw(["--git-dir=" + bare.path, "rev-parse", "refs/heads/main"]).text
      .trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertEqual(remoteHash, commit.hash)
    try await raw([
      "remote", "set-url", "origin", directory.appendingPathComponent("missing.git").path,
    ])
    do {
      _ = try await git.network("push")
      XCTFail()
    } catch {}
    let headAfter = try await raw(["rev-parse", "HEAD"]).text.trimmingCharacters(
      in: .whitespacesAndNewlines)
    XCTAssertEqual(headAfter, commit.hash)
    let history = try await git.history()
    XCTAssertEqual(history.count, 2)
  }
  func testHEADAndBranchChangesInvalidateSnapshot() async throws {
    try await seed()
    try write("first.txt", "change\n")
    try await git.stage(try await git.status().files)
    let expected = try await git.snapshot()
    try await git.createBranch("other")
    try await git.switchBranch("other")
    do {
      _ = try await git.commit(message: "fix: stale branch", expected: expected)
      XCTFail()
    } catch GitPierError.indexChanged {}
  }
  func testFailedHunkCannotDamageWorkingFileOrIndex() async throws {
    try await seed()
    try write("first.txt", "ONE\ntwo\nthree\n")
    let file = try await git.status().files[0]
    let patch = DiffParser.parse(try await git.patch(for: file, comparison: .unstaged)).hunks[0]
      .patch
    try write("first.txt", "unrelated contents\n")
    let before = try Data(contentsOf: directory.appendingPathComponent("first.txt"))
    do {
      try await git.applyHunk(patch, reverse: true, toIndex: false)
      XCTFail()
    } catch {}
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("first.txt")), before)
    let snapshot = try await git.snapshot()
    XCTAssertTrue(snapshot.paths.isEmpty)
  }
  func testConcurrentWritesAreSerialized() async throws {
    try await seed()
    try write("first.txt", "a")
    try write("second.txt", "b")
    let files = try await git.status().files
    let service = git!
    async let a: Void = service.stage([files.first { $0.path == "first.txt" }!])
    async let b: Void = service.stage([files.first { $0.path == "second.txt" }!])
    try await a
    try await b
    let status = try await git.status()
    XCTAssertEqual(status.staged.count, 2)
  }
  func testSplitIndexCanCommitWithoutReplacement() async throws {
    try await seed()
    try await raw(["update-index", "--split-index"])
    try write("first.txt", "split changed\n")
    try await git.stage(try await git.status().files)
    let expected = try await git.snapshot()
    _ = try await git.commit(message: "fix: split index", expected: expected)
    let remaining = try await git.status()
    XCTAssertEqual(remaining.files.count, 0)
  }
  func testSymlinkAndBinaryDiff() async throws {
    try await seed()
    try FileManager.default.createSymbolicLink(
      atPath: directory.appendingPathComponent("link").path, withDestinationPath: "first.txt")
    try Data([0, 1, 2, 3, 255]).write(to: directory.appendingPathComponent("binary.bin"))
    let files = try await git.status().files
    let binary = files.first { $0.path == "binary.bin" }!
    let binaryPatch = try await git.patch(for: binary, comparison: .unstaged)
    XCTAssertTrue(DiffParser.parse(binaryPatch).binary)
    try await git.stage(files)
    let mode = try await raw(["ls-files", "--stage", "--", "link"]).text
    XCTAssertTrue(mode.hasPrefix("120000"))
  }
  func testConflictDetectionAndMergeAbort() async throws {
    try await seed()
    try await git.createBranch("feature")
    try await git.switchBranch("feature")
    try write("first.txt", "feature\n")
    try await raw(["add", "--", "first.txt"])
    try await raw(["commit", "-m", "feature"])
    try await git.switchBranch("main")
    try write("first.txt", "main\n")
    try await raw(["add", "--", "first.txt"])
    try await raw(["commit", "-m", "main"])
    do {
      try await git.perform(["merge", "--no-edit", "feature"])
      XCTFail()
    } catch {}
    let state = try await git.status()
    XCTAssertEqual(state.operation, .merge)
    XCTAssertTrue(state.files.contains(where: \.isConflicted))
    do {
      _ = try await git.snapshot()
      XCTFail()
    } catch {}
    try await git.perform(["merge", "--abort"])
    let after = try await git.status()
    XCTAssertNil(after.operation)
    XCTAssertTrue(after.files.isEmpty)
  }
  func testDirtyBranchSwitchRefusesOverwrite() async throws {
    try await seed()
    try await git.createBranch("feature")
    try await git.switchBranch("feature")
    try write("first.txt", "feature\n")
    try await raw(["add", "--", "first.txt"])
    try await raw(["commit", "-m", "feature"])
    try await git.switchBranch("main")
    try write("first.txt", "local changes\n")
    do {
      try await git.switchBranch("feature")
      XCTFail()
    } catch {}
    XCTAssertEqual(
      try String(contentsOf: directory.appendingPathComponent("first.txt")), "local changes\n")
  }
  func testSubmoduleStatusAndStagingOnlyGitlink() async throws {
    try await seed()
    let child = directory.appendingPathComponent("child-source")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    func childGit(_ args: [String]) async throws {
      let result = try await ProcessRunner().run(
        executable: "/usr/bin/git", arguments: ["-C", child.path] + args, directory: nil,
        environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
      guard result.code == 0 else {
        throw GitPierError.command("child git", result.code, result.errorText)
      }
    }
    try await childGit(["init", "-b", "main"])
    try await childGit(["config", "user.name", "Tests"])
    try await childGit(["config", "user.email", "tests@example.invalid"])
    try "child\n".write(
      to: child.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)
    try await childGit(["add", "--", "child.txt"])
    try await childGit(["commit", "-m", "child"])
    try await raw(["-c", "protocol.file.allow=always", "submodule", "add", child.path, "module"])
    try await raw(["add", "--", ".gitmodules", "module"])
    try await raw(["commit", "-m", "add submodule"])
    try "dirty\n".write(
      to: directory.appendingPathComponent("module/child.txt"), atomically: true, encoding: .utf8)
    let state = try await git.status()
    let module = state.files.first { $0.path == "module" }!
    XCTAssertTrue(module.submodule.hasPrefix("S"))
    try await git.stage([module])
    let files = try await raw(["ls-files", "--", "module/child.txt"]).text
    XCTAssertTrue(files.isEmpty)
  }
  func testCloneAndIndependentRegistry() async throws {
    try await seed()
    let destination = directory.appendingPathComponent("clone")
    try await GitService.clone(url: directory.path, destination: destination)
    let cloned = await GitServiceRegistry.shared.service(for: destination)
    let original = await GitServiceRegistry.shared.service(for: directory)
    XCTAssertFalse(cloned === original)
    let state = try await cloned.status()
    XCTAssertEqual(state.branch, "main")
    XCTAssertTrue(state.files.isEmpty)
  }
  func testHistoryPaginationAndTwoCommitDiff() async throws {
    try await seed()
    let first = try await raw(["rev-parse", "HEAD"]).text.trimmingCharacters(
      in: .whitespacesAndNewlines)
    try write("first.txt", "updated\n")
    try await git.stage(try await git.status().files)
    let second = try await git.commit(
      message: "fix: second\n\nbody with unicode 中文", expected: git.snapshot())
    let page = try await git.history(skip: 1, count: 1)
    XCTAssertEqual(page.count, 1)
    XCTAssertEqual(page[0].hash, first)
    let patch = try await git.commitPatch(second.hash, path: "first.txt", parent: first)
    XCTAssertTrue(String(decoding: patch, as: UTF8.self).contains("+updated"))
    let records = try await git.history()
    XCTAssertTrue(records[0].body.contains("中文"))
    XCTAssertEqual(CommitGraph.layout(records).count, 2)
  }
  func testKeychainRoundTripWithoutDiskSecrets() throws {
    let store = KeychainStore(service: "GitPier.acceptance." + UUID().uuidString)
    let id = UUID()
    defer { try? store.delete(id: id) }
    do {
      try store.save("synthetic-test-token", id: id)
      XCTAssertEqual(try store.read(id: id), "synthetic-test-token")
      try store.save("replacement-test-token", id: id)
      XCTAssertEqual(try store.read(id: id), "replacement-test-token")
      try store.delete(id: id)
      XCTAssertNil(try store.read(id: id))
    } catch {
      throw XCTSkip(
        "Keychain access unavailable in this execution environment: " + error.localizedDescription)
    }
    let configuration = WorkspaceConfiguration()
    let json = try JSONEncoder().encode(configuration)
    XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("synthetic-test-token"))
  }
  func testRunnerOutputLimitsAndCancellation() async throws {
    do {
      _ = try await ProcessRunner().run(
        executable: "/usr/bin/yes", arguments: ["output"], directory: nil, timeout: 0.2, limit: 1024
      )
      XCTFail()
    } catch GitPierError.timeout {}
    let task = Task {
      try await ProcessRunner().run(executable: "/bin/sleep", arguments: ["30"], directory: nil)
    }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    let start = Date()
    do {
      _ = try await task.value
      XCTFail()
    } catch is CancellationError {}
    XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    do {
      _ = try await ProcessRunner().run(
        executable: "/usr/bin/printf", arguments: [String(repeating: "a", count: 3000)],
        directory: nil, limit: 100)
      XCTFail()
    } catch GitPierError.outputLimit {}
  }
}
