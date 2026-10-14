import Foundation

public enum PatchTarget: String, CaseIterable, Sendable { case workingTree, index }
public enum PatchExportFormat: String, CaseIterable, Sendable { case diff, commitEmail }
public struct PatchPreviewFile: Identifiable, Sendable {
  public var id: String { path }
  public let path: String
  public let additions: Int?
  public let deletions: Int?
  public let document: DiffDocument
  public var binary: Bool { additions == nil || deletions == nil || document.binary }
}
public struct PatchImportReview: Sendable {
  public let patch: Data
  public let target: PatchTarget
  public let operation: GitOperationReview
  public let indexDigest: Data
  public let files: [PatchPreviewFile]
  public let working: [String: ConflictWorkingState]
  public let summary: String
}

public enum PatchParser {
  public static let limit = 8 * 1024 * 1024
  public static func sections(_ data: Data) throws -> [Data] {
    guard !data.isEmpty, data.count <= limit, !data.contains(0),
      let text = String(data: data, encoding: .utf8) else {
      throw GitPierError.invalidInput("Choose a UTF-8 Git Diff patch within 8 MiB.")
    }
    let lines = text.components(separatedBy: "\n")
    if lines.first?.hasPrefix("From ") == true || lines.prefix(30).contains(where: { $0.hasPrefix("Subject: ") }) {
      throw GitPierError.invalidInput("This is a format-patch email, which creates commits through git am. Email import is not supported; use the terminal to preserve its hooks and recovery flow.")
    }
    guard lines.first?.hasPrefix("diff --git ") == true else {
      throw GitPierError.invalidInput("Import requires a Git Diff patch beginning with diff --git.")
    }
    var sections: [[String]] = []
    for line in lines {
      if line.hasPrefix("diff --git ") { sections.append([]) }
      sections[sections.count - 1].append(line)
    }
    guard sections.count <= 200 else { throw GitPierError.invalidInput("A patch may affect at most 200 files.") }
    var binaryBytes = 0
    for section in sections {
      guard !section.contains(where: { $0.hasPrefix("rename ") || $0.hasPrefix("copy ")
        || $0 == "new file mode 120000" || $0 == "deleted file mode 120000"
        || $0 == "new file mode 160000" || $0 == "deleted file mode 160000"
        || ($0.hasPrefix("index ") && ($0.hasSuffix(" 120000") || $0.hasSuffix(" 160000"))) }) else {
        throw GitPierError.invalidInput("Patch import currently supports regular files. Rename/copy, symlink and submodule patches must be handled in the terminal.")
      }
      if let binary = section.firstIndex(of: "GIT binary patch") {
        for line in section[(binary + 1)...] {
          if line.hasPrefix("delta ") { throw GitPierError.invalidInput("Binary delta patches require terminal review. Import supports bounded literal binary patches.") }
          if line.hasPrefix("literal ") {
            guard let size = Int(line.dropFirst(8)), size >= 0, size <= limit else {
              throw GitPierError.invalidInput("A decoded binary patch file must stay within 8 MiB.")
            }
            binaryBytes += size
            guard binaryBytes <= 32 * 1024 * 1024 else { throw GitPierError.invalidInput("Decoded binary patch data exceeds 32 MiB.") }
          }
        }
      }
      if let old = section.first(where: { $0.hasPrefix("--- ") }),
        let new = section.first(where: { $0.hasPrefix("+++ ") }) {
        func name(_ line: String, prefix: String) -> String? {
          let path = String(line.dropFirst(4)).components(separatedBy: "\t")[0]
          if path == "/dev/null" { return nil }
          let quoted = path.hasPrefix("\"") ? String(path.dropFirst()) : path
          return quoted.hasPrefix(prefix) ? String(quoted.dropFirst(2)) : "invalid-" + path
        }
        let before = name(old, prefix: "a/"), after = name(new, prefix: "b/")
        guard before == nil || after == nil || before == after else {
          throw GitPierError.invalidInput("The patch's old and new paths do not describe the same regular file.")
        }
      }
    }
    return sections.map { Data(($0.joined(separator: "\n") + ($0.last == "" ? "" : "\n")).utf8) }
  }
  public static func files(_ numstat: Data, sections: [Data]) throws -> [PatchPreviewFile] {
    let records = numstat.split(separator: 0)
    guard records.count == sections.count else { throw GitPierError.invalidInput("The patch file summary is ambiguous.") }
    var result: [PatchPreviewFile] = []
    var seen = Set<String>()
    for (record, section) in zip(records, sections) {
      guard let row = String(data: record, encoding: .utf8) else { throw GitPierError.invalidInput("Patch paths must be UTF-8.") }
      let fields = row.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
      guard fields.count == 3, seen.insert(fields[2]).inserted else { throw GitPierError.invalidInput("The patch contains duplicate or ambiguous paths.") }
      let path = fields[2]
      try InputValidation.repositoryPath(path)
      guard !path.split(separator: "/").contains(where: { $0.lowercased() == ".git" }),
        !path.split(separator: "/").contains(where: { $0.lowercased() == ".gitmodules" }) else { throw GitPierError.unsafePath(path) }
      result.append(PatchPreviewFile(path: path, additions: Int(fields[0]), deletions: Int(fields[1]), document: DiffParser.parse(section)))
    }
    return result
  }
}
