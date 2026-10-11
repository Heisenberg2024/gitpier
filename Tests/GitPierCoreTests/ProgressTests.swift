import XCTest

@testable import GitPierCore

private final class ProgressCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [GitTransferProgress] = []
  func add(_ value: GitTransferProgress) {
    lock.lock()
    values.append(value)
    lock.unlock()
  }
  var all: [GitTransferProgress] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}
final class ProgressTests: XCTestCase {
  func testCompletionSummaryRemovesTransientCountersAndKeepsFinalResults() {
    let output =
      "Enumerating objects: 22, done.\nCounting objects: 4% (1/22)\r"
      + "Counting objects: 100% (22/22), done.\rWriting objects: 100% (22/22), done.\n"
      + "remote: Total 22 (delta 0), reused 0 (delta 0)\nTo /temporary/remote.git\n"
      + "   old..new  main -> main\nwarning: useful diagnostic\n"
    XCTAssertEqual(
      GitOutputSummary.details(output),
      "To /temporary/remote.git\nold..new  main -> main\nwarning: useful diagnostic")
    XCTAssertEqual(GitOutputSummary.details(""), "")
    XCTAssertEqual(GitOutputSummary.details("Already up to date.\n"), "Already up to date.")
    XCTAssertEqual(GitOutputSummary.details("remote: Counting objects: 2, done.\n"), "")
  }
  func testChunkedCountersAndUnknownOutput() {
    let capture = ProgressCapture()
    let decoder = GitProgressDecoder { capture.add($0) }
    decoder.feed(Data("Receiving obj".utf8))
    XCTAssertTrue(capture.all.isEmpty)
    decoder.feed(Data("ects: 42% (42/100)\rwarning: token=synthetic-secret\n".utf8))
    decoder.feed(Data("remote: Resolving deltas: 100% (10/10), done.\r".utf8))
    XCTAssertEqual(
      capture.all,
      [
        GitTransferProgress(phase: .receiving, fraction: 0.42),
        GitTransferProgress(phase: .resolving, fraction: 1),
      ])
    XCTAssertNil(GitProgressDecoder.parse("private.example token=synthetic-secret 42%"))
    XCTAssertNil(GitProgressDecoder.parse("Writing objects: 999%"))
  }
  func testRepeatedProgressAndOversizedUnknownLineRemainBounded() {
    let capture = ProgressCapture()
    let decoder = GitProgressDecoder { capture.add($0) }
    decoder.feed(Data(repeating: 65, count: 100_000))
    decoder.feed(Data("\nWriting objects: 100% (1/1)\rWriting objects: 100% (1/1)\r".utf8))
    XCTAssertEqual(capture.all, [GitTransferProgress(phase: .writing, fraction: 1)])
  }
}
extension GitServiceTests {
  func testIdentityBatchPreservesValuesAndEmptyDefaults() async throws {
    try await raw(["config", "--local", "user.name", "Unicode 中文"])
    try await raw(["config", "--local", "pull.rebase", "true"])
    let values = try await git.identity()
    XCTAssertEqual(values["user.name"], "Unicode 中文")
    XCTAssertEqual(values["user.email"], "tests@example.invalid")
    XCTAssertEqual(values["pull.rebase"], "true")
    XCTAssertEqual(values["user.signingkey"], "")
  }
  func testRunnerTimeoutAndStreamedStderrPreserveExitAndOutput() async throws {
    let progress = ProgressCapture()
    let decoder = GitProgressDecoder { progress.add($0) }
    let result = try await ProcessRunner().run(
      executable: "/bin/sh",
      arguments: ["-c", "printf 'Writing objects: 100%% (1/1)\\r' >&2; printf 'complete\\n'"],
      directory: directory,
      onStderr: { decoder.feed($0) })
    XCTAssertEqual(result.code, 0)
    XCTAssertEqual(result.text, "complete\n")
    XCTAssertTrue(result.errorText.contains("Writing objects"))
    XCTAssertEqual(progress.all.last?.fraction, 1)
    do {
      _ = try await ProcessRunner().run(
        executable: "/bin/sleep", arguments: ["30"], directory: directory, timeout: 0.1)
      XCTFail("Must time out")
    } catch GitPierError.timeout {}
  }
}
