import XCTest

@testable import GitPierCore

extension GitServiceTests {
  /// Incompressible binary data whose encoded Git patch exceeds the 16 MiB read limit.
  private func stageLargeBinary() async throws -> String {
    var bytes = Data(count: 14 * 1024 * 1024)
    bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
      var state: UInt64 = 0x123456789abcdef
      for index in stride(from: 0, to: buffer.count, by: 8) {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        buffer.storeBytes(of: state, toByteOffset: index, as: UInt64.self)
      }
      buffer[0] = 0
    }
    try bytes.write(to: directory.appendingPathComponent("art.bin"))
    try await raw(["add", "--", "art.bin"])
    return try await raw(["rev-parse", ":art.bin"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func testLargeBinarySnapshotAllowsSelectedCommitAndPushPreservingExternalStaging() async throws {
    try await seed()
    let blob = try await stageLargeBinary()
    try write("first.txt", "ONE\ntwo\nthree\n")
    try await raw(["add", "--", "first.txt"])
    try write("first.txt", "ONE\ntwo\nTHREE\n")
    try write("second.txt", "externally staged\n")
    try await raw(["add", "--", "second.txt"])
    let index = directory.appendingPathComponent(".git/index")
    let before = try Data(contentsOf: index)
    let review = try await git.snapshot()
    XCTAssertEqual(try Data(contentsOf: index), before, "Reading the snapshot must preserve the real Index")
    XCTAssertEqual(Set(review.paths), ["art.bin", "first.txt", "second.txt"])
    XCTAssertLessThan(review.patch.count, 1024 * 1024)
    let statistics = DiffParser.parse(review.patch)
    XCTAssertEqual(statistics.additions, 2)
    XCTAssertEqual(statistics.deletions, 2)

    let selected = try await git.status().files.filter { $0.path != "second.txt" }
    _ = try await git.commit(message: "feat: binary assets", expected: review, selection: selected)
    let committedBlob = try await raw(["rev-parse", "HEAD:art.bin"]).text
    let committedText = try await raw(["show", "HEAD:first.txt"]).text
    let excludedText = try await raw(["show", "HEAD:second.txt"]).text
    XCTAssertEqual(committedBlob.trimmingCharacters(in: .whitespacesAndNewlines), blob)
    XCTAssertEqual(committedText, "ONE\ntwo\nthree\n")
    XCTAssertEqual(excludedText, "other\n")
    let remaining = try await git.status()
    XCTAssertEqual(remaining.staged.map(\.path), ["second.txt"])
    XCTAssertTrue(remaining.files.first { $0.path == "first.txt" }?.isUnstaged == true)

    let remote = directory.appendingPathComponent(".git/remote.git")
    try await raw(["init", "--bare", remote.path])
    try await raw(["remote", "add", "origin", remote.path])
    _ = try await git.network("push", remote: "origin", branch: "main")
    let remoteBlob = try await raw(["--git-dir=" + remote.path, "rev-parse", "main:art.bin"]).text
    XCTAssertEqual(remoteBlob.trimmingCharacters(in: .whitespacesAndNewlines), blob)
    let afterPush = try await git.snapshot()
    XCTAssertEqual(afterPush.paths, ["second.txt"])
  }

  func testUnbornLargeBinarySnapshotStillRejectsChangedBinaryIndex() async throws {
    _ = try await stageLargeBinary()
    let review = try await git.snapshot()
    XCTAssertNil(review.head)
    XCTAssertEqual(review.paths, ["art.bin"])
    XCTAssertLessThan(review.patch.count, 1024 * 1024)
    try Data([0, 1, 2, 3]).write(to: directory.appendingPathComponent("art.bin"))
    try await raw(["add", "--", "art.bin"])
    let changed = try await git.snapshot()
    XCTAssertNotEqual(changed.identity, review.identity)
    do {
      _ = try await git.commit(message: "feat: stale assets", expected: review)
      XCTFail("A compact snapshot must still reject changed binary staging")
    } catch GitPierError.indexChanged {}
    let current = try await git.snapshot()
    XCTAssertEqual(current.identity, changed.identity)
    XCTAssertNil(current.head)
  }
}
