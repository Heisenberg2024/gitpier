import XCTest
@testable import GitPierCore

final class CommitMessageFormatterTests: XCTestCase {
  func testNormalizesSubjectAndParagraphSpacingWithoutReflowing() {
    let input = "\r\n  fix(push):   改善重试  \r\nExplain the reason. \r\n\r\n\r\nKeep this paragraph.\r\n\r\n"
    let expected = "fix(push): 改善重试\n\nExplain the reason.\n\nKeep this paragraph."
    XCTAssertEqual(CommitMessageFormatter.format(input), expected)
    XCTAssertEqual(CommitMessageFormatter.format(expected), expected)
    XCTAssertEqual(CommitMessageFormatter.format("  自由格式的标题  "), "自由格式的标题")
    XCTAssertEqual(CommitMessageFormatter.format("  \r\n \t "), "")
  }

  func testPreservesListsTrailersURLsAndCodeWhitespace() {
    let message = """
      Document `x  y` and https://example.invalid/path?q=x%20y

      - Outer
        - Nested
      \(String(repeating: " ", count: 4))indented block\u{20}


          next code line\u{20}

      ~~~~sh
      printf 'keep  this'\u{20}


      ~~~~

      See https://example.invalid/a  \u{0A}Hard line break above.

      Signed-off-by: Example User <user@example.invalid>
      """
    XCTAssertEqual(CommitMessageFormatter.format(message), message)
  }
}
