import Foundation
import CryptoKit

public enum RemoteCheckPhase: String, Codable, Sendable {
  case notChecked, queued, checking, upToDate, referencesUpdated, failed, authenticationRequired, skipped
  public static func forFailure(_ error: Error) -> RemoteCheckPhase {
    if case AutomaticFetchError.skipped = error { return .skipped }
    if case AutomaticFetchError.authenticationRequired = error { return .authenticationRequired }
    let message = error.localizedDescription.lowercased()
    let authentication = ["authentication failed", "could not read username", "terminal prompts disabled",
      "permission denied (publickey", "host key verification failed", "could not read password",
      "invalid username or token", "could not get password", "unable to get password", "keychain lookup failed",
      "ssh identity is not readable", "authentication could not be configured"]
    return authentication.contains { message.contains($0) } ? .authenticationRequired : .failed
  }
}

/// Persist opaque target digests, ownership and time/state metadata; runtime diagnostics never go to disk.
public struct RemoteCheckRecord: Codable, Equatable, Sendable {
  public var repositoryIDs: Set<UUID> = []
  public var phase: RemoteCheckPhase = .notChecked
  public var lastSuccess: Date?
  public var lastAttempt: Date?
  public var nextEligible: Date?
  public var failures = 0
  public var diagnostic: String?
  public init() {}
  public func isStale(now: Date = Date(), interval: TimeInterval) -> Bool {
    guard let lastSuccess else { return true }
    return phase == .failed || phase == .authenticationRequired || now.timeIntervalSince(lastSuccess) < 0
      || now.timeIntervalSince(lastSuccess) >= interval
  }
}

public struct RemoteCheckPolicy: Sendable {
  public static let intervals = [10, 15, 30, 60]
  public static let workspaceInterval: TimeInterval = 45 * 60
  public static func mayEvaluate(_ settings: AppSettings, active: Bool, online: Bool, writing: Bool) -> Bool {
    settings.automaticFetch && active && online && !writing
  }
  public static func includes(_ id: UUID, current: UUID?, settings: AppSettings) -> Bool {
    !settings.remoteCheckExcludedRepositories.contains(id) && (settings.remoteCheckScope == "workspace" || id == current)
  }
  public static func interval(_ settings: AppSettings, current: Bool) -> TimeInterval {
    current ? Double(intervals.contains(settings.remoteCheckIntervalMinutes) ? settings.remoteCheckIntervalMinutes : 15) * 60 : workspaceInterval
  }
  public static func backoff(_ failures: Int) -> TimeInterval {
    min(3600, 300 * pow(2, Double(max(0, min(failures - 1, 4)))))
  }
}

/// Wall dates survive restarts; uptime deadlines prevent forward/backward wall-clock jumps from
/// bypassing an interval in this process. Restored future timestamps are bounded to at most one hour.
public struct RemoteCheckSchedule: Sendable {
  private var deadlines: [String: (deadline: TimeInterval, delay: TimeInterval)] = [:]
  public init() {}
  public mutating func eligible(_ key: String, record: RemoteCheckRecord, interval: TimeInterval,
                                now: Date, uptime: TimeInterval) -> Bool {
    if record.phase == .queued || record.phase == .checking || record.phase == .authenticationRequired { return false }
    let successful = record.phase == .upToDate || record.phase == .referencesUpdated
    let successDeadline = record.lastSuccess?.addingTimeInterval(interval)
    let retryDeadline = record.nextEligible ?? record.lastAttempt?.addingTimeInterval(interval)
    let wallDeadline: Date?
    if successful { wallDeadline = successDeadline }
    else { wallDeadline = [successDeadline, retryDeadline].compactMap { $0 }.max() }
    if let old = deadlines[key], successful, old.delay != interval {
      deadlines[key] = (old.deadline - old.delay + interval, interval)
    } else if deadlines[key] == nil {
      deadlines[key] = (uptime + min(max(0, wallDeadline?.timeIntervalSince(now) ?? 0), max(interval, 3600)), interval)
    }
    return uptime >= deadlines[key]!.deadline
  }
  public mutating func attempted(_ key: String, delay: TimeInterval, uptime: TimeInterval) {
    deadlines[key] = (uptime + delay, delay)
  }
  public mutating func retain(_ keys: Set<String>) { deadlines = deadlines.filter { keys.contains($0.key) } }
}

/// Coordinator streams retain completed jobs. An older batch completion must not replace a
/// subsequent repository-button Fetch, even after the stream republishes its retained history.
public struct RemoteCheckAttemptOrder: Sendable {
  private var latest: [String: (UUID, TimeInterval)] = [:]
  public init() {}
  public mutating func accepts(target: String, attempt: UUID, startedUptime: TimeInterval) -> Bool {
    if let old = latest[target], startedUptime < old.1 || startedUptime == old.1 && attempt != old.0 { return false }
    latest[target] = (attempt, startedUptime)
    return true
  }
}

public struct RemoteCheckStore: Sendable {
  public let url: URL
  public init(url: URL) { self.url = url }
  private struct Envelope: Codable { var version = 1; var records: [String: RemoteCheckRecord] }
  public func load() throws -> [String: RemoteCheckRecord] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
    guard envelope.version == 1 else { throw GitPierError.configuration("Unsupported remote check metadata version.") }
    return envelope.records.mapValues { record in
      var record = record
      if record.phase == .checking || record.phase == .queued { record.phase = record.lastSuccess == nil ? .notChecked : .upToDate }
      return record
    }
  }
  public func save(_ records: [String: RemoteCheckRecord]) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    // Runtime diagnostics can contain server-controlled text. Keep them out of the disk file.
    let safe = records.mapValues { value in var value = value; value.diagnostic = nil; return value }
    try encoder.encode(Envelope(records: safe)).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  public static func key(_ target: WorkspaceFetchTarget) -> String {
    SHA256.hash(data: Data(target.id.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

public struct WorkspaceFetchResult: Sendable {
  public var output: String
  public var referencesUpdated: Bool
  public init(output: String = "", referencesUpdated: Bool = false) {
    self.output = output; self.referencesUpdated = referencesUpdated
  }
}
public enum AutomaticFetchError: Error, LocalizedError, Sendable {
  case skipped(String), authenticationRequired
  public var errorDescription: String? {
    switch self {
    case .skipped(let reason): return reason
    case .authenticationRequired: return "Authentication required. Run Fetch manually to continue."
    }
  }
}
