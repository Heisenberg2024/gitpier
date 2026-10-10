import Foundation

public enum StatusParser {
  public static func parse(_ data: Data) throws -> RepositoryStatus {
    let records = data.split(separator: 0, omittingEmptySubsequences: false)
    var status = RepositoryStatus()
    var i = 0
    while i < records.count {
      guard let row = String(data: Data(records[i]), encoding: .utf8) else {
        throw GitPierError.invalidInput("Non-UTF-8 repository paths cannot be operated on safely.")
      }
      i += 1
      if row.isEmpty { continue }
      if row.hasPrefix("# ") {
        // --branch headers are NUL terminated in porcelain v2 -z.
        for header in row.split(separator: "\n") {
          if header.hasPrefix("# branch.head ") { status.branch = String(header.dropFirst(14)) }
          if header.hasPrefix("# branch.oid ") {
            let oid = String(header.dropFirst(13))
            status.head = oid == "(initial)" ? nil : oid
          }
          if header.hasPrefix("# branch.upstream ") {
            status.upstream = String(header.dropFirst(18))
          }
          if header.hasPrefix("# branch.ab ") {
            let counts = header.dropFirst(12).split(separator: " ")
            if counts.count == 2 {
              status.ahead = Int(counts[0].dropFirst()) ?? 0
              status.behind = Int(counts[1].dropFirst()) ?? 0
            }
          }
        }
        continue
      }
      if row.hasPrefix("? ") {
        status.files.append(
          FileChange(path: String(row.dropFirst(2)), index: "?", worktree: "?", kind: .untracked))
        continue
      }
      if row.hasPrefix("! ") { continue }
      let prefix = row.first
      let fieldsCount = prefix == "1" ? 8 : prefix == "2" ? 9 : prefix == "u" ? 10 : 0
      guard fieldsCount > 0 else { throw GitPierError.invalidInput("Unknown Git status record") }
      let fields = row.split(
        separator: " ", maxSplits: fieldsCount, omittingEmptySubsequences: false)
      guard fields.count == fieldsCount + 1, fields[1].count == 2 else {
        throw GitPierError.invalidInput("Malformed Git status record")
      }
      let xy = Array(fields[1])
      let path = String(fields[fieldsCount])
      var original: String?
      if prefix == "2" {
        guard i < records.count else {
          throw GitPierError.invalidInput("Missing original rename path")
        }
        guard let source = String(data: Data(records[i]), encoding: .utf8) else {
          throw GitPierError.invalidInput("Non-UTF-8 rename paths cannot be operated on safely.")
        }
        original = source
        i += 1
      }
      let codes = String(fields[1])
      let kind: ChangeKind
      if prefix == "u" {
        kind = .conflicted
      } else if codes.contains("R") {
        kind = .renamed
      } else if codes.contains("C") {
        kind = .copied
      } else if codes.contains("D") {
        kind = .deleted
      } else if codes.contains("A") {
        kind = .added
      } else if codes.contains("T") {
        kind = .typeChanged
      } else {
        kind = .modified
      }
      status.files.append(
        FileChange(
          path: path, originalPath: original, index: xy[0], worktree: xy[1],
          submodule: String(fields[2]), kind: kind))
    }
    return status
  }
}
