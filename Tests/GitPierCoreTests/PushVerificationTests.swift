import XCTest
@testable import GitPierCore

private actor PushCheckpointProbe {
  var values: [PushCheckpoint] = []
  func record(_ value: PushCheckpoint) { values.append(value) }
  func last() -> PushCheckpoint? { values.last }
}

final class PushVerificationTests: XCTestCase {
  var fixture: URL!
  var root: URL!
  var remote: URL!
  var git: GitService!
  override func setUp() async throws {
    fixture = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-push-verification-" + UUID().uuidString).resolvingSymlinksInPath()
    root = fixture.appendingPathComponent("repository"); remote = fixture.appendingPathComponent("remote.git")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    git = GitService(root: root)
    for args in [["init", "-b", "main"], ["config", "user.name", "Verification Fixture"],
      ["config", "user.email", "verify@example.invalid"], ["config", "commit.gpgsign", "false"],
      ["config", "core.hooksPath", root.appendingPathComponent(".git/hooks").path]] { try await raw(args) }
    try await commit("seed")
    try await raw(["init", "--bare", remote.path]); try await raw(["remote", "add", "origin", remote.path])
    try await raw(["push", "--set-upstream", "origin", "main"])
  }
  override func tearDown() async throws { try? FileManager.default.removeItem(at: fixture) }
  @discardableResult func raw(_ args: [String]) async throws -> CommandResult {
    let result = try await ProcessRunner().run(executable: "/usr/bin/git", arguments: args, directory: root,
      environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
    guard result.code == 0 else { throw GitPierError.command("fixture", result.code, result.errorText) }
    return result
  }
  func commit(_ value: String) async throws {
    try Data((value + "\n").utf8).write(to: root.appendingPathComponent("tracked.txt"))
    try await raw(["add", "--", "tracked.txt"]); try await raw(["commit", "-m", value])
  }
  func checkpoint(_ service: GitService? = nil) async throws -> PushCheckpoint {
    let value = try await (service ?? git!).reviewPushCheckpoint()
    return try XCTUnwrap(value, "The default single-branch Push must have a recoverable target")
  }
  func wrapper(_ body: String) throws -> URL {
    let url = fixture.appendingPathComponent("git-wrapper")
    try ("#!/bin/sh\n" + body + "\nexec /usr/bin/git \"$@\"\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }
  func testNetworkPushResolvesEachSafetyPhaseTargetOnlyOnce() async throws {
    let log = fixture.appendingPathComponent("checkpoint-commands")
    let path = try wrapper("printf '%s\\n' \"$*\" >> '\(log.path)'")
    let service = GitService(root: root, gitPath: path.path), probe = PushCheckpointProbe()
    _ = try await service.network("push", observer: PushRecoveryObserver(localCommit: { _ in },
      checkpoint: { await probe.record($0) }))
    let captured = await probe.last()
    XCTAssertNotNil(captured, "Do not meet the process budget by skipping checkpoint capture")
    let commands = try String(contentsOf: log, encoding: .utf8).components(separatedBy: "\n")
    XCTAssertEqual(commands.filter { $0.contains("remote get-url --push --all -- origin") }.count, 3,
      "Capture, completion of capture and post-observer validation each resolve a fresh target once")
    XCTAssertEqual(commands.filter { $0.contains("ls-remote --get-url --") }.count, 3,
      "Every existing boundary still checks native URL re-expansion")
    XCTAssertEqual(commands.filter { $0.contains("config --null --get-regexp") && $0.contains("credential\\.") }.count, 3,
      "Every existing boundary still reads a fresh complete safety fingerprint")
    XCTAssertEqual(commands.filter { $0.contains("config --null --get-all remote.origin.") }.count, 0,
      "Use the already read configuration rather than starting more identical readers")
    XCTAssertEqual(commands.filter { $0.hasSuffix("rev-parse --show-toplevel --absolute-git-dir --git-common-dir") }.count, 3,
      "Each phase freshly resolves all three directory paths in one native query")
    XCTAssertEqual(commands.filter { $0.hasSuffix("rev-parse --show-toplevel") }.count, 0)
    XCTAssertEqual(commands.filter { $0.contains("config --bool --get") }.count, 0,
      "The complete configuration already establishes that both boolean keys are absent")
    XCTAssertEqual(commands.filter { $0.contains("status --porcelain=v2 -z --branch --untracked-files=all") }.count, 2,
      "Both source checks retain the complete native status scan")
    XCTAssertEqual(commands.filter { $0.contains("push --progress --porcelain") }.count, 1)
  }
  func testLinkedWorktreeWithNewlineUsesUnambiguousDirectoryReads() async throws {
    let linked = fixture.appendingPathComponent("linked\nworktree")
    try await raw(["worktree", "add", "-b", "linked", linked.path])
    try await raw(["-C", linked.path, "push", "--set-upstream", "origin", "linked"])
    let log = fixture.appendingPathComponent("checkpoint-commands")
    let path = try wrapper("printf '%s\\n' \"$*\" >> '\(log.path)'")
    let service = GitService(root: linked, gitPath: path.path)
    let target = try await checkpoint(service)
    let directories = try await service.metadataDirectories()
    XCTAssertEqual(target.workingTree, linked.path)
    XCTAssertEqual(target.gitDirectory, directories.first?.resolvingSymlinksInPath().path)
    XCTAssertEqual(target.commonDirectory, root.appendingPathComponent(".git").path)
    XCTAssertNotEqual(target.gitDirectory, target.commonDirectory)
    let result = try await service.verifyPush(target)
    XCTAssertTrue(result.confirmed)
    let commands = try String(contentsOf: log, encoding: .utf8).components(separatedBy: "\n")
    XCTAssertEqual(commands.filter { $0.hasSuffix("rev-parse --show-toplevel --absolute-git-dir --git-common-dir") }.count, 4)
    XCTAssertEqual(commands.filter { $0.hasSuffix("rev-parse --show-toplevel") }.count, 4,
      "An LF in a native path requires independent path reads in every phase")
  }
  func testReplacingGitDirectoryAfterCheckpointPreventsPush() async throws {
    try await commit("must not push from replaced Git directory")
    let gitDirectory = root.appendingPathComponent(".git"), replacement = fixture.appendingPathComponent("replacement")
    let oldDirectory = fixture.appendingPathComponent("original"), replaced = fixture.appendingPathComponent("replaced")
    let attempted = fixture.appendingPathComponent("unexpected-push")
    try FileManager.default.copyItem(at: gitDirectory, to: replacement)
    let path = try wrapper("case \" $* \" in *\" push \"*) touch '\(attempted.path)';; esac")
    let service = GitService(root: root, gitPath: path.path)
    let before = try await raw(["--git-dir=" + remote.path, "rev-parse", "refs/heads/main"]).stdout
    let observer = PushRecoveryObserver(localCommit: { _ in }, checkpoint: { _ in
      do {
        try FileManager.default.moveItem(at: gitDirectory, to: oldDirectory)
        try FileManager.default.moveItem(at: replacement, to: gitDirectory)
        try Data().write(to: replaced)
      } catch { XCTFail("Replace only the temporary fixture's Git directory: \(error)") }
    })
    do { _ = try await service.network("push", observer: observer); XCTFail("The new directory inode must invalidate the checkpoint") }
    catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: replaced.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: attempted.path))
    let after = try await raw(["--git-dir=" + remote.path, "rev-parse", "refs/heads/main"]).stdout
    XCTAssertEqual(after, before)
  }
  func testPostCheckpointObserverAuthenticationChangeStillPreventsPush() async throws {
    try await commit("must not push after reconfiguration")
    let directory = try XCTUnwrap(root), attempted = fixture.appendingPathComponent("unexpected-push")
    let path = try wrapper("case \" $* \" in *\" push \"*) touch '\(attempted.path)';; esac")
    let service = GitService(root: directory, gitPath: path.path)
    let before = try await raw(["--git-dir=" + remote.path, "rev-parse", "refs/heads/main"]).stdout
    let observer = PushRecoveryObserver(localCommit: { _ in }, checkpoint: { _ in
      _ = try? await ProcessRunner().run(executable: "/usr/bin/git",
        arguments: ["config", "http.extraHeader", "X-Fixture-Account: replaced"], directory: directory,
        environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
    })
    do { _ = try await service.network("push", observer: observer); XCTFail("Revalidate after the observer before writing") }
    catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: attempted.path))
    let after = try await raw(["--git-dir=" + remote.path, "rev-parse", "refs/heads/main"]).stdout
    XCTAssertEqual(after, before)
  }
  func testEmptyPushURLFollowsNativeListSemantics() async throws {
    try await raw(["config", "--add", "remote.origin.pushurl", ""])
    try await raw(["config", "--add", "remote.origin.pushurl", remote.path])
    let native = try await raw(["remote", "get-url", "--push", "--all", "--", "origin"]).stdout
    let single = Data((remote.path + "\n").utf8)
    let target = try await git.reviewPushCheckpoint()
    if native == single {
      let observation = try await git.verifyPush(XCTUnwrap(target))
      XCTAssertTrue(observation.confirmed)
    } else {
      XCTAssertEqual(native, Data([10]) + single, "Older Git retains the empty entry in its destination list")
      XCTAssertNil(target, "A blank destination line cannot be discarded as single-target proof")
    }
  }
  func testMultipleEffectivePushDestinationsRemainManual() async throws {
    try await raw(["config", "--add", "remote.origin.pushurl", remote.path])
    try await raw(["config", "--add", "remote.origin.pushurl", fixture.appendingPathComponent("other.git").path])
    let target = try await git.reviewPushCheckpoint()
    XCTAssertNil(target)
  }
  func testTransportChangedDuringSourceStatusCannotCreateCheckpoint() async throws {
    let path = try wrapper("""
      case " $* " in
        *" status "*)
          /usr/bin/git "$@"; code=$?
          /usr/bin/git config remote.origin.uploadpack /usr/bin/false
          exit "$code";;
      esac
      """)
    let service = GitService(root: root, gitPath: path.path)
    do {
      let target = try await service.reviewPushCheckpoint()
      XCTAssertNil(target, "Transport validation must observe configuration after source status")
    } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
  }
  func testTransportChangedDuringFinalRemoteResolutionPreventsNativePush() async throws {
    try await commit("must not use a newly configured transport")
    let armed = fixture.appendingPathComponent("after-checkpoint")
    let mutated = fixture.appendingPathComponent("transport-changed")
    let attempted = fixture.appendingPathComponent("unexpected-push")
    let path = try wrapper("""
      case "$*" in
        "--no-pager remote")
          /usr/bin/git "$@"; code=$?
          if [ -f '\(armed.path)' ]; then
            /usr/bin/git config remote.origin.receivepack /usr/bin/false || exit $?
            touch '\(mutated.path)'
          fi
          exit "$code";;
        *" push "*) touch '\(attempted.path)';;
      esac
      """)
    let service = GitService(root: root, gitPath: path.path)
    let observer = PushRecoveryObserver(localCommit: { _ in }, checkpoint: { _ in
      try? Data().write(to: armed)
    })
    do { _ = try await service.network("push", observer: observer); XCTFail("The final configuration check must reject the new transport") }
    catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: mutated.path), "The final native remote query must inject the change")
    XCTAssertFalse(FileManager.default.fileExists(atPath: attempted.path), "Do not start Push with a newly configured transport")
  }
  func testMixedCaseRemoteAndMultipleFetchURLsKeepExactPushDestination() async throws {
    try await raw(["remote", "rename", "origin", "OriginUpper"])
    try await raw(["config", "--add", "remote.OriginUpper.url", fixture.appendingPathComponent("unused-fetch.git").path])
    try await raw(["config", "remote.OriginUpper.pushurl", remote.path])
    let target = try await checkpoint()
    XCTAssertEqual(target.remote, "OriginUpper")
    let result = try await git.verifyPush(target)
    XCTAssertTrue(result.confirmed)
  }
  func testExactRemoteCheckpointIsConfirmedWithoutChangingLocalGitState() async throws {
    let target = try await checkpoint()
    try Data("staged\n".utf8).write(to: root.appendingPathComponent("tracked.txt")); try await raw(["add", "tracked.txt"])
    try Data("working\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
    let index = root.appendingPathComponent(".git/index"), config = root.appendingPathComponent(".git/config")
    let before = try Data(contentsOf: index), configuration = try Data(contentsOf: config)
    let refs = try await raw(["show-ref"]).stdout
    let observation = try await git.verifyPush(target)
    XCTAssertTrue(observation.confirmed); XCTAssertEqual(observation.remoteHead, target.localHead)
    XCTAssertEqual(try Data(contentsOf: index), before); XCTAssertEqual(try Data(contentsOf: config), configuration)
    let afterRefs = try await raw(["show-ref"]).stdout; XCTAssertEqual(afterRefs, refs)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/FETCH_HEAD").path))
  }
  func testDifferentOrMissingRemoteTipStaysUnconfirmedAndDoesNotPush() async throws {
    try await commit("local only")
    let target = try await checkpoint()
    let different = try await git.verifyPush(target)
    XCTAssertFalse(different.confirmed); XCTAssertNotNil(different.remoteHead)
    XCTAssertNotEqual(different.remoteHead, target.localHead)
    try await raw(["--git-dir=" + remote.path, "update-ref", "-d", "refs/heads/main"])
    let missing = try await git.verifyPush(target)
    XCTAssertFalse(missing.confirmed); XCTAssertNil(missing.remoteHead)
  }
  func testVerificationUsesPushURLInsteadOfFetchURL() async throws {
    let pushRemote = fixture.appendingPathComponent("push.git")
    try await raw(["clone", "--bare", remote.path, pushRemote.path])
    try await raw(["remote", "set-url", "--push", "origin", pushRemote.path])
    try await commit("push destination")
    _ = try await git.network("push")
    let target = try await checkpoint(), observation = try await git.verifyPush(target)
    XCTAssertTrue(observation.confirmed)
    let fetchHead = try await raw(["--git-dir=" + remote.path, "rev-parse", "refs/heads/main"]).text.trimmingCharacters(in: .newlines)
    XCTAssertNotEqual(fetchHead, target.localHead)
  }
  func testPushReviewDisplaysEffectiveDestinationWithoutURLCredentials() async throws {
    let cases = [
      ("https://fixture-user:fixture-password@example.invalid:9443/team/review.git?token=fixture-query#fragment",
       "https://example.invalid:9443/team/review.git"),
      ("fixture-user@[2001:db8::1]:team/review.git", "[2001:db8::1]:team/review.git"),
    ]
    for (effectiveURL, display) in cases {
      try await raw(["remote", "set-url", "--push", "origin", effectiveURL])
      let reviewed = try await git.reviewPushCheckpointWithDestination()
      XCTAssertEqual(reviewed?.destination, display)
      let exact = try await checkpoint()
      XCTAssertEqual(reviewed?.checkpoint, exact)
    }
  }
  func testChangedDestinationCannotResolveOriginalUnknownResult() async throws {
    let target = try await checkpoint()
    try await raw(["remote", "set-url", "--push", "origin", fixture.appendingPathComponent("other.git").path])
    do { _ = try await git.verifyPush(target); XCTFail("Changed destination must require a fresh review") }
    catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
  }
  func testHistoricalVerificationAllowsBranchSwitchButRetryRefusesIt() async throws {
    let target = try await checkpoint()
    try await raw(["switch", "-c", "other"])
    let observation = try await git.verifyPush(target); XCTAssertTrue(observation.confirmed)
    do { _ = try await git.retryPush(target); XCTFail("Retry must remain bound to the original branch") }
    catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
  }
  func testRetryRefusesChangedHeadAndPreservesExternalCommit() async throws {
    let target = try await checkpoint()
    try await commit("external head")
    let before = try await raw(["rev-parse", "HEAD"]).stdout
    do { _ = try await git.retryPush(target); XCTFail("A new HEAD needs a new Push review") }
    catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
    let after = try await raw(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(before, after)
  }
  func testRetryChecksRemoteAndPushesOnlyOriginalCommit() async throws {
    try await commit("retry checkpoint")
    let target = try await checkpoint(), before = try await raw(["rev-list", "--count", "HEAD"]).stdout
    _ = try await git.retryPush(target)
    let observation = try await git.verifyPush(target); XCTAssertTrue(observation.confirmed)
    let after = try await raw(["rev-list", "--count", "HEAD"]).stdout; XCTAssertEqual(after, before)
  }
  func testAlreadyConfirmedRetryDoesNotSendAnotherPush() async throws {
    let log = fixture.appendingPathComponent("push-count")
    let path = try wrapper("case \" $* \" in *\" push \"*) printf x >> '\(log.path)';; esac")
    let service = GitService(root: root, gitPath: path.path), target = try await checkpoint(service)
    _ = try await service.retryPush(target)
    XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
  }
  func testAcceptedPushFollowedByClientFailureKeepsOriginalCheckpoint() async throws {
    try await commit("accepted before error")
    let path = try wrapper("case \" $* \" in *\" push \"*) /usr/bin/git \"$@\"; code=$?; [ \"$code\" -eq 0 ] && exit 84; exit \"$code\";; esac")
    let service = GitService(root: root, gitPath: path.path), probe = PushCheckpointProbe()
    do {
      _ = try await service.network("push", observer: PushRecoveryObserver(localCommit: { _ in }, checkpoint: { await probe.record($0) }))
      XCTFail("The wrapper must expose the post-acceptance client error")
    } catch { }
    let captured = await probe.last(), target = try XCTUnwrap(captured)
    let observation = try await service.verifyPush(target)
    XCTAssertTrue(observation.confirmed)
    XCTAssertEqual(target.localReference, "refs/heads/main"); XCTAssertEqual(target.remoteReference, "refs/heads/main")
  }
  func testBroadPushConfigurationsDoNotInventSingleTarget() async throws {
    for (key, value) in [("push.default", "matching"), ("push.followTags", "true"), ("remote.origin.mirror", "true"),
      ("remote.origin.push", "refs/heads/*:refs/heads/*")] {
      try await raw(["config", key, value])
      let target = try await git.reviewPushCheckpoint(); XCTAssertNil(target, key)
      try await raw(["config", "--unset", key])
    }
  }
  func testChainedURLRewriteCannotConfirmAnotherRepositoryOrSkipPush() async throws {
    let a = fixture.appendingPathComponent("A", isDirectory: true), b = fixture.appendingPathComponent("B", isDirectory: true)
    try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
    let actualRemote = a.appendingPathComponent("repo"), otherRemote = b.appendingPathComponent("repo")
    try await raw(["clone", "--bare", remote.path, actualRemote.path])
    try await commit("only the unrelated repository has this commit")
    try await raw(["clone", "--bare", root.path, otherRemote.path])
    try await raw(["remote", "set-url", "origin", "source:repo"])
    try await raw(["config", "url." + a.absoluteString + ".insteadOf", "source:"])
    try await raw(["config", "url." + b.absoluteString + ".insteadOf", a.absoluteString])
    let local = try await raw(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    let actualBefore = try await raw(["--git-dir=" + actualRemote.path, "rev-parse", "main"]).text.trimmingCharacters(in: .newlines)
    XCTAssertNotEqual(actualBefore, local)
    // A conservative implementation may decline a checkpoint for this custom
    // transport. If one is retained, it must never prove B as the result at A.
    if let target = try await git.reviewPushCheckpoint() {
      let observation = try await git.verifyPush(target)
      XCTAssertFalse(observation.confirmed, "The expanded URL must not be rewritten into unrelated B")
      _ = try await git.retryPush(target)
      let actualAfter = try await raw(["--git-dir=" + actualRemote.path, "rev-parse", "main"]).text.trimmingCharacters(in: .newlines)
      XCTAssertEqual(actualAfter, local, "Do not skip a necessary Push because unrelated B matches")
    }
  }
  func testCustomNamedRemoteTransportsRequireManualVerification() async throws {
    for (key, value) in [("remote.origin.vcs", "custom-fixture"), ("remote.origin.receivepack", "/custom/receive"),
      ("remote.origin.uploadpack", "/custom/upload"), ("remote.origin.serverOption", "namespace=other")] {
      try await raw(["config", key, value])
      let target = try await git.reviewPushCheckpoint()
      XCTAssertNil(target, "A raw URL query cannot prove named custom transport semantics: " + key)
      try await raw(["config", "--unset", key])
    }
  }
  func testChangedAuthenticationConfigurationInvalidatesCheckpoint() async throws {
    let target = try await checkpoint()
    try await raw(["config", "http.extraHeader", "X-Fixture-Account: changed"])
    do { _ = try await git.verifyPush(target); XCTFail("A different authentication context requires a fresh target review") }
    catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
  }
  func testEffectiveURLCannotInheritAnotherNamedRemoteTransport() async throws {
    try await raw(["remote", "set-url", "origin", "transport"])
    try await raw(["remote", "add", "transport", "transport"])
    try await raw(["config", "remote.transport.uploadpack", "/custom/not-executed"])
    let target = try await git.reviewPushCheckpoint()
    XCTAssertNil(target, "An effective path interpreted as another remote must stay manual")
  }
  func testCustomURLHelpersAreNotInvokedForVerification() async throws {
    for url in ["ext::/custom/not-executed", "custom-fixture://host/repository"] {
      try await raw(["remote", "set-url", "origin", url])
      let target = try await git.reviewPushCheckpoint()
      XCTAssertNil(target, "Only a standard transport can establish a saved Push result: " + url)
    }
  }
  func testExplicitFirstPushRetainsVerificationAfterSettingUpstream() async throws {
    try await raw(["config", "--unset", "branch.main.remote"])
    try await raw(["config", "--unset", "branch.main.merge"])
    let path = try wrapper("case \" $* \" in *\" push \"*) /usr/bin/git \"$@\"; code=$?; [ \"$code\" -eq 0 ] && exit 84; exit \"$code\";; esac")
    let service = GitService(root: root, gitPath: path.path), probe = PushCheckpointProbe()
    do { _ = try await service.network("push", remote: "origin", branch: "main",
      observer: PushRecoveryObserver(localCommit: { _ in }, checkpoint: { await probe.record($0) })); XCTFail() } catch { }
    let captured = await probe.last(), target = try XCTUnwrap(captured)
    let observation = try await service.verifyPush(target)
    XCTAssertTrue(observation.confirmed)
  }
  func testRetryNonFastForwardRemainsKnownRejection() async throws {
    try await raw(["switch", "-c", "peer"]); try await commit("remote changed")
    try await raw(["push", "origin", "peer:main"]); try await raw(["switch", "main"])
    try await commit("local changed")
    let target = try await checkpoint()
    do { _ = try await git.retryPush(target); XCTFail("Divergence requires the original Merge & Push review") }
    catch is PushRejection { }
    catch { XCTFail("Known rejection was incorrectly treated as unknown: \(error)") }
  }
  func testAcceptedPushCancellationStillHasVerifiableCheckpoint() async throws {
    try await commit("accepted before cancellation")
    let marker = fixture.appendingPathComponent("accepted")
    let path = try wrapper("case \" $* \" in *\" push \"*) /usr/bin/git \"$@\" || exit $?; touch '\(marker.path)'; /bin/sleep 20; exit 0;; esac")
    let service = GitService(root: root, gitPath: path.path), probe = PushCheckpointProbe()
    let task = Task { try await service.network("push", observer: PushRecoveryObserver(localCommit: { _ in }, checkpoint: { await probe.record($0) })) }
    defer { task.cancel() }
    for _ in 0..<300 {
      if FileManager.default.fileExists(atPath: marker.path) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    task.cancel()
    do { _ = try await task.value; XCTFail("Cancellation should interrupt client observation") } catch { }
    let captured = await probe.last(), target = try XCTUnwrap(captured)
    let observation = try await service.verifyPush(target)
    XCTAssertTrue(observation.confirmed)
  }
  func testUnterminatedRemoteResponseCannotConfirmPush() async throws {
    let head = try await raw(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    let path = try wrapper("case \" $* \" in *\" --get-url \"*) exec /usr/bin/git \"$@\";; *\" ls-remote \"*) printf '%s\\trefs/heads/main' '\(head)'; exit 0;; esac")
    let service = GitService(root: root, gitPath: path.path), target = try await checkpoint(service)
    let observation = try await service.verifyPush(target)
    XCTAssertFalse(observation.confirmed)
  }
  func testIncompleteOrWrongRefOutputCannotConfirmPush() async throws {
    let head = try await raw(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    let path = try wrapper("case \" $* \" in *\" --get-url \"*) exec /usr/bin/git \"$@\";; *\" ls-remote \"*) printf '%s\\trefs/heads/other\\n' '\(head)'; exit 0;; esac")
    let service = GitService(root: root, gitPath: path.path)
    let target = try await checkpoint(service)
    let observation = try await service.verifyPush(target)
    XCTAssertFalse(observation.confirmed)
  }
  func testOnlyMatchingVerifiedObservationResolvesItsOriginalRecord() async throws {
    let target = try await checkpoint(), observation = try await git.verifyPush(target)
    var history = OperationCenterHistory(recentLimit: 2)
    var unknown = WorkflowOperationRecord(kind: .commitAndPush, state: .resultUnknown)
    unknown.pushCheckpoint = target; unknown.localCommit = target.localHead; unknown.setDetail("Original client failure")
    history.insert(unknown)
    for _ in 0..<5 { history.insert(WorkflowOperationRecord(kind: .fetch, state: .succeeded)) }
    XCTAssertFalse(history.reconcilePush(UUID(), observation: observation))
    XCTAssertTrue(history.reconcilePush(unknown.id, observation: observation))
    let resolved = try XCTUnwrap(history.records.first { $0.id == unknown.id })
    XCTAssertEqual(resolved.state, .succeeded); XCTAssertEqual(resolved.localCommit, target.localHead)
    XCTAssertEqual(resolved.detail, "Original client failure"); XCTAssertNotNil(resolved.verifiedAt)
    XCTAssertFalse(history.reconcilePush(unknown.id, observation: observation))
  }
}
