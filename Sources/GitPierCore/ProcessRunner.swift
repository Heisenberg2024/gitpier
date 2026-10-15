import Foundation
import PTYSupport

public struct CommandResult: Sendable {
  public let code: Int32
  public let stdout: Data
  public let stderr: Data
  public var text: String { String(decoding: stdout, as: UTF8.self) }
  public var errorText: String { String(decoding: stderr, as: UTF8.self) }
}

private final class ProcessBox: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var cancelled = false
  private let event = DispatchSemaphore(value: 0)
  func exited() { event.signal() }
  func wait(until deadline: DispatchTime) -> Bool { event.wait(timeout: deadline) == .success }
  func attach(_ process: Process) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    self.process = process
    return !cancelled
  }
  func cancel() {
    lock.lock()
    let firstCancellation = !cancelled
    cancelled = true
    let p = process
    lock.unlock()
    if firstCancellation { event.signal() }
    if let p, p.isRunning { gitpier_signal_process_tree(p.processIdentifier, SIGTERM) }
  }
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
}

private final class OutputBuffer: @unchecked Sendable {
  let limit: Int
  private let lock = NSLock()
  private var data = Data()
  private var overflow = false
  init(limit: Int) { self.limit = limit }
  func append(_ bytes: Data) {
    lock.lock()
    defer { lock.unlock() }
    if data.count + bytes.count > limit { overflow = true }
    if data.count < limit { data.append(bytes.prefix(limit - data.count)) }
  }
  func result() -> (Data, Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (data, overflow)
  }
}

public struct ProcessRunner: Sendable {
  public init() {}
  public func run(
    executable: String, arguments: [String], directory: URL?, environment: [String: String] = [:],
    input: Data? = nil, timeout: TimeInterval = 120, limit: Int = 16 * 1024 * 1024,
    excludingEnvironmentKeys: [String] = [], onStderr: (@Sendable (Data) -> Void)? = nil
  ) async throws -> CommandResult {
    let box = ProcessBox()
    return try await withTaskCancellationHandler(
      operation: {
        try Task.checkCancellation()
        let result = try await Task.detached(priority: .userInitiated) {
          try Self.runBlocking(
            executable: executable, arguments: arguments, directory: directory,
            environment: environment, input: input, timeout: timeout, limit: limit, box: box,
            excludingEnvironmentKeys: excludingEnvironmentKeys, onStderr: onStderr)
        }.value
        try Task.checkCancellation()
        return result
      }, onCancel: { box.cancel() })
  }
  private static func runBlocking(
    executable: String, arguments: [String], directory: URL?, environment: [String: String],
    input: Data?, timeout: TimeInterval, limit: Int, box: ProcessBox,
    excludingEnvironmentKeys: [String], onStderr: (@Sendable (Data) -> Void)?
  ) throws -> CommandResult {
    let begin = ProcessInfo.processInfo.systemUptime
    var launched = begin
    var waited = begin
    defer {
      if ProcessTrace.enabled {
        let known: Set<String> = [
          "status", "diff", "commit", "config", "rev-parse", "write-tree", "log", "for-each-ref",
          "remote", "fetch", "pull", "push", "clone",
        ]
        ProcessTrace.record(
          ProcessTraceSample(
            command: arguments.first(where: { known.contains($0) }) ?? "other",
            launchMS: (launched - begin) * 1000, waitMS: (waited - launched) * 1000,
            drainMS: (ProcessInfo.processInfo.systemUptime - waited) * 1000))
      }
    }
    let process = Process()
    let activity = ProcessTrace.enabled && URL(fileURLWithPath: executable).lastPathComponent == "git" ? GitProcessActivity.begin() : nil
    process.terminationHandler = { _ in if let activity { GitProcessActivity.end(activity) }; box.exited() }
    defer { process.terminationHandler = nil; if let activity { GitProcessActivity.end(activity) } }
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    var env = ProcessInfo.processInfo.environment
    for key in excludingEnvironmentKeys { env[key] = nil }
    // GUI launches need standard CLI locations; user shell configuration is left to the PTY.
    env["PATH"] = env["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    for (key, value) in environment { env[key] = value }
    process.environment = env
    let out = Pipe()
    let err = Pipe()
    let stdin = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = stdin
    let stdout = OutputBuffer(limit: limit)
    let stderr = OutputBuffer(limit: limit)
    guard box.attach(process) else { throw CancellationError() }
    try process.run()
    launched = ProcessInfo.processInfo.systemUptime
    if box.isCancelled { box.cancel() }
    let readers = DispatchGroup()
    for (pipe, buffer) in [(out, stdout), (err, stderr)] {
      readers.enter()
      DispatchQueue.global().async {
        while true {
          let data = pipe.fileHandleForReading.availableData
          if data.isEmpty { break }
          buffer.append(data)
          if pipe === err { onStderr?(data) }
        }
        readers.leave()
      }
    }
    DispatchQueue.global().async {
      if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) }
      try? stdin.fileHandleForWriting.close()
    }
    let finished = box.wait(until: .now() + max(0, timeout))
    let expired = !finished && !box.isCancelled
    if process.isRunning {
      gitpier_signal_process_tree(process.processIdentifier, SIGTERM)
      _ = box.wait(until: .now() + 2)
      if process.isRunning { gitpier_signal_process_tree(process.processIdentifier, SIGKILL) }
    }
    process.waitUntilExit()
    waited = ProcessInfo.processInfo.systemUptime
    // Descendants may inherit pipes. Don't wait indefinitely after a cancelled command.
    if readers.wait(timeout: .now() + 2) == .timedOut {
      try? out.fileHandleForReading.close()
      try? err.fileHandleForReading.close()
    }
    if expired { throw GitPierError.timeout }
    let (output, largeOut) = stdout.result()
    let (errors, largeErr) = stderr.result()
    if largeOut || largeErr { throw GitPierError.outputLimit }
    return CommandResult(code: process.terminationStatus, stdout: output, stderr: errors)
  }
}
