import XCTest
@testable import GitPierCore

final class GitAuthenticationTests: XCTestCase {
  private var root: URL!
  private var service: GitService!
  private var record: RepositoryRecord!
  private let environment = ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false"]
  override func setUp() async throws {
    root = URL(fileURLWithPath: "/private/tmp/GitPier-auth-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    _ = try await raw(["init", "-q", "-b", "main"])
    _ = try await raw(["remote", "add", "origin", "https://example.invalid/team/repo.git"])
    record = RepositoryRecord(path: root.path)
    service = GitService(root: root)
    await service.configure(gitPath: "/usr/bin/git", authEnvironment: environment)
  }
  override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
  @discardableResult private func raw(_ args: [String], input: Data? = nil) async throws -> CommandResult {
    let result = try await ProcessRunner().run(executable: "/usr/bin/git", arguments: args, directory: root, environment: environment, input: input)
    XCTAssertEqual(result.code, 0, result.errorText); return result
  }
  private func target() async throws -> WorkspaceFetchTarget { try await service.reviewWorkspaceFetch(record)[0] }
  private func store(_ name: String, credentials: String) throws -> String {
    let path = root.appendingPathComponent(name)
    try Data(credentials.utf8).write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    return "store --file=" + InputValidation.shellQuote(path.path)
  }
  func testLiteralHelperOptionsAndShellRefusal() {
    XCTAssertEqual(SafeCredentialHelper.supported("store --file='/tmp/a b'"), ["store", "--file=/tmp/a b"])
    XCTAssertEqual(SafeCredentialHelper.supported("cache --timeout 600 --socket=/tmp/socket"), ["cache", "--timeout", "600", "--socket=/tmp/socket"])
    for value in ["!echo token", "store; touch /tmp/x", "store --file=$(echo x)", "store --file=`x`", "manager", "/tmp/store", "store --unknown=x", "store --file", "osxkeychain arg"] {
      XCTAssertNil(SafeCredentialHelper.supported(value), value)
    }
  }
  private func githubCLI() throws -> String {
    guard let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first(where: FileManager.default.isExecutableFile(atPath:)) else {
      throw XCTSkip("GitHub CLI is required for its isolated credential integration")
    }
    return gh
  }
  func testGitHubCLIHelperRecognitionRejectsExtraShellCommands() {
    XCTAssertEqual(SafeCredentialHelper.githubCLI("!/opt/homebrew/bin/gh auth git-credential"), "/opt/homebrew/bin/gh")
    XCTAssertEqual(SafeCredentialHelper.githubCLI("!'/tmp/path with spaces/gh' auth git-credential"), "/tmp/path with spaces/gh")
    XCTAssertEqual(SafeCredentialHelper.githubCLI("!gh auth git-credential"), "gh")
    for value in ["!gh auth git-credential; touch /tmp/x", "!gh auth token", "!gh auth git-credential get", "!gh auth git-credential --hostname=x", "!$(which gh) auth git-credential", "gh auth git-credential", "!/tmp/not-gh auth git-credential"] {
      XCTAssertNil(SafeCredentialHelper.githubCLI(value), value)
    }
  }
  func testHelperCompatibilityUpgradeReevaluatesOldBlocksOnceAndKeepsSuccess() throws {
    let persistence = RemoteCheckStore(url: root.appendingPathComponent("remote-checks.json"))
    var old = RemoteCheckRecord()
    old.helperCompatibilityVersion = nil; old.phase = .authenticationRequired
    old.authenticationFailure = .unsupportedHelper; old.lastSuccess = Date(timeIntervalSince1970: 100)
    old.lastAttempt = Date(timeIntervalSince1970: 200); old.repositoryIDs = [record.id]
    try persistence.save(["old": old])
    var restored = try XCTUnwrap(persistence.load()["old"])
    XCTAssertEqual(restored.phase, .notChecked); XCTAssertNil(restored.authenticationFailure)
    XCTAssertEqual(restored.lastSuccess, old.lastSuccess); XCTAssertEqual(restored.lastAttempt, old.lastAttempt)
    XCTAssertEqual(restored.repositoryIDs, old.repositoryIDs)
    var schedule = RemoteCheckSchedule()
    XCTAssertTrue(schedule.eligible("old", record: restored, interval: 900, now: Date().addingTimeInterval(1), uptime: 1))
    restored.phase = .authenticationRequired; restored.authenticationFailure = .requiresForegroundAuthorization
    try persistence.save(["old": restored])
    XCTAssertEqual(try persistence.load()["old"]?.phase, .authenticationRequired, "New failures must not loop after relaunch")
    for failure in [BackgroundAuthenticationState.accessDenied, .serverRejected] {
      old.authenticationFailure = failure
      try persistence.save(["old": old])
      XCTAssertEqual(try persistence.load()["old"]?.authenticationFailure, failure)
    }
    old.authenticationFailure = .requiresForegroundAuthorization
    try persistence.save(["old": old])
    XCTAssertEqual(try persistence.load()["old"]?.phase, .notChecked)
    old.helperCompatibilityVersion = 1
    try persistence.save(["old": old])
    let nativeKeychain = try XCTUnwrap(persistence.load()["old"])
    XCTAssertEqual(nativeKeychain.phase, .notChecked)
    XCTAssertEqual(nativeKeychain.helperCompatibilityVersion, RemoteCheckRecord.currentHelperCompatibilityVersion)
    XCTAssertEqual(nativeKeychain.lastSuccess, old.lastSuccess)
    XCTAssertEqual(nativeKeychain.repositoryIDs, old.repositoryIDs)
    try persistence.save(["old": nativeKeychain])
    XCTAssertEqual(try persistence.load()["old"], nativeKeychain)
    old.phase = .skipped; old.authenticationFailure = nil
    try persistence.save(["old": old])
    XCTAssertEqual(try persistence.load()["old"]?.phase, .notChecked, "Reevaluate old transport skips once")
    for failure in [BackgroundAuthenticationState.credentialMissing, .configurationInvalid, .sshIdentityNotLoaded, .sshAgentUnavailable] {
      old.helperCompatibilityVersion = 2; old.phase = .authenticationRequired; old.authenticationFailure = failure
      try persistence.save(["old": old])
      XCTAssertEqual(try persistence.load()["old"]?.phase, .notChecked)
    }
  }
  func testOrderedHelpersUseFirstCredentialInsteadOfLastURLMatch() async throws {
    let first = try store("first credentials", credentials: "https://first:synthetic-first@example.invalid\n")
    let second = try store("last", credentials: "https://last:synthetic-last@example.invalid\n")
    try await raw(["config", "--add", "credential.helper", first])
    try await raw(["config", "--add", "credential.helper", second])
    let native = try await raw(["config", "--get-urlmatch", "credential.helper", "https://example.invalid/team/repo.git"])
    XCTAssertEqual(native.text.trimmingCharacters(in: .newlines), second)
    let info = try await service.backgroundAuthentication(target())
    XCTAssertEqual(info.state, .ready); XCTAssertEqual(info.source, "store")
  }
  func testURLScopedResetPathPortAndUsernameRetainGitMatching() async throws {
    let fallback = try store("wrong", credentials: "https://wrong:synthetic@example.invalid\n")
    let exact = try store("exact", credentials: "https://alice:synthetic-a@example.invalid:8443/team/repo.git\nhttps://bob:synthetic-b@example.invalid:8443/other.git\n")
    try await raw(["remote", "set-url", "origin", "https://alice@example.invalid:8443/team/repo.git"])
    try await raw(["config", "credential.helper", fallback])
    try await raw(["config", "--add", "credential.https://example.invalid:8443/team.helper", ""])
    try await raw(["config", "--add", "credential.https://example.invalid:8443/team.helper", exact])
    try await raw(["config", "credential.useHttpPath", "true"])
    let info = try await service.backgroundAuthentication(target())
    XCTAssertEqual(info.state, .ready)
    try await raw(["remote", "set-url", "origin", "https://charlie@example.invalid:8443/team/repo.git"])
    do { _ = try await service.backgroundAuthentication(target()); XCTFail("Wrong account was accepted") }
    catch { XCTAssertEqual((error as? AuthenticationFailure)?.state, .credentialMissing) }
  }
  func testURLRewriteAndUseHttpPathFalseUseEffectiveTransport() async throws {
    let helper = try store("credentials", credentials: "https://alice:synthetic@example.invalid\n")
    try await raw(["config", "credential.helper", helper])
    try await raw(["config", "url.https://alice@example.invalid/.insteadOf", "alias:"])
    try await raw(["remote", "set-url", "origin", "alias:team/repo.git"])
    let info = try await service.backgroundAuthentication(target())
    XCTAssertEqual(info.transport, "HTTPS"); XCTAssertEqual(info.state, .ready)
  }
  func testConfiguredShellHelperIsReusedAndCanFallThroughToLaterHelper() async throws {
    let marker = root.appendingPathComponent("must-not-exist")
    try await raw(["config", "--add", "credential.helper", "!touch " + InputValidation.shellQuote(marker.path)])
    do { _ = try await service.backgroundAuthentication(target()); XCTFail() }
    catch { XCTAssertEqual((error as? AuthenticationFailure)?.state, .credentialMissing) }
    let helper = try store("safe", credentials: "https://alice:synthetic@example.invalid\n")
    try await raw(["config", "--add", "credential.helper", helper])
    let info = try await service.backgroundAuthentication(target())
    XCTAssertEqual(info.state, .ready)
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
  }
  func testNativeCacheSocketAndEmptyReset() async throws {
    let socket = root.appendingPathComponent("cache.sock").path
    let helper = "cache --socket=" + InputValidation.shellQuote(socket)
    try await raw(["config", "credential.helper", helper])
    defer { try? FileManager.default.removeItem(atPath: socket) }
    try await raw(["credential-cache", "--socket=" + socket, "store"], input: Data("protocol=https\nhost=example.invalid\nusername=cached\npassword=synthetic-cache\n\n".utf8))
    let info = try await service.backgroundAuthentication(target())
    XCTAssertEqual(info.source, "cache")
    try await raw(["credential-cache", "--socket=" + socket, "exit"])
    try await raw(["config", "--add", "credential.helper", ""])
    do { _ = try await service.backgroundAuthentication(target()); XCTFail() }
    catch { XCTAssertEqual((error as? AuthenticationFailure)?.state, .credentialMissing) }
  }
  func testCredentialConfigurationChangeInvalidatesReviewedTarget() async throws {
    let old = try await target()
    try await raw(["config", "credential.username", "changed"])
    let new = try await target()
    XCTAssertNotEqual(old.id, new.id)
    do { _ = try await service.backgroundAuthentication(old); XCTFail() }
    catch { XCTAssertEqual((error as? AuthenticationFailure)?.state, .configurationInvalid) }
    try await raw(["config", "http.extraHeader", "Authorization: synthetic-header"])
    let headerTarget = try await target()
    XCTAssertNotEqual(headerTarget.id, new.id)
  }
  func testExplicitRecoveryResetsBothClocksPreservesSuccessAndIsTargetScoped() {
    var schedule = RemoteCheckSchedule(), record = RemoteCheckRecord(), other = RemoteCheckRecord()
    let now = Date(); record.phase = .authenticationRequired; record.lastSuccess = now
    record.failures = 4; record.lastAttempt = now; record.authenticationFailure = .credentialMissing
    schedule.attempted("a", delay: 3600, uptime: 20); schedule.attempted("b", delay: 3600, uptime: 20)
    schedule.retry("a", record: &record, now: now, uptime: 21)
    XCTAssertTrue(schedule.eligible("a", record: record, interval: 900, now: now, uptime: 21))
    XCTAssertFalse(schedule.eligible("b", record: other, interval: 900, now: now, uptime: 21))
    XCTAssertEqual(record.lastSuccess, now); XCTAssertEqual(record.lastAttempt, now)
    XCTAssertNil(record.authenticationFailure); XCTAssertEqual(record.failures, 0)
    other.phase = .authenticationRequired
    XCTAssertFalse(schedule.eligible("b", record: other, interval: 900, now: now, uptime: 9999))
  }
  func testFailureClassesSeparateHostVerificationAndNetworkFromCredentialRejection() {
    XCTAssertEqual(AuthenticationFailure.classify(GitPierError.configuration("Host key verification failed")), .hostVerificationFailed)
    XCTAssertEqual(RemoteCheckPhase.forFailure(GitPierError.configuration("Host key verification failed")), .failed)
    XCTAssertEqual(AuthenticationFailure.classify(GitPierError.timeout), .networkFailure)
    XCTAssertEqual(RemoteCheckPhase.forFailure(GitPierError.configuration("Permission denied (publickey).")), .authenticationRequired)
    XCTAssertEqual(RemoteCheckPhase.forFailure(AuthenticationFailure(.unsupportedHelper)), .authenticationRequired)
  }
  func testManagedProfileDoesNotReturnAnotherAccountCredentialOrProtocolLines() {
    let profile = CredentialProfile(name: "account", host: "example.invalid:8443", username: "alice")
    XCTAssertNotNil(AuthenticationContext.helperResponse(request: "protocol=https\nhost=example.invalid:8443\nusername=alice\n", profile: profile, secret: "synthetic"))
    for request in ["protocol=https\nhost=example.invalid\n", "protocol=https\nhost=example.invalid:8443\nusername=bob\n", "protocol=http\nhost=example.invalid:8443\n"] {
      XCTAssertNil(AuthenticationContext.helperResponse(request: request, profile: profile, secret: "synthetic"))
    }
    XCTAssertNil(AuthenticationContext.helperResponse(request: "protocol=https\nhost=example.invalid:8443\n", profile: profile, secret: "synthetic\rsecret"))
  }
  func testManagedProfileIdentityIsStableAndIncludesProfileChanges() throws {
    let profile = CredentialProfile(name: "account", host: "example.invalid", username: "alice")
    let first = try AuthenticationContext.make(profile: profile, executable: "/tmp/synthetic-helper", configurationPath: "/tmp/synthetic-config").environment["GITPIER_AUTH_IDENTITY"]
    for _ in 0..<100 {
      XCTAssertEqual(try AuthenticationContext.make(profile: profile, executable: "/tmp/synthetic-helper", configurationPath: "/tmp/synthetic-config").environment["GITPIER_AUTH_IDENTITY"], first)
    }
    var changed = profile; changed.username = "bob"
    XCTAssertNotEqual(try AuthenticationContext.make(profile: changed, executable: "/tmp/synthetic-helper", configurationPath: "/tmp/synthetic-config").environment["GITPIER_AUTH_IDENTITY"], first)
  }
}

extension GitAuthenticationTests {
  func testPublicGitProtocolFirstAutomaticFetchUsesNativeTransport() async throws {
    let remote = root.appendingPathComponent("public.git")
    try await raw(["init", "--bare", "-q", remote.path])
    try await raw(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "fixture"])
    try await raw(["push", remote.path, "HEAD:refs/heads/main"])
    let portResult = try await ProcessRunner().run(executable: "/usr/bin/python3", arguments: ["-c", "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1])"], directory: root)
    let port = portResult.text.trimmingCharacters(in: .newlines)
    let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    server.arguments = ["daemon", "--export-all", "--reuseaddr", "--listen=127.0.0.1", "--port=" + port, "--base-path=" + root.path]
    server.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
    try server.run()
    addTeardownBlock {
      if server.isRunning { server.terminate() }
      for _ in 0..<100 where server.isRunning { try await Task.sleep(for: .milliseconds(10)) }
      XCTAssertFalse(server.isRunning)
    }
    let ready = try await ProcessRunner().run(executable: "/usr/bin/python3", arguments: ["-c", "import socket,time\nfor _ in range(100):\n try:\n  s=socket.create_connection(('127.0.0.1',int('" + port + "')), .1); s.close(); break\n except OSError: time.sleep(.02)\nelse: raise SystemExit(1)"], directory: root)
    XCTAssertEqual(ready.code, 0)
    try await raw(["remote", "set-url", "origin", "git://127.0.0.1:" + port + "/public.git"])
    let snapshot = try await service.workspaceSnapshot(record)
    let target = try XCTUnwrap(snapshot.remoteTarget)
    let fetched = try await service.checkedWorkspaceFetch(target, automatic: true)
    XCTAssertTrue(fetched.referencesUpdated)
    XCTAssertEqual(fetched.authentication?.transport, "Git")
    XCTAssertTrue(fetched.authentication?.verifiedByFetch == true)
  }
  func testFirstAutomaticHTTPSFetchWithTLSAndExistingStoreWithoutManualFetch() async throws {
    try await verifyFirstAutomaticHTTPSFetch(useGitHubCLI: false)
  }
  func testGitHubCLIFirstAutomaticHTTPSFetchWithTLSWithoutManualFetch() async throws {
    try await verifyFirstAutomaticHTTPSFetch(useGitHubCLI: true)
  }
  func testGitHubCLIFirstAutomaticFetchUsesExistingSecurityClientKeychainGrant() async throws {
    try await verifyFirstAutomaticHTTPSFetch(useGitHubCLI: true, useGitHubCLIKeychain: true)
  }
  func testNativeOSXKeychainFirstAutomaticFetchReusesOriginalGrantWithoutGitPierAccess() async throws {
    try await verifyFirstAutomaticHTTPSFetch(useGitHubCLI: false, useSystemKeychain: true)
  }
  func testNativeOSXKeychainFirstAutomaticHTTPFetchPreservesProtocolAndCredentialOnRejection() async throws {
    try await verifyFirstAutomaticHTTPSFetch(useGitHubCLI: false, useSystemKeychain: true, useHTTP: true)
  }
  func testPublicHTTPAndHTTPSFirstAutomaticFetchNeedsNoCredentialOrHelperCall() async throws {
    for http in [false, true] { try await verifyFirstAutomaticHTTPSFetch(useGitHubCLI: false, useHTTP: http, usePublic: true) }
  }
  func testNativeHelperFormsAndPartialResponsesAcrossHTTPAndHTTPS() async throws {
    for http in [false, true] {
      for form in ["named", "absolute", "shell", "partial", "bearer", "header", "userinfo", "askpass", "environmentAskpass", "sshAskpass", "managedExclusive"] {
        try await verifyFirstAutomaticHTTPSFetch(useGitHubCLI: false, useHTTP: http, customHelper: form)
      }
    }
  }
  func testTerminalAndGitPierCloneReuseExistingAuthenticationForFirstAutomaticFetch() async throws {
    for http in [false, true] {
      for workflow in ["terminalClone", "appClone"] {
        try await verifyFirstAutomaticHTTPSFetch(useGitHubCLI: false, useHTTP: http, workflow: workflow)
      }
    }
  }
  private func verifyFirstAutomaticHTTPSFetch(useGitHubCLI: Bool, useGitHubCLIKeychain: Bool = false, useSystemKeychain: Bool = false, useHTTP: Bool = false, usePublic: Bool = false, customHelper: String? = nil, workflow: String? = nil) async throws {
    let scheme = useHTTP ? "http" : "https"
    print("NATIVE_AUTH_CASE: " + scheme + "/" + (customHelper ?? workflow ?? (usePublic ? "public" : "native")))
    _ = try await service.read(["config", "--unset-all", "http.extraHeader"], allowFailure: true)
    let remote = root.appendingPathComponent("remote.git")
    try await raw(["init", "--bare", "-q", remote.path])
    try await raw(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "fixture"])
    try await raw(["push", remote.path, "HEAD:refs/heads/main"])
    try await raw(["--git-dir", remote.path, "symbolic-ref", "HEAD", "refs/heads/main"])
    let cert = root.appendingPathComponent("cert.pem"), key = root.appendingPathComponent("key.pem")
    let openssl = root.appendingPathComponent("openssl.cnf")
    try Data("[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=IP:127.0.0.1,DNS:localhost\n".utf8).write(to: openssl)
    let generated = try await ProcessRunner().run(executable: "/usr/bin/openssl", arguments: ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-config", openssl.path, "-keyout", key.path, "-out", cert.path], directory: root, timeout: 20)
    XCTAssertEqual(generated.code, 0)
    let portFile = root.appendingPathComponent("port")
    if FileManager.default.fileExists(atPath: portFile.path) { try FileManager.default.removeItem(at: portFile) }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/authenticated-https.py")
    // The system Git on older supported macOS versions predates authtype. A
    // native helper must negotiate capabilities and fall back to Basic there.
    let capabilities = try await ProcessRunner().run(executable: "/usr/bin/git", arguments: ["credential", "capability"], directory: root, environment: environment)
    let bearer = customHelper == "bearer" && capabilities.code == 0 && capabilities.text.split(separator: "\n").contains("capability authtype")
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [fixture.path, root.path, cert.path, key.path, portFile.path, scheme, usePublic ? "public" : "private", bearer ? "bearer" : "basic"]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run()
    addTeardownBlock {
      if process.isRunning { process.terminate() }
      for _ in 0..<100 where process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
      XCTAssertFalse(process.isRunning, "Disposable TLS fixture did not terminate")
    }
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: portFile.path) && process.isRunning { try await Task.sleep(for: .milliseconds(20)) }
    guard process.isRunning, let port = try? String(contentsOf: portFile, encoding: .utf8) else { return XCTFail("Isolated TLS server did not start") }
    let url = scheme + "://" + (customHelper == "userinfo" ? "alice:gitpier-synthetic-token@" : "") + "127.0.0.1:" + port + "/remote.git"
    try await raw(["remote", "set-url", "origin", url])
    try await raw(["config", "http.sslCAInfo", cert.path])
    let helper = try store("saved", credentials: scheme + "://alice:gitpier-synthetic-token@127.0.0.1:" + port + "\n")
    try await raw(["config", "--add", "credential.helper", helper])
    let cacheSocket = root.appendingPathComponent("fetch-cache.sock").path
    try await raw(["config", "--add", "credential.helper", "cache --socket=" + InputValidation.shellQuote(cacheSocket)])
    var credentialFile = root.appendingPathComponent("saved")
    let helperLog = root.appendingPathComponent("native-helper-log")
    if FileManager.default.fileExists(atPath: helperLog.path) { try FileManager.default.removeItem(at: helperLog) }
    var keychainService: String?
    var nativeKeychainHelper: String?
    let nativeQuery = "protocol=" + scheme + "\nhost=127.0.0.1:" + port + "\npath=remote.git\nusername=alice\n"
    func nativeKeychain(_ helper: String, _ operation: String, token: String? = nil, query: String? = nil) async throws -> CommandResult {
      let request = (query ?? nativeQuery) + (token.map { "password=" + $0 + "\n" } ?? "") + "\n"
      return try await ProcessRunner().run(executable: helper, arguments: [operation], directory: nil, input: Data(request.utf8), timeout: 10)
    }
    func credentialText(_ token: String) -> String {
      if useGitHubCLIKeychain { return "'127.0.0.1:\(port)':\n    user: alice\n" }
      return useGitHubCLI ? "'127.0.0.1:\(port)':\n    user: alice\n    oauth_token: \(token)\n" : scheme + "://alice:\(token)@127.0.0.1:\(port)\n"
    }
    func tokenData(_ token: String) -> Data { Data(("go-keyring-base64:" + Data(token.utf8).base64EncodedString()).utf8) }
    func security(_ command: String) async throws -> CommandResult {
      // The actual gh creator/reader is security, not XCTest or GitPier. Keep
      // synthetic values in stdin, and never broaden a foreign item's ACL.
      try await ProcessRunner().run(executable: "/usr/bin/security", arguments: ["-i"],
        directory: nil, input: Data((command + "\n").utf8), timeout: 10)
    }
    func replaceToken(_ token: String) async throws {
      if let nativeKeychainHelper {
        // Older Apple helpers silently ignore store for an existing item. Only
        // replace this fixture's exact identity, then verify the replacement.
        let erased = try await nativeKeychain(nativeKeychainHelper, "erase")
        XCTAssertEqual(erased.code, 0)
        let result = try await nativeKeychain(nativeKeychainHelper, "store", token: token)
        XCTAssertEqual(result.code, 0, "Cannot update this test's native credential")
        let read = try await nativeKeychain(nativeKeychainHelper, "get")
        XCTAssertTrue(read.text.split(separator: "\n").contains(Substring("password=" + token)), "Native fixture replacement must take effect before testing rejection")
      } else if let keychainService {
        let encoded = String(decoding: tokenData(token), as: UTF8.self)
        let result = try await security("add-generic-password -U -s " + InputValidation.shellQuote(keychainService) + " -a alice -w " + InputValidation.shellQuote(encoded))
        XCTAssertEqual(result.code, 0, "Cannot update synthetic native credential")
      } else { try Data(credentialText(token).utf8).write(to: credentialFile) }
    }
    if useGitHubCLI {
      let gh = try githubCLI()
      let config = root.appendingPathComponent("gh-config")
      try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
      credentialFile = config.appendingPathComponent("hosts.yml")
      try Data(credentialText("gitpier-synthetic-token").utf8).write(to: credentialFile)
      var env = environment
      for name in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"] { env[name] = "" }
      env["GH_CONFIG_DIR"] = config.path
      env["GITPIER_HELPER_EXECUTABLE"] = root.appendingPathComponent("nonexistent-GitPier-helper").path
      await service.configure(gitPath: "/usr/bin/git", authEnvironment: env)
      try await raw(["config", "--add", "credential." + url + ".helper", ""])
      try await raw(["config", "--add", "credential." + url + ".helper", "!" + InputValidation.shellQuote(gh) + " auth git-credential"])
      if useGitHubCLIKeychain {
        let name = "gh:127.0.0.1:" + port
        let encoded = String(decoding: tokenData("gitpier-synthetic-token"), as: UTF8.self)
        // No -U on creation: a preexisting item must never be changed or deleted.
        let created = try await security("add-generic-password -s " + InputValidation.shellQuote(name) + " -a alice -T /usr/bin/security -w " + InputValidation.shellQuote(encoded))
        guard created.code == 0 else { return XCTFail("Cannot create isolated native gh credential") }
        keychainService = name
        addTeardownBlock {
          let result = try await ProcessRunner().run(executable: "/usr/bin/security",
            arguments: ["delete-generic-password", "-s", name, "-a", "alice"], directory: nil, timeout: 10)
          XCTAssertEqual(result.code, 0, "Cannot remove this test's native credential")
        }
        let read = try await security("find-generic-password -s " + InputValidation.shellQuote(name) + " -a alice -w")
        guard read.code == 0, read.text.trimmingCharacters(in: .newlines) == encoded else {
          return XCTFail("Native security fixture readback failed (exit \(read.code)); no credential output is logged")
        }
        let native = try await ProcessRunner().run(executable: gh, arguments: ["auth", "git-credential", "get"], directory: root, environment: env, input: Data((nativeQuery + "\n").utf8))
        guard native.code == 0, native.text.split(separator: "\n").contains("password=gitpier-synthetic-token") else {
          return XCTFail("Original gh cannot read its isolated fixture (exit \(native.code)); automatic Fetch has not run")
        }
      }
    }
    if useSystemKeychain {
      let execPath = try await raw(["--exec-path"]).text.trimmingCharacters(in: .newlines)
      let helper = execPath + "/git-credential-osxkeychain"
      // The original native client creates and reads its own unique loopback item.
      // Do not create an XCTest-owned item or grant the GitPier reader access.
      let existing = try await nativeKeychain(helper, "get")
      guard existing.code == 0, !existing.text.contains("password=") else { return XCTFail("Fixture credential identity is already in use") }
      let created = try await nativeKeychain(helper, "store", token: "gitpier-synthetic-token")
      guard created.code == 0 else { return XCTFail("Cannot create isolated native osxkeychain credential") }
      nativeKeychainHelper = helper
      let cleanupInput = Data((nativeQuery + "\n").utf8)
      addTeardownBlock {
        let result = try await ProcessRunner().run(executable: helper, arguments: ["erase"], directory: nil, input: cleanupInput, timeout: 10)
        XCTAssertEqual(result.code, 0, "Cannot remove this test's native osxkeychain item")
        let after = try await ProcessRunner().run(executable: helper, arguments: ["get"], directory: nil, input: cleanupInput, timeout: 10)
        XCTAssertEqual(after.code, 0); XCTAssertFalse(after.text.contains("password="))
      }
      var env = environment
      env["GITPIER_HELPER_EXECUTABLE"] = root.appendingPathComponent("nonexistent-GitPier-helper").path
      await service.configure(gitPath: "/usr/bin/git", authEnvironment: env)
      try await raw(["config", "credential.useHttpPath", "true"])
      try await raw(["config", "credential.username", "alice"])
      try await raw(["config", "--add", "credential." + url + ".helper", ""])
      try await raw(["config", "--add", "credential." + url + ".helper", "osxkeychain"])
      for wrong in [nativeQuery.replacingOccurrences(of: "username=alice", with: "username=wrong-account"),
                    nativeQuery.replacingOccurrences(of: "path=remote.git", with: "path=wrong.git"),
                    nativeQuery.replacingOccurrences(of: "protocol=" + scheme, with: "protocol=" + (useHTTP ? "https" : "http"))] {
        let absent = try await nativeKeychain(helper, "get", query: wrong)
        XCTAssertEqual(absent.code, 0); XCTAssertFalse(absent.text.contains("password="))
      }
    }
    if let customHelper {
      let executable = root.appendingPathComponent("git-credential-fixture")
      let script = """
      #!/usr/bin/python3
      import pathlib, sys, urllib.parse
      pathlib.Path(\(String(reflecting: helperLog.path))).open('a').write(sys.argv[-1] + '\\n')
      request = sys.stdin.read()
      if sys.argv[-1] == 'get':
          token = urllib.parse.urlsplit(pathlib.Path(\(String(reflecting: credentialFile.path))).read_text().strip()).password
          if '--bearer' in sys.argv and 'capability[]=authtype' in request.splitlines():
              print('capability[]=authtype\\nauthtype=Bearer\\ncredential=' + token)
          else:
              if '--password-only' not in sys.argv: print('username=alice')
              if '--username-only' not in sys.argv: print('password=' + token)
          print()
      """
      try Data(script.utf8).write(to: executable)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
      var env = environment; env["PATH"] = root.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
      await service.configure(gitPath: "/usr/bin/git", authEnvironment: env)
      try await raw(["config", "--add", "credential.helper", ""])
      let helper: String
      switch customHelper {
      case "named": helper = "fixture --label='literal ; $ value'"
      case "absolute": helper = executable.path + " --label='with spaces'"
      case "partial": helper = executable.path + " --username-only"
      case "bearer": helper = executable.path + " --bearer"
      default: helper = "!f() { " + InputValidation.shellQuote(executable.path) + " \"$@\"; }; f"
      }
      try await raw(["config", "--add", "credential.helper", helper])
      if customHelper == "partial" { try await raw(["config", "--add", "credential.helper", executable.path + " --password-only"]) }
      if ["askpass", "environmentAskpass", "sshAskpass", "managedExclusive"].contains(customHelper) {
        let askpass = root.appendingPathComponent("original-askpass")
        try Data("""
        #!/usr/bin/python3
        import pathlib, sys, urllib.parse
        token = urllib.parse.urlsplit(pathlib.Path(\(String(reflecting: credentialFile.path))).read_text().strip()).password
        print('alice' if 'username' in sys.argv[1].lower() else token)
        """.utf8).write(to: askpass)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
        try await raw(["config", "--add", "credential.helper", ""])
        env["GIT_ASKPASS"] = nil
        _ = try await raw(["config", "core.askPass", ["askpass", "managedExclusive"].contains(customHelper) ? askpass.path : "/usr/bin/false"])
        if customHelper == "environmentAskpass" { env["GIT_ASKPASS"] = askpass.path }
        if customHelper == "sshAskpass" {
          _ = try await raw(["config", "--unset", "core.askPass"])
          env["SSH_ASKPASS"] = askpass.path; env["SSH_ASKPASS_REQUIRE"] = "force"
        }
        var args: [String] = []
        if customHelper == "managedExclusive" {
          env["GITPIER_CREDENTIAL_ID"] = UUID().uuidString
          args = ["-c", "credential.helper=", "-c", "credential.helper=!f() { echo 'GitPier authentication: requiresForegroundAuthorization' >&2; }; f"]
        }
        await service.configure(gitPath: "/usr/bin/git", authArguments: args, authEnvironment: env)
      }
      if ["header", "userinfo"].contains(customHelper) {
        try await raw(["config", "--add", "credential.helper", ""])
        if customHelper == "header" {
          try await raw(["config", "http.extraHeader", "Authorization: Basic " + Data("alice:gitpier-synthetic-token".utf8).base64EncodedString()])
        }
      }
    }
    if usePublic {
      // A public server never challenges, so even a configured helper must remain unused.
      try await raw(["config", "--add", "credential.helper", ""])
      try await raw(["config", "--add", "credential.helper", "!touch " + InputValidation.shellQuote(helperLog.path)])
    }
    addTeardownBlock {
      _ = try? await ProcessRunner().run(executable: "/usr/bin/git", arguments: ["credential-cache", "--socket=" + cacheSocket, "exit"], directory: nil)
    }
    if let workflow {
      let global = root.appendingPathComponent("clone-gitconfig")
      try await raw(["config", "--file", global.path, "credential.helper", helper])
      try await raw(["config", "--file", global.path, "http.sslCAInfo", cert.path])
      var env = environment; env["GIT_CONFIG_GLOBAL"] = global.path
      let destination = root.appendingPathComponent("cloned-" + UUID().uuidString)
      if workflow == "terminalClone" {
        let clone = try await ProcessRunner().run(executable: "/usr/bin/git", arguments: ["clone", "--", url, destination.path], directory: root, environment: env)
        guard clone.code == 0 else { return XCTFail("Synthetic terminal clone failed: " + GitService.redact(clone.errorText)) }
      } else { try await GitService.clone(url: url, destination: destination, environment: env) }
      service = GitService(root: destination); record = RepositoryRecord(path: destination.path)
      await service.configure(gitPath: "/usr/bin/git", authEnvironment: env)
      try await raw(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "remote update"])
      try await raw(["push", remote.path, "HEAD:refs/heads/main"])
    }
    let resolved = try await service.upstreamFetchTarget(record)
    let reviewed = try XCTUnwrap(resolved)
    if customHelper == "managedExclusive" {
      do { _ = try await service.checkedWorkspaceFetch(reviewed, automatic: true); XCTFail("A native provider masked the explicitly selected unavailable Token") }
      catch { XCTAssertEqual(AuthenticationFailure.classify(error), .requiresForegroundAuthorization) }
      return
    }
    let headBefore = try await service.read(["rev-parse", "HEAD"]).stdout
    let indexBefore = try? Data(contentsOf: service.root.appendingPathComponent(".git/index"))
    let fetchHeadBefore = try? Data(contentsOf: service.root.appendingPathComponent(".git/FETCH_HEAD"))
    let first = try await service.checkedWorkspaceFetch(reviewed, automatic: true)
    XCTAssertTrue(first.referencesUpdated); XCTAssertEqual(first.authentication?.state, .ready)
    XCTAssertEqual(first.authentication?.source, "gitConfiguration")
    XCTAssertTrue(first.authentication?.verifiedByFetch == true)
    XCTAssertEqual(first.authentication?.transport, useHTTP ? "HTTP" : "HTTPS")
    let fetched = try await service.read(["rev-parse", "refs/remotes/origin/main"])
    let head = try await raw(["rev-parse", "HEAD"]); XCTAssertEqual(fetched.stdout, head.stdout)
    let headAfter = try await service.read(["rev-parse", "HEAD"]).stdout
    XCTAssertEqual(headBefore, headAfter)
    XCTAssertEqual(indexBefore, try? Data(contentsOf: service.root.appendingPathComponent(".git/index")))
    XCTAssertEqual(fetchHeadBefore, try? Data(contentsOf: service.root.appendingPathComponent(".git/FETCH_HEAD")))
    if usePublic { XCTAssertFalse(FileManager.default.fileExists(atPath: helperLog.path)); return }
    if workflow != nil || ["header", "userinfo"].contains(customHelper ?? "") { return }
    let before = try Data(contentsOf: credentialFile)
    // Server rejection must not erase either a store entry or another helper's credential.
    try await replaceToken("invalid-synthetic-token")
    do { _ = try await service.checkedWorkspaceFetch(reviewed, automatic: true); XCTFail() }
    catch { XCTAssertEqual(AuthenticationFailure.classify(error), .serverRejected) }
    if let nativeKeychainHelper {
      let retained = try await nativeKeychain(nativeKeychainHelper, "get")
      XCTAssertEqual(retained.code, 0)
      XCTAssertTrue(retained.text.split(separator: "\n").contains("password=invalid-synthetic-token"), "Server rejection must not erase the native credential")
      XCTAssertEqual(try Data(contentsOf: credentialFile), before)
      try await replaceToken("gitpier-synthetic-token")
    } else if let keychainService {
      let read = try await security("find-generic-password -s " + InputValidation.shellQuote(keychainService) + " -a alice -w")
      XCTAssertEqual(read.code, 0)
      XCTAssertEqual(read.text.trimmingCharacters(in: .newlines), String(decoding: tokenData("invalid-synthetic-token"), as: UTF8.self), "Native rejection must not erase the existing gh item")
      XCTAssertEqual(try Data(contentsOf: credentialFile), before)
      try await replaceToken("gitpier-synthetic-token")
    } else {
      XCTAssertEqual(try String(contentsOf: credentialFile, encoding: .utf8), credentialText("invalid-synthetic-token"))
      try before.write(to: credentialFile)
    }
    if let customHelper, !["askpass", "environmentAskpass", "sshAskpass"].contains(customHelper) {
      let operations = try String(contentsOf: helperLog, encoding: .utf8).split(separator: "\n")
      XCTAssertFalse(operations.isEmpty); XCTAssertTrue(operations.allSatisfy { $0 == "get" }, "Automatic Fetch must not store or erase native credentials")
    }
    let manual = try await service.checkedWorkspaceFetch(reviewed)
    XCTAssertFalse(manual.referencesUpdated)
  }
}

extension GitAuthenticationTests {
  func testIsolatedSSHAgentPreparationMatchesSelectedIdentityAndSurvivesServiceRestart() async throws {
    addTeardownBlock { await SSHAgentSession.shared.shutdown() }
    let key = root.appendingPathComponent("identity")
    let generated = try await ProcessRunner().run(executable: "/usr/bin/ssh-keygen", arguments: ["-q", "-t", "ed25519", "-N", "", "-f", key.path], directory: root)
    XCTAssertEqual(generated.code, 0)
    let config = root.appendingPathComponent("ssh-config")
    try Data("Host alias.invalid\n HostName example.invalid\n Port 2222\n User git\n IdentityAgent SSH_AUTH_SOCK\n IdentitiesOnly yes\n IdentityFile \(key.path)\n".utf8).write(to: config)
    try await raw(["remote", "set-url", "origin", "ssh://git@alias.invalid/repository.git"])
    let service = GitService(root: root, sshConfigurationPath: config.path)
    var env = environment
    env["SSH_AUTH_SOCK"] = root.appendingPathComponent("absent-agent").path
    env["GITPIER_SSH_IDENTITY"] = key.path
    await service.configure(gitPath: "/usr/bin/git", authEnvironment: env)
    let target = try await service.reviewWorkspaceFetch(record)[0]
    let absent = try await service.backgroundAuthentication(target)
    XCTAssertEqual(absent.state, .sshAgentUnavailable)
    let prepared = try await service.prepareSSHAuthentication(target)
    XCTAssertEqual(prepared.state, .ready)
    guard let socket = await SSHAgentSession.shared.currentSocket() else { return XCTFail("No private agent") }
    let bound = await SSHAgentSession.shared.currentSocket(repository: root.path, authenticationIdentity: "")
    XCTAssertEqual(bound, socket)
    let unrelated = await SSHAgentSession.shared.currentSocket(repository: root.path + "/other", authenticationIdentity: "")
    let differentProfile = await SSHAgentSession.shared.currentSocket(repository: root.path, authenticationIdentity: "different")
    XCTAssertNil(unrelated); XCTAssertNil(differentProfile)
    env["SSH_AUTH_SOCK"] = socket
    let restarted = GitService(root: root, sshConfigurationPath: config.path)
    await restarted.configure(gitPath: "/usr/bin/git", authEnvironment: env)
    let reused = try await restarted.backgroundAuthentication(target)
    XCTAssertEqual(reused.state, .ready)
    // A different selected identity must not be described as ready merely because an agent is nonempty.
    let other = root.appendingPathComponent("other")
    _ = try await ProcessRunner().run(executable: "/usr/bin/ssh-keygen", arguments: ["-q", "-t", "ed25519", "-N", "", "-f", other.path], directory: root)
    env["GITPIER_SSH_IDENTITY"] = other.path
    await restarted.configure(gitPath: "/usr/bin/git", authEnvironment: env)
    let wrong = try await restarted.backgroundAuthentication(target)
    XCTAssertEqual(wrong.state, .sshIdentityNotLoaded)
    await SSHAgentSession.shared.shutdown()
    let stopped = try await restarted.backgroundAuthentication(target)
    XCTAssertEqual(stopped.state, .sshAgentUnavailable)
  }
  func testSSHBackgroundConfigGuardsJumpHostsAndRetainsAliasAndCustomPort() async throws {
    let config = root.appendingPathComponent("ssh-config")
    try Data("Host alias.invalid\n HostName example.invalid\n Port 2222\n ProxyJump jump.invalid:2200\nHost *\n BatchMode no\n StrictHostKeyChecking no\n UseKeychain yes\n".utf8).write(to: config)
    let guardConfig = try SSHBackgroundConfiguration(userConfiguration: config.path)
    defer { guardConfig.remove() }
    for destination in ["alias.invalid", "jump.invalid"] {
      let result = try await ProcessRunner().run(executable: "/usr/bin/ssh", arguments: ["-G", "-F", guardConfig.path, destination], directory: root)
      XCTAssertEqual(result.code, 0)
      let parsed = SSHAuthenticationConfiguration(result.text)
      XCTAssertEqual(parsed.first("batchmode"), "yes")
      XCTAssertEqual(parsed.first("stricthostkeychecking"), "true")
      XCTAssertEqual(parsed.first("numberofpasswordprompts"), "0")
      if destination == "alias.invalid" { XCTAssertEqual(parsed.first("port"), "2222"); XCTAssertEqual(parsed.first("hostname"), "example.invalid") }
    }
  }
}

extension GitAuthenticationTests {
  func testRealSSHFirstAutomaticFetchAfterEncryptedIdentityPreparationAndStrictKnownHosts() async throws {
    addTeardownBlock { await SSHAgentSession.shared.shutdown() }
    let key = root.appendingPathComponent("encrypted-identity"), hostKey = root.appendingPathComponent("host-key")
    for (path, passphrase) in [(key, "synthetic-passphrase"), (hostKey, "")] {
      let result = try await ProcessRunner().run(executable: "/usr/bin/ssh-keygen", arguments: ["-q", "-t", "ed25519", "-N", passphrase, "-f", path.path], directory: root)
      XCTAssertEqual(result.code, 0)
    }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let authorization = repository.appendingPathComponent(".cache/GitPier-sshd-auth-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: authorization, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: authorization) }
    // StrictModes rejects /private/tmp's ancestor permissions; keep only the synthetic public
    // authorization in a private directory with safe ancestors. No real authorized_keys is used.
    let authorized = authorization.appendingPathComponent("authorized_keys")
    try Data(contentsOf: key.appendingPathExtension("pub")).write(to: authorized)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authorized.path)
    let serverConfig = root.appendingPathComponent("sshd-config")
    let allocator = try await ProcessRunner().run(executable: "/usr/bin/python3", arguments: ["-c", "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1])"], directory: root)
    let port = allocator.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let pid = root.appendingPathComponent("sshd.pid")
    try Data("Port \(port)\nListenAddress 127.0.0.1\nHostKey \(hostKey.path)\nPidFile \(pid.path)\nAuthorizedKeysFile \(authorized.path)\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nStrictModes yes\nLogLevel ERROR\n".utf8).write(to: serverConfig)
    let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
    server.arguments = ["-D", "-e", "-f", serverConfig.path]
    server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
    try server.run()
    defer { if server.isRunning { server.terminate() } }
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: pid.path) && server.isRunning { try await Task.sleep(for: .milliseconds(20)) }
    guard server.isRunning, FileManager.default.fileExists(atPath: pid.path) else { return XCTFail("The isolated SSH server could not start") }
    let remote = root.appendingPathComponent("remote.git")
    try await raw(["init", "--bare", "-q", remote.path])
    try await raw(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "fixture"])
    try await raw(["push", remote.path, "HEAD:refs/heads/main"])
    let known = root.appendingPathComponent("known_hosts")
    try Data(("[127.0.0.1]:\(port) " + (try String(contentsOf: hostKey.appendingPathExtension("pub"), encoding: .utf8))).utf8).write(to: known)
    let clientConfig = root.appendingPathComponent("ssh-config")
    try Data("Host fixture.invalid\n HostName 127.0.0.1\n Port \(port)\n User \(NSUserName())\n IdentityAgent SSH_AUTH_SOCK\n IdentityFile \(key.path)\n IdentitiesOnly yes\n UserKnownHostsFile \(known.path)\n GlobalKnownHostsFile /dev/null\n StrictHostKeyChecking yes\n".utf8).write(to: clientConfig)
    let askpass = root.appendingPathComponent("synthetic-askpass")
    try Data("#!/bin/sh\nprintf '%s\\n' synthetic-passphrase\n".utf8).write(to: askpass)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
    try await raw(["remote", "set-url", "origin", "ssh://fixture.invalid" + remote.path])
    let service = GitService(root: root, sshConfigurationPath: clientConfig.path)
    var env = environment
    env["GIT_SSH_COMMAND"] = "/usr/bin/ssh"; env["GIT_SSH_VARIANT"] = "ssh"
    env["SSH_AUTH_SOCK"] = root.appendingPathComponent("absent-agent").path
    env["GITPIER_SSH_IDENTITY"] = key.path; env["SSH_ASKPASS"] = askpass.path; env["DISPLAY"] = "fixture:0"
    await service.configure(gitPath: "/usr/bin/git", authEnvironment: env)
    let target = try await service.reviewWorkspaceFetch(record)[0]
    let nativeAskpass = try await service.checkedWorkspaceFetch(target, automatic: true)
    XCTAssertTrue(nativeAskpass.referencesUpdated)
    XCTAssertTrue(nativeAskpass.authentication?.verifiedByFetch == true, "Original SSH Askpass must work without Agent preparation")
    let prepared = try await service.prepareSSHAuthentication(target)
    XCTAssertEqual(prepared.state, .ready)
    let first = try await service.checkedWorkspaceFetch(target, automatic: true)
    XCTAssertFalse(first.referencesUpdated)
    // A file identity needs no agent preparation. Reuse core.sshCommand and SCP syntax,
    // including native Match exec and UseKeychain settings, exactly as manual Git does.
    await SSHAgentSession.shared.shutdown()
    let fileIdentity = root.appendingPathComponent("file-identity")
    try FileManager.default.copyItem(at: key, to: fileIdentity)
    let decrypted = try await ProcessRunner().run(executable: "/usr/bin/ssh-keygen", arguments: ["-p", "-P", "synthetic-passphrase", "-N", "", "-f", fileIdentity.path], directory: root)
    XCTAssertEqual(decrypted.code, 0)
    let matchMarker = root.appendingPathComponent("native-match-ran")
    try Data("Host fixture.invalid\n HostName 127.0.0.1\n Port \(port)\n User \(NSUserName())\n IdentityAgent none\n IdentityFile \(fileIdentity.path)\n IdentitiesOnly yes\n UseKeychain yes\n UserKnownHostsFile \(known.path)\n GlobalKnownHostsFile /dev/null\n StrictHostKeyChecking yes\nMatch exec \"touch \(matchMarker.path)\"\n".utf8).write(to: clientConfig)
    try await raw(["config", "core.sshCommand", "/usr/bin/ssh -F " + InputValidation.shellQuote(clientConfig.path)])
    try await raw(["remote", "set-url", "origin", "fixture.invalid:" + remote.path])
    let fileService = GitService(root: root)
    await fileService.configure(gitPath: "/usr/bin/git", authEnvironment: environment.merging(["SSH_AUTH_SOCK": root.appendingPathComponent("absent-agent").path, "GIT_SSH_VARIANT": "ssh"]) { _, new in new })
    let fileTarget = try await fileService.reviewWorkspaceFetch(record)[0]
    let fileFetch = try await fileService.checkedWorkspaceFetch(fileTarget, automatic: true)
    XCTAssertTrue(fileFetch.authentication?.verifiedByFetch == true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: matchMarker.path))
    // GIT_SSH is also a native Git entry point, not necessarily GIT_SSH_COMMAND.
    let launcher = root.appendingPathComponent("native-ssh")
    try Data(("#!/bin/sh\nexec /usr/bin/ssh -F " + InputValidation.shellQuote(clientConfig.path) + " \"$@\"\n").utf8).write(to: launcher)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
    try await raw(["config", "--unset", "core.sshCommand"])
    await fileService.configure(gitPath: "/usr/bin/git", authEnvironment: environment.merging(["GIT_SSH": launcher.path, "GIT_SSH_VARIANT": "ssh"]) { _, new in new })
    let launcherTarget = try await fileService.reviewWorkspaceFetch(record)[0]
    let launcherFetch = try await fileService.checkedWorkspaceFetch(launcherTarget, automatic: true)
    XCTAssertTrue(launcherFetch.authentication?.verifiedByFetch == true)
    // Change only the temporary host file. Host verification must fail separately from credentials.
    try Data(("[127.0.0.1]:\(port) " + (try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8))).utf8).write(to: known)
    do { _ = try await fileService.checkedWorkspaceFetch(launcherTarget, automatic: true); XCTFail("Changed host key was accepted") }
    catch { XCTAssertEqual(AuthenticationFailure.classify(error), .hostVerificationFailed); XCTAssertEqual(RemoteCheckPhase.forFailure(error), .failed) }
  }
}

extension GitAuthenticationTests {
  func testSSHStaticIncludesAndNonexecutingMatchConditionsAreAccepted() throws {
    let config = root.appendingPathComponent("ssh-config"), includes = root.appendingPathComponent("conf")
    try FileManager.default.createDirectory(at: includes, withIntermediateDirectories: false)
    try Data("Host alias.invalid\n HostName example.invalid\nMatch host exec\n Port 2222\n".utf8).write(to: includes.appendingPathComponent("safe.conf"))
    try Data("Include conf/*.conf\nMatch canonical host *.invalid\n User git\n".utf8).write(to: config)
    XCTAssertNoThrow(try SSHConfigurationSafety.validate(userConfiguration: config.path, systemConfiguration: nil, userDirectory: root.path))
    try Data("Include ${UNSAFE_DYNAMIC_INCLUDE}\n".utf8).write(to: config)
    XCTAssertThrowsError(try SSHConfigurationSafety.validate(userConfiguration: config.path, systemConfiguration: nil, userDirectory: root.path))
    for option in ["ProxyCommand", "LocalCommand", "KnownHostsCommand", "PKCS11Provider", "SecurityKeyProvider"] {
      try Data((option + " /tmp/unknown-external-command\n").utf8).write(to: config)
      XCTAssertThrowsError(try SSHConfigurationSafety.validate(userConfiguration: config.path, systemConfiguration: nil, userDirectory: root.path))
    }
  }
  func testSSHMatchExecIsBlockedBeforeOpenSSHCanRunIncludedCommand() async throws {
    let config = root.appendingPathComponent("ssh-config"), included = root.appendingPathComponent("included-config"), marker = root.appendingPathComponent("must-not-run")
    try Data(("Include " + included.path + "\n").utf8).write(to: config)
    try await raw(["remote", "set-url", "origin", "ssh://git@example.invalid/repo.git"])
    let service = GitService(root: root, sshConfigurationPath: config.path)
    await service.configure(gitPath: "/usr/bin/git", authEnvironment: environment)
    let target = try await service.reviewWorkspaceFetch(record)[0]
    for condition in ["Match exec", "Match !exec", "Match=exec"] {
      try Data((condition + " \"touch " + marker.path + "\"\n HostName example.invalid\n").utf8).write(to: included)
      do { _ = try await service.backgroundAuthentication(target); XCTFail("External condition was accepted") }
      catch { XCTAssertEqual((error as? AuthenticationFailure)?.state, .configurationInvalid) }
      XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
  }
}
