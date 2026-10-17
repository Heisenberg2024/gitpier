import XCTest
@testable import GitPierCore

final class DiffParserSafetyTests: XCTestCase {
  private func patch(_ header: String, body: String = "-old\n+new\n") -> Data {
    Data(("diff --git a/file.txt b/file.txt\n--- a/file.txt\n+++ b/file.txt\n" + header + "\n" + body).utf8)
  }
  private func assertRejected(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
    let value = DiffParser.parse(data)
    XCTAssertEqual(value.raw, String(decoding: data, as: UTF8.self), file: file, line: line)
    XCTAssertTrue(value.hunks.isEmpty, file: file, line: line); XCTAssertTrue(value.pairs.isEmpty, file: file, line: line)
    XCTAssertTrue(value.complexMetadata, file: file, line: line); XCTAssertFalse(SelectivePatch.supported(value), file: file, line: line)
    XCTAssertThrowsError(try SelectivePatch.build(value, selected: [0]), file: file, line: line)
  }
  func testRemoteIntMaxCoordinatesCannotOverflowOrEnableLineActions() {
    assertRejected(patch("@@ -\(Int.max) +1 @@"))
    assertRejected(patch("@@ -1 +\(Int.max) @@"))
    assertRejected(patch("@@ -\(Int.max),0 +1 @@", body: "+new\n"))
    assertRejected(patch("@@ -1 +\(Int.max),0 @@", body: "-old\n"))
  }
  func testMalformedRemoteHunkCoordinatesNeverIndexEmptyComponents() {
    for header in ["@@ - + @@", "@@ -,1 +1 @@", "@@ -1, +1 @@", "@@ -1,,2 +1 @@", "@@ -one +1 @@", "@@ --1 +1 @@", "@@ -1 +-1 @@", "@@ -1 +1", "@@ -0 +1 @@", "@@ -1,-2 +1 @@"] {
      assertRejected(patch(header))
    }
  }
  func testOverflowingAndImpossibleDeclaredCountsAreRejected() {
    let huge = String(repeating: "9", count: 500)
    assertRejected(patch("@@ -\(huge),1 +1 @@"))
    assertRejected(patch("@@ -1,\(huge) +1 @@"))
    assertRejected(patch("@@ -1,\(Int.max) +1 @@"))
    assertRejected(patch("@@ -1,1000000 +1 @@"))
  }
  func testInvalidLaterHunkCannotLeaveEarlierActionableHunks() {
    assertRejected(patch("@@ -1 +1 @@", body: "-old\n+new\n@@ -\(Int.max) +4 @@\n-old\n+new\n"))
  }
  func testNormalOmittedCountsAndZeroLengthRangesKeepExactNumbers() throws {
    let replaced = DiffParser.parse(patch("@@ -10 +20 @@"))
    XCTAssertEqual(replaced.hunks.first?.lines.map(\.oldNumber), [10, nil])
    XCTAssertEqual(replaced.hunks.first?.lines.map(\.newNumber), [nil, 20])
    let added = DiffParser.parse(patch("@@ -0,0 +1,2 @@", body: "+one\n+two\n"))
    XCTAssertEqual(added.hunks.first?.lines.map(\.newNumber), [1, 2]); XCTAssertFalse(added.complexMetadata)
    let deleted = DiffParser.parse(patch("@@ -1,2 +0,0 @@", body: "-one\n-two\n"))
    XCTAssertEqual(deleted.hunks.first?.lines.map(\.oldNumber), [1, 2]); XCTAssertFalse(deleted.complexMetadata)
    XCTAssertTrue(SelectivePatch.supported(replaced))
    let selected = try SelectivePatch.build(replaced, selected: Set(replaced.hunks[0].lines.map(\.id)))
    XCTAssertTrue(String(decoding: selected, as: UTF8.self).contains("@@ -10,1 +10,1 @@"))
  }
  func testLargeButRepresentableCoordinatesAreNotClampedOrInvented() {
    let start = Int.max - 100
    let value = DiffParser.parse(patch("@@ -\(start) +\(start) @@"))
    XCTAssertEqual(value.hunks.first?.lines.first?.oldNumber, start)
    XCTAssertEqual(value.hunks.first?.lines.last?.newNumber, start)
    XCTAssertFalse(value.complexMetadata)
  }
  func testEntireCRLFPatchHeadersKeepOriginalProtocolAndContentBytes() {
    for header in ["@@ -1 +1 @@", "@@ -1 +1 @@ functionName"] {
      let lf = String(decoding: patch(header), as: UTF8.self)
      let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n"), data = Data(crlf.utf8)
      let value = DiffParser.parse(data)
      XCTAssertEqual(value.raw, crlf); XCTAssertFalse(value.complexMetadata)
      XCTAssertEqual(value.hunks.count, 1)
      XCTAssertEqual(value.hunks.first?.header, header + "\r")
      XCTAssertEqual(value.hunks.first?.lines.map(\.text), ["old\r", "new\r"])
      XCTAssertEqual(value.hunks.first?.lines.map(\.oldNumber), [1, nil])
      XCTAssertEqual(value.hunks.first?.lines.map(\.newNumber), [nil, 1])
      XCTAssertEqual(value.hunks.first?.patch, data)
    }
  }
  func testContentOnlyCRLFIsNeverTrimmedDuringHeaderParsing() throws {
    let data = patch("@@ -1 +1 @@", body: "-old\r\n+new\r\n")
    let value = DiffParser.parse(data)
    XCTAssertEqual(value.raw, String(decoding: data, as: UTF8.self)); XCTAssertFalse(value.complexMetadata)
    XCTAssertEqual(value.hunks.first?.header, "@@ -1 +1 @@")
    XCTAssertEqual(value.hunks.first?.lines.map(\.text), ["old\r", "new\r"])
    let selected = try SelectivePatch.build(value, selected: Set(value.hunks[0].lines.map(\.id)))
    XCTAssertTrue(String(decoding: selected, as: UTF8.self).hasSuffix("-old\r\n+new\r\n"))
  }
  func testNoFinalNewlineMarkersAndUnterminatedPatchStillParse() throws {
    let body = "-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file"
    let data = patch("@@ -1 +1 @@", body: body), value = DiffParser.parse(data)
    XCTAssertEqual(value.raw, String(decoding: data, as: UTF8.self)); XCTAssertEqual(value.hunks.count, 1)
    XCTAssertEqual(value.hunks.first?.lines.map(\.text), ["old", "new"]); XCTAssertFalse(value.complexMetadata)
    let selected = try SelectivePatch.build(value, selected: Set(value.hunks[0].lines.map(\.id)))
    XCTAssertEqual(String(decoding: selected, as: UTF8.self).components(separatedBy: "\\ No newline at end of file").count - 1, 2)
  }
  func testCRLFZeroLengthRangesAndUnterminatedContentPreserveNumbers() {
    let added = DiffParser.parse(patch("@@ -0,0 +1,2 @@\r", body: "+one\r\n+two\r"))
    XCTAssertFalse(added.complexMetadata); XCTAssertEqual(added.hunks.first?.lines.map(\.text), ["one\r", "two\r"])
    XCTAssertEqual(added.hunks.first?.lines.map(\.oldNumber), [nil, nil]); XCTAssertEqual(added.hunks.first?.lines.map(\.newNumber), [1, 2])
    let deleted = DiffParser.parse(patch("@@ -1,2 +0,0 @@\r", body: "-one\r\n-two\r"))
    XCTAssertFalse(deleted.complexMetadata); XCTAssertEqual(deleted.hunks.first?.lines.map(\.oldNumber), [1, 2])
    XCTAssertEqual(deleted.hunks.first?.lines.map(\.newNumber), [nil, nil])
  }
  func testBodyMustExactlyMatchBothDeclaredCounts() {
    for header in ["@@ -1 +1,0 @@", "@@ -1,0 +1 @@", "@@ -1,2 +1 @@", "@@ -1 +1,2 @@"] {
      assertRejected(patch(header))
    }
    assertRejected(patch("@@ -0,0 +0,0 @@"))
    assertRejected(patch("@@ -0,0 +0,0 @@", body: ""))
    assertRejected(patch("@@ -1 +1 @@", body: ""))
    assertRejected(patch("@@ -1,2 +1,2 @@", body: " same\n"))
    assertRejected(patch("@@ -1,2 +1,2 @@", body: " same\n-old\n"))
    assertRejected(patch("@@ -1 +1 @@", body: "-old\n+new\n extra\n"))
  }
  func testBadLaterBodyCountsDiscardEveryEarlierActionableHunk() {
    assertRejected(patch("@@ -1 +1 @@", body: "-old\n+new\n@@ -4 +4,0 @@\n-old\n+new\n"))
  }
}
