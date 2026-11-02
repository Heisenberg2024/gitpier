import XCTest

@testable import GitPierCore

extension GitServiceTests {
  func testStatusAndSnapshotAvoidUnusedCommonDirectoryQueries() async throws {
    try await seed()
    try write("first.txt", "reviewed staging\n")
    try await raw(["add", "--", "first.txt"])
    let index = directory.appendingPathComponent(".git/index")
    let bytes = try Data(contentsOf: index)
    let trace = directory.appendingPathComponent(".git/status-commands")
    let wrapper = directory.appendingPathComponent(".git/status-git")
    try """
      #!/bin/sh
      printf '%s\\n' "$*" >> \(InputValidation.shellQuote(trace.path))
      exec /usr/bin/git "$@"
      """.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    let service = GitService(root: directory, gitPath: wrapper.path)
    let value = try await service.snapshot()
    let commands = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n")
    XCTAssertEqual(commands.filter { $0.contains(" status ") }.count, 2,
      "Both native porcelain observations are required for snapshot consistency")
    XCTAssertFalse(commands.contains { $0.contains("--git-common-dir") },
      "Repository status does not consume the common directory")
    XCTAssertLessThanOrEqual(commands.count, 8, "Remove unused queries, not final validation")
    XCTAssertEqual(value.paths, ["first.txt"])
    XCTAssertEqual(try Data(contentsOf: index), bytes)
  }

  func testSnapshotRejectsExternalHEADAdvanceDuringCollection() async throws {
    try await seed()
    let before = try await git.status()
    let next = try await raw(["commit-tree", "HEAD^{tree}", "-p", "HEAD"], input: Data("external\n".utf8))
      .text.trimmingCharacters(in: .newlines)
    let wrapper = try snapshotMutationWrapper("/usr/bin/git update-ref HEAD " + next + " || exit $?")
    let service = GitService(root: directory, gitPath: wrapper.path)
    do {
      _ = try await service.snapshot(status: before)
      XCTFail("Advancing HEAD while reading the private Index must invalidate review")
    } catch GitPierError.indexChanged {}
    let after = try await git.status()
    XCTAssertEqual(after.head, next)
    XCTAssertEqual(after.branch, before.branch)
  }

  func testStatusAndSnapshotKeepNewlineWorktreeIndexIsolated() async throws {
    try await seed()
    let linked = directory.deletingLastPathComponent().appendingPathComponent(
      "GitPier-linked-" + UUID().uuidString + "\npath\n")
    defer { try? FileManager.default.removeItem(at: linked) }
    try await raw(["worktree", "add", "-b", "linked-observation", linked.path])
    let service = GitService(root: linked)
    try Data("linked staging\n".utf8).write(to: linked.appendingPathComponent("first.txt"))
    try await service.perform(["add", "--", "first.txt"])
    let mainIndex = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    let state = try await service.status()
    let value = try await service.snapshot(status: state)
    XCTAssertEqual(value.branch, "linked-observation")
    XCTAssertEqual(value.paths, ["first.txt"])
    XCTAssertTrue(String(decoding: value.patch, as: UTF8.self).contains("+linked staging"))
    let main = try await git.snapshot()
    XCTAssertTrue(main.paths.isEmpty)
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), mainIndex)

    // Reusing an actor must not cache the previous worktree's metadata path.
    try await raw(["worktree", "remove", "--force", linked.path])
    try await raw(["worktree", "add", "-b", "replacement-observation", linked.path])
    let replacement = try await service.status()
    XCTAssertEqual(replacement.branch, "replacement-observation")
    XCTAssertTrue(replacement.files.isEmpty)
  }

  /// The wrapper delegates to real Git, but interleaves another client's write at a
  /// command boundary. No production test hooks or scheduling sleeps are needed.
  private func snapshotMutationWrapper(_ mutation: String) throws -> URL {
    let wrapper = directory.appendingPathComponent(".git/snapshot-git")
    let script = """
      #!/bin/sh
      case " $* " in
        *" diff --cached "*)
          if [ ! -e .git/snapshot-mutated ]; then
            : > .git/snapshot-mutated
            \(mutation)
          fi
          ;;
      esac
      exec /usr/bin/git "$@"
      """
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    return wrapper
  }

  func testSnapshotRejectsExternalIndexChangeBetweenTreeAndPatch() async throws {
    try await seed()
    try write("first.txt", "reviewed staging\n")
    try await raw(["add", "--", "first.txt"])
    let wrapper = try snapshotMutationWrapper("""
      printf 'external staging\n' > first.txt
      /usr/bin/env -u GIT_INDEX_FILE /usr/bin/git add -- first.txt || exit $?
      cp .git/index .git/external-index || exit $?
      """)
    let service = GitService(root: directory, gitPath: wrapper.path)
    do {
      _ = try await service.snapshot()
      XCTFail("An Index change during collection must require a new review")
    } catch GitPierError.indexChanged {}
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")),
      try Data(contentsOf: directory.appendingPathComponent(".git/external-index")))
    let staged = try await raw(["show", ":first.txt"]).text
    XCTAssertEqual(staged, "external staging\n")
  }

  func testSnapshotRejectsBranchChangeEvenWhenHEADCommitIsIdentical() async throws {
    try await seed()
    try await raw(["branch", "other"])
    let before = try await git.status()
    let wrapper = try snapshotMutationWrapper("/usr/bin/git symbolic-ref HEAD refs/heads/other || exit $?")
    let service = GitService(root: directory, gitPath: wrapper.path)
    do {
      _ = try await service.snapshot(status: before)
      XCTFail("A same-commit branch switch must invalidate the snapshot's branch identity")
    } catch GitPierError.indexChanged {}
    let after = try await git.status()
    XCTAssertEqual(after.head, before.head)
    XCTAssertEqual(after.branch, "other")
  }

  func testUnbornSnapshotRejectsIndexCreatedDuringCollection() async throws {
    let wrapper = try snapshotMutationWrapper("""
      printf 'new staging\n' > first.txt
      /usr/bin/env -u GIT_INDEX_FILE /usr/bin/git add -- first.txt || exit $?
      cp .git/index .git/external-index || exit $?
      """)
    let service = GitService(root: directory, gitPath: wrapper.path)
    do {
      _ = try await service.snapshot()
      XCTFail("Creating the first Index during collection must invalidate an empty-tree review")
    } catch GitPierError.indexChanged {}
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")),
      try Data(contentsOf: directory.appendingPathComponent(".git/external-index")))
    let state = try await git.status()
    XCTAssertNil(state.head)
    XCTAssertEqual(state.staged.map(\.path), ["first.txt"])
  }

  func testSnapshotOfSplitIndexPreservesPartialStagingAndLiveBytes() async throws {
    try await seed()
    try write("first.txt", "staged version\n")
    try await raw(["add", "--", "first.txt"])
    try write("first.txt", "working version\n")
    try await raw(["update-index", "--split-index"])
    let index = directory.appendingPathComponent(".git/index")
    let before = try Data(contentsOf: index)
    let value = try await git.snapshot()
    XCTAssertEqual(value.paths, ["first.txt"])
    XCTAssertTrue(String(decoding: value.patch, as: UTF8.self).contains("+staged version"))
    XCTAssertFalse(String(decoding: value.patch, as: UTF8.self).contains("+working version"))
    let treeText = try await raw(["show", value.tree + ":first.txt"]).text
    XCTAssertEqual(treeText, "staged version\n")
    XCTAssertEqual(try Data(contentsOf: index), before)
  }
}
