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
