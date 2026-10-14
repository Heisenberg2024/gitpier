import XCTest
@testable import GitPierCore

extension GitServiceTests {
  private func moduleOrigin() async throws -> URL {
    let source = directory.deletingLastPathComponent().appendingPathComponent("GitPier-module-origin-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: source) }
    try await raw(["init", "-b", "main", source.path])
    try await raw(["-C", source.path, "config", "user.name", "Module Tests"])
    try await raw(["-C", source.path, "config", "user.email", "module@example.invalid"])
    try await raw(["-C", source.path, "config", "commit.gpgsign", "false"])
    try "one\n".write(to: source.appendingPathComponent("content.txt"), atomically: true, encoding: .utf8)
    try await raw(["-C", source.path, "add", "--", "content.txt"])
    try await raw(["-C", source.path, "commit", "-m", "module seed"])
    return source
  }
  private func moduleFixture() async throws -> (URL, URL) {
    try await seed()
    let source = try await moduleOrigin()
    // File transport is enabled only for this isolated fixture process, never globally.
    await git.configure(gitPath: "/usr/bin/git", authArguments: ["-c", "protocol.file.allow=always"],
                        authEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
    let review = try await git.reviewSubmoduleAdd(url: source.path, path: "vendor/child")
    _ = try await git.addSubmodule(review)
    try await raw(["commit", "-m", "record child"])
    return (source, directory.appendingPathComponent("vendor/child"))
  }
  private func advanceModule(_ source: URL) async throws -> String {
    try "two\n".write(to: source.appendingPathComponent("content.txt"), atomically: true, encoding: .utf8)
    try await raw(["-C", source.path, "add", "--", "content.txt"])
    try await raw(["-C", source.path, "commit", "-m", "module next"])
    return try await raw(["-C", source.path, "rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
  }
  private func moduleRejected(_ action: () async throws -> Void) async {
    do { try await action(); XCTFail("Expected submodule rejection") } catch {}
  }
  func testSubmoduleEmptyRepositoryListIsReadOnly() async throws {
    try await seed(); let before = try await git.reviewOperation()
    let modules = try await git.submodules(); XCTAssertTrue(modules.isEmpty)
    let after = try await git.reviewOperation(); XCTAssertEqual(after, before)
  }
  func testSubmoduleAddRecordsGitlinkAndKeepsOtherPartialStaging() async throws {
    try await seed(); let source = try await moduleOrigin()
    await git.configure(gitPath: "/usr/bin/git", authArguments: ["-c", "protocol.file.allow=always"], authEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
    try write("first.txt", "staged\n"); try await raw(["add", "--", "first.txt"]); try write("first.txt", "working\n")
    let review = try await git.reviewSubmoduleAdd(url: source.path, path: "child space 中文")
    let before = try await raw(["show", ":first.txt"]).text
    _ = try await git.addSubmodule(review)
    let modules = try await git.submodules()
    XCTAssertEqual(modules.count, 1); XCTAssertTrue(modules[0].initialized); XCTAssertTrue(modules[0].registered)
    XCTAssertEqual(modules[0].currentHead, modules[0].indexCommit); XCTAssertNil(modules[0].parentCommit)
    let after = try await raw(["show", ":first.txt"]).text; XCTAssertEqual(after, before)
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("first.txt"), encoding: .utf8), "working\n")
    let entry = try await raw(["ls-files", "--stage", "--", "child space 中文"]).text
    XCTAssertTrue(entry.hasPrefix("160000 "))
  }
  func testSubmoduleUninitializedInitAndRecordedCheckout() async throws {
    let (_, child) = try await moduleFixture()
    try FileManager.default.removeItem(at: child)
    try await raw(["config", "--remove-section", "submodule.vendor/child"])
    let missing = try await git.submodules()[0]
    XCTAssertFalse(missing.initialized); XCTAssertFalse(missing.registered)
    let initialize = try await git.reviewSubmodule("vendor/child", action: .initialize)
    _ = try await git.performSubmodule(initialize)
    XCTAssertFalse(FileManager.default.fileExists(atPath: child.path))
    let updated = try await git.reviewSubmodule("vendor/child", action: .recorded)
    _ = try await git.performSubmodule(updated)
    let restored = try await git.submodules()[0]
    XCTAssertTrue(restored.initialized); XCTAssertEqual(restored.currentHead, restored.indexCommit)
    XCTAssertEqual(try String(contentsOf: child.appendingPathComponent("content.txt"), encoding: .utf8), "one\n")
  }
  func testSubmoduleRecordedAndRemoteUpdatesAreSeparateAndPreserveParentIndex() async throws {
    let (source, child) = try await moduleFixture()
    let initial = try await git.submodules()[0]
    let target = try await advanceModule(source)
    let index = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    let remote = try await git.reviewSubmodule("vendor/child", action: .remote)
    XCTAssertEqual(remote.target, target); XCTAssertNotEqual(remote.target, initial.indexCommit)
    _ = try await git.performSubmodule(remote)
    let changed = try await git.submodules()[0]
    XCTAssertEqual(changed.currentHead, target); XCTAssertEqual(changed.indexCommit, initial.indexCommit)
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), index)
    let recorded = try await git.reviewSubmodule("vendor/child", action: .recorded)
    _ = try await git.performSubmodule(recorded)
    XCTAssertEqual(try String(contentsOf: child.appendingPathComponent("content.txt"), encoding: .utf8), "one\n")
    let references = try await raw(["-C", child.path, "for-each-ref", "refs/gitpier/submodule"]).stdout
    XCTAssertTrue(references.isEmpty)
  }
  func testSubmoduleDirtyAndUntrackedChildrenAreProtected() async throws {
    let (_, child) = try await moduleFixture()
    try "local\n".write(to: child.appendingPathComponent("content.txt"), atomically: true, encoding: .utf8)
    await moduleRejected { _ = try await self.git.reviewSubmodule("vendor/child", action: .recorded) }
    try await raw(["-C", child.path, "restore", "--", "content.txt"])
    try "untracked".write(to: child.appendingPathComponent("unknown.txt"), atomically: true, encoding: .utf8)
    await moduleRejected { _ = try await self.git.reviewSubmodule("vendor/child", action: .remote) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: child.appendingPathComponent("unknown.txt").path))
  }
  func testSubmoduleExternalChildIndexAndModulesFileChangesRejectReview() async throws {
    let (_, child) = try await moduleFixture()
    let review = try await git.reviewSubmodule("vendor/child", action: .recorded)
    try "local\n".write(to: child.appendingPathComponent("content.txt"), atomically: true, encoding: .utf8)
    try await raw(["-C", child.path, "add", "--", "content.txt"])
    await moduleRejected { _ = try await self.git.performSubmodule(review) }
    let content = try await raw(["-C", child.path, "show", ":content.txt"]).text; XCTAssertEqual(content, "local\n")
    try await raw(["-C", child.path, "reset", "--hard", "HEAD"])
    let fresh = try await git.reviewSubmodule("vendor/child", action: .sync)
    try write(".gitmodules", "# external\n")
    await moduleRejected { _ = try await self.git.performSubmodule(fresh) }
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(".gitmodules"), encoding: .utf8), "# external\n")
  }
  func testSubmoduleSyncUpdatesOnlySelectedURLSettings() async throws {
    let (_, child) = try await moduleFixture()
    let replacement = try await moduleOrigin()
    try await raw(["config", "--file", ".gitmodules", "submodule.vendor/child.url", replacement.path])
    let before = try Data(contentsOf: child.appendingPathComponent("content.txt"))
    let review = try await git.reviewSubmodule("vendor/child", action: .sync)
    _ = try await git.performSubmodule(review)
    let url = try await raw(["-C", child.path, "remote", "get-url", "origin"]).text.trimmingCharacters(in: .newlines)
    XCTAssertEqual(url, replacement.path)
    XCTAssertEqual(try Data(contentsOf: child.appendingPathComponent("content.txt")), before)
  }
  func testSubmoduleDoesNotConfuseParentFallbackWithInitializedChild() async throws {
    let (_, child) = try await moduleFixture()
    try FileManager.default.removeItem(at: child)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try "preserve".write(to: child.appendingPathComponent("unknown.txt"), atomically: true, encoding: .utf8)
    let module = try await git.submodules()[0]
    XCTAssertFalse(module.initialized); XCTAssertNil(module.currentHead)
    await moduleRejected { _ = try await self.git.reviewSubmodule("vendor/child", action: .recorded) }
    XCTAssertEqual(try String(contentsOf: child.appendingPathComponent("unknown.txt"), encoding: .utf8), "preserve")
  }
  func testSubmoduleBadAndSymlinkPathsAreDisplayedAndRefused() async throws {
    try await seed()
    try write(".gitmodules", "[submodule \"bad\"]\n path = ../outside\n url = https://example.invalid/repo.git\n")
    let modules = try await git.submodules()
    XCTAssertEqual(modules.count, 1); XCTAssertNotNil(modules[0].problem)
    await moduleRejected { _ = try await self.git.reviewSubmodule("../outside", action: .initialize) }
    try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("alias").path, withDestinationPath: directory.deletingLastPathComponent().path)
    await moduleRejected { _ = try await self.git.reviewSubmoduleAdd(url: "https://example.invalid/repo.git", path: "alias/child") }
  }
  func testSubmoduleAddRejectsDirtyConfigExistingPathsAndStaleIndex() async throws {
    try await seed(); let source = try await moduleOrigin()
    await git.configure(gitPath: "/usr/bin/git", authArguments: ["-c", "protocol.file.allow=always"], authEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
    await moduleRejected { _ = try await self.git.reviewSubmoduleAdd(url: source.path, path: "first.txt") }
    try write(".gitmodules", "# draft\n")
    await moduleRejected { _ = try await self.git.reviewSubmoduleAdd(url: source.path, path: "child") }
    try FileManager.default.removeItem(at: directory.appendingPathComponent(".gitmodules"))
    let review = try await git.reviewSubmoduleAdd(url: source.path, path: "child")
    try write("second.txt", "external stage\n"); try await raw(["add", "--", "second.txt"])
    await moduleRejected { _ = try await self.git.addSubmodule(review) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("child").path))
  }
  func testSubmoduleNetworkFailureKeepsRecordedState() async throws {
    let (_, child) = try await moduleFixture()
    try await raw(["-C", child.path, "remote", "set-url", "origin", directory.appendingPathComponent("no-such-remote").path])
    let index = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    await moduleRejected { _ = try await self.git.reviewSubmodule("vendor/child", action: .remote) }
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), index)
    XCTAssertEqual(try String(contentsOf: child.appendingPathComponent("content.txt"), encoding: .utf8), "one\n")
  }
  func testSubmoduleChildWorktreeIsNotChangedByParentUpdate() async throws {
    let (source, child) = try await moduleFixture()
    let linked = directory.deletingLastPathComponent().appendingPathComponent("GitPier-module-linked-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: linked) }
    try await raw(["-C", child.path, "worktree", "add", "-b", "linked-child", linked.path])
    try "linked working draft\n".write(to: linked.appendingPathComponent("content.txt"), atomically: true, encoding: .utf8)
    let before = try await raw(["-C", linked.path, "rev-parse", "HEAD"]).text
    _ = try await advanceModule(source)
    let review = try await git.reviewSubmodule("vendor/child", action: .remote)
    _ = try await git.performSubmodule(review)
    let after = try await raw(["-C", linked.path, "rev-parse", "HEAD"]).text; XCTAssertEqual(after, before)
    XCTAssertEqual(try String(contentsOf: linked.appendingPathComponent("content.txt"), encoding: .utf8), "linked working draft\n")
  }
  func testSubmoduleNestedListingIsBoundedAndActionsStayWithParent() async throws {
    let (_, child) = try await moduleFixture(), nested = try await moduleOrigin()
    try await raw(["-C", child.path, "config", "user.name", "Nested Tests"])
    try await raw(["-C", child.path, "config", "user.email", "nested@example.invalid"])
    try await raw(["-C", child.path, "config", "commit.gpgsign", "false"])
    try await raw(["-c", "protocol.file.allow=always", "-C", child.path, "submodule", "add", "--", nested.path, "inner"])
    try await raw(["-C", child.path, "commit", "-m", "nested module"])
    let modules = try await git.submodules()
    XCTAssertEqual(modules.map(\.path), ["vendor/child", "vendor/child/inner"])
    XCTAssertEqual(modules[1].depth, 1)
    await moduleRejected { _ = try await self.git.reviewSubmodule("vendor/child/inner", action: .recorded) }
  }
  func testSubmoduleUpdateWaitsForTheRegisteredChildWriteQueue() async throws {
    let (_, childURL) = try await moduleFixture()
    let review = try await git.reviewSubmodule("vendor/child", action: .recorded)
    let child = await GitServiceRegistry.shared.service(for: childURL)
    let started = directory.appendingPathComponent(".git/child-write-started")
    let checkout = directory.appendingPathComponent(".git/checkout-started")
    let release = directory.appendingPathComponent(".git/child-write-release")
    let wrapper = directory.appendingPathComponent(".git/queue-fixture-git")
    let script = """
      #!/bin/sh
      busy=0
      checkout=0
      for arg in "$@"; do
        [ "$arg" = gitpier.queue-fixture ] && busy=1
        [ "$arg" = checkout ] && checkout=1
      done
      if [ "$busy" = 1 ]; then
        touch "$GITPIER_CHILD_STARTED"
        attempt=0
        while [ ! -f "$GITPIER_CHILD_RELEASE" ]; do
          attempt=$((attempt + 1)); [ "$attempt" -gt 200 ] && exit 1
          sleep 0.05
        done
      fi
      [ "$checkout" = 1 ] && touch "$GITPIER_CHECKOUT_STARTED"
      exec /usr/bin/git "$@"
      """ + "\n"
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    let environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
      "GITPIER_CHILD_STARTED": started.path, "GITPIER_CHECKOUT_STARTED": checkout.path, "GITPIER_CHILD_RELEASE": release.path]
    await child.configure(gitPath: wrapper.path, authEnvironment: environment)
    await git.configure(gitPath: wrapper.path, authEnvironment: environment)
    let busy = Task { try await child.perform(["config", "gitpier.queue-fixture", "one"]) }
    let deadline = ContinuousClock.now + .seconds(8)
    while !FileManager.default.fileExists(atPath: started.path), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
    let parent = git!
    let reservationStarted = directory.appendingPathComponent(".git/reservation-started")
    let reserved = Task {
      try await child.submoduleReservation(initialized: false, heldCommon: "fixture") {
        try Data().write(to: reservationStarted)
      }
    }
    let updating = Task { try await parent.performSubmodule(review) }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertFalse(FileManager.default.fileExists(atPath: checkout.path), "Parent checkout must wait for the child's actor queue")
    XCTAssertFalse(FileManager.default.fileExists(atPath: reservationStarted.path), "A reservation must wait for the child's existing write")
    try Data().write(to: release)
    _ = try await busy.value; try await reserved.value; _ = try await updating.value
    XCTAssertTrue(FileManager.default.fileExists(atPath: reservationStarted.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: checkout.path))
  }
  func testSubmoduleIgnoredCollisionStopsWithoutOverwritingLocalData() async throws {
    let (origin, child) = try await moduleFixture()
    try "ignored.dat\n".write(to: child.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
    try "local ignored data".write(to: child.appendingPathComponent("ignored.dat"), atomically: true, encoding: .utf8)
    try "remote tracked data".write(to: origin.appendingPathComponent("ignored.dat"), atomically: true, encoding: .utf8)
    try await raw(["-C", origin.path, "add", "--", "ignored.dat"])
    try await raw(["-C", origin.path, "commit", "-m", "tracked collision"])
    let before = try await raw(["-C", child.path, "rev-parse", "HEAD"]).text
    let review = try await git.reviewSubmodule("vendor/child", action: .remote)
    await moduleRejected { _ = try await self.git.performSubmodule(review) }
    let after = try await raw(["-C", child.path, "rev-parse", "HEAD"]).text; XCTAssertEqual(after, before)
    XCTAssertEqual(try String(contentsOf: child.appendingPathComponent("ignored.dat"), encoding: .utf8), "local ignored data")
  }
  func testSubmoduleHiddenWorkingChangesAreNotOverwritten() async throws {
    let (_, child) = try await moduleFixture()
    let review = try await git.reviewSubmodule("vendor/child", action: .recorded)
    try await raw(["-C", child.path, "update-index", "--assume-unchanged", "--", "content.txt"])
    try "hidden local edits\n".write(to: child.appendingPathComponent("content.txt"), atomically: true, encoding: .utf8)
    await moduleRejected { _ = try await self.git.reviewSubmodule("vendor/child", action: .recorded) }
    await moduleRejected { _ = try await self.git.performSubmodule(review) }
    XCTAssertEqual(try String(contentsOf: child.appendingPathComponent("content.txt"), encoding: .utf8), "hidden local edits\n")
  }
}
