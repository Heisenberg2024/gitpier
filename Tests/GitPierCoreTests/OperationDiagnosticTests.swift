import XCTest

@testable import GitPierCore

final class OperationDiagnosticTests: XCTestCase {
  func testAuthenticationDiagnosticsRedactHeadersAndNamedSecrets() {
    let input = """
      fatal: https://fixture-user:fixture-password@example.invalid/repo?access_token=fixture-query-token
      Authorization: Bearer fixture-bearer-token
      Proxy-Authorization: Basic fixture-basic-value
      {"access_token":"fixture-json-token","refresh_token":"fixture-refresh-token","client_secret":"fixture-client-secret"}
      password=fixture-form-password
      token: fixture-named-token
      remote: permission denied (HTTP 403)
      """
    let diagnostic = GitService.redact(input)
    for secret in ["fixture-user", "fixture-password", "fixture-query-token", "fixture-bearer-token",
      "fixture-basic-value", "fixture-json-token", "fixture-refresh-token", "fixture-client-secret",
      "fixture-form-password", "fixture-named-token"] {
      XCTAssertFalse(diagnostic.contains(secret), "An authentication value remained in a user-visible diagnostic")
    }
    XCTAssertTrue(diagnostic.contains("example.invalid/repo"))
    XCTAssertTrue(diagnostic.contains("permission denied (HTTP 403)"))
  }

  func testHistoricalFailureRetainsItsOwnBoundedDiagnosticAndLocalCommit() {
    let hash = String(repeating: "a", count: 40)
    var history = OperationCenterHistory()
    var failed = WorkflowOperationRecord(kind: .commitAndPush, state: .running)
    history.insert(failed)
    failed.localCommit = hash
    failed.setDetail("Local commit succeeded; push failed.\nAuthorization: Bearer fixture-history-secret\n" + String(repeating: "diagnostic ", count: 1000))
    failed.state = .failed; failed.revision = 1
    XCTAssertTrue(history.update(failed))
    history.insert(WorkflowOperationRecord(kind: .push, state: .succeeded))
    let recorded = history.records.first { $0.id == failed.id }
    XCTAssertEqual(recorded?.localCommit, hash)
    XCTAssertEqual(recorded?.detail?.count, 4096)
    XCTAssertTrue(recorded?.detail?.contains("Local commit succeeded; push failed") == true)
    XCTAssertFalse(recorded?.detail?.contains("fixture-history-secret") == true)
    failed.state = .running; failed.setDetail("late progress"); failed.revision = 2
    XCTAssertFalse(history.update(failed))
    XCTAssertEqual(history.records.first { $0.id == failed.id }?.detail, recorded?.detail)
  }

  func testDiagnosticRetentionBoundsUTF8EvenForOneHugeGrapheme() {
    var record = WorkflowOperationRecord(kind: .git)
    let cluster = "e" + String(repeating: "\u{301}", count: 32768)
    record.setDetail("Failure: " + cluster)
    XCTAssertLessThanOrEqual(record.detail?.utf8.count ?? 0, 16 * 1024)
    XCTAssertTrue(record.detail?.hasPrefix("Failure: ") == true)
    record.setDetail(String(repeating: "🙂", count: 10000))
    XCTAssertEqual(record.detail?.count, 4096)
    XCTAssertEqual(record.detail?.utf8.count, 16 * 1024)
    XCTAssertFalse(record.detail?.contains("\u{fffd}") == true)
    record.setDetail("a" + String(repeating: "🙂", count: 10000))
    XCTAssertEqual(record.detail?.count, 4096)
    XCTAssertLessThanOrEqual(record.detail?.utf8.count ?? 0, 16 * 1024)
    XCTAssertFalse(record.detail?.contains("\u{fffd}") == true)
  }
}
