import Foundation

public struct LFSPointer: Equatable, Sendable {
  public static let limit = 1024
  public let oid: String
  public let size: UInt64
  public static func parse(_ data: Data) -> LFSPointer? {
    guard data.count <= limit, !data.contains(0), let text = String(data: data, encoding: .utf8) else { return nil }
    let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }.filter { !$0.isEmpty }
    guard lines.first == "version https://git-lfs.github.com/spec/v1" else { return nil }
    var oid: String?, size: UInt64?
    for line in lines.dropFirst() {
      if line.hasPrefix("oid sha256:"), oid == nil {
        let value = String(line.dropFirst(11))
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }; oid = value.lowercased()
      } else if line.hasPrefix("size "), size == nil { size = UInt64(line.dropFirst(5)) }
      else if !line.hasPrefix("ext-") { return nil }
    }
    guard let oid, let size else { return nil }; return LFSPointer(oid: oid, size: size)
  }
}
public struct LFSRule: Identifiable, Sendable {
  public let id: Int
  public let pattern: String
  public let attributes: [String]
}
public enum LFSAttributes {
  public static let limit = 1024 * 1024
  private static let values = ["filter=lfs", "diff=lfs", "merge=lfs", "-text"]
  /// Git's quoted pattern syntax, not shell quoting. All untouched lines keep their bytes.
  static func tokens(_ line: String) -> [String]? {
    let bytes = Array(line.utf8)
    var i = 0, result: [String] = []
    while i < bytes.count {
      while i < bytes.count && (bytes[i] == 32 || bytes[i] == 9) { i += 1 }
      if i == bytes.count { break }
      if result.isEmpty && bytes[i] == 35 { return [] }
      var token: [UInt8] = []
      if bytes[i] == 34 {
        i += 1; var closed = false
        while i < bytes.count {
          let byte = bytes[i]; i += 1
          if byte == 34 { closed = true; break }
          if byte == 92 {
            guard i < bytes.count else { return nil }
            let escaped = bytes[i]; i += 1
            if (48...55).contains(escaped) {
              var value = Int(escaped - 48), digits = 1
              while digits < 3 && i < bytes.count && (48...55).contains(bytes[i]) {
                value = value * 8 + Int(bytes[i] - 48); i += 1; digits += 1
              }
              guard value <= 255 else { return nil }; token.append(UInt8(value))
            } else {
              switch escaped {
              case 34, 92: token.append(escaped)
              case 116: token.append(9)
              case 110: token.append(10)
              case 114: token.append(13)
              case 98: token.append(8)
              case 102: token.append(12)
              case 118: token.append(11)
              default: return nil
              }
            }
          } else { token.append(byte) }
        }
        guard closed, i == bytes.count || bytes[i] == 32 || bytes[i] == 9 else { return nil }
      } else {
        while i < bytes.count && bytes[i] != 32 && bytes[i] != 9 { token.append(bytes[i]); i += 1 }
      }
      guard let text = String(bytes: token, encoding: .utf8) else { return nil }; result.append(text)
    }
    return result
  }
  public static func rules(_ data: Data) throws -> [LFSRule] {
    guard data.count <= limit, let text = String(data: data, encoding: .utf8), !data.contains(0) else {
      throw GitPierError.invalidInput("The root .gitattributes must be UTF-8 within 1 MiB.")
    }
    return text.components(separatedBy: "\n").enumerated().compactMap { index, line in
      guard let fields = tokens(line.hasSuffix("\r") ? String(line.dropLast()) : line), fields.count > 1,
        !fields[0].hasPrefix("[attr]"), fields.dropFirst().contains("filter=lfs") else { return nil }
      return LFSRule(id: index, pattern: fields[0], attributes: Array(fields.dropFirst()))
    }
  }
  private static func quote(_ pattern: String) -> String {
    "\"" + pattern.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\t", with: "\\t") + "\""
  }
  public static func edit(_ data: Data, pattern: String, track: Bool) throws -> Data {
    _ = try rules(data)
    guard !pattern.isEmpty, pattern.utf8.count <= 4096, !pattern.contains("\n"), !pattern.contains("\r"),
      !pattern.utf8.contains(0), !pattern.hasPrefix("!"), !pattern.hasPrefix("[attr]"),
      !pattern.split(separator: "/").contains("..") else {
      throw GitPierError.invalidInput("Enter a nonempty repository glob without newlines, negation or parent traversal.")
    }
    let text = String(decoding: data, as: UTF8.self)
    let newline = text.contains("\r\n") ? "\r\n" : "\n"
    if track {
      let canonical = quote(pattern) + " " + values.joined(separator: " ")
      let last = text.components(separatedBy: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
      if let last, let fields = tokens(last.hasSuffix("\r") ? String(last.dropLast()) : last), fields == [pattern] + values { return data }
      let prefix = data.isEmpty || data.last == 10 ? text : text + newline
      let result = Data((prefix + canonical + newline).utf8)
      guard result.count <= limit else { throw GitPierError.outputLimit }; return result
    }
    var output = "", changed = false
    let lines = text.components(separatedBy: "\n")
    for (index, raw) in lines.enumerated() {
      let terminated = index < lines.count - 1
      let cr = raw.hasSuffix("\r"), line = cr ? String(raw.dropLast()) : raw
      guard let fields = tokens(line), fields.first == pattern,
        fields.dropFirst().contains("filter=lfs") else {
        output += raw + (terminated ? "\n" : ""); continue
      }
      let retained = fields.dropFirst().filter { !values.contains($0) }
      if retained.isEmpty { changed = true; continue }
      output += quote(pattern) + " " + retained.joined(separator: " ") + (terminated ? (cr ? "\r\n" : "\n") : "")
      changed = true
    }
    guard changed else { throw GitPierError.invalidInput("No direct LFS rule for this pattern exists in the root .gitattributes. Inspect nested or custom rules in the editor.") }
    return Data(output.utf8)
  }
}

public struct LFSFile: Identifiable, Sendable {
  public var id: String { path }
  public let path: String
  public let oid: String
  public let size: Int64
  public let downloaded: Bool
  public let materialized: Bool
  public let workingPointer: LFSPointer?
}
struct LFSNativeFiles: Decodable {
  struct File: Decodable { let name: String; let size: Int64; let checkout: Bool; let downloaded: Bool; let oid_type: String; let oid: String }
  let files: [File]?
}
public struct LFSState: Sendable {
  public let installed: Bool
  public let configured: Bool
  public let version: String
  public let diagnostic: String?
  public let attributes: Data
  public let rules: [LFSRule]
  public let files: [LFSFile]
  public let trackingSummary: String
  public var inUse: Bool {
    !rules.isEmpty || !files.isEmpty || trackingSummary.components(separatedBy: "\n").contains { $0.hasPrefix("    ") || $0.hasPrefix("\t") }
  }
}
public struct LFSRuleReview: Sendable {
  public let operation: GitOperationReview
  public let working: ConflictWorkingState
  public let before: Data
  public let after: Data
  public let document: DiffDocument
  public let pattern: String
  public let track: Bool
}
public enum LFSNetworkAction: String, Sendable { case fetch, pull }
public struct LFSNetworkReview: Sendable {
  public let action: LFSNetworkAction
  public let remote: String
  public let remoteURL: String
  public let operation: GitOperationReview
  public let indexDigest: Data
  public let configuration: Data
  public let settings: ConflictWorkingState
}
