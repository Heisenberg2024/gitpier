import XCTest

@testable import GitPierCore

final class ReleaseConfigurationTests: XCTestCase {
  func testSingleProductionSourceAndMissingKeyGate() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let config = try JSONDecoder().decode(
      ReleaseConfiguration.self,
      from: Data(
        contentsOf: root.appendingPathComponent(
          "Sources/GitPier/Resources/ReleaseConfiguration.json")))
    try config.validate()
    XCTAssertGreaterThan(Int(config.build) ?? 0, 16)
    XCTAssertEqual(config.hasSigningKey, !config.publicEDKey.isEmpty)
  }
  func testHistoryDateAndHashValidation() throws {
    var query = HistoryQuery()
    query.after = "2026-02-30"
    XCTAssertThrowsError(try query.validate())
    query.after = "2026-10-12"
    query.before = "2026-10-11"
    XCTAssertThrowsError(try query.validate())
    query.before = "2026-10-13"
    query.hash = "--all"
    XCTAssertThrowsError(try query.validate())
    query.hash = "abcd1234"
    XCTAssertNoThrow(try query.validate())
    query.message = "bad\0input"
    XCTAssertThrowsError(try query.validate())
  }
  func testHistoryQueryIdentityIsStable() {
    var query = HistoryQuery()
    query.message = "native query"
    query.author = "tester"
    query.scope = .allReferences
    let identity = query.identity
    for _ in 0..<100 { XCTAssertEqual(query.identity, identity) }
    query.before = "2026-10-12"
    XCTAssertNotEqual(query.identity, identity)
  }
}
