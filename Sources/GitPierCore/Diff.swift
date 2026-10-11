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
    let source = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let binary = raw.contains("Binary files ") || raw.contains("GIT binary patch")
    let complex = source.contains {
      $0.hasPrefix("rename ") || $0.hasPrefix("copy ") || $0.hasPrefix("old mode ")
        || $0.hasPrefix("new mode ") || $0.contains("160000")
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
      let tokens = header.split(separator: " ")
      var old = tokens.count > 2 ? Int(tokens[1].dropFirst().split(separator: ",")[0]) ?? 0 : 0
      var new = tokens.count > 2 ? Int(tokens[2].dropFirst().split(separator: ",")[0]) ?? 0 : 0
      var lines: [DiffLine] = []
      i += 1
      while i < source.count && !source[i].hasPrefix("@@ ") && !source[i].hasPrefix("diff --git ") {
        let row = source[i]
        i += 1
        if row.hasPrefix("\\ No newline") { continue }
        guard let marker = row.first, [" ", "+", "-"].contains(marker) else { continue }
        let kind: DiffLineKind = marker == "+" ? .addition : marker == "-" ? .deletion : .context
        lines.append(
          DiffLine(
            id: lineID, kind: kind, text: String(row.dropFirst()),
            oldNumber: kind == .addition ? nil : old, newNumber: kind == .deletion ? nil : new))
        lineID += 1
        if kind != .addition { old += 1 }
        if kind != .deletion { new += 1 }
      }
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
}
