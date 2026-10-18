import XCTest
@testable import GitPierCore

final class NavigationRequestTests: XCTestCase {
  let current = URL(fileURLWithPath: "/tmp/example")
  func testHelpAndVersionDoNotRequireFilesystemOrGUI() throws {
    XCTAssertEqual(try GitPierCLICommand.parse(["--help"], directory: current), .help)
    XCTAssertEqual(try GitPierCLICommand.parse(["--version"], directory: current), .version)
    XCTAssertEqual(try GitPierCLICommand.parse([], directory: current), .help)
  }
  func testRelativeCurrentAndAbsolutePaths() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    let directory = root.appendingPathComponent("current")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for (value, expected) in [(".", directory.path), ("../repo", root.appendingPathComponent("repo").path), (root.path, root.path)] {
      guard case .open(let request) = try GitPierCLICommand.parse(["open", value], directory: directory) else { return XCTFail() }
      XCTAssertEqual(request.directory.path, expected)
    }
  }
  func testAllPagesAndUnicodeSpecialPathsRoundtripWithoutShell() throws {
    for page in NavigationPage.allCases {
      let request = try NavigationRequest(directory: URL(fileURLWithPath: "/tmp/中文 space & + # % $() `sample`/"), page: page)
      XCTAssertEqual(try NavigationRequest(url: request.url), request)
    }
  }
  func testExplicitPageMayPrecedePath() throws {
    guard case .open(let request) = try GitPierCLICommand.parse(["open", "--page", "history", "."], directory: current) else { return XCTFail() }
    XCTAssertEqual(request.page, .history)
  }
  func testRejectsMutationCredentialAndMalformedArguments() {
    for args in [["push"], ["open", ".", "--force"], ["open", "--token", "secret"], ["open", ".", "--page", "reset"], ["open", ".", "--page"], ["open", "a", "b"], ["open", "--page", "commit", "--page", "history"], ["--help", "secret"], ["open", "bad\npath"], ["open", ""]] {
      XCTAssertThrowsError(try GitPierCLICommand.parse(args, directory: current), args.joined(separator: " "))
    }
  }
  func testOAuthIsNeverANavigationRequest() {
    XCTAssertThrowsError(try NavigationRequest(url: URL(string: "gitpier://oauth/gitlab?code=secret&state=secret")!))
  }
  func testRejectsUnrecognizedOrDuplicatedURLFields() throws {
    let request = try NavigationRequest(directory: current)
    for suffix in ["&token=secret", "&page=push", "#fragment", "&path=/tmp/another", "&command=reset"] {
      XCTAssertThrowsError(try NavigationRequest(url: URL(string: request.url.absoluteString + suffix)!))
    }
    for string in ["https://navigate/open", "gitpier://user:pass@navigate/open", "gitpier://navigate:123/open", "gitpier://navigate/reset"] {
      XCTAssertThrowsError(try NavigationRequest(url: URL(string: string)!))
    }
  }
  func testRejectsUnsupportedVersionAndRelativeEncodedPath() throws {
    let request = try NavigationRequest(directory: current)
    XCTAssertThrowsError(try NavigationRequest(url: URL(string: request.url.absoluteString.replacingOccurrences(of: "v=1", with: "v=2"))!))
    var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
    components.queryItems = components.queryItems!.map { $0.name == "path" ? URLQueryItem(name: "path", value: "relative") : $0 }
    XCTAssertThrowsError(try NavigationRequest(url: components.url!))
  }
  func testMissingOrFilePathIsRefused() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("example".utf8).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
    XCTAssertThrowsError(try NavigationRequest(directory: file).validateAccess())
    XCTAssertThrowsError(try NavigationRequest(directory: file.appendingPathComponent("missing")).validateAccess())
  }
  func testUnreadableDirectoryIsRefused() throws {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
      try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
    XCTAssertThrowsError(try NavigationRequest(directory: root).validateAccess())
  }
  func testSymlinkResolvesToItsActualDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let link = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    XCTAssertEqual(try NavigationRequest(directory: link).directory.path, root.resolvingSymlinksInPath().path)
  }
}
