import Foundation

public struct GitSubmodule: Identifiable, Equatable, Sendable {
  public var id: String { path }
  public let name: String
  public let path: String
  public let localPath: String
  public let depth: Int
  public let url: String
  public let configuredURL: String
  public let branch: String
  public let currentHead: String?
  public let indexCommit: String?
  public let parentCommit: String?
  public let registered: Bool
  public let initialized: Bool
  public let changes: Int?
  public let operation: GitOperation?
  public let problem: String?
}
public enum SubmoduleAction: String, Sendable { case initialize, sync, recorded, remote }
public struct SubmoduleReview: Sendable {
  public let module: GitSubmodule
  public let action: SubmoduleAction
  public let parent: GitOperationReview
  public let modulesFile: ConflictWorkingState
  public let configuration: Data
  public let child: GitOperationReview?
  public let target: String?
  public let remote: String?
}
public struct SubmoduleAddReview: Sendable {
  public let path: String
  public let url: String
  public let parent: GitOperationReview
  public let modulesFile: ConflictWorkingState
  public let configuration: Data
}

enum SubmoduleParser {
  static func declarations(_ data: Data) throws -> [(String, String)] {
    try data.split(separator: 0).map { row in
      guard let text = String(data: row, encoding: .utf8), let split = text.firstIndex(of: "\n") else {
        throw GitPierError.invalidInput("Invalid .gitmodules path declarations.")
      }
      let key = String(text[..<split]), value = String(text[text.index(after: split)...])
      guard key.hasPrefix("submodule."), key.hasSuffix(".path") else { throw GitPierError.invalidInput("Invalid submodule configuration key.") }
      let name = String(key.dropFirst(10).dropLast(5))
      guard !name.isEmpty, !name.contains("\n"), !name.contains("\r") else { throw GitPierError.invalidInput("Invalid submodule name.") }
      return (name, value)
    }
  }
  static func gitlinks(_ data: Data, index: Bool) throws -> [String: String] {
    var result: [String: String] = [:]
    for row in data.split(separator: 0) where row.starts(with: Data("160000 ".utf8)) {
      guard let text = String(data: row, encoding: .utf8), let tab = text.firstIndex(of: "\t") else {
        throw GitPierError.invalidInput("Submodule paths must be UTF-8.")
      }
      let fields = text[..<tab].split(separator: " ").map(String.init)
      guard fields.count == 3 else { throw GitPierError.invalidInput("Invalid gitlink metadata.") }
      if index && fields[2] != "0" { continue }
      let hash = index ? fields[1] : fields[2]
      guard [40, 64].contains(hash.count), hash.allSatisfy(\.isHexDigit) else { throw GitPierError.invalidInput("Invalid gitlink commit.") }
      result[String(text[text.index(after: tab)...])] = hash
    }
    return result
  }
  static func otherIndex(_ data: Data, excluding paths: Set<String>) -> Data {
    var result = Data()
    for row in data.split(separator: 0) {
      guard let tab = row.firstIndex(of: 9) else { continue }
      let path = String(decoding: row[row.index(after: tab)...], as: UTF8.self)
      if !paths.contains(path) { result.append(row); result.append(0) }
    }
    return result
  }
}
