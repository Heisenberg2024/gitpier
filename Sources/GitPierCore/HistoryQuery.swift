import Foundation

public struct HistoryQuery: Equatable, Sendable, Codable {
  public enum Scope: String, Codable, Sendable { case currentBranch, allReferences }
  public var scope: Scope = .currentBranch
  public var message = ""
  public var author = ""
  public var hash = ""
  public var after = ""
  public var before = ""
  public init() {}
  public var identity: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
  }

  public func validate() throws {
    for value in [message, author, hash, after, before] {
      guard !value.contains("\0"), !value.contains("\n"), value.utf8.count <= 4096 else {
        throw GitPierError.invalidInput("Invalid history query.")
      }
    }
    if !hash.isEmpty {
      guard (4...64).contains(hash.count), hash.allSatisfy(\.isHexDigit) else {
        throw GitPierError.invalidInput(
          "Enter at least four hexadecimal characters for a commit hash.")
      }
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    for value in [after, before] where !value.isEmpty {
      guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
        throw GitPierError.invalidInput("Use YYYY-MM-DD for history dates.")
      }
    }
    guard after.isEmpty || before.isEmpty || after <= before else {
      throw GitPierError.invalidInput("The start date must precede the end date.")
    }
  }
}
