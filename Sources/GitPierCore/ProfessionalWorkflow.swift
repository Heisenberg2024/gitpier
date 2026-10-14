import Foundation

public struct ReflogEntry: Identifiable, Equatable, Sendable {
  public var id: String { "\(sequence):" + selector + hash + message }
  public let sequence: Int
  public let hash: String
  public let selector: String
  public let date: Date
  public let message: String
  public var operation: String {
    String((message.split(separator: ":", maxSplits: 1).first ?? "other").split(separator: "(", maxSplits: 1).first ?? "other").trimmingCharacters(in: .whitespaces)
  }
}

public struct GitWorktree: Identifiable, Equatable, Sendable {
  public var id: String { path }
  public let path: String
  public let head: String
  public let branch: String
  public let main: Bool
  public let bare: Bool
  public let locked: Bool
  public let lockReason: String
  public let prunable: Bool
  public let pruneReason: String
  public let missing: Bool
  /// nil means unavailable, rather than clean.
  public let changeCount: Int?
}

/// Persisted only after GitPier successfully creates a linked working tree.
public struct WorktreeOwnership: Codable, Equatable, Sendable {
  public let path: String
  public let commonDirectory: String
  public let gitDirectory: String
  public let creationID: String?
  public init(path: String, commonDirectory: String, gitDirectory: String, creationID: String? = nil) {
    self.path = path; self.commonDirectory = commonDirectory; self.gitDirectory = gitDirectory
    self.creationID = creationID
  }
}
public struct WorktreeRemovalReview: Sendable {
  public let worktree: GitWorktree
  public let ownership: WorktreeOwnership
}
public struct WorktreeRepairReview: Equatable, Sendable {
  public let ownership: WorktreeOwnership
  public let previous: GitWorktree
}
public enum BranchComparisonMode: String, CaseIterable, Sendable { case tips, mergeBase }
public struct BranchComparisonResult: Sendable {
  public let left: String
  public let right: String
  public let leftHash: String
  public let rightHash: String
  public let mergeBases: [String]
  public let leftOnlyCount: Int
  public let rightOnlyCount: Int
  public let leftOnly: [CommitRecord]
  public let rightOnly: [CommitRecord]
  public let diffBase: String
  public let mode: BranchComparisonMode
  public let files: [FileChange]
}
public struct BlameLine: Identifiable, Sendable {
  public var id: Int { line }
  public let line: Int
  public let originalLine: Int
  public let hash: String
  public let author: String
  public let date: Date
  public let originalPath: String
  public let text: String
  public var uncommitted: Bool { hash.allSatisfy { $0 == "0" } }
}
public struct BlamePage: Sendable {
  public let lines: [BlameLine]
  public let totalLines: Int
  public let revision: String?
}

public enum ProfessionalWorkflowParser {
  /// Resolve the existing ancestor first: Foundation can preserve /private/var for a
  /// missing leaf while returning /var for the same directory before it was moved.
  public static func canonicalPath(_ raw: String) -> String {
    var ancestor = URL(fileURLWithPath: raw).standardizedFileURL
    var suffix: [String] = []
    while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
      suffix.insert(ancestor.lastPathComponent, at: 0)
      ancestor = ancestor.deletingLastPathComponent()
    }
    var resolved = ancestor.resolvingSymlinksInPath()
    for component in suffix { resolved.appendPathComponent(component) }
    var path = resolved.standardizedFileURL.path
    if path.hasPrefix("/private/var/"),
      (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var")) == "/private/var" {
      path = String(path.dropFirst("/private".count))
    }
    return path
  }

  public static func reflog(_ data: Data, offset: Int = 0) -> [ReflogEntry] {
    let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
    var result: [ReflogEntry] = []
    var i = 0
    while i + 2 < fields.count {
      let hash = fields[i].trimmingCharacters(in: .newlines)
      if hash.isEmpty { i += 1; continue }
      let selector = fields[i + 1]
      let timestamp = selector.components(separatedBy: "@{").last?.split(separator: " ").first.flatMap { Double($0) } ?? 0
      result.append(ReflogEntry(sequence: offset + result.count, hash: hash, selector: selector, date: Date(timeIntervalSince1970: timestamp), message: fields[i + 2]))
      i += 3
    }
    return result
  }
  public static func worktrees(_ data: Data) -> [GitWorktree] {
    let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
    var records: [[String]] = [], record: [String] = []
    for field in fields {
      if field.isEmpty { if !record.isEmpty { records.append(record); record = [] } }
      else { record.append(field) }
    }
    if !record.isEmpty { records.append(record) }
    return records.enumerated().compactMap { index, row in
      func value(_ key: String) -> String { row.first { $0.hasPrefix(key + " ") }.map { String($0.dropFirst(key.count + 1)) } ?? "" }
      let rawPath = value("worktree")
      guard !rawPath.isEmpty else { return nil }
      let path = canonicalPath(rawPath)
      return GitWorktree(path: path, head: value("HEAD"), branch: value("branch"), main: index == 0,
        bare: row.contains("bare"), locked: row.contains { $0 == "locked" || $0.hasPrefix("locked ") }, lockReason: value("locked"),
        prunable: row.contains { $0 == "prunable" || $0.hasPrefix("prunable ") }, pruneReason: value("prunable"),
        missing: !FileManager.default.fileExists(atPath: path), changeCount: nil)
    }
  }
  public static func blame(_ data: Data) -> [BlameLine] {
    var result: [BlameLine] = []
    var hash = "", author = "", path = ""
    var old = 0, line = 0, time: Double = 0
    for row in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
      if row.hasPrefix("\t") {
        result.append(BlameLine(line: line, originalLine: old, hash: hash, author: author,
          date: Date(timeIntervalSince1970: time), originalPath: decodePath(path), text: String(row.dropFirst())))
      } else {
        let parts = row.split(separator: " ")
        if parts.count >= 3, [40, 64].contains(parts[0].count), parts[0].allSatisfy(\.isHexDigit) {
          hash = String(parts[0]); old = Int(parts[1]) ?? 0; line = Int(parts[2]) ?? 0
          author = ""; path = ""; time = 0
        } else if row.hasPrefix("author ") { author = String(row.dropFirst(7)) }
        else if row.hasPrefix("author-time ") { time = Double(row.dropFirst(12)) ?? 0 }
        else if row.hasPrefix("filename ") { path = String(row.dropFirst(9)) }
      }
    }
    return result
  }
  /// Git's core.quotePath uses C escapes and UTF-8 octal bytes.
  public static func decodePath(_ value: String) -> String {
    guard value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
    let input = Array(value.dropFirst().dropLast().utf8)
    var bytes: [UInt8] = [], i = 0
    while i < input.count {
      if input[i] != 92 { bytes.append(input[i]); i += 1; continue }
      i += 1
      guard i < input.count else { break }
      if input[i] >= 48 && input[i] <= 55 {
        var number = 0, count = 0
        while i < input.count, count < 3, input[i] >= 48, input[i] <= 55 { number = number * 8 + Int(input[i] - 48); i += 1; count += 1 }
        bytes.append(UInt8(truncatingIfNeeded: number))
      } else {
        let escapes: [UInt8: UInt8] = [97: 7, 98: 8, 116: 9, 110: 10, 118: 11, 102: 12, 114: 13]
        bytes.append(escapes[input[i]] ?? input[i]); i += 1
      }
    }
    return String(decoding: bytes, as: UTF8.self)
  }
}

/// A FIFO for lifecycle metadata shared by different working-tree GitService actors.
actor CommonDirectoryQueue {
  static let shared = CommonDirectoryQueue()
  private var held: Set<String> = []
  private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  func acquire(_ key: String) async {
    if held.insert(key).inserted { return }
    await withCheckedContinuation { waiters[key, default: []].append($0) }
  }
  func release(_ key: String) {
    if var queue = waiters[key], !queue.isEmpty {
      let next = queue.removeFirst(); waiters[key] = queue; next.resume()
    } else { held.remove(key); waiters[key] = nil }
  }
}
