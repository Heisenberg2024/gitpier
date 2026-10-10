import Foundation

public final class ConfigurationStore: @unchecked Sendable {
  public let url: URL
  private let lock = NSLock()
  public init(url: URL? = nil) {
    self.url =
      url
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("GitPier/workspace.json")
  }
  public func load() throws -> WorkspaceConfiguration {
    lock.lock()
    defer { lock.unlock() }
    guard FileManager.default.fileExists(atPath: url.path) else { return WorkspaceConfiguration() }
    return try JSONDecoder().decode(WorkspaceConfiguration.self, from: Data(contentsOf: url))
  }
  public func save(_ configuration: WorkspaceConfiguration) throws {
    lock.lock()
    defer { lock.unlock() }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(configuration).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

public enum InputValidation {
  public static func repositoryPath(_ path: String) throws {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
      !path.utf8.contains(0), path != ".git", !path.hasPrefix(".git/")
    else { throw GitPierError.unsafePath(path) }
  }
  public static func remoteURL(_ value: String) throws {
    guard !value.isEmpty, !value.hasPrefix("-"), !value.contains("\n"), !value.utf8.contains(0)
    else { throw GitPierError.invalidInput("Invalid remote URL") }
    if let url = URL(string: value), ["http", "https"].contains(url.scheme ?? "") {
      guard url.user == nil, url.password == nil else {
        throw GitPierError.invalidInput(
          "Keep credentials out of remote URLs. Use Keychain credentials instead.")
      }
    }
    if value.hasPrefix("ext::") {
      throw GitPierError.invalidInput("External remote helpers are not accepted by the URL editor.")
    }
  }
  public static func reference(_ value: String) throws {
    guard !value.isEmpty, !value.hasPrefix("-"), !value.utf8.contains(0), !value.contains("\n")
    else { throw GitPierError.invalidInput("Invalid Git reference") }
  }
  public static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
