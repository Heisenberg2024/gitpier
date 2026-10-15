import Darwin
import XCTest

@testable import GitPierCore

final class ProcessRunnerTests: XCTestCase {
  func testClosedStdinDoesNotTerminateRunner() async throws {
    let probeKey = "GITPIER_SIGPIPE_REGRESSION_PROBE"
    if ProcessInfo.processInfo.environment[probeKey] == "1" {
      try await checkClosedStdinWithDefaultSignalHandling()
      FileHandle.standardOutput.write(Data("SIGPIPE stdin probe completed\n".utf8))
      return
    }

    // A broken pipe must fail this disposable child, never the parent test suite.
    let result = try await ProcessRunner().run(
      executable: "/usr/bin/xcrun",
      arguments: [
        "xctest", "-XCTest",
        "GitPierCoreTests.ProcessRunnerTests/testClosedStdinDoesNotTerminateRunner",
        Bundle(for: ProcessRunnerTests.self).bundleURL.path,
      ], directory: nil, environment: [probeKey: "1"], timeout: 30)
    XCTAssertEqual(result.code, 0, result.errorText + result.text)
    XCTAssertTrue(result.text.contains("SIGPIPE stdin probe completed"))
  }

  private func checkClosedStdinWithDefaultSignalHandling() async throws {
    // Swift/XCTest versions can inherit different SIGPIPE policies. Exercise the
    // normal terminating policy in an isolated process, without changing CI's policy.
    let previous = signal(SIGPIPE, SIG_DFL)
    defer { signal(SIGPIPE, previous) }
    let runner = ProcessRunner()
    let input = Data(repeating: 65, count: 4 * 1024 * 1024)
    for command in [
      "exec 0<&-; printf 'rejected input' >&2; sleep 0.05; exit 23",
      "dd bs=1 count=1 >/dev/null 2>&1; exec 0<&-; printf 'rejected input' >&2; sleep 0.05; exit 23",
    ] {
      let result = try await runner.run(
        executable: "/bin/sh", arguments: ["-c", command], directory: nil, input: input)
      XCTAssertEqual(result.code, 23)
      XCTAssertEqual(result.errorText, "rejected input")
    }

    let consumed = Data(String(repeating: "stdin 中文\n", count: 1_000).utf8)
    let result = try await runner.run(
      executable: "/bin/cat", arguments: [], directory: nil, input: consumed)
    XCTAssertEqual(result.code, 0)
    XCTAssertEqual(result.stdout, consumed)

    do {
      _ = try await runner.run(
        executable: "/bin/sh", arguments: ["-c", "exec 0<&-; sleep 10"], directory: nil,
        input: input, timeout: 0.1)
      XCTFail("Closed stdin must retain timeout handling")
    } catch GitPierError.timeout {}

    let task = Task {
      try await runner.run(
        executable: "/bin/sh", arguments: ["-c", "exec 0<&-; sleep 10"], directory: nil,
        input: input)
    }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Closed stdin must retain cancellation")
    } catch is CancellationError {}

    var action = sigaction()
    XCTAssertEqual(sigaction(SIGPIPE, nil, &action), 0)
    XCTAssertNil(action.__sigaction_u.__sa_handler, "Runner must preserve the process-wide default")
  }
}
