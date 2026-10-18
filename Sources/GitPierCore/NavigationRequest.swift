import Foundation

public enum NavigationPage: String, CaseIterable, Sendable {
  case commit, history, branches, worktrees, compare
}
public enum GitPierCLICommand: Equatable, Sendable {
  case help, version, open(NavigationRequest)
  public static func parse(_ arguments: [String], directory: URL) throws -> Self {
    if arguments == ["--help"] || arguments == ["-h"] || arguments.isEmpty { return .help }
    if arguments == ["--version"] { return .version }
    guard arguments.first == "open" else { throw NavigationRequest.invalid }
    var path: String?, page = NavigationPage.commit, hasPage = false
    var i = 1
    while i < arguments.count {
      let value = arguments[i]
      if value == "--page" {
        guard !hasPage, i + 1 < arguments.count, let selected = NavigationPage(rawValue: arguments[i + 1]) else { throw NavigationRequest.invalid }
        hasPage = true; page = selected; i += 2
      } else {
        guard path == nil, !value.hasPrefix("-"), !value.isEmpty else { throw NavigationRequest.invalid }
        path = value; i += 1
      }
    }
    let pathValue = path ?? "."
    try NavigationRequest.validatePath(pathValue)
    let url = URL(fileURLWithPath: pathValue, relativeTo: URL(fileURLWithPath: directory.path, isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath()
    return .open(try NavigationRequest(directory: url, page: page))
  }
}
/// Fixed navigation vocabulary; no Git arguments, credentials, shell, or mutation verbs.
public struct NavigationRequest: Equatable, Sendable {
  public let directory: URL
  public let page: NavigationPage
  public let id: UUID
  public static var invalid: GitPierError { .invalidInput("Use gitpier open [path] [--page commit|history|branches|worktrees|compare].") }
  public init(directory: URL, page: NavigationPage = .commit, id: UUID = UUID()) throws {
    guard directory.isFileURL, directory.host == nil || directory.host == "" || directory.host == "localhost" else { throw Self.invalid }
    try Self.validatePath(directory.path)
    guard directory.path.hasPrefix("/") else { throw Self.invalid }
    let canonical = directory.standardizedFileURL.resolvingSymlinksInPath()
    self.directory = URL(fileURLWithPath: canonical.path, isDirectory: true); self.page = page; self.id = id
  }
  static func validatePath(_ path: String) throws {
    guard !path.isEmpty, path.utf8.count <= 8192,
      !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw invalid }
  }
  public func validateAccess() throws {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
      FileManager.default.isReadableFile(atPath: directory.path), FileManager.default.isExecutableFile(atPath: directory.path) else {
      throw GitPierError.invalidInput("Choose an accessible local repository directory.")
    }
  }
  public var url: URL {
    var components = URLComponents()
    components.scheme = "gitpier"; components.host = "navigate"; components.path = "/open"
    components.queryItems = [URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "id", value: id.uuidString),
      URLQueryItem(name: "path", value: directory.path), URLQueryItem(name: "page", value: page.rawValue)]
    return components.url!
  }
  public init(url: URL) throws {
    guard url.absoluteString.utf8.count <= 32768, let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
      c.scheme == "gitpier", c.host == "navigate", c.path == "/open", c.user == nil, c.password == nil,
      c.port == nil, c.fragment == nil, let items = c.queryItems, items.count == 4,
      Set(items.map(\.name)) == Set(["v", "id", "path", "page"]),
      items.first(where: { $0.name == "v" })?.value == "1",
      let rawID = items.first(where: { $0.name == "id" })?.value, let id = UUID(uuidString: rawID),
      let rawPath = items.first(where: { $0.name == "path" })?.value, rawPath.hasPrefix("/"),
      let rawPage = items.first(where: { $0.name == "page" })?.value, let page = NavigationPage(rawValue: rawPage) else { throw Self.invalid }
    try self.init(directory: URL(fileURLWithPath: rawPath), page: page, id: id)
  }
}
