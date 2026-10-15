import Foundation

public struct ProcessTraceSample: Sendable {
  public let command: String
  public let launchMS: Double
  public let waitMS: Double
  public let drainMS: Double
}
private final class ProcessTraceBuffer: @unchecked Sendable {
  let lock = NSLock()
  var samples: [ProcessTraceSample] = []
}
public enum ProcessTrace {
  public static let enabled =
    ProcessInfo.processInfo.environment["GITPIER_PERFORMANCE_TRACE"] == "1"
  private static let buffer = ProcessTraceBuffer()
  public static func record(_ sample: ProcessTraceSample) {
    guard enabled else { return }
    buffer.lock.lock()
    buffer.samples.append(sample)
    buffer.lock.unlock()
  }
  public static func take() -> [ProcessTraceSample] {
    buffer.lock.lock()
    defer { buffer.lock.unlock() }
    let result = buffer.samples
    buffer.samples.removeAll()
    return result
  }
}

/// Opt-in performance counters contain only counts; arguments, paths and queries are never stored.
private final class GitActivityBuffer: @unchecked Sendable {
  let lock = NSLock()
  var active: Set<UUID> = []
  var peak = 0
  var launches = 0
}
public enum GitProcessActivity {
  private static let buffer = GitActivityBuffer()
  static func begin() -> UUID {
    buffer.lock.lock(); defer { buffer.lock.unlock() }
    let id = UUID(); buffer.active.insert(id); buffer.launches += 1
    buffer.peak = max(buffer.peak, buffer.active.count); return id
  }
  static func end(_ id: UUID) {
    buffer.lock.lock(); defer { buffer.lock.unlock() }; buffer.active.remove(id)
  }
  public static func reset() {
    buffer.lock.lock(); defer { buffer.lock.unlock() }; buffer.peak = buffer.active.count; buffer.launches = 0
  }
  public static func snapshot() -> (active: Int, peak: Int, launches: Int) {
    buffer.lock.lock(); defer { buffer.lock.unlock() }; return (buffer.active.count, buffer.peak, buffer.launches)
  }
}
