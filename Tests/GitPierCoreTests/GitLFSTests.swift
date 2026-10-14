import XCTest
@testable import GitPierCore

extension GitServiceTests {
  private func lfsFixture(_ mode: String = "ready") async throws {
    let wrapper = directory.appendingPathComponent("git-lfs-fixture")
    let oid = String(repeating: "a", count: 64)
    let script = """
      #!/bin/sh
      if [ "$1" = --no-pager ]; then shift; fi
      if [ "$1" = config ] && [ "$2" = --get ] && [ "$3" = filter.lfs.process ]; then
        [ "$GITPIER_LFS_MODE" = unconfigured ] && exit 1
        echo 'git-lfs filter-process'; exit 0
      fi
      if [ "$1" = lfs ]; then
        shift
        case "$1" in
          version)
            if [ "$GITPIER_LFS_MODE" = missing ]; then echo "git: 'lfs' is not a git command" >&2; exit 1; fi
            echo 'git-lfs/3.7.1 (isolated fixture)'; exit 0;;
          ls-files)
            printf '%s\\n' '{"files":[{"name":"asset.bin","size":2048,"checkout":false,"downloaded":true,"oid_type":"sha256","oid":"\(oid)","version":"https://git-lfs.github.com/spec/v1"}]}'; exit 0;;
          track) echo 'Listing tracked patterns'; echo '    *.bin (.gitattributes)'; exit 0;;
          fetch)
            if [ "$GITPIER_LFS_MODE" = failure ]; then echo 'authentication failed https://user:secret@example.invalid/lfs' >&2; exit 1; fi
            if [ "$GITPIER_LFS_MODE" = wait ]; then touch "$GITPIER_LFS_MARKER"; sleep 20; fi
            if [ "$GITPIER_LFS_MODE" = move-head ]; then /usr/bin/git commit --allow-empty -m external >/dev/null; fi
            printf 'Downloading LFS objects: 55%% (1/2)\\rDownloading LFS objects: 100%% (2/2)\\n' >&2
            echo 'fetched fixture'; exit 0;;
          checkout)
            printf '%s' "$GIT_INDEX_FILE" > "$GITPIER_LFS_CHECKOUT_INDEX"
            [ "$GITPIER_LFS_MODE" = checkout-failure ] && { echo 'checkout failed' >&2; exit 1; }
            echo 'checked out fixture'; exit 0;;
        esac
      fi
      exec /usr/bin/git "$@"
      """ + "\n"
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    await git.configure(gitPath: wrapper.path, authEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
      "GITPIER_LFS_MODE": mode, "GITPIER_LFS_MARKER": directory.appendingPathComponent(".git/lfs-test-started").path,
      "GITPIER_LFS_CHECKOUT_INDEX": directory.appendingPathComponent(".git/lfs-test-index").path])
  }
  private func lfsRejected(_ action: () async throws -> Void) async {
    do { try await action(); XCTFail("Expected LFS rejection") } catch {}
  }
  func testLFSInstalledAndMissingEnvironmentDoNotInstallOrChangeIndex() async throws {
    try await seed(); try await lfsFixture("missing")
    let index = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    let missing = try await git.lfsState(); XCTAssertFalse(missing.installed)
    await lfsRejected { _ = try await self.git.reviewLFSRule("*.bin", track: true) }
    try await lfsFixture()
    let pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:" + String(repeating: "a", count: 64) + "\nsize 2048\n"
    try write("asset.bin", pointer)
    let state = try await git.lfsState()
    XCTAssertTrue(state.installed); XCTAssertTrue(state.configured)
    XCTAssertEqual(state.files[0].workingPointer?.size, 2048)
    XCTAssertFalse(state.files[0].materialized); XCTAssertTrue(state.files[0].downloaded)
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), index)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/hooks/pre-push").path))
  }
  func testLFSRootTrackUntrackPreservesAttributesCRLFAndPartialIndex() async throws {
    try await seed(); try await lfsFixture()
    let original = "# custom\r\n*.swift text linguist-generated\r\n"
    try write(".gitattributes", original); try await raw(["add", "--", ".gitattributes"])
    try write(".gitattributes", original + "# working draft\r\n")
    let index = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    let review = try await git.reviewLFSRule("folder space/*.bin", track: true)
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(".gitattributes"), encoding: .utf8), original + "# working draft\r\n")
    try await git.applyLFSRule(review)
    let attributes = try String(contentsOf: directory.appendingPathComponent(".gitattributes"), encoding: .utf8)
    XCTAssertTrue(attributes.hasPrefix(original + "# working draft\r\n"))
    let native = try await raw(["check-attr", "filter", "--", "folder space/a.bin"]).text
    XCTAssertTrue(native.contains("filter: lfs"))
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), index)
    let untrack = try await git.reviewLFSRule("folder space/*.bin", track: false)
    try await git.applyLFSRule(untrack)
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(".gitattributes"), encoding: .utf8), original + "# working draft\r\n")
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), index)
  }
  func testLFSUntrackKeepsOtherAttributesAndComments() throws {
    let source = Data("# keep\n\"*.bin\" filter=lfs diff=lfs merge=lfs -text linguist-generated eol=lf\n*.swift text\n".utf8)
    let output = try LFSAttributes.edit(source, pattern: "*.bin", track: false)
    XCTAssertEqual(String(decoding: output, as: UTF8.self), "# keep\n\"*.bin\" linguist-generated eol=lf\n*.swift text\n")
    XCTAssertThrowsError(try LFSAttributes.edit(output, pattern: "missing", track: false))
  }
  func testLFSRulesKeepQuotedPatternsLiteralAndRejectUnsafeInputs() async throws {
    try await seed(); try await lfsFixture()
    let pattern = "$(touch injected)/*.bin"
    let review = try await git.reviewLFSRule(pattern, track: true)
    try await git.applyLFSRule(review)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("injected").path))
    let rules = try LFSAttributes.rules(review.after); XCTAssertEqual(rules[0].pattern, pattern)
    for invalid in ["", "bad\npattern", "!negation", "../outside", "[attr]macro"] {
      XCTAssertThrowsError(try LFSAttributes.edit(Data(), pattern: invalid, track: true))
    }
  }
  func testLFSRuleExternalChangesAndSymlinksAreRejected() async throws {
    try await seed(); try await lfsFixture()
    let review = try await git.reviewLFSRule("*.bin", track: true)
    try write(".gitattributes", "external text\n")
    await lfsRejected { try await self.git.applyLFSRule(review) }
    try FileManager.default.removeItem(at: directory.appendingPathComponent(".gitattributes"))
    try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent(".gitattributes").path, withDestinationPath: "first.txt")
    await lfsRejected { _ = try await self.git.reviewLFSRule("*.bin", track: true) }
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("first.txt"), encoding: .utf8), "one\ntwo\nthree\n")
  }
  func testLFSPointerValidationIsStrictAndBounded() {
    let oid = String(repeating: "a", count: 64)
    let valid = Data("version https://git-lfs.github.com/spec/v1\noid sha256:\(oid)\nsize 9999999999\n".utf8)
    XCTAssertEqual(LFSPointer.parse(valid)?.size, 9999999999)
    XCTAssertNil(LFSPointer.parse(Data("version https://git-lfs.github.com/spec/v1\noid sha256:bad\nsize 1\n".utf8)))
    XCTAssertNil(LFSPointer.parse(Data(repeating: 97, count: LFSPointer.limit + 1)))
    XCTAssertNil(LFSPointer.parse(Data("version https://git-lfs.github.com/spec/v1\noid sha256:\(oid)\nsize -1\n".utf8)))
  }
  func testLFSFetchAllowsPartialStagingAndPullRequiresCleanTrackedFiles() async throws {
    try await seed(); try await lfsFixture()
    try await raw(["remote", "add", "origin", "https://example.invalid/repo.git"])
    try write("first.txt", "staged\n"); try await raw(["add", "--", "first.txt"]); try write("first.txt", "working\n")
    let index = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    await lfsRejected { _ = try await self.git.reviewLFSNetwork(.pull, remote: "origin") }
    let review = try await git.reviewLFSNetwork(.fetch, remote: "origin")
    _ = try await git.performLFSNetwork(review)
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), index)
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("first.txt"), encoding: .utf8), "working\n")
  }
  func testLFSPullUsesPrivateIndexAndDoesNotInstallFilters() async throws {
    try await seed(); try await lfsFixture(); try await raw(["remote", "add", "origin", "https://example.invalid/repo.git"])
    let index = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    let review = try await git.reviewLFSNetwork(.pull, remote: "origin")
    _ = try await git.performLFSNetwork(review)
    let used = try String(contentsOf: directory.appendingPathComponent(".git/lfs-test-index"), encoding: .utf8)
    XCTAssertNotEqual(used, directory.appendingPathComponent(".git/index").path)
    XCTAssertTrue(used.contains("GitPier-lfs-index-"))
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), index)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/index.lock").path))
    try await lfsFixture("unconfigured")
    await lfsRejected { _ = try await self.git.reviewLFSNetwork(.pull, remote: "origin") }
  }
  func testLFSNetworkFailuresRedactCredentialsAndLeaveState() async throws {
    try await seed(); try await lfsFixture("failure"); try await raw(["remote", "add", "origin", "https://example.invalid/repo.git"])
    let index = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    let review = try await git.reviewLFSNetwork(.fetch, remote: "origin")
    do { _ = try await git.performLFSNetwork(review); XCTFail("Expected authentication failure") }
    catch { XCTAssertFalse(error.localizedDescription.contains("secret")); XCTAssertTrue(error.localizedDescription.contains("[redacted]")) }
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), index)
  }
  func testLFSNetworkRejectsRemoteChangesAndHeadMovementBeforeCheckout() async throws {
    try await seed(); try await lfsFixture(); try await raw(["remote", "add", "origin", "https://example.invalid/repo.git"])
    let stale = try await git.reviewLFSNetwork(.fetch, remote: "origin")
    try await raw(["remote", "set-url", "origin", "https://other.example.invalid/repo.git"])
    await lfsRejected { _ = try await self.git.performLFSNetwork(stale) }
    try await lfsFixture("move-head")
    let pull = try await git.reviewLFSNetwork(.pull, remote: "origin")
    await lfsRejected { _ = try await self.git.performLFSNetwork(pull) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/lfs-test-index").path))
  }
  func testLFSCancellationStopsBeforeCheckoutAndPreservesIndex() async throws {
    try await seed(); try await lfsFixture("wait"); try await raw(["remote", "add", "origin", "https://example.invalid/repo.git"])
    let index = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    let review = try await git.reviewLFSNetwork(.pull, remote: "origin")
    let service = git!
    let task = Task { try await service.performLFSNetwork(review) }
    let marker = directory.appendingPathComponent(".git/lfs-test-started")
    for _ in 0..<100 { if FileManager.default.fileExists(atPath: marker.path) { break }; try await Task.sleep(for: .milliseconds(20)) }
    task.cancel()
    do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error \(error)") }
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), index)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/lfs-test-index").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/index.lock").path))
  }
  func testLFSRealPercentagesReuseNativeProgressDecoder() {
    XCTAssertEqual(GitProgressDecoder.parse("Downloading LFS objects: 55% (1/2), 2 GB")?.fraction, 0.55)
    XCTAssertEqual(GitProgressDecoder.parse("Checking out LFS objects: 100% (2/2)")?.phase, .checkout)
    XCTAssertNil(GitProgressDecoder.parse("authentication failed https://example.invalid/55%"))
  }
}
