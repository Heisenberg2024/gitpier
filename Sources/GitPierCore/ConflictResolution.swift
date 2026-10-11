import Foundation

public struct ConflictVersion: Sendable {
  public let stage: Int
  public let mode: String
  public let objectID: String
  public let contents: Data?
  public var isRegular: Bool { mode == "100644" || mode == "100755" }
  public var text: String? {
    guard let contents, !contents.contains(0) else { return nil }
    return String(data: contents, encoding: .utf8)
  }
}

public struct ConflictWorkingState: Equatable, Sendable {
  public enum Kind: Equatable, Sendable { case absent, regular, symbolicLink, other }
  public let kind: Kind
  public let digest: String
  public let permissions: Int
}

public struct ConflictSnapshot: Sendable {
  public static let textLimit = 1024 * 1024
  public let path: String
  public let head: String?
  public let branch: String
  public let operation: GitOperation?
  public let operationIdentity: Data
  public let indexEntries: Data
  public let versions: [ConflictVersion]
  public let working: ConflictWorkingState
  public let workingContents: Data?
  public let markerSize: Int
  public var base: ConflictVersion? { versions.first { $0.stage == 1 } }
  public var ours: ConflictVersion? { versions.first { $0.stage == 2 } }
  public var theirs: ConflictVersion? { versions.first { $0.stage == 3 } }
  public var supportsVersions: Bool { versions.allSatisfy(\.isRegular) }
  public var resultText: String? {
    guard supportsVersions, working.kind == .regular, let workingContents,
      !workingContents.contains(0), versions.allSatisfy({ $0.text != nil })
    else { return nil }
    return String(data: workingContents, encoding: .utf8)
  }
}

public enum ConflictResolution: Sendable {
  case text(String)
  case ours, theirs, delete
}

public struct MergeReview: Sendable {
  public let index: IndexSnapshot
  public let parents: Data
  public let message: String
}

public enum ConflictBlockChoice: Sendable { case ours, theirs, both }
public struct ConflictBlock: Sendable {
  public let range: NSRange
  public let ours: String
  public let theirs: String
}

/// Keeps exact line terminators and UTF-16 editor ranges, including Git diff3/zdiff3 markers.
public enum ConflictMarkers {
  private static func lines(_ text: String) -> [String] {
    let parts = text.components(separatedBy: "\n")
    return parts.indices.compactMap { index in
      if index == parts.count - 1 { return parts[index].isEmpty ? nil : parts[index] }
      return parts[index] + "\n"
    }
  }
  private static func marker(_ line: String, character: Character, size: Int) -> Bool {
    let body = line.trimmingCharacters(in: .newlines)
    let prefix = String(repeating: String(character), count: max(1, size))
    guard body.hasPrefix(prefix) else { return false }
    let suffix = body.dropFirst(prefix.count)
    return suffix.isEmpty || suffix.first == " " || suffix.first == "\t"
  }
  public static func containsMarkers(_ text: String, size: Int = 7) -> Bool {
    lines(text).contains { line in
      marker(line, character: "<", size: size) || marker(line, character: ">", size: size)
        || marker(line, character: "|", size: size)
    }
  }
  public static func blocks(_ text: String, size: Int = 7) -> [ConflictBlock] {
    let rows = lines(text)
    var result: [ConflictBlock] = []
    var offset = 0
    var i = 0
    while i < rows.count {
      guard marker(rows[i], character: "<", size: size) else {
        offset += rows[i].utf16.count
        i += 1
        continue
      }
      let start = i
      var j = i + 1
      var base: Int?
      var separator: Int?
      while j < rows.count {
        if marker(rows[j], character: "<", size: size) { break }
        if marker(rows[j], character: "|", size: size), separator == nil { base = j }
        if marker(rows[j], character: "=", size: size), separator == nil { separator = j }
        if marker(rows[j], character: ">", size: size) { break }
        j += 1
      }
      guard j < rows.count, marker(rows[j], character: ">", size: size), let separator,
        separator > start, base == nil || base! < separator
      else {
        offset += rows[i].utf16.count
        i += 1
        continue
      }
      let length = rows[start...j].reduce(0) { $0 + $1.utf16.count }
      result.append(
        ConflictBlock(
          range: NSRange(location: offset, length: length),
          ours: rows[(start + 1)..<(base ?? separator)].joined(),
          theirs: rows[(separator + 1)..<j].joined()))
      offset += length
      i = j + 1
    }
    return result
  }
  public static func resolving(
    _ text: String, block: Int, choice: ConflictBlockChoice, size: Int = 7
  ) -> String {
    let regions = blocks(text, size: size)
    guard regions.indices.contains(block) else { return text }
    let region = regions[block]
    let replacement: String
    switch choice {
    case .ours: replacement = region.ours
    case .theirs: replacement = region.theirs
    case .both: replacement = region.ours + region.theirs
    }
    return (text as NSString).replacingCharacters(in: region.range, with: replacement)
  }
}
