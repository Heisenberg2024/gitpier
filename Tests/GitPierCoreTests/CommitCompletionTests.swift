import CryptoKit
import XCTest

@testable import GitPierCore

extension GitServiceTests {
  func testCommitKeepsOriginalAbbreviationConfigurationVisibleToHooks() async throws {
    try await seed()
    try await raw(["config", "core.abbrev", "4"])
    try write("first.txt", "selected\n")
    try await raw(["add", "--", "first.txt"])
    let expected = try await git.snapshot()
    let hook = directory.appendingPathComponent(".git/hooks/pre-commit")
    try """
      #!/bin/sh
      value=$(/usr/bin/git config --get core.abbrev)
      [ "$value" = 4 ] || { echo 'Original hook abbreviation configuration was changed' >&2; exit 1; }
      """.write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    let result = try await git.commit(message: "fix: preserve hook configuration", expected: expected)
    let head = try await raw(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    XCTAssertEqual(result.hash, head)
    XCTAssertEqual(result.hash.count, 40)
    XCTAssertNil(result.observationWarning)
  }

  private func completionFailureGit(_ command: String, removeReceipt: Bool = false,
    failAfterCommit: Bool = false) throws -> URL {
    let wrapper = directory.appendingPathComponent(".git/completion-git")
    try """
      #!/bin/sh
      case " $* " in
        *" commit "*)
          /usr/bin/git "$@"
          result=$?
          if [ "$result" = 0 ]; then : > .git/native-commit-completed; fi
          \(removeReceipt ? "if [ -n \"${GITPIER_COMMIT_RECEIPT:-}\" ]; then rm -f -- \"$GITPIER_COMMIT_RECEIPT\"; fi" : "")
          \(failAfterCommit ? "if [ \"$result\" = 0 ]; then echo 'Synthetic failure after completed commit' >&2; exit 83; fi" : "")
          exit "$result"
          ;;
        *" \(command) "*)
          if [ -e .git/native-commit-completed ]; then
            echo 'Synthetic observation failure after native commit' >&2
            exit 82
          fi
          ;;
      esac
      exec /usr/bin/git "$@"
      """.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    return wrapper
  }

  func testNativeCommitResultSurvivesFinalIndexObservationFailure() async throws {
    try await seed()
    try write("first.txt", "selected\n")
    try await raw(["add", "--", "first.txt"])
    let expected = try await git.snapshot()
    let original = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    let wrapper = try completionFailureGit("write-tree")
    let service = GitService(root: directory, gitPath: wrapper.path)
    let result = try await service.commit(message: "fix: retain native completion", expected: expected)
    let head = try await raw(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    XCTAssertNotEqual(head, expected.head)
    XCTAssertEqual(result.hash, head)
    XCTAssertTrue(result.indexChangedDuringCommit, "An unobserved Index must require review")
    XCTAssertTrue(result.output.contains("Synthetic observation failure"), "Retain the original diagnosis")
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), original)
  }

  func testNativeCommitResultSurvivesLaterHEADQueryFailure() async throws {
    try await seed()
    try write("first.txt", "selected\n")
    try await raw(["add", "--", "first.txt"])
    let expected = try await git.snapshot()
    let wrapper = try completionFailureGit("rev-parse HEAD")
    let service = GitService(root: directory, gitPath: wrapper.path)
    let result = try await service.commit(message: "fix: retain exact commit", expected: expected)
    let head = try await raw(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    XCTAssertNotEqual(head, expected.head)
    XCTAssertEqual(result.hash, head)
    XCTAssertEqual(result.hash.count, 40)
    XCTAssertFalse(result.indexChangedDuringCommit)
  }

  func testCommitReceiptPrecedesOriginalPostCommitHookHEADChange() async throws {
    try await seed()
    try write("first.txt", "selected\n")
    try await raw(["add", "--", "first.txt"])
    let expected = try await git.snapshot()
    let hook = directory.appendingPathComponent(".git/hooks/post-commit")
    try """
      #!/bin/sh
      git rev-parse HEAD > .git/actual-created-commit || exit $?
      git update-ref HEAD HEAD^ || exit $?
      printf 'post hook executed\\n' >&2
      """.write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    let result = try await git.commit(message: "fix: capture before hooks", expected: expected)
    let created = try String(contentsOf: directory.appendingPathComponent(".git/actual-created-commit"), encoding: .utf8)
      .trimmingCharacters(in: .newlines)
    let current = try await raw(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    XCTAssertEqual(current, expected.head)
    XCTAssertNotEqual(created, current)
    XCTAssertEqual(result.hash, created, "Report the created commit rather than a hook's later HEAD")
    XCTAssertTrue(result.output.contains("post hook executed"))
  }

  func testMissingCompletionReceiptRequiresHistoryVerification() async throws {
    try await seed()
    try write("first.txt", "selected\n")
    try await raw(["add", "--", "first.txt"])
    let expected = try await git.snapshot()
    let wrapper = try completionFailureGit("rev-parse HEAD", removeReceipt: true)
    let service = GitService(root: directory, gitPath: wrapper.path)
    do {
      _ = try await service.commit(message: "fix: unverified receipt", expected: expected)
      XCTFail("A missing receipt must not invent a commit identity")
    } catch let error as CommitCompletionUnverified {
      XCTAssertTrue(error.diagnostic.contains("receipt"))
      XCTAssertTrue(error.localizedDescription.contains("History"))
    }
    let head = try await raw(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    XCTAssertNotEqual(head, expected.head, "The local commit really succeeded")
  }

  func testNativeCommitReceiptSurvivesCommandReportingFailureAfterSuccess() async throws {
    try await seed()
    try write("first.txt", "selected\n")
    try await raw(["add", "--", "first.txt"])
    let expected = try await git.snapshot()
    let wrapper = try completionFailureGit("unused-command", failAfterCommit: true)
    let service = GitService(root: directory, gitPath: wrapper.path)
    let result = try await service.commit(message: "fix: preserve receipt", expected: expected)
    let head = try await raw(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    XCTAssertNotEqual(head, expected.head)
    XCTAssertEqual(result.hash, head)
    XCTAssertTrue(result.output.contains("Synthetic failure after completed commit"))
    XCTAssertTrue(result.indexChangedDuringCommit)
  }

  func testCommitReceiptRejectsHEADMovedBeforeReceiptCapture() async throws {
    try await seed()
    try write("first.txt", "selected\n")
    try await raw(["add", "--", "first.txt"])
    let expected = try await git.snapshot()
    let wrapper = directory.appendingPathComponent(".git/receipt-race-git")
    try """
      #!/bin/sh
      case " $* " in
        *" rev-parse --verify HEAD "*)
          if [ -n "${GITPIER_COMMIT_RECEIPT:-}" ] && [ -f "$GITPIER_COMMIT_RECEIPT" ] && [ ! -e .git/receipt-raced ]; then
            : > .git/receipt-raced
            /usr/bin/git rev-parse HEAD > .git/actual-created-commit
            /usr/bin/git update-ref HEAD HEAD^ || exit $?
          fi
          ;;
      esac
      exec /usr/bin/git "$@"
      """.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    let service = GitService(root: directory, gitPath: wrapper.path)
    do {
      _ = try await service.commit(message: "fix: verify receipt identity", expected: expected)
      XCTFail("Do not report another writer's HEAD as the commit that just completed")
    } catch let error as CommitCompletionUnverified {
      XCTAssertTrue(error.diagnostic.contains("summary"))
    }
    let actual = try String(contentsOf: directory.appendingPathComponent(".git/actual-created-commit"), encoding: .utf8)
      .trimmingCharacters(in: .newlines)
    XCTAssertNotEqual(actual, expected.head)
  }

  func testCommitReceiptRejectsAnotherHEADWithCollidingShortPrefix() async throws {
    try await seed()
    try await raw(["config", "core.abbrev", "4"])
    try write("first.txt", "selected\n")
    try await raw(["add", "--", "first.txt"])
    let expected = try await git.snapshot()
    let identity = "Receipt Collision <fixture@example.invalid> 1700000000 +0000"
    typealias Object = (hash: String, message: String, bytes: Data)
    var seen: [String: Object] = [:], pair: (Object, Object)?
    // 65,537 objects guarantee a repeated four-hex prefix; normally a few
    // hundred suffice. This is bounded and deterministic for the fixture tree.
    for number in 0...65536 {
      let message = "receipt collision \(number)\n"
      let bytes = Data("tree \(expected.tree)\nparent \(expected.head!)\nauthor \(identity)\ncommitter \(identity)\n\n\(message)".utf8)
      var encoded = Data("commit \(bytes.count)\0".utf8); encoded.append(bytes)
      let hash = Insecure.SHA1.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
      let object = (hash, message, bytes), prefix = String(hash.prefix(4))
      if let previous = seen[prefix] { pair = (previous, object); break }
      seen[prefix] = object
    }
    let (created, other) = try XCTUnwrap(pair)
    for object in [created, other] {
      let written = try await raw(["hash-object", "-t", "commit", "-w", "--stdin"], input: object.bytes)
        .text.trimmingCharacters(in: .newlines)
      XCTAssertEqual(written, object.hash)
    }
    let wrapper = directory.appendingPathComponent(".git/collision-git")
    try """
      #!/bin/sh
      case " $* " in
        *" commit "*)
          /usr/bin/git "$@" > .git/collision-summary
          result=$?
          cat .git/collision-summary
          exit "$result" ;;
        *" rev-parse --verify HEAD "*)
          if [ -n "${GITPIER_COMMIT_RECEIPT:-}" ] && [ -f "$GITPIER_COMMIT_RECEIPT" ] && [ ! -e .git/collision-raced ]; then
            : > .git/collision-raced
            /usr/bin/git update-ref HEAD \(other.hash) || exit $?
          fi ;;
      esac
      exec /usr/bin/git "$@"
      """.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    let service = GitService(root: directory, gitPath: wrapper.path)
    await service.configure(gitPath: wrapper.path, authEnvironment: [
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_AUTHOR_NAME": "Receipt Collision", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
      "GIT_COMMITTER_NAME": "Receipt Collision", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
      "GIT_AUTHOR_DATE": "1700000000 +0000", "GIT_COMMITTER_DATE": "1700000000 +0000",
    ])
    do {
      _ = try await service.commit(message: created.message, expected: expected)
      XCTFail("A shared short prefix must not corroborate a different HEAD")
    } catch is CommitCompletionUnverified {}
    let native = try String(contentsOf: directory.appendingPathComponent(".git/collision-summary"), encoding: .utf8)
    let expression = try NSRegularExpression(pattern: #"\[main ([0-9a-f]+)\]"#)
    let match = try XCTUnwrap(expression.firstMatch(in: native, range: NSRange(native.startIndex..., in: native)))
    let range = try XCTUnwrap(Range(match.range(at: 1), in: native))
    XCTAssertGreaterThan(native[range].count, 4)
    XCTAssertTrue(created.hash.hasPrefix(native[range]))
    XCTAssertFalse(other.hash.hasPrefix(native[range]))
  }
}
