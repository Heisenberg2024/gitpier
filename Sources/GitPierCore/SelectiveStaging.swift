import Foundation
import CryptoKit
import Darwin

public struct SelectiveStagingReview: Sendable {
  public let file: FileChange
  public let comparison: DiffComparison
  public let operation: GitOperationReview
  public let indexDigest: Data
  public let working: ConflictWorkingState
  public let document: DiffDocument
}

public enum SelectivePatch {
  private struct Token {
    let line: DiffLine
    let row: String
    let noNewline: Bool
  }
  public static func supported(_ document: DiffDocument) -> Bool {
    let lines = document.raw.components(separatedBy: "\n")
    return !document.binary && !document.complexMetadata && !document.hunks.isEmpty
      && document.raw.utf8.count <= 2 * 1024 * 1024 && document.pairs.count <= 20_000
      && !document.raw.utf8.contains(0)
      && lines.filter { $0.hasPrefix("diff --git ") }.count == 1
      && !lines.contains { $0.hasPrefix("new file mode ") || $0.hasPrefix("deleted file mode ")
        || ($0.hasPrefix("index ") && ($0.hasSuffix(" 120000") || $0.hasSuffix(" 160000")))
        || $0.hasPrefix("--- /dev/null") || $0.hasPrefix("+++ /dev/null") }
  }
  /// Unselected source deletions become context; unselected target additions disappear.
  /// For Unstage, invert the full source diff first so context matches the current Index.
  public static func build(_ document: DiffDocument, selected: Set<Int>, reverse: Bool = false) throws -> Data {
    guard supported(document) else {
      throw GitPierError.invalidInput("Line actions require a bounded regular-text modification without rename, creation, deletion or mode changes. Use file or supported hunk actions.")
    }
    let eligible = Set(document.hunks.flatMap(\.lines).filter { $0.kind == .addition || $0.kind == .deletion }.map(\.id))
    guard !selected.isEmpty, selected.isSubset(of: eligible) else {
      throw GitPierError.invalidInput("Select at least one valid changed line from this Diff.")
    }
    let source = document.raw.components(separatedBy: "\n")
    guard let first = source.firstIndex(where: { $0.hasPrefix("@@ ") }) else { throw GitPierError.invalidInput("Missing patch hunks.") }
    let prefix = Array(source[..<first]).filter { !$0.hasPrefix("index ") }
    guard let old = prefix.first(where: { $0.hasPrefix("--- ") }),
      let new = prefix.first(where: { $0.hasPrefix("+++ ") }) else { throw GitPierError.invalidInput("Missing patch paths.") }
    var output = prefix.map { reverse && $0 == old ? "--- " + new.dropFirst(4)
      : reverse && $0 == new ? "+++ " + old.dropFirst(4) : $0 }
    let regex = try NSRegularExpression(pattern: "^@@ -([0-9]+)(?:,([0-9]+))? \\+([0-9]+)(?:,([0-9]+))? @@.*$")
    var cursor = first, delta = 0, hunkIndex = 0, emitted = 0
    while cursor < source.count {
      if cursor == source.count - 1 && source[cursor].isEmpty { break }
      let header = source[cursor]
      let ns = header as NSString
      guard let match = regex.firstMatch(in: header, range: NSRange(location: 0, length: ns.length)),
        hunkIndex < document.hunks.count else { throw GitPierError.invalidInput("Invalid patch hunk header.") }
      func number(_ index: Int, fallback: Int) -> Int {
        let range = match.range(at: index)
        return range.location == NSNotFound ? fallback : Int(ns.substring(with: range)) ?? fallback
      }
      let oldStart = number(1, fallback: 0), oldCount = number(2, fallback: 1)
      let newStart = number(3, fallback: 0), newCount = number(4, fallback: 1)
      let start = reverse ? newStart : oldStart, count = reverse ? newCount : oldCount
      let hunk = document.hunks[hunkIndex]
      var tokens: [Token] = [], lineIndex = 0
      cursor += 1
      while cursor < source.count && !source[cursor].hasPrefix("@@ ") {
        let row = source[cursor]; cursor += 1
        if row.isEmpty && cursor == source.count { break }
        guard let marker = row.first, [" ", "+", "-"].contains(marker), lineIndex < hunk.lines.count else {
          throw GitPierError.invalidInput("Invalid patch line.")
        }
        let original = hunk.lines[lineIndex]; lineIndex += 1
        let kind: DiffLineKind = marker == "+" ? .addition : marker == "-" ? .deletion : .context
        guard original.kind == kind, original.text == String(row.dropFirst()) else { throw GitPierError.invalidInput("The Diff selection no longer matches its patch.") }
        let noNewline = cursor < source.count && source[cursor] == "\\ No newline at end of file"
        if noNewline { cursor += 1 }
        tokens.append(Token(line: original, row: row, noNewline: noNewline))
      }
      var lines: [String] = [], sourceCount = 0, targetCount = 0, changed = false
      func emit(_ token: Token, _ marker: Character) {
        lines.append(String(marker) + token.row.dropFirst())
        if token.noNewline { lines.append("\\ No newline at end of file") }
        if marker != "+" { sourceCount += 1 }
        if marker != "-" { targetCount += 1 }
      }
      var tokenIndex = 0
      while tokenIndex < tokens.count {
        if tokens[tokenIndex].line.kind == .context {
          emit(tokens[tokenIndex], " "); tokenIndex += 1; continue
        }
        let blockStart = tokenIndex
        while tokenIndex < tokens.count && tokens[tokenIndex].line.kind != .context { tokenIndex += 1 }
        let block = tokens[blockStart..<tokenIndex]
        let removals = block.filter { $0.line.kind == (reverse ? .addition : .deletion) }
        let additions = block.filter { $0.line.kind == (reverse ? .deletion : .addition) }
        // Match the shared side-by-side Diff's replacement pairs. Leaving a removed
        // line as context before every addition would move partially selected replacements.
        for index in 0..<max(removals.count, additions.count) {
          if index < removals.count {
            let token = removals[index], chosen = selected.contains(token.line.id)
            emit(token, chosen ? "-" : " "); changed = changed || chosen
          }
          if index < additions.count, selected.contains(additions[index].line.id) {
            emit(additions[index], "+"); changed = true
          }
        }
      }
      guard lineIndex == hunk.lines.count, sourceCount == count else { throw GitPierError.invalidInput("The patch line counts are invalid.") }
      if changed {
        var destination = start + delta
        if count == 0 && targetCount > 0 { destination += 1 }
        if count > 0 && targetCount == 0 { destination -= 1 }
        guard destination >= 0 else { throw GitPierError.invalidInput("Invalid selected patch position.") }
        output.append("@@ -\(start),\(count) +\(destination),\(targetCount) @@")
        output += lines; emitted += 1
        delta += targetCount - sourceCount
      }
      hunkIndex += 1
    }
    guard emitted > 0, hunkIndex == document.hunks.count else { throw GitPierError.invalidInput("No selected patch changes.") }
    return Data((output.joined(separator: "\n") + "\n").utf8)
  }
}

/// Holds Git's real Index lock while native apply works on an isolated copy. Publishing is
/// an atomic rename; another tool's lock or changed Index is never replaced on failure.
final class IndexEditTransaction {
  let index: URL
  let lock: URL
  let original: Data
  private let descriptor: Int32
  private let permissions: mode_t
  init(index: URL) throws {
    self.index = index; lock = URL(fileURLWithPath: index.path + ".lock")
    let attributes = try FileManager.default.attributesOfItem(atPath: index.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      (attributes[.size] as? Int ?? Int.max) <= 64 * 1024 * 1024 else { throw GitPierError.unsafePath(index.path) }
    permissions = mode_t(attributes[.posixPermissions] as? Int ?? 0o644)
    descriptor = open(lock.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, permissions)
    guard descriptor >= 0 else { throw GitPierError.invalidInput("The Git Index is locked by another operation. Retry after it finishes.") }
    do { original = try Data(contentsOf: index) }
    catch { close(descriptor); unlink(lock.path); throw error }
  }
  private var ownsLock: Bool {
    var file = stat(), held = stat()
    return lstat(lock.path, &file) == 0 && fstat(descriptor, &held) == 0
      && file.st_ino == held.st_ino && file.st_dev == held.st_dev
  }
  func publish(_ data: Data) throws {
    guard ownsLock, try Data(contentsOf: index) == original else { throw GitPierError.indexChanged }
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        offset += count
      }
    }
    guard fsync(descriptor) == 0, fchmod(descriptor, permissions) == 0, ownsLock else {
      throw GitPierError.invalidInput("Could not safely prepare the reviewed Index update.")
    }
    guard try Data(contentsOf: index) == original else { throw GitPierError.indexChanged }
    guard rename(lock.path, index.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
  }
  deinit { if ownsLock { unlink(lock.path) }; close(descriptor) }
}
