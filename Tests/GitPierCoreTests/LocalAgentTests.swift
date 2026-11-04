import Darwin
import XCTest
@testable import GitPierCore

final class LocalAgentTests: XCTestCase {
  var root: URL!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("GitPier-agent-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
  func executable(_ body: String, name: String = "codex", combinedHelp: Bool = true) throws -> URL {
    let file = root.appendingPathComponent(name)
    let help = "if [ \"$1\" = --help ]" + (combinedHelp ? " || [ \"$6\" = --help ]" : "") + "; then printf '%s\\n' '--no-daemon --sandbox workspace-write --ask-for-approval on-request'; exit 0; fi\n"
    try Data(("#!/bin/sh\n" + help + body + "\n").utf8).write(to: file)
    XCTAssertEqual(chmod(file.path, 0o700), 0); return file
  }
  func testVersionIdentityRejectsOtherToolsAndControlSequences() {
    XCTAssertEqual(AgentExecutable.parseVersion("codex-cli 0.163.0-alpha.10.2\n"), "codex-cli 0.163.0-alpha.10.2")
    for value in ["codex 1.0.0", "codex-cli latest", "other-cli 1.2.3", "codex-cli 1.2.3\ncommand", "codex-cli 1.2", "\u{1B}[31mcodex-cli 1.0.0"] {
      XCTAssertNil(AgentExecutable.parseVersion(value))
    }
  }
  func testExplicitExecutableProbeUsesVersionAndSafeParserArguments() async throws {
    let file = try executable("[ \"$#\" = 1 ] && [ \"$1\" = --version ] || exit 2\nprintf 'codex-cli 0.163.0\\n'")
    let detected = try await AgentExecutable.detect(explicitPath: file.path)
    XCTAssertEqual(detected.path, file.path); XCTAssertEqual(detected.version, "codex-cli 0.163.0")
    try detected.validate()
  }
  func testPathLookupAndSymlinkResolveToStableExecutable() async throws {
    let file = try executable("printf 'codex-cli 1.0.0\\n'", name: "actual")
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("codex"), withDestinationURL: file)
    let detected = try await AgentExecutable.detect(searchPath: ".:" + root.path)
    XCTAssertEqual(detected.path, file.path)
  }
  func testFinderEnvironmentFindsCodexInUserLocalBin() async throws {
    let file = try executable("printf 'codex-cli 1.0.0\\n'", name: "standalone-codex")
    let bin = root.appendingPathComponent(".local/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("codex"), withDestinationURL: file)
    let environment = try AgentEnvironment(inheriting: ["HOME": root.path, "PATH": "/usr/bin:/bin"])
    let paths = environment.values["PATH", default: ""].split(separator: ":").map(String.init)
    _ = try XCTUnwrap(paths.firstIndex(of: bin.path), "Finder's environment must include the user's local command directory")
    let detected = try await AgentExecutable.detect(environment: environment)
    XCTAssertEqual(detected.path, file.path)
    XCTAssertEqual(detected.environment, environment)
    try detected.validate()
  }
  func testInheritedPathKeepsPriorityOverUserLocalBin() async throws {
    let preferred = try executable("printf 'codex-cli 2.0.0\\n'")
    let bin = root.appendingPathComponent(".local/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let alternate = try executable("printf 'codex-cli 1.0.0\\n'", name: "alternate-codex")
    try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("codex"), withDestinationURL: alternate)
    let environment = try AgentEnvironment(inheriting: ["HOME": root.path, "PATH": root.path + ":/usr/bin:/bin"])
    let detected = try await AgentExecutable.detect(environment: environment)
    XCTAssertEqual(detected.path, preferred.path)
  }
  func testLocalBinFallbackIsUniqueAndRejectsInvalidHomePaths() throws {
    let bin = root.appendingPathComponent(".local/bin").path
    let environment = try AgentEnvironment(inheriting: ["HOME": root.path, "PATH": "/usr/bin:" + bin])
    XCTAssertEqual(environment.values["PATH", default: ""].split(separator: ":").filter { $0 == bin }.count, 1)
    for home in ["relative-home", "/invalid\u{0}home"] {
      let invalid = try AgentEnvironment(inheriting: ["HOME": home, "PATH": "/usr/bin:/bin"])
      XCTAssertFalse(invalid.values["PATH", default: ""].contains(".local/bin"))
    }
  }
  func testMissingNonExecutableWrongToolAndNonzeroExitAreRefused() async throws {
    let file = try executable("printf 'other-cli 1.0.0\\n'")
    for path in [root.appendingPathComponent("missing").path, root.path, file.path, "relative"] {
      do { _ = try await AgentExecutable.detect(explicitPath: path); XCTFail("Should reject \(path)") } catch {}
    }
    try Data("#!/bin/sh\nexit 3\n".utf8).write(to: file)
    do { _ = try await AgentExecutable.detect(explicitPath: file.path); XCTFail("Nonzero probe") } catch {}
    XCTAssertEqual(chmod(file.path, 0o600), 0)
    do { _ = try await AgentExecutable.detect(explicitPath: file.path); XCTFail("Not executable") } catch {}
  }
  func testExecutableChangeAfterDetectionRequiresNewReview() async throws {
    let file = try executable("printf 'codex-cli 1.0.0\\n'")
    let detected = try await AgentExecutable.detect(explicitPath: file.path)
    try Data("#!/bin/sh\nprintf changed\n".utf8).write(to: file)
    XCTAssertThrowsError(try detected.validate())
  }
  func testVersionWithoutSafeInteractiveOptionsIsRejected() async throws {
    let file = root.appendingPathComponent("old-codex")
    try Data("#!/bin/sh\nprintf 'codex-cli 0.1.0\\n'\n".utf8).write(to: file)
    XCTAssertEqual(chmod(file.path, 0o700), 0)
    do { _ = try await AgentExecutable.detect(explicitPath: file.path); XCTFail("Missing supported interactive options") } catch LocalAgentError.invalidVersion {}
  }
  func testHelpKeywordsDoNotProveSafeArgumentsCanBeCombined() async throws {
    let file = try executable("[ \"$1\" = --version ] && { printf 'codex-cli 1.0.0\\n'; exit 0; }; exit 2", combinedHelp: false)
    do { _ = try await AgentExecutable.detect(explicitPath: file.path); XCTFail("Reject a CLI whose parser refuses the actual safe launch combination") }
    catch LocalAgentError.invalidVersion {}
  }
}
