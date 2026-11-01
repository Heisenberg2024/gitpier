import XCTest

@testable import GitPierCore

extension GitServiceTests {
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
