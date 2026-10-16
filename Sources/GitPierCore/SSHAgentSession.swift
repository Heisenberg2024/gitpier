import Foundation
import Darwin

/// Created only by the user's Prepare action when no inherited agent is available.
/// Never edits shell/SSH configuration or persists a passphrase.
public actor SSHAgentSession {
  public static let shared = SSHAgentSession()
  private var process: Process?
  private var directory: URL?
  private var preparation: Task<String, Error>?
  private var preparationID: UUID?
  public func currentSocket() -> String? {
    guard process?.isRunning == true else { return nil }
    guard let path = directory?.appendingPathComponent("socket").path,
      FileManager.default.fileExists(atPath: path) else { return nil }
    return path
  }
  public func prepareSocket() async throws -> String {
    if let preparation { return try await preparation.value }
    let id = UUID()
    let task = Task { try await self.startAgent() }
    preparation = task; preparationID = id
    defer { if preparationID == id { preparation = nil; preparationID = nil } }
    return try await task.value
  }
  private func startAgent() async throws -> String {
    if let socket = currentSocket() { return socket }
    await stopAgent()
    let directory = URL(fileURLWithPath: "/private/tmp/GitPier-agent-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    self.directory = directory
    let socket = directory.appendingPathComponent("socket").path
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
    // A bounded identity lifetime also limits exposure after an abnormal application exit.
    process.arguments = ["-D", "-t", "3600", "-a", socket]
    process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    do {
      try process.run(); self.process = process
      for _ in 0..<100 {
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: socket), process.isRunning { return socket }
        if !process.isRunning { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      throw AuthenticationFailure(.sshAgentUnavailable)
    } catch { await stopAgent(); throw error }
  }
  public func shutdown() async {
    let task = preparation
    task?.cancel()
    _ = await task?.result
    await stopAgent()
  }
  private func stopAgent() async {
    if let process, process.isRunning {
      let pid = process.processIdentifier
      process.terminate()
      // Foundation waitUntilExit can miss termination delivery on a cooperative executor.
      // Agent handles SIGTERM; use a bounded kernel liveness check, never an unbounded wait.
      for _ in 0..<50 {
        if !process.isRunning || Darwin.kill(pid, 0) != 0 { break }
        try? await Task.sleep(for: .milliseconds(20))
      }
    }
    process = nil
    if let directory { try? FileManager.default.removeItem(at: directory) }
    directory = nil
  }
}
