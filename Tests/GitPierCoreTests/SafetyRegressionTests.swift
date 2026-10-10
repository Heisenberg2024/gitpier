import XCTest

@testable import GitPierCore

extension GitServiceTests {
  func testSettingsMigrationPreservesOldValuesAndNewDefaults() throws {
    let settings = try JSONDecoder().decode(
      AppSettings.self,
      from: Data(
        "{\"appearance\":\"dark\",\"terminalFont\":\"Menlo\",\"automaticRefresh\":false}".utf8))
    XCTAssertEqual(settings.appearance, .dark)
    XCTAssertFalse(settings.automaticRefresh)
    XCTAssertEqual(settings.terminalLineSpacing, 1.1)
    XCTAssertEqual(settings.terminalCursor, "blinkBlock")
    XCTAssertFalse(settings.completionNotifications)
    let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(restored.terminalFont, "Menlo")
  }
  func testRefreshDoesNotReplaceOrModifyLiveIndex() async throws {
    try await seed()
    try write("first.txt", "stage this\n")
    try await git.stage(try await git.status().files)
    let index = directory.appendingPathComponent(".git/index")
    let before = try Data(contentsOf: index)
    _ = try await git.snapshot()
    _ = try await git.snapshot()
    XCTAssertEqual(try Data(contentsOf: index), before)
  }
  func testPartiallyStagedRenameCanStageAgain() async throws {
    try await seed()
    try await raw(["mv", "first.txt", "renamed.txt"])
    try write("renamed.txt", "updated after rename\n")
    let file = try await git.status().files.first { $0.path == "renamed.txt" }!
    XCTAssertTrue(file.isPartial)
    try await git.stage([file])
    let result = try await raw(["show", ":renamed.txt"]).text
    XCTAssertEqual(result, "updated after rename\n")
  }
  func testPostCommitHookStagingUsesLiveIndex() async throws {
    try await seed()
    try write("first.txt", "commit\n")
    try await git.stage(try await git.status().files)
    try write("second.txt", "post hook\n")
    let expected = try await git.snapshot()
    let hook = directory.appendingPathComponent(".git/hooks/post-commit")
    try "#!/bin/sh\ngit add -- second.txt\n".write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    let commit = try await git.commit(message: "fix: post hook", expected: expected)
    XCTAssertTrue(commit.indexChangedDuringCommit)
    let committed = try await raw(["show", "HEAD:second.txt"]).text
    XCTAssertEqual(committed, "other\n")
    let state = try await git.status()
    XCTAssertTrue(state.files.first { $0.path == "second.txt" }!.isStaged)
  }
  func testPreviewReadsExactHEADIndexAndWorkingContents() async throws {
    try await seed()
    try write("first.txt", "index\n")
    try await git.stage(try await git.status().files)
    try write("first.txt", "worktree\n")
    let file = try await git.status().files[0]
    let head = try await git.fileContents(file, comparison: .staged, after: false)
    let index = try await git.fileContents(file, comparison: .staged, after: true)
    let worktree = try await git.fileContents(file, comparison: .unstaged, after: true)
    XCTAssertEqual(head, Data("one\ntwo\nthree\n".utf8))
    XCTAssertEqual(index, Data("index\n".utf8))
    XCTAssertEqual(worktree, Data("worktree\n".utf8))
  }
  func testDiscardOnlyUnstagedAndSymlinkDeletionDoesNotDeleteTarget() async throws {
    try await seed()
    try write("first.txt", "index\n")
    try await git.stage(try await git.status().files)
    try write("first.txt", "worktree\n")
    let file = try await git.status().files[0]
    try await git.discard(file)
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("first.txt")), "index\n")
    let staged = try await git.status()
    XCTAssertTrue(staged.files[0].isStaged)
    let link = directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "second.txt")
    let untracked = try await git.status().files.first { $0.path == "link" }!
    try await git.discard(untracked)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("second.txt").path))
  }
  func testNonUTF8PathsFailWithoutGuessingAndHTTPProfilesRefuseSecrets() throws {
    XCTAssertThrowsError(try StatusParser.parse(Data([63, 32, 255, 0])))
    let profile = CredentialProfile(name: "HTTPS", host: "example.invalid", username: "test")
    XCTAssertNil(
      AuthenticationContext.helperResponse(
        request: "protocol=http\nhost=example.invalid\n", profile: profile, secret: "synthetic"))
    XCTAssertThrowsError(try InputValidation.repositoryPath("../outside"))
  }
  func testCherryPickRevertAndResetInIsolatedRepo() async throws {
    try await seed()
    try await git.createBranch("feature")
    try await git.switchBranch("feature")
    try write("feature.txt", "feature\n")
    try await git.stage(try await git.status().files)
    let commit = try await git.commit(message: "feat: feature", expected: git.snapshot())
    try await git.switchBranch("main")
    try await git.perform(["cherry-pick", commit.hash])
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("feature.txt").path))
    let cherry = try await raw(["rev-parse", "HEAD"]).text.trimmingCharacters(
      in: .whitespacesAndNewlines)
    try await git.perform(["revert", "--no-edit", cherry])
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("feature.txt").path))
    try await git.perform(["reset", "--soft", "HEAD~1"])
    let soft = try await git.status()
    XCTAssertTrue(soft.files.contains(where: \.isStaged))
    try await git.perform(["reset", "--mixed", "HEAD"])
    let mixed = try await git.status()
    XCTAssertEqual(mixed.staged.count, 0)
    try await git.perform(["reset", "--hard", "HEAD"])
    let hard = try await git.status()
    XCTAssertTrue(hard.files.isEmpty)
  }
  func testRebaseConflictPreservedAndAborted() async throws {
    try await seed()
    try await git.createBranch("feature")
    try await git.switchBranch("feature")
    try write("first.txt", "feature\n")
    try await git.stage(try await git.status().files)
    _ = try await git.commit(message: "feat: side", expected: git.snapshot())
    try await git.switchBranch("main")
    try write("first.txt", "main\n")
    try await git.stage(try await git.status().files)
    _ = try await git.commit(message: "fix: base", expected: git.snapshot())
    try await git.switchBranch("feature")
    do {
      try await git.perform(["rebase", "main"])
      XCTFail()
    } catch {}
    let state = try await git.status()
    XCTAssertEqual(state.operation, .rebase)
    XCTAssertTrue(state.files.contains(where: \.isConflicted))
    try await git.perform(["rebase", "--abort"])
    let after = try await git.status()
    XCTAssertNil(after.operation)
    XCTAssertEqual(after.branch, "feature")
  }
}
