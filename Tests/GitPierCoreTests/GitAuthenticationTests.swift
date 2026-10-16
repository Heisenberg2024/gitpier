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
  func testUnknownHelpersDoNotRunAndDoNotPreventLaterSafeHelper() async throws {
    let marker = root.appendingPathComponent("must-not-exist")
    try await raw(["config", "--add", "credential.helper", "!touch " + InputValidation.shellQuote(marker.path)])
    do { _ = try await service.backgroundAuthentication(target()); XCTFail() }
    catch { XCTAssertEqual((error as? AuthenticationFailure)?.state, .unsupportedHelper) }
    let helper = try store("safe", credentials: "https://alice:synthetic@example.invalid\n")
    try await raw(["config", "--add", "credential.helper", helper])
    let info = try await service.backgroundAuthentication(target())
    XCTAssertEqual(info.state, .ready)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
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
  func testFirstAutomaticHTTPSFetchWithTLSAndExistingStoreWithoutManualFetch() async throws {
    let remote = root.appendingPathComponent("remote.git")
    try await raw(["init", "--bare", "-q", remote.path])
    try await raw(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "fixture"])
    try await raw(["push", remote.path, "HEAD:refs/heads/main"])
    let cert = root.appendingPathComponent("cert.pem"), key = root.appendingPathComponent("key.pem")
    let openssl = root.appendingPathComponent("openssl.cnf")
    try Data("[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=IP:127.0.0.1,DNS:localhost\n".utf8).write(to: openssl)
    let generated = try await ProcessRunner().run(executable: "/usr/bin/openssl", arguments: ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-config", openssl.path, "-keyout", key.path, "-out", cert.path], directory: root, timeout: 20)
    XCTAssertEqual(generated.code, 0)
    let portFile = root.appendingPathComponent("port")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/authenticated-https.py")
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [fixture.path, root.path, cert.path, key.path, portFile.path]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: portFile.path) && process.isRunning { try await Task.sleep(for: .milliseconds(20)) }
    guard process.isRunning, let port = try? String(contentsOf: portFile, encoding: .utf8) else { return XCTFail("Isolated TLS server did not start") }
    let url = "https://127.0.0.1:" + port + "/remote.git"
    try await raw(["remote", "set-url", "origin", url])
    try await raw(["config", "http.sslCAInfo", cert.path])
    let helper = try store("saved", credentials: "https://alice:gitpier-synthetic-token@127.0.0.1:" + port + "\n")
    try await raw(["config", "--add", "credential.helper", helper])
    let cacheSocket = root.appendingPathComponent("fetch-cache.sock").path
    try await raw(["config", "--add", "credential.helper", "cache --socket=" + InputValidation.shellQuote(cacheSocket)])
    addTeardownBlock {
      _ = try? await ProcessRunner().run(executable: "/usr/bin/git", arguments: ["credential-cache", "--socket=" + cacheSocket, "exit"], directory: nil)
    }
    let reviewed = try await target()
    let first = try await service.checkedWorkspaceFetch(reviewed, automatic: true)
    XCTAssertTrue(first.referencesUpdated); XCTAssertEqual(first.authentication?.state, .ready)
    let fetched = try await raw(["rev-parse", "refs/remotes/origin/main"])
    let head = try await raw(["rev-parse", "HEAD"]); XCTAssertEqual(fetched.stdout, head.stdout)
    let before = try Data(contentsOf: root.appendingPathComponent("saved"))
    // Server rejection must not erase either a store entry or another helper's credential.
    try Data("https://alice:invalid-synthetic-token@127.0.0.1:\(port)\n".utf8).write(to: root.appendingPathComponent("saved"))
    do { _ = try await service.checkedWorkspaceFetch(reviewed, automatic: true); XCTFail() }
    catch { XCTAssertEqual(AuthenticationFailure.classify(error), .serverRejected) }
    XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("saved"), encoding: .utf8).contains("invalid-synthetic-token"))
    try before.write(to: root.appendingPathComponent("saved"))
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
    do { _ = try await service.checkedWorkspaceFetch(target, automatic: true); XCTFail("Locked identity unexpectedly authenticated") }
    catch { XCTAssertEqual(AuthenticationFailure.classify(error), .sshAgentUnavailable) }
    let prepared = try await service.prepareSSHAuthentication(target)
    XCTAssertEqual(prepared.state, .ready)
    let first = try await service.checkedWorkspaceFetch(target, automatic: true)
    XCTAssertTrue(first.referencesUpdated)
    // Change only the temporary host file. Host verification must fail separately from credentials.
    try Data(("[127.0.0.1]:\(port) " + (try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8))).utf8).write(to: known)
    do { _ = try await service.checkedWorkspaceFetch(target, automatic: true); XCTFail("Changed host key was accepted") }
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
