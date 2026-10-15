import XCTest
@testable import GitPierCore

final class RemoteCheckTests: XCTestCase {
  func testSettingsMigrationDefaultsRemainOfflineAndIndependent() throws {
    let old = try JSONDecoder().decode(AppSettings.self, from: Data("{\"automaticRefresh\":true,\"refreshPolicyVersion\":1}".utf8))
    XCTAssertFalse(old.automaticFetch); XCTAssertTrue(old.automaticRefresh)
    XCTAssertEqual(old.remoteCheckIntervalMinutes, 15); XCTAssertEqual(old.remoteCheckScope, "workspace")
    XCTAssertTrue(old.remoteCheckExcludedRepositories.isEmpty)
    var configured = old; configured.automaticFetch = true; configured.remoteCheckIntervalMinutes = 30
    configured.remoteCheckScope = "current"; configured.remoteCheckExcludedRepositories = [UUID()]
    XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(configured)), configured)
    let invalid = try JSONDecoder().decode(AppSettings.self, from: Data("{\"remoteCheckIntervalMinutes\":0,\"remoteCheckScope\":\"all\"}".utf8))
    XCTAssertEqual(invalid.remoteCheckIntervalMinutes, 15); XCTAssertEqual(invalid.remoteCheckScope, "current")
  }
  func testAutomaticChecksRequireExplicitOptInForegroundNetworkAndNoWrites() {
    var settings = AppSettings()
    XCTAssertFalse(RemoteCheckPolicy.mayEvaluate(settings, active: true, online: true, writing: false))
    settings.automaticFetch = true
    XCTAssertTrue(RemoteCheckPolicy.mayEvaluate(settings, active: true, online: true, writing: false))
    XCTAssertFalse(RemoteCheckPolicy.mayEvaluate(settings, active: false, online: true, writing: false))
    XCTAssertFalse(RemoteCheckPolicy.mayEvaluate(settings, active: true, online: false, writing: false))
    XCTAssertFalse(RemoteCheckPolicy.mayEvaluate(settings, active: true, online: true, writing: true))
    settings.automaticFetch = false
    XCTAssertFalse(RemoteCheckPolicy.mayEvaluate(settings, active: true, online: true, writing: false))
  }
  func testScopeAndPerRepositoryExclusionNeverGrantImplicitWorkspaceAccess() {
    var settings = AppSettings(); let current = UUID(), other = UUID()
    settings.remoteCheckScope = "current"
    XCTAssertTrue(RemoteCheckPolicy.includes(current, current: current, settings: settings))
    XCTAssertFalse(RemoteCheckPolicy.includes(other, current: current, settings: settings))
    XCTAssertFalse(RemoteCheckPolicy.includes(current, current: nil, settings: settings))
    settings.remoteCheckScope = "workspace"
    XCTAssertTrue(RemoteCheckPolicy.includes(other, current: current, settings: settings))
    settings.remoteCheckExcludedRepositories = [other]
    XCTAssertFalse(RemoteCheckPolicy.includes(other, current: current, settings: settings))
  }
  func testIntervalsAndCappedFailureBackoff() {
    XCTAssertEqual(RemoteCheckPolicy.intervals, [10, 15, 30, 60])
    XCTAssertEqual(RemoteCheckPolicy.interval(AppSettings(), current: true), 900)
    XCTAssertEqual(RemoteCheckPolicy.interval(AppSettings(), current: false), 2700)
    XCTAssertEqual((1...7).map(RemoteCheckPolicy.backoff), [300, 600, 1200, 2400, 3600, 3600, 3600])
  }
  func testNeverCheckedIsImmediatelyEligibleButInFlightAndAuthenticationAreNot() {
    var schedule = RemoteCheckSchedule(), record = RemoteCheckRecord()
    XCTAssertTrue(schedule.eligible("a", record: record, interval: 900, now: Date(), uptime: 10))
    for phase in [RemoteCheckPhase.queued, .checking, .authenticationRequired] {
      record.phase = phase
      XCTAssertFalse(schedule.eligible("a", record: record, interval: 900, now: Date(), uptime: 10000))
    }
  }
  func testSuccessfulFetchAndRapidRepositorySwitchesDoNotRepeat() {
    var schedule = RemoteCheckSchedule(), record = RemoteCheckRecord()
    let now = Date(timeIntervalSince1970: 10000)
    record.phase = .upToDate; record.lastSuccess = now; record.lastAttempt = now
    schedule.attempted("shared", delay: 900, uptime: 100)
    for offset in [0.0, 1, 5, 500, 899] {
      XCTAssertFalse(schedule.eligible("shared", record: record, interval: 900, now: now.addingTimeInterval(offset), uptime: 100 + offset))
    }
    XCTAssertTrue(schedule.eligible("shared", record: record, interval: 900, now: now.addingTimeInterval(900), uptime: 1000))
  }
  func testCurrentWorktreeUsesShorterIntervalAfterWorkspaceFetch() {
    var schedule = RemoteCheckSchedule(), record = RemoteCheckRecord()
    let now = Date(); record.phase = .referencesUpdated; record.lastSuccess = now
    schedule.attempted("shared", delay: 2700, uptime: 100)
    XCTAssertFalse(schedule.eligible("shared", record: record, interval: 900, now: now, uptime: 100))
    XCTAssertTrue(schedule.eligible("shared", record: record, interval: 900, now: now, uptime: 1000))
  }
  func testClockChangesCannotBypassMonotonicDeadline() {
    var schedule = RemoteCheckSchedule(), record = RemoteCheckRecord()
    let now = Date(); record.phase = .upToDate; record.lastSuccess = now
    schedule.attempted("a", delay: 900, uptime: 100)
    XCTAssertFalse(schedule.eligible("a", record: record, interval: 900, now: now.addingTimeInterval(86400), uptime: 101))
    XCTAssertFalse(schedule.eligible("a", record: record, interval: 900, now: now.addingTimeInterval(-86400), uptime: 102))
    XCTAssertTrue(schedule.eligible("a", record: record, interval: 900, now: now.addingTimeInterval(-86400), uptime: 1000))
  }
  func testRestartRestoresSuccessAndFutureClockIsBounded() {
    var schedule = RemoteCheckSchedule(), record = RemoteCheckRecord()
    let now = Date(); record.phase = .upToDate; record.lastSuccess = now.addingTimeInterval(-600)
    XCTAssertFalse(schedule.eligible("a", record: record, interval: 900, now: now, uptime: 10))
    XCTAssertTrue(schedule.eligible("a", record: record, interval: 900, now: now, uptime: 310))
    record.lastSuccess = now.addingTimeInterval(86400)
    XCTAssertFalse(schedule.eligible("future", record: record, interval: 900, now: now, uptime: 10))
    XCTAssertTrue(schedule.eligible("future", record: record, interval: 900, now: now, uptime: 3610))
  }
  func testNetworkRecoveryDoesNotBypassBackoff() {
    var schedule = RemoteCheckSchedule(), record = RemoteCheckRecord()
    let now = Date(); record.phase = .failed; record.failures = 2; record.nextEligible = now.addingTimeInterval(600)
    XCTAssertFalse(schedule.eligible("a", record: record, interval: 900, now: now, uptime: 10))
    XCTAssertFalse(schedule.eligible("a", record: record, interval: 900, now: now.addingTimeInterval(86400), uptime: 30))
    XCTAssertTrue(schedule.eligible("a", record: record, interval: 900, now: now, uptime: 610))
  }
  func testUpstreamWithoutComparisonIsNeverInterpretedAsZeroZeroEquality() throws {
    let gone = try StatusParser.parse(Data("# branch.head main\0# branch.upstream origin/missing\0".utf8))
    XCTAssertEqual(gone.upstream, "origin/missing"); XCTAssertFalse(gone.upstreamComparable)
    let valid = try StatusParser.parse(Data("# branch.head main\0# branch.upstream origin/main\0# branch.ab +0 -0\0".utf8))
    XCTAssertTrue(valid.upstreamComparable)
    let malformed = try StatusParser.parse(Data("# branch.ab +oops -0\0".utf8))
    XCTAssertFalse(malformed.upstreamComparable)
  }
  func testOldBatchReplayCannotOverwriteNewManualAttemptOrFailure() {
    var order = RemoteCheckAttemptOrder(); let batch = UUID(), manual = UUID()
    XCTAssertTrue(order.accepts(target: "shared", attempt: batch, startedUptime: 10))
    XCTAssertTrue(order.accepts(target: "shared", attempt: batch, startedUptime: 10))
    XCTAssertTrue(order.accepts(target: "shared", attempt: manual, startedUptime: 20))
    XCTAssertFalse(order.accepts(target: "shared", attempt: batch, startedUptime: 10))
    XCTAssertTrue(order.accepts(target: "shared", attempt: manual, startedUptime: 20))
    XCTAssertTrue(order.accepts(target: "other", attempt: batch, startedUptime: 10))
  }
  func testFailurePreservesLastSuccessButFreshLocalStateDoesNotVerifyRemote() {
    var record = RemoteCheckRecord()
    XCTAssertTrue(record.isStale(interval: 900))
    record.lastSuccess = Date(); record.phase = .upToDate
    XCTAssertFalse(record.isStale(interval: 900))
    record.phase = .failed
    XCTAssertNotNil(record.lastSuccess); XCTAssertTrue(record.isStale(interval: 900))
  }
  func testRemoteDiagnosticsRedactURLCredentialsAndQuerySecrets() {
    let value = GitService.redact("https://user:secret@example.invalid/repo?access_token=token-value&branch=main ssh://user:pass@example.invalid/r")
    XCTAssertFalse(value.contains("secret")); XCTAssertFalse(value.contains("token-value")); XCTAssertFalse(value.contains("user:pass"))
    XCTAssertTrue(value.contains("branch=main"))
  }
  func testAtomicMetadataRoundTripDoesNotPersistServerDiagnostics() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-remote-history-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = RemoteCheckStore(url: dir.appendingPathComponent("checks.json"))
    var record = RemoteCheckRecord(); record.lastSuccess = Date(timeIntervalSince1970: 12345)
    record.lastAttempt = Date(timeIntervalSince1970: 12390); record.phase = .failed; record.failures = 3
    record.nextEligible = Date(timeIntervalSince1970: 14000); record.repositoryIDs = [UUID()]
    record.diagnostic = "https://user:secret@remote.invalid/repo?token=secret"
    try store.save(["opaque-sha256": record])
    let loaded = try store.load()["opaque-sha256"]!
    XCTAssertEqual(loaded.lastSuccess, record.lastSuccess); XCTAssertEqual(loaded.failures, 3)
    XCTAssertEqual(loaded.repositoryIDs, record.repositoryIDs); XCTAssertNil(loaded.diagnostic)
    let text = try String(contentsOf: store.url, encoding: .utf8)
    XCTAssertFalse(text.contains("secret")); XCTAssertFalse(text.contains("remote.invalid"))
    let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    try store.save([:]); XCTAssertTrue(try store.load().isEmpty)
  }
  func testInterruptedChecksRecoverWithoutClaimingNewSuccessAndUnknownVersionsFail() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-remote-history-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = RemoteCheckStore(url: dir.appendingPathComponent("checks.json"))
    var record = RemoteCheckRecord(); record.phase = .checking; record.lastAttempt = Date()
    try store.save(["key": record]); XCTAssertEqual(try store.load()["key"]?.phase, .notChecked)
    try Data("{\"version\":99,\"records\":{}}".utf8).write(to: store.url)
    XCTAssertThrowsError(try store.load())
    XCTAssertTrue(try String(contentsOf: store.url, encoding: .utf8).contains("99"))
  }
}
