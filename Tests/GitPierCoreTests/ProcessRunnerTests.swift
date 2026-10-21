import Darwin
import XCTest

@testable import GitPierCore

private final class OutputCallbackProbe: @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var returned = false
  func waitForEntry() -> Bool { entered.wait(timeout: .now() + 10) == .success }
  func block() { entered.signal(); _ = release.wait(timeout: .now() + 10) }
  func markReturned() { lock.lock(); returned = true; lock.unlock() }
  var hasReturned: Bool { lock.lock(); defer { lock.unlock() }; return returned }
}

final class ProcessRunnerTests: XCTestCase {
  func testOutputPumpCapturesBothStreamsUnderBackpressure() async throws {
    let size = 256 * 1024 + 17
    let result = try await ProcessRunner().run(executable: "/usr/bin/python3", arguments: ["-c", """
      import sys, threading
      writer = threading.Thread(target=lambda: sys.stdout.buffer.write(b'A' * \(size)))
      writer.start()
      sys.stderr.buffer.write(b'B' * \(size))
      writer.join()
      """], directory: nil)
    XCTAssertEqual(result.code, 0)
    XCTAssertEqual(result.stdout, Data(repeating: 65, count: size))
    XCTAssertEqual(result.stderr, Data(repeating: 66, count: size))
  }

  func testOutputPumpRetainsTheStderrLimit() async throws {
    do {
      _ = try await ProcessRunner().run(executable: "/usr/bin/python3",
        arguments: ["-c", "import sys; sys.stderr.buffer.write(b'x' * 8192)"], directory: nil, limit: 4096)
      XCTFail("Oversized stderr must not become a successful partial result")
    } catch GitPierError.outputLimit {}
  }

  func testOutputCallbacksCannotOutliveTheCommandResult() async throws {
    let probe = OutputCallbackProbe()
    defer { probe.release.signal() }
    let work = Task {
      let result = try await ProcessRunner().run(executable: "/bin/sh",
        arguments: ["-c", "printf 'stderr payload' >&2"], directory: nil, onStderr: { _ in probe.block() })
      probe.markReturned()
      return result
    }
    let entered = await Task.detached { probe.waitForEntry() }.value
    XCTAssertTrue(entered)
    // Hold a real reader beyond the existing two-second drain deadline.
    try await Task.sleep(for: .milliseconds(2500))
    let returnedWithReaderActive = probe.hasReturned
    probe.release.signal()
    let result = try await work.value
    XCTAssertFalse(returnedWithReaderActive, "Returning while an output reader is active permits late callbacks and concurrent descriptor close/reuse")
    XCTAssertEqual(result.code, 0); XCTAssertEqual(result.errorText, "stderr payload")
  }

  func testInheritedOutputPipesDoNotCrashOrContaminateLaterCommands() async throws {
    let probeKey = "GITPIER_OUTPUT_DRAIN_REGRESSION_PROBE"
    if ProcessInfo.processInfo.environment[probeKey] == "1" {
      for _ in 0..<3 {
        let result = try await ProcessRunner().run(executable: "/bin/sh",
          arguments: ["-c", "/bin/sleep 3 & printf 'parent stdout'; printf 'parent stderr' >&2"], directory: nil)
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.text, "parent stdout")
        XCTAssertEqual(result.errorText, "parent stderr")
        // Reuse descriptors immediately while the inherited writer is still alive.
        let next = try await ProcessRunner().run(executable: "/usr/bin/printf", arguments: ["next command"], directory: nil)
        XCTAssertEqual(next.code, 0); XCTAssertEqual(next.text, "next command")
      }
      FileHandle.standardOutput.write(Data("Output drain probe completed\n".utf8))
      return
    }
    let bundle = Bundle(for: ProcessRunnerTests.self).bundleURL.path
    // The old implementation can raise an Objective-C exception. Capture the
    // disposable XCTest process to files, so a pipe crash cannot kill this suite.
    // Dynamic Self captures the non-Sendable test instance in Swift 6.1.
    let result = try await Task.detached { @Sendable [bundle, probeKey] in
      try ProcessRunnerTests.outputDrainProbe(bundle: bundle, key: probeKey)
    }.value
    XCTAssertEqual(result.0, 0, result.1)
    XCTAssertTrue(result.1.contains("Output drain probe completed"))
  }

  private static func outputDrainProbe(bundle: String, key: String) throws -> (Int32, String) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-output-probe-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("output.log")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["xctest", "-XCTest", "GitPierCoreTests.ProcessRunnerTests/testInheritedOutputPipesDoNotCrashOrContaminateLaterCommands", bundle]
    var environment = ProcessInfo.processInfo.environment; environment[key] = "1"; process.environment = environment
    process.standardOutput = handle; process.standardError = handle
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()
    if finished.wait(timeout: .now() + 30) == .timedOut, process.isRunning {
      process.terminate()
      if finished.wait(timeout: .now() + 2) == .timedOut, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    }
    process.waitUntilExit()
    return (process.terminationStatus, try String(contentsOf: output, encoding: .utf8))
  }

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
