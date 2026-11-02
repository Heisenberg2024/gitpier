import XCTest

@testable import GitPierCore

extension GitServiceTests {
  func testReviewedCommitHonorsOriginalReferenceTransactionVeto() async throws {
    try await seed()
    try write("first.txt", "selected\n")
    try await raw(["add", "--", "first.txt"])
    let expected = try await git.snapshot()
    let hook = directory.appendingPathComponent(".git/hooks/reference-transaction")
    try """
      #!/bin/sh
      if [ "$1" = prepared ]; then
        echo 'Synthetic native ref policy veto' >&2
        exit 1
      fi
      """.write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    // Positive control: this policy is genuinely enforced by native Git.
    do { try await raw(["commit", "-m", "native policy control"]); XCTFail("Native veto did not run") }
    catch { XCTAssertTrue(error.localizedDescription.contains("Synthetic native ref policy veto")) }
    let before = try await raw(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    let index = directory.appendingPathComponent(".git/index")
    let indexBytes = try Data(contentsOf: index)
    XCTAssertEqual(before, expected.head)
    do {
      _ = try await git.commit(message: "fix: honor native ref policy", expected: expected)
      XCTFail("Private commit hooks must not bypass the original ref-transaction policy")
    } catch { XCTAssertTrue(error.localizedDescription.contains("Synthetic native ref policy veto")) }
    let after = try await raw(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    XCTAssertEqual(after, before)
    XCTAssertEqual(try Data(contentsOf: index), indexBytes)
  }

  func testOriginalReferenceTransactionReceivesNativeArgumentsAndInput() async throws {
    try await seed()
    try write("first.txt", "selected\n")
    try await raw(["add", "--", "first.txt"])
    let hooks = directory.appendingPathComponent(".git/hooks with 'quote' and newline\n")
    try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
    try await raw(["config", "core.hooksPath", hooks.path])
    let hook = hooks.appendingPathComponent("reference-transaction")
    try """
      #!/bin/sh
      printf '%s' "$0" > .git/ref-hook-path
      printf '%s' "$#" > .git/ref-hook-argument-count
      printf 'phase:%s\\n' "$1" >> .git/ref-hook-transcript
      cat >> .git/ref-hook-transcript
      """.write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    let before = try await raw(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    try await raw(["commit", "-m", "fix: delegate hook input"])
    let nativeHash = try await raw(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    let transcript = directory.appendingPathComponent(".git/ref-hook-transcript")
    let nativeInput = try String(contentsOf: transcript, encoding: .utf8)
    let nativePath = try String(contentsOf: directory.appendingPathComponent(".git/ref-hook-path"), encoding: .utf8)
    // Restore only the disposable fixture's ref; retain the staged tree and
    // compare against the installed Git's complete native hook protocol.
    try await raw(["update-ref", "HEAD", before, nativeHash])
    try FileManager.default.removeItem(at: transcript)
    let expected = try await git.snapshot()
    let result = try await git.commit(message: "fix: delegate hook input", expected: expected)
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(".git/ref-hook-path"), encoding: .utf8), nativePath)
    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(".git/ref-hook-argument-count"), encoding: .utf8), "1")
    let reviewedInput = try String(contentsOf: transcript, encoding: .utf8)
    XCTAssertEqual(reviewedInput.replacingOccurrences(of: result.hash, with: "<created>"),
      nativeInput.replacingOccurrences(of: nativeHash, with: "<created>"))
    XCTAssertTrue(reviewedInput.contains("phase:prepared\n"))
    XCTAssertTrue(reviewedInput.contains("phase:committed\n"))
    XCTAssertTrue(reviewedInput.contains(before + " " + result.hash + " refs/heads/main"))
  }
}
