import Foundation

public enum DiffLineKind: String, Sendable { case context, addition, deletion, header, gap }
public struct DiffLine: Identifiable, Sendable {
  public let id: Int
  public let kind: DiffLineKind
  public let text: String
  public let oldNumber: Int?
  public let newNumber: Int?
  public init(id: Int, kind: DiffLineKind, text: String, oldNumber: Int?, newNumber: Int?) {
    self.id = id
    self.kind = kind
    self.text = text
    self.oldNumber = oldNumber
    self.newNumber = newNumber
  }
}
public struct DiffPair: Identifiable, Sendable {
  public let id: Int
  public let old: DiffLine?
  public let new: DiffLine?
}
public struct DiffHunk: Identifiable, Sendable {
  public let id: Int
  public let header: String
  public let lines: [DiffLine]
  public let patch: Data
  public let rowOffset: Int
  public var additions: Int { lines.filter { $0.kind == .addition }.count }
  public var deletions: Int { lines.filter { $0.kind == .deletion }.count }
}
public struct DiffDocument: Sendable {
  public let revision = UUID()
  public let raw: String
  public let hunks: [DiffHunk]
  public let pairs: [DiffPair]
  public let binary: Bool
  public let complexMetadata: Bool
  public var additions: Int { hunks.reduce(0) { $0 + $1.additions } }
  public var deletions: Int { hunks.reduce(0) { $0 + $1.deletions } }
  public var hasOldContent: Bool {
    hunks.contains { $0.lines.contains { $0.oldNumber != nil } }
  }
  public static let empty = DiffParser.parse(Data())
}

public enum DiffParser {
  public static func parse(_ data: Data) -> DiffDocument {
    let raw = String(decoding: data, as: UTF8.self)
    // CRLF is one Swift Character; split the LF protocol delimiter without dropping CR bytes.
    let source = raw.components(separatedBy: "\n")
    let binary = source.contains { $0.hasPrefix("Binary files ") || $0 == "GIT binary patch" }
    // Preserve the source for browser/export fallback, but expose no actionable hunks or
    // invented line numbers when an untrusted remote patch contains invalid coordinates.
    func invalidHunks() -> DiffDocument {
      DiffDocument(raw: raw, hunks: [], pairs: [], binary: binary, complexMetadata: true)
    }
    let complex = String(data: data, encoding: .utf8) == nil || source.contains {
      $0.hasPrefix("rename ") || $0.hasPrefix("copy ") || $0.hasPrefix("old mode ")
        || $0.hasPrefix("new mode ") || ($0.hasPrefix("index ") && $0.hasSuffix(" 160000"))
        || $0 == "new file mode 160000" || $0 == "deleted file mode 160000"
    }
    var prefix: [String] = []
    var hunks: [DiffHunk] = []
    var pairs: [DiffPair] = []
    var i = 0
    var lineID = 0
    while i < source.count && !source[i].hasPrefix("@@ ") {
      prefix.append(source[i])
      i += 1
    }
    while i < source.count {
      guard source[i].hasPrefix("@@ ") else {
        i += 1
        continue
      }
      let header = source[i]
      let start = i
      // Accept CRLF protocol headers without stripping CR bytes from the original
      // header, patch or file content (a content CR may be meaningful to Git).
      let protocolHeader = header.hasSuffix("\r") ? String(header.dropLast()) : header
      let tokens = protocolHeader.split(separator: " ")
      // Leave headroom for the body counters and selected-line patch offsets. The body
      // cannot contain more lines than the supplied text; huge declared counts are invalid.
      let maximum = Int.max - source.count - 1
      guard tokens.count >= 4, tokens[0] == "@@", tokens[3] == "@@",
        let oldRange = range(tokens[1], marker: "-", maximum: maximum, lineLimit: source.count),
        let newRange = range(tokens[2], marker: "+", maximum: maximum, lineLimit: source.count),
        oldRange.count > 0 || newRange.count > 0 else { return invalidHunks() }
      var old = oldRange.start, new = newRange.start
      var oldUsed = 0, newUsed = 0
      var lines: [DiffLine] = []
      i += 1
      while i < source.count && !source[i].hasPrefix("@@ ") && !source[i].hasPrefix("diff --git ") {
        let row = source[i]
        i += 1
        if row.hasPrefix("\\ No newline") { continue }
        guard let marker = row.first, [" ", "+", "-"].contains(marker) else { continue }
        let kind: DiffLineKind = marker == "+" ? .addition : marker == "-" ? .deletion : .context
        if kind != .addition { guard oldUsed < oldRange.count else { return invalidHunks() }; oldUsed += 1 }
        if kind != .deletion { guard newUsed < newRange.count else { return invalidHunks() }; newUsed += 1 }
        lines.append(
          DiffLine(
            id: lineID, kind: kind, text: String(row.dropFirst()),
            oldNumber: kind == .addition ? nil : old, newNumber: kind == .deletion ? nil : new))
        lineID += 1
        if kind != .addition {
          let next = old.addingReportingOverflow(1); guard !next.overflow else { return invalidHunks() }; old = next.partialValue
        }
        if kind != .deletion {
          let next = new.addingReportingOverflow(1); guard !next.overflow else { return invalidHunks() }; new = next.partialValue
        }
      }
      guard oldUsed == oldRange.count, newUsed == newRange.count else { return invalidHunks() }
      let offset = pairs.count
      let heading = DiffLine(
        id: lineID, kind: .header, text: header, oldNumber: nil, newNumber: nil)
      lineID += 1
      pairs.append(DiffPair(id: pairs.count, old: heading, new: heading))
      var cursor = 0
      while cursor < lines.count {
        let line = lines[cursor]
        if line.kind == .context {
          pairs.append(DiffPair(id: pairs.count, old: line, new: line))
          cursor += 1
          continue
        }
        var removed: [DiffLine] = []
        var added: [DiffLine] = []
        while cursor < lines.count && lines[cursor].kind != .context {
          if lines[cursor].kind == .deletion { removed.append(lines[cursor]) }
          if lines[cursor].kind == .addition { added.append(lines[cursor]) }
          cursor += 1
        }
        for j in 0..<max(removed.count, added.count) {
          pairs.append(
            DiffPair(
              id: pairs.count, old: j < removed.count ? removed[j] : nil,
              new: j < added.count ? added[j] : nil))
        }
      }
      var patchLines = prefix + Array(source[start..<i])
      while patchLines.last == "" { patchLines.removeLast() }
      hunks.append(
        DiffHunk(
          id: hunks.count, header: header, lines: lines,
          patch: Data((patchLines.joined(separator: "\n") + "\n").utf8), rowOffset: offset))
    }
    return DiffDocument(
      raw: raw, hunks: hunks, pairs: pairs, binary: binary, complexMetadata: complex)
  }
  private static func range(_ token: Substring, marker: Character, maximum: Int, lineLimit: Int) -> (start: Int, count: Int)? {
    guard token.first == marker else { return nil }
    let values = token.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
    guard (1...2).contains(values.count), values.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
      let start = Int(values[0]) else { return nil }
    let count: Int
    if values.count == 2 { guard let value = Int(values[1]) else { return nil }; count = value }
    else { count = 1 }
    guard count <= lineLimit, start > 0 || count == 0 else { return nil }
    let end = start.addingReportingOverflow(count)
    guard !end.overflow, end.partialValue <= maximum else { return nil }
    return (start, count)
  }
}
