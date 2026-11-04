import Foundation

/// Suggests whitespace changes only. Callers decide whether to use the suggestion.
public enum CommitMessageFormatter {
  public static let suggestedSubjectLength = 50
  public static let suggestedBodyWidth = 72

  public static func format(_ message: String) -> String {
    let lines = message.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
    guard let first = lines.firstIndex(where: { !blank($0) }) else { return "" }
    var subject = lines[first].trimmingCharacters(in: .whitespaces)
    if let prefix = subject.range(of: #"^[A-Za-z][A-Za-z0-9-]*(?:\([^\n()]+\))?!?:[ \t]+(?=\S)"#, options: .regularExpression) {
      let normalized = subject[prefix].trimmingCharacters(in: .whitespaces) + " "
      subject.replaceSubrange(prefix, with: normalized)
    }
    var body: [String] = []
    var pendingBlank: [String] = []
    var fence: (marker: Character, length: Int)?
    var previousIndented = false
    for line in lines.dropFirst(first + 1) {
      if let open = fence {
        body.append(line)
        if let marker = fenceMarker(line), marker.marker == open.marker,
          marker.length >= open.length, marker.tail.allSatisfy(\.isWhitespace) { fence = nil }
        continue
      }
      if blank(line) { pendingBlank.append(line); continue }
      let indented = line.hasPrefix("    ") || line.hasPrefix("\t")
      if !body.isEmpty && !pendingBlank.isEmpty {
        body += previousIndented && indented ? pendingBlank : [""]
      }
      pendingBlank.removeAll(keepingCapacity: true)
      previousIndented = indented
      if let marker = fenceMarker(line) {
        fence = (marker.marker, marker.length)
        body.append(line)
      } else if indented || line.hasSuffix("  ") || line.last != " " && line.last != "\t" {
        body.append(line)
      } else {
        body.append(String(line.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed()))
      }
    }
    return body.isEmpty ? subject : subject + "\n\n" + body.joined(separator: "\n")
  }

  private static func blank(_ line: String) -> Bool { line.allSatisfy(\.isWhitespace) }

  private static func fenceMarker(_ line: String) -> (marker: Character, length: Int, tail: Substring)? {
    let indent = line.prefix(while: { $0 == " " }).count
    guard indent < 4 else { return nil }
    let text = line.dropFirst(indent)
    guard let marker = text.first, marker == "`" || marker == "~" else { return nil }
    let length = text.prefix(while: { $0 == marker }).count
    return length >= 3 ? (marker, length, text.dropFirst(length)) : nil
  }
}
