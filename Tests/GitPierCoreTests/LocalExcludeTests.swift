import XCTest

@testable import GitPierCore

extension GitServiceTests {
  func testLocalExcludeIsLiteralAnchoredAndPreservesIndexAndRules() async throws {
    try await seed()
    try write("first.txt", "staged externally\n")
    try await raw(["add", "--", "first.txt"])
    let indexURL = directory.appendingPathComponent(".git/index")
    let index = try Data(contentsOf: indexURL)
    let exclude = directory.appendingPathComponent(".git/info/exclude")
    let original = Data("# Preserve comments\nexisting-rule".utf8)
    try original.write(to: exclude)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: exclude.path)
    try write(".gitignore", "shared-rule\n")
    let path = "中文 folder/!#file [a]*?\\ end "
    try write(path, "local-only\n")
    try write("nested/" + path, "same name elsewhere\n")
    try write("中文 folder/!#file aXX end ", "glob sibling\n")
    try await git.excludeLocally(path)
    let bytes = try Data(contentsOf: exclude)
    XCTAssertTrue(bytes.starts(with: original + Data("\n".utf8)))
    let check = try await raw(["check-ignore", "--", path])
    XCTAssertFalse(check.stdout.isEmpty)
    let remaining = try await git.status().untracked.map(\.path)
    XCTAssertFalse(remaining.contains(path))
    XCTAssertTrue(remaining.contains("nested/" + path))
    XCTAssertTrue(remaining.contains("中文 folder/!#file aXX end "))
    XCTAssertEqual(try Data(contentsOf: indexURL), index)
    XCTAssertEqual(
      try String(contentsOf: directory.appendingPathComponent(".gitignore"), encoding: .utf8),
      "shared-rule\n")
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: exclude.path)[.posixPermissions] as? Int,
      0o600)
    try await git.excludeLocally(path)
    XCTAssertEqual(
      try Data(contentsOf: exclude), bytes, "Repeated exclusion must not duplicate rules")
  }

  func testLocalExcludeRejectsTrackedAndNewlyStagedFiles() async throws {
    try await seed()
    try write("new.txt", "untracked before menu opened\n")
    let stale = try await git.status().untracked.first { $0.path == "new.txt" }!
    try await raw(["add", "--", stale.path])
    try write("intent.txt", "intent-to-add\n")
    try await raw(["add", "--intent-to-add", "--", "intent.txt"])
    let exclude = directory.appendingPathComponent(".git/info/exclude")
    let before = try Data(contentsOf: exclude)
    let index = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
    for path in ["first.txt", stale.path, "intent.txt"] {
      do {
        try await git.excludeLocally(path)
        XCTFail("Must reject tracked or staged file: \(path)")
      } catch GitPierError.invalidInput {}
    }
    XCTAssertEqual(try Data(contentsOf: exclude), before)
    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".git/index")), index)
  }

  func testLocalExcludeUsesSharedMetadataForLinkedWorktree() async throws {
    try await seed()
    let linked = directory.appendingPathComponent("linked-worktree")
    try await raw(["worktree", "add", "-b", "linked", linked.path])
    let path = "local only.txt"
    try Data("worktree content\n".utf8).write(to: linked.appendingPathComponent(path))
    let service = GitService(root: linked)
    let indexLocation = try await service.read(["rev-parse", "--git-path", "index"]).text
      .trimmingCharacters(in: .newlines)
    let indexURL = URL(fileURLWithPath: indexLocation)
    let index = try Data(contentsOf: indexURL)
    try await service.excludeLocally(path)
    let shared = try String(
      contentsOf: directory.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
    XCTAssertTrue(shared.contains("/local\\ only.txt\n"))
    let remaining = try await service.status().untracked.map(\.path)
    XCTAssertFalse(remaining.contains(path))
    XCTAssertEqual(try Data(contentsOf: indexURL), index)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: linked.appendingPathComponent(".gitignore").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: linked.appendingPathComponent(path).path))
  }

  func testLocalExcludeRejectsNewlinesAndSymlinkedMetadata() async throws {
    try write("safe.txt", "untracked\n")
    for path in ["unsafe\n*.txt", "unsafe\r*.txt", "../unsafe"] {
      do {
        try await git.excludeLocally(path)
        XCTFail("Must reject unsafe rule")
      } catch is GitPierError {}
    }
    let external = directory.appendingPathComponent("untouched.txt")
    let original = Data("do not overwrite\n".utf8)
    try original.write(to: external)
    let info = directory.appendingPathComponent(".git/info")
    let exclude = info.appendingPathComponent("exclude")
    try FileManager.default.removeItem(at: exclude)
    try FileManager.default.createSymbolicLink(at: exclude, withDestinationURL: external)
    do {
      try await git.excludeLocally("safe.txt")
      XCTFail("Must reject exclude symlink")
    } catch GitPierError.invalidInput {}
    XCTAssertEqual(try Data(contentsOf: external), original)
    try FileManager.default.removeItem(at: info)
    let destination = directory.appendingPathComponent("external-info")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: info, withDestinationURL: destination)
    do {
      try await git.excludeLocally("safe.txt")
      XCTFail("Must reject info directory symlink")
    } catch GitPierError.invalidInput {}
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: destination.appendingPathComponent("exclude").path))
  }

  func testLocalExcludeCreatesMissingInfoAndRejectsMissingFile() async throws {
    try FileManager.default.removeItem(at: directory.appendingPathComponent(".git/info"))
    try write("new.txt", "untracked\n")
    try await git.excludeLocally("new.txt")
    XCTAssertEqual(
      try String(
        contentsOf: directory.appendingPathComponent(".git/info/exclude"), encoding: .utf8),
      "/new.txt\n")
    do {
      try await git.excludeLocally("gone.txt")
      XCTFail("Must reject vanished file")
    } catch GitPierError.invalidInput {}
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("new.txt").path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/index").path))
  }

  func testConcurrentWorktreeLocalExcludesPreserveEveryRule() async throws {
    try await seed()
    let linked = directory.appendingPathComponent("linked-worktree")
    try await raw(["worktree", "add", "-b", "linked", linked.path])
    let service = GitService(root: linked)
    let paths = (0..<12).map { "local-\($0).tmp" }
    for path in paths {
      try write(path, "main\n")
      try Data("linked\n".utf8).write(to: linked.appendingPathComponent(path))
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for path in paths {
        group.addTask { [git = git!] in try await git.excludeLocally(path) }
        group.addTask { try await service.excludeLocally(path) }
      }
      try await group.waitForAll()
    }
    let rules = try String(
      contentsOf: directory.appendingPathComponent(".git/info/exclude"), encoding: .utf8
    )
    .split(separator: "\n")
    for path in paths { XCTAssertEqual(rules.filter { $0 == "/" + path }.count, 1) }
    let remaining = try await service.status().untracked.map(\.path)
    XCTAssertFalse(remaining.contains(where: { paths.contains($0) }))
  }
}
