import XCTest
@testable import GitPierCore

extension LocalAgentTests {
  func testLoginStatusDoesNotTreatEveryNonzeroExitAsLoggedOut() async throws {
    let cases: [(String, AgentLoginStatus)] = [
      ("printf 'sensitive output must not be retained\\n' >&2; exit 0", .loggedIn),
      ("printf 'Not logged in\\n' >&2; exit 1", .loginRequired),
      ("printf 'Error loading configuration\\n' >&2; exit 1", .unconfirmed(.executionFailed)),
      ("printf 'unknown command\\n' >&2; exit 2", .unconfirmed(.executionFailed)),
      ("printf 'Not logged in\\n' >&2; exit 9", .unconfirmed(.executionFailed))
    ]
    for (body, expected) in cases {
      let file = try executable("if [ \"$1\" = login ] && [ \"$2\" = status ]; then " + body + "; fi\nprintf 'codex-cli 1.0.0\\n'")
      let detected = try await AgentExecutable.detect(explicitPath: file.path)
      let result = try await detected.checkLogin()
      XCTAssertEqual(result, expected)
    }
  }
  func testLoginTimeoutOutputLimitAndCancellationAreNotLoginRequired() async throws {
    let file = try executable("if [ \"$1\" = login ]; then exec /bin/sleep 30; fi\nprintf 'codex-cli 1.0.0\\n'")
    let detected = try await AgentExecutable.detect(explicitPath: file.path)
    let timeout = try await detected.checkLogin(timeout: 0.05)
    XCTAssertEqual(timeout, .unconfirmed(.timedOut))
    let work = Task { try await detected.checkLogin() }
    try await Task.sleep(for: .milliseconds(30)); work.cancel()
    do { _ = try await work.value; XCTFail("Cancellation must propagate") } catch is CancellationError {}
    let huge = try executable("if [ \"$1\" = login ]; then /usr/bin/yes private | /usr/bin/head -c 20000; exit 0; fi\nprintf 'codex-cli 1.0.0\\n'", name: "huge")
    let overflowExecutable = try await AgentExecutable.detect(explicitPath: huge.path)
    let overflow = try await overflowExecutable.checkLogin()
    XCTAssertEqual(overflow, .unconfirmed(.outputLimit))
  }
  func testLoginRevalidatesExecutableAndUsesTheDetectedEffectiveEnvironment() async throws {
    let home = root.path
    let environment = try AgentEnvironment(inheriting: ["HOME": home, "CODEX_HOME": home, "PATH": "/usr/bin:/bin", "GITPIER_AUTH_TEST": "remove", "GIT_ASKPASS": "/private/managed-helper"])
    let file = try executable("""
    [ "$HOME" = \(InputValidation.shellQuote(home)) ] && [ "$CODEX_HOME" = \(InputValidation.shellQuote(home)) ] && [ -z "$GITPIER_AUTH_TEST" ] && [ -z "$GIT_ASKPASS" ] || exit 12
    if [ "$1" = login ]; then exit 0; fi
    printf 'codex-cli 1.0.0\\n'
    """)
    let detected = try await AgentExecutable.detect(explicitPath: file.path, environment: environment)
    let status = try await detected.checkLogin(); XCTAssertEqual(status, .loggedIn)
    XCTAssertEqual(detected.environment, environment)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
    do { _ = try await detected.checkLogin(); XCTFail("Replaced executable must be detected") } catch LocalAgentError.changed {}
  }
  func testFinderAndCustomCodexHomePreserveOfficialAuthAndProxyVariables() throws {
    let inherited = ["HOME": root.path, "PATH": "/usr/bin:/bin", "CODEX_HOME": root.path,
      "OPENAI_API_KEY": "synthetic", "CODEX_API_KEY": "synthetic-codex", "CODEX_ACCESS_TOKEN": "synthetic-access",
      "HTTPS_PROXY": "http://proxy.invalid", "OPENAI_FEDERATION_RULE_ID": "synthetic-rule", "OPENAI_IDENTITY_TOKEN_FILE": "/synthetic/token",
      "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "credential.helper", "GIT_CONFIG_VALUE_0": "private-helper", "GIT_DIR": "/wrong"]
    let normal = try AgentEnvironment(inheriting: inherited)
    for key in ["HOME", "CODEX_HOME", "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "HTTPS_PROXY", "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE"] {
      XCTAssertEqual(normal.values[key], inherited[key])
    }
    XCTAssertNil(normal.values["GIT_CONFIG_COUNT"]); XCTAssertNil(normal.values["GIT_DIR"])
    let finder = try AgentEnvironment(inheriting: ["PATH": "/usr/bin:/bin"])
    XCTAssertNil(finder.values["CODEX_HOME"]); XCTAssertFalse(finder.values["HOME", default: ""].isEmpty)
    XCTAssertTrue(finder.values["PATH", default: ""].contains("/opt/homebrew/bin"))
    let explicit = try AgentEnvironment(inheriting: [:], codexHome: root.path)
    XCTAssertEqual(explicit.values["CODEX_HOME"], root.path)
    for path in ["relative", "~/custom", root.appendingPathComponent("missing").path, root.path + "/../escape"] {
      XCTAssertThrowsError(try AgentEnvironment(inheriting: [:], codexHome: path))
    }
  }
}
