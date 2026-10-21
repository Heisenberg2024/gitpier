import Darwin
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
  var hasOverflowed: Bool { lock.lock(); defer { lock.unlock() }; return overflow }
}

private final class OutputDrain: @unchecked Sendable {
  private let lock = NSLock()
  private var deadline: TimeInterval?
  private var failure: Int32?
  func finish() { lock.lock(); deadline = ProcessInfo.processInfo.systemUptime + 2; lock.unlock() }
  var expired: Bool {
    lock.lock(); defer { lock.unlock() }
    return deadline.map { ProcessInfo.processInfo.systemUptime >= $0 } ?? false
  }
  func fail(_ code: Int32) { lock.lock(); failure = code; lock.unlock() }
  var error: Int32? { lock.lock(); defer { lock.unlock() }; return failure }
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
    // Finder's PATH often contains only system directories. Preserve its precedence,
    // while making standard macOS CLI helpers available to both manual and automatic Git.
    for location in ["/opt/homebrew/bin", "/usr/local/bin"] {
      if !env["PATH"]!.split(separator: ":").contains(Substring(location)) { env["PATH"]! += ":" + location }
    }
    for (key, value) in environment { env[key] = value }
    process.environment = env
    let out = Pipe()
    let err = Pipe()
    let stdin = Pipe()
    // Git can reject input or exit before the asynchronous writer finishes.
    // Return EPIPE on this descriptor instead of terminating the caller; keep
    // the process-wide signal policy (and hooks/child processes) unchanged.
    guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    process.standardOutput = out
    process.standardError = err
    process.standardInput = stdin
    let stdout = OutputBuffer(limit: limit)
    let stderr = OutputBuffer(limit: limit)
    guard box.attach(process) else { throw CancellationError() }
    try process.run()
    launched = ProcessInfo.processInfo.systemUptime
    if box.isCancelled { box.cancel() }
    let readers = DispatchGroup(), drain = OutputDrain()
    readers.enter()
    DispatchQueue.global().async {
      defer { readers.leave() }
      Self.readOutput(out: out, err: err, stdout: stdout, stderr: stderr, drain: drain, onStderr: onStderr)
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
    // Only the reader closes its descriptors. Closing a FileHandle concurrently
    // with availableData can raise an Objective-C exception on macOS 15.
    drain.finish()
    readers.wait()
    if expired { throw GitPierError.timeout }
    if let code = drain.error { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    let (output, largeOut) = stdout.result()
    let (errors, largeErr) = stderr.result()
    if largeOut || largeErr { throw GitPierError.outputLimit }
    return CommandResult(code: process.terminationStatus, stdout: output, stderr: errors)
  }

  private static func readOutput(out: Pipe, err: Pipe, stdout: OutputBuffer, stderr: OutputBuffer,
    drain: OutputDrain, onStderr: (@Sendable (Data) -> Void)?) {
    let handles = [out.fileHandleForReading, err.fileHandleForReading]
    defer { for handle in handles { try? handle.close() } }
    var descriptors = handles.map { pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN), revents: 0) }
    for descriptor in descriptors {
      let flags = fcntl(descriptor.fd, F_GETFL)
      guard flags >= 0, fcntl(descriptor.fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { drain.fail(errno); return }
    }
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while descriptors.contains(where: { $0.fd >= 0 }) {
      // Descendants may keep pipes open after their parent exits. After the
      // drain deadline, consume already-readable data without waiting for them.
      let finishing = drain.expired
      let ready = poll(&descriptors, nfds_t(descriptors.count), finishing ? 0 : 100)
      if ready < 0 {
        if errno == EINTR { continue }
        drain.fail(errno); return
      }
      if ready == 0 { if finishing { return }; continue }
      for index in descriptors.indices where descriptors[index].fd >= 0 && descriptors[index].revents != 0 {
        if descriptors[index].revents & Int16(POLLNVAL) != 0 { drain.fail(EBADF); return }
        let count = Darwin.read(descriptors[index].fd, &buffer, buffer.count)
        if count > 0 {
          let data = Data(buffer.prefix(count))
          if index == 0 { stdout.append(data) } else { stderr.append(data); onStderr?(data) }
        } else if count == 0 { descriptors[index].fd = -1 }
        else if errno != EAGAIN && errno != EINTR { drain.fail(errno); return }
      }
      // A continuously writing descendant cannot extend draining indefinitely.
      if drain.expired && (stdout.hasOverflowed || stderr.hasOverflowed) { return }
    }
  }
}
