import XCTest

@testable import GitPierCore

extension GitServiceTests {
  func testFiveThousandCommitPagesKeepFullHashesAndFollowBranchChanges() async throws {
    var stream = ""
    for index in 0..<5000 {
      let message = "stability history \(index)\n", content = "value \(index)\n"
      stream += "commit refs/heads/main\ncommitter Stability Fixture <fixture@example.invalid> \(1_700_000_000 + index) +0000\ndata \(message.utf8.count)\n\(message)M 100644 inline history.txt\ndata \(content.utf8.count)\n\(content)\n"
    }
    try await raw(["fast-import", "--quiet"], input: Data(stream.utf8))
    var records: [CommitRecord] = []
    for offset in stride(from: 0, to: 5000, by: 500) {
      let page = try await git.history(skip: offset, count: 500)
      XCTAssertEqual(page.count, 500)
      records.append(contentsOf: page)
    }
    XCTAssertEqual(Set(records.map(\.hash)).count, 5000)
    XCTAssertTrue(records.allSatisfy { $0.hash.count == 40 })
    XCTAssertEqual(records.first?.subject, "stability history 4999")
    XCTAssertEqual(records.last?.subject, "stability history 0")
    let tail = try await git.history(skip: 5000)
    XCTAssertTrue(tail.isEmpty)
    try await raw(["branch", "history-earlier", records[2500].hash])
    try await raw(["symbolic-ref", "HEAD", "refs/heads/history-earlier"])
    let changed = try await git.history(count: 100)
    XCTAssertEqual(changed.first?.hash, records[2500].hash)
    XCTAssertEqual(changed.count, 100)
  }

  func testCommitReceiptSupportsSHA256Repositories() async throws {
    let root = directory.appendingPathComponent(".git/sha256-fixture")
    try await raw(["init", "-b", "main", "--object-format=sha256", root.path])
    for args in [["user.name", "Stability Fixture"], ["user.email", "fixture@example.invalid"],
      ["commit.gpgsign", "false"], ["core.hooksPath", root.appendingPathComponent(".git/hooks").path]] {
      try await raw(["-C", root.path, "config"] + args)
    }
    try Data("sha256\n".utf8).write(to: root.appendingPathComponent("file.txt"))
    try await raw(["-C", root.path, "add", "--", "file.txt"])
    let service = GitService(root: root)
    let result = try await service.commit(message: "feat: sha256 fixture", expected: service.snapshot())
    let hash = try await raw(["-C", root.path, "rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    XCTAssertEqual(result.hash, hash)
    XCTAssertEqual(hash.count, 64)
    XCTAssertNil(result.observationWarning)
  }
}
