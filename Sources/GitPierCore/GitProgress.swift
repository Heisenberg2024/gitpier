import Foundation

/// Completed commands retain diagnostics and final results, never transient transfer counters.
public enum GitOutputSummary {
  public static func details(_ output: String) -> String {
    output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { fragment in
      let line = fragment.trimmingCharacters(in: .whitespaces)
      let counter = line.hasPrefix("remote: ") ? String(line.dropFirst(8)) : line
      guard !line.isEmpty, GitProgressDecoder.parse(line) == nil,
        !counter.hasPrefix("Enumerating objects:"),
        !counter.hasPrefix("Counting objects:"),
        !counter.hasPrefix("Compressing objects:"),
        !counter.hasPrefix("Receiving objects:"),
        !counter.hasPrefix("Resolving deltas:"),
        !counter.hasPrefix("Writing objects:"),
        !counter.hasPrefix("Updating files:"),
        !counter.hasPrefix("Checking out files:"),
        !counter.hasPrefix("Total ")
      else { return nil }
      return line
    }.joined(separator: "\n")
  }
}

public enum GitTransferPhase: String, Codable, Sendable {
  case counting, compressing, receiving, resolving, writing, checkout
}
public struct GitTransferProgress: Equatable, Sendable {
  public let phase: GitTransferPhase
  public let fraction: Double
  public init(phase: GitTransferPhase, fraction: Double) {
    self.phase = phase
    self.fraction = fraction
  }
}

/// Only known Git transfer counters reach UI. Raw stderr, paths and authentication data never do.
public final class GitProgressDecoder: @unchecked Sendable {
  private let lock = NSLock()
  private var pending = Data()
  private var last: GitTransferProgress?
  private var lastEmission: TimeInterval = 0
  private let sink: @Sendable (GitTransferProgress) -> Void
  public init(_ sink: @escaping @Sendable (GitTransferProgress) -> Void) { self.sink = sink }
  public func feed(_ bytes: Data) {
    lock.lock()
    pending.append(bytes)
    var candidate: GitTransferProgress?
    while let end = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
      let line = String(decoding: pending[..<end], as: UTF8.self)
      pending.removeSubrange(...end)
      if let parsed = Self.parse(line) { candidate = parsed }
    }
    if pending.count > 8192 { pending = Data(pending.suffix(8192)) }
    let now = ProcessInfo.processInfo.systemUptime
    let emit = candidate.flatMap { value -> GitTransferProgress? in
      guard value != last else { return nil }
      guard value.phase != last?.phase || value.fraction == 1 || now - lastEmission >= 0.05 else {
        return nil
      }
      last = value
      lastEmission = now
      return value
    }
    lock.unlock()
    if let emit { sink(emit) }
  }
  public static func parse(_ input: String) -> GitTransferProgress? {
    var line = input.trimmingCharacters(in: .whitespaces)
    if line.hasPrefix("remote: ") { line = String(line.dropFirst(8)) }
    let prefixes: [(String, GitTransferPhase)] = [
      ("Counting objects:", .counting), ("Compressing objects:", .compressing),
      ("Receiving objects:", .receiving), ("Resolving deltas:", .resolving),
      ("Writing objects:", .writing), ("Updating files:", .checkout),
      ("Checking out files:", .checkout),
    ]
    guard let phase = prefixes.first(where: { line.hasPrefix($0.0) })?.1,
      let range = line.range(of: #"\b[0-9]{1,3}%"#, options: .regularExpression),
      let percent = Int(line[range].dropLast()), (0...100).contains(percent)
    else { return nil }
    return GitTransferProgress(phase: phase, fraction: Double(percent) / 100)
  }
}
