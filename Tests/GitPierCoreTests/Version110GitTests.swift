import XCTest

@testable import GitPierCore

extension GitServiceTests {
  func testRemoteDeletionCannotFollowAnEditedPushURL() async throws {
    try await seed()
    let first = directory.appendingPathComponent("first.git")
    let second = directory.appendingPathComponent("second.git")
    try await raw(["init", "--bare", first.path])
    try await raw(["remote", "add", "origin", first.path])
    _ = try await git.network("push", remote: "origin", branch: "main")
    try await raw(["clone", "--bare", first.path, second.path])
    let hash = try await git.status().head!
    let review = try await git.reviewRemoteDeletion(
      remote: "origin", reference: "refs/heads/main", expectedHash: hash)
    try await raw(["remote", "set-url", "--push", "origin", second.path])
    do {
      _ = try await git.deleteRemoteReference(review)
      XCTFail("The server changed")
    } catch { XCTAssertTrue(error.localizedDescription.contains("destination changed")) }
    let remaining = try await raw(["--git-dir=" + second.path, "rev-parse", "refs/heads/main"]).text
    XCTAssertEqual(remaining.trimmingCharacters(in: .whitespacesAndNewlines), hash)
    let current = try await git.reviewRemoteDeletion(
      remote: "origin", reference: "refs/heads/main", expectedHash: hash)
    // Avoid Git's default current-branch deletion refusal in this disposable bare fixture.
    try await raw(["--git-dir=" + second.path, "config", "receive.denyDeleteCurrent", "ignore"])
    _ = try await git.deleteRemoteReference(current)
  }
  func testStaleUntrackedDiscardCannotDeleteExternallyStagedFile() async throws {
    try await seed()
    try write("new.txt", "preserve external staging\n")
    let selected = try await git.status().untracked[0]
    try await raw(["add", "new.txt"])
    do {
      try await git.discard(selected)
      XCTFail("The file is now staged")
    } catch {
      XCTAssertEqual(error.localizedDescription, GitPierError.indexChanged.localizedDescription)
    }
    XCTAssertEqual(
      try String(contentsOf: directory.appendingPathComponent("new.txt"), encoding: .utf8),
      "preserve external staging\n")
    let staged = try await raw(["show", ":new.txt"]).text
    XCTAssertEqual(staged, "preserve external staging\n")
  }
  func testConfirmedRewriteRejectsExternalHEADAndIndex() async throws {
    try await seed()
    let review = try await git.reviewOperation()
    try write("first.txt", "external staged edit\n")
    try await raw(["add", "first.txt"])
    do {
      try await git.perform(["reset", "--hard", "HEAD"], expected: review)
      XCTFail("A stale hard reset must not run")
    } catch {
      XCTAssertEqual(error.localizedDescription, GitPierError.indexChanged.localizedDescription)
    }
    let staged = try await raw(["show", ":first.txt"]).text
    XCTAssertEqual(staged, "external staged edit\n")
    let second = try await git.reviewOperation()
    try await raw(["commit", "-m", "external"])
    let before = try await git.status()
    do {
      try await git.perform(["reset", "--hard", "HEAD~1"], expected: second)
      XCTFail("External HEAD changed")
    } catch {
      XCTAssertEqual(error.localizedDescription, GitPierError.indexChanged.localizedDescription)
    }
    let after = try await git.status()
    XCTAssertEqual(after.head, before.head)
  }
  func testAbortReviewRejectsChangedOperationIdentity() async throws {
    try await seed()
    try await raw(["branch", "topic"])
    try write("first.txt", "main\n")
    try await raw(["add", "first.txt"])
    try await raw(["commit", "-m", "main"])
    try await raw(["switch", "topic"])
    try write("first.txt", "topic\n")
    try await raw(["add", "first.txt"])
    try await raw(["commit", "-m", "topic"])
    try await raw(["switch", "main"])
    do {
      try await git.perform(["merge", "topic"])
      XCTFail("Expected conflict")
    } catch {}
    let review = try await git.reviewOperation()
    let marker = directory.appendingPathComponent(".git/MERGE_HEAD")
    let original = try Data(contentsOf: marker)
    let other = try await raw(["rev-parse", "HEAD"]).stdout
    try other.write(to: marker)
    do {
      try await git.perform(["merge", "--abort"], expected: review)
      XCTFail("Changed operation must not be aborted")
    } catch {
      XCTAssertEqual(error.localizedDescription, GitPierError.indexChanged.localizedDescription)
    }
    XCTAssertEqual(try Data(contentsOf: marker), other)
    try original.write(to: marker)
    let current = try await git.reviewOperation()
    _ = try await git.perform(["merge", "--abort"], expected: current)
  }
  func testFixedForceLeaseCannotBeWeakenedByAnotherFetch() async throws {
    try await seed()
    let bare = directory.appendingPathComponent("lease.git")
    try await raw(["init", "--bare", bare.path])
    try await raw(["remote", "add", "origin", bare.path])
    _ = try await git.network("push", remote: "origin", branch: "main")
    let review = try await git.reviewForcePush(remote: "origin", branch: "main")
    let other = directory.appendingPathComponent("other")
    try await raw(["clone", bare.path, other.path])
    // The bare repository's symbolic HEAD is unrelated to this fixture's selected branch.
    try await raw(["-C", other.path, "switch", "main"])
    try await raw(["-C", other.path, "config", "user.name", "Other"])
    try await raw(["-C", other.path, "config", "user.email", "other@example.invalid"])
    try await raw(["-C", other.path, "config", "commit.gpgsign", "false"])
    try "new remote\n".write(
      to: other.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
    try await raw(["-C", other.path, "add", "first.txt"])
    try await raw(["-C", other.path, "commit", "-m", "new remote"])
    try await raw(["-C", other.path, "push", "origin", "main"])
    try await raw(["fetch", "origin"])
    let remoteHead = try await raw(["--git-dir=" + bare.path, "rev-parse", "refs/heads/main"]).text
    do {
      _ = try await git.network(
        "push", remote: "origin", branch: "main", forceWithLease: true, forceReview: review)
      XCTFail("A refreshed tracking ref must not weaken an approved lease")
    } catch {}
    let remaining = try await raw(["--git-dir=" + bare.path, "rev-parse", "refs/heads/main"]).text
    XCTAssertEqual(remaining, remoteHead)
    let reviewed = try await git.reviewForcePush(remote: "origin", branch: "main")
    _ = try await git.network(
      "push", remote: "origin", branch: "main", forceWithLease: true, forceReview: reviewed)
    let replaced = try await raw(["--git-dir=" + bare.path, "rev-parse", "refs/heads/main"]).text
    XCTAssertEqual(replaced.trimmingCharacters(in: .whitespacesAndNewlines), reviewed.localHead)
  }
  func testForceReviewRejectsChangedDestinationAndBranch() async throws {
    try await seed()
    let bare = directory.appendingPathComponent("lease.git")
    try await raw(["init", "--bare", bare.path])
    try await raw(["remote", "add", "origin", bare.path])
    _ = try await git.network("push", remote: "origin", branch: "main")
    let review = try await git.reviewForcePush(remote: "origin", branch: "main")
    try await raw([
      "remote", "set-url", "--push", "origin", directory.appendingPathComponent("changed.git").path,
    ])
    do {
      _ = try await git.network(
        "push", remote: "origin", branch: "main", forceWithLease: true, forceReview: review)
      XCTFail("Destination changed")
    } catch { XCTAssertTrue(error.localizedDescription.contains("destination changed")) }
    try await raw(["remote", "set-url", "--push", "origin", bare.path])
    let branchReview = try await git.reviewForcePush(remote: "origin", branch: "main")
    try await git.createBranch("other")
    try await git.switchBranch("other")
    do {
      _ = try await git.network(
        "push", remote: "origin", branch: "main", forceWithLease: true, forceReview: branchReview)
      XCTFail("Branch changed")
    } catch { XCTAssertTrue(error.localizedDescription.contains("branch")) }
  }
  func testClearingExplicitPushURLRestoresFallback() async throws {
    try await raw(["remote", "add", "origin", "https://example.invalid/fetch.git"])
    try await raw(["remote", "set-url", "--push", "origin", "https://example.invalid/push.git"])
    let original = try await git.remotes()[0]
    try await git.saveRemote(
      name: "origin", fetchURL: original.configuredFetchURLs[0], pushURL: "", expected: original)
    let result = try await git.remotes()[0]
    XCTAssertTrue(result.configuredPushURLs.isEmpty)
    XCTAssertEqual(result.fetchURL, result.pushURL)
  }
  func testMultipleRemoteDestinationsAndRedactedSecretsArePreserved() async throws {
    try await raw(["remote", "add", "origin", "https://user:secret@example.invalid/a.git"])
    try await raw(["remote", "set-url", "--add", "origin", "https://example.invalid/b.git"])
    try await raw([
      "remote", "set-url", "--add", "--push", "origin", "https://example.invalid/p1.git",
    ])
    try await raw([
      "remote", "set-url", "--add", "--push", "origin", "https://example.invalid/p2.git",
    ])
    let original = try await git.remotes()[0]
    XCTAssertFalse(original.configuredFetchURLs.joined().contains("secret"))
    try await git.saveRemote(
      name: "origin", fetchURL: original.configuredFetchURLs[0],
      pushURL: original.configuredPushURLs[0], expected: original)
    let rawURL = try await raw(["remote", "get-url", "origin"]).text
    XCTAssertTrue(rawURL.contains("user:secret@"))
    do {
      try await git.saveRemote(
        name: "origin", fetchURL: original.configuredFetchURLs[0], pushURL: "", expected: original)
      XCTFail("Multiple destinations must not be lost")
    } catch {}
    let unchanged = try await git.remotes()[0]
    XCTAssertEqual(unchanged.configuredPushURLs, original.configuredPushURLs)
    try await git.saveRemote(
      name: "origin", fetchURL: "https://example.invalid/new.git",
      pushURL: original.configuredPushURLs[0], expected: original)
    let changed = try await git.remotes()[0]
    XCTAssertEqual(
      changed.configuredFetchURLs,
      ["https://example.invalid/new.git", "https://example.invalid/b.git"])
  }
  func testRemoteStaleSnapshotInvalidInputAndDuplicateName() async throws {
    try await git.saveRemote(
      name: "origin", fetchURL: "https://example.invalid/a.git", pushURL: "", expected: nil)
    let original = try await git.remotes()[0]
    try await raw(["remote", "set-url", "origin", "https://example.invalid/external.git"])
    do {
      try await git.saveRemote(
        name: "origin", fetchURL: "https://example.invalid/new.git", pushURL: "", expected: original
      )
      XCTFail("Stale edit")
    } catch {}
    do {
      try await git.saveRemote(
        name: "origin", fetchURL: "https://example.invalid/new.git", pushURL: "", expected: nil)
      XCTFail("Duplicate")
    } catch {}
    do {
      try await git.saveRemote(name: "new", fetchURL: "-bad", pushURL: "", expected: nil)
      XCTFail("Invalid URL")
    } catch {}
    let remotes = try await git.remotes()
    XCTAssertEqual(remotes.count, 1)
  }
  func testStashPreviewIncludesUntrackedAndDoesNotWriteIndex() async throws {
    try await seed()
    try write("first.txt", "saved tracked\n")
    try write("new [file].swift", "let value = 1\n")
    try await git.perform(["stash", "push", "--include-untracked", "-m", "preview"])
    let stash = try await git.stashes()[0]
    let before = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    let files = try await git.stashFiles(stash)
    XCTAssertEqual(Set(files.map { $0.change.path }), ["first.txt", "new [file].swift"])
    for file in files {
      let patch = try await git.stashPatch(stash, file: file)
      XCTAssertFalse(DiffParser.parse(patch).hunks.isEmpty)
    }
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), before)
    _ = try await git.stashOperation("drop", stash: stash)
    do {
      _ = try await git.stashFiles(stash)
      XCTFail("Deleted stash")
    } catch {}
    do {
      _ = try await git.stashOperation("apply", stash: stash)
      XCTFail("Deleted stash")
    } catch {}
  }
  func testFullHistoryNativeFiltersPaginationHashAndBranchScope() async throws {
    try await seed()
    let first = try await git.history()[0]
    for index in 0..<5 {
      try write("first.txt", "\(index)\n")
      try await raw(["add", "first.txt"])
      try await raw(["commit", "-m", "query [literal] \(index)"])
    }
    var query = HistoryQuery()
    query.message = "[literal]"
    query.author = "GitPier Tests"
    let page = try await git.history(count: 2, query: query)
    let next = try await git.history(skip: 2, count: 2, query: query)
    XCTAssertEqual(page.count, 2)
    XCTAssertEqual(next.count, 2)
    XCTAssertTrue(Set(page.map(\.hash)).isDisjoint(with: next.map(\.hash)))
    query.hash = String(first.hash.prefix(8))
    query.message = ""
    let exact = try await git.history(query: query)
    XCTAssertEqual(exact.map(\.hash), [first.hash])
    try await raw(["checkout", "--orphan", "other"])
    try await raw(["commit", "-m", "other only"])
    query.hash = ""
    query.message = "query [literal]"
    let noMatches = try await git.history(query: query)
    XCTAssertTrue(noMatches.isEmpty)
    query.scope = .allReferences
    let allMatches = try await git.history(query: query)
    XCTAssertEqual(allMatches.count, 5)
    query.after = "2099-01-01"
    let futureMatches = try await git.history(query: query)
    XCTAssertTrue(futureMatches.isEmpty)
  }
}
