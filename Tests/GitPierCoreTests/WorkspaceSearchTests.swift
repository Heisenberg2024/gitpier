import XCTest
@testable import GitPierCore

private actor SearchCounter {
  var active = 0; var peak = 0; var calls = 0
  func load(_ record: RepositoryRecord, query: String) async throws -> WorkspaceRepositorySearchPage {
    active += 1; peak = max(peak, active); calls += 1
    defer { active -= 1 }
    try await Task.sleep(for: .milliseconds(25))
    return WorkspaceRepositorySearchPage(hits: [WorkspaceSearchHit(repositoryID: record.id, kind: .file, value: query, detail: record.name)], hasMore: false)
  }
  func stats() -> (Int, Int, Int) { (active, peak, calls) }
}
final class WorkspaceSearchTests: XCTestCase {
  var fixture: URL!
  var root: URL!
  var git: GitService!
  var record: RepositoryRecord!
  override func setUp() async throws {
    fixture = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-search-" + UUID().uuidString)
    root = fixture.appendingPathComponent("repository"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    git = GitService(root: root); record = RepositoryRecord(path: root.path, name: "Search Fixture")
    try await raw(["init", "-b", "main"]); try await raw(["config", "user.name", "Search Tests"])
    try await raw(["config", "user.email", "search@example.invalid"]); try await raw(["config", "commit.gpgsign", "false"])
    try await raw(["config", "core.hooksPath", root.appendingPathComponent(".git/hooks").path])
    for path in ["源代码/你好 [literal]*?.swift", "-leading.swift", ":(glob)evil.txt", "line\nbreak.txt", "normal.txt"] {
      let url = root.appendingPathComponent(path); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try "fixture\n".write(to: url, atomically: true, encoding: .utf8)
    }
    try await raw(["add", "."]); try await raw(["commit", "-m", "Unicode 工作空间 search", "-m", "literal [query] body"])
  }
  override func tearDown() async throws { try? FileManager.default.removeItem(at: fixture) }
  @discardableResult func raw(_ args: [String]) async throws -> CommandResult {
    let result = try await ProcessRunner().run(executable: "/usr/bin/git", arguments: args, directory: root,
      environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
    guard result.code == 0 else { throw GitPierError.command("fixture", result.code, result.errorText) }; return result
  }
  func testMetadataNamePathOrganizationBranchRemoteAndFavoritesWithoutQueries() async throws {
    var value = record!; value.group = "Engineering"; value.favorite = true
    var state = RepositoryStatus(); state.branch = "feature/search"
    var entry = WorkspaceEntry(record: value)
    entry.snapshot = WorkspaceSnapshot(record: value, status: state, gitDirectory: "g", commonDirectory: "g", remoteNames: ["upstream"]); entry.state = .fresh
    for query in ["fixture", "repository", "engineering", "FEATURE/SEARCH", "upstream"] {
      let hits = WorkspaceSearchService.metadata([entry], query: query); XCTAssertEqual(hits.map(\.repositoryID), [value.id])
    }
    XCTAssertTrue(WorkspaceFilter.favorites.matches(entry))
    let probe = SearchCounter(), service = WorkspaceSearchService(loader: { record, query, _, _, _ in try await probe.load(record, query: query) })
    let page = try await service.search(records: [value], query: "fixture", kinds: [.repository]); XCTAssertTrue(page.hits.isEmpty)
    let stats = await probe.stats(); XCTAssertEqual(stats.2, 0)
  }
  func testUnicodeTrackedPathAndLiteralMetacharacters() async throws {
    for (query, expected) in [("你好", "源代码/你好 [literal]*?.swift"), ("[literal]*?", "源代码/你好 [literal]*?.swift"),
                              ("源代码/", "源代码/你好 [literal]*?.swift"), ("-leading", "-leading.swift"),
                              (":(glob)", ":(glob)evil.txt"), ("line\nbreak", "line\nbreak.txt")] {
      let result = try await git.workspaceSearch(record: record, query: query, kinds: [.file])
      XCTAssertEqual(result.hits.map(\.value), [expected], query)
    }
    try "private\n".write(to: root.appendingPathComponent("untracked-secret.txt"), atomically: true, encoding: .utf8)
    let none = try await git.workspaceSearch(record: record, query: "untracked-secret", kinds: [.file]); XCTAssertTrue(none.hits.isEmpty)
  }
  func testCommitMessageBodyAndHashAndNoResults() async throws {
    let message = try await git.workspaceSearch(record: record, query: "工作空间", kinds: [.commit])
    XCTAssertEqual(message.hits.count, 1); XCTAssertEqual(message.hits[0].detail, "Unicode 工作空间 search")
    let body = try await git.workspaceSearch(record: record, query: "[query]", kinds: [.commit]); XCTAssertEqual(body.hits.count, 1)
    let head = try await git.status().head!
    let hash = try await git.workspaceSearch(record: record, query: String(head.prefix(9)), kinds: [.commit]); XCTAssertEqual(hash.hits.map(\.value), [head])
    let noMatches = try await git.workspaceSearch(record: record, query: "--all --not-an-option", kinds: [.file, .commit]); XCTAssertTrue(noMatches.hits.isEmpty)
  }
  func testNativeFileAndCommitPaginationStayBounded() async throws {
    for index in 0..<30 {
      try "\(index)\n".write(to: root.appendingPathComponent("page-\(index).txt"), atomically: true, encoding: .utf8)
      try await raw(["add", "."]); try await raw(["commit", "-m", "page message \(index)"])
    }
    let first = try await git.workspaceSearch(record: record, query: "page", kinds: [.file, .commit], size: 10)
    let second = try await git.workspaceSearch(record: record, query: "page", kinds: [.file, .commit], page: 1, size: 10)
    let third = try await git.workspaceSearch(record: record, query: "page", kinds: [.file, .commit], page: 2, size: 10)
    XCTAssertEqual(first.hits.count, 20); XCTAssertEqual(second.hits.count, 20); XCTAssertTrue(first.hasMore); XCTAssertFalse(third.hasMore)
    XCTAssertTrue(Set(first.hits.map(\.id)).isDisjoint(with: second.hits.map(\.id)))
  }
  func testScopeFailureAndCrossRepositoryIsolation() async throws {
    let missing = RepositoryRecord(path: fixture.appendingPathComponent("missing").path)
    let service = WorkspaceSearchService()
    let result = try await service.search(records: [record, missing], query: "normal", kinds: [.file])
    XCTAssertEqual(result.hits.map(\.repositoryID), [record.id]); XCTAssertNotNil(result.errors[missing.id])
    let empty = try await service.search(records: [], query: "normal", kinds: [.file]); XCTAssertTrue(empty.hits.isEmpty)
    let onlyMissing = try await service.search(records: [missing], query: "normal", kinds: [.file]); XCTAssertTrue(onlyMissing.hits.isEmpty)
  }
  func testLargeRepositoryListHasBoundedWorkersAndStableOrder() async throws {
    let probe = SearchCounter(), service = WorkspaceSearchService(loader: { record, query, _, _, _ in try await probe.load(record, query: query) })
    let records = (0..<100).map { RepositoryRecord(path: "/fixture/\($0)") }
    let page = try await service.search(records: records, query: "literal", kinds: [.file])
    XCTAssertEqual(page.hits.map(\.repositoryID), records.map(\.id))
    let stats = await probe.stats(); XCTAssertEqual(stats.2, 100); XCTAssertLessThanOrEqual(stats.1, 3)
  }
  func testCancellingSearchStopsRunningAndUnstartedQueries() async throws {
    let probe = SearchCounter(), service = WorkspaceSearchService(loader: { record, query, _, _, _ in try await probe.load(record, query: query) })
    let records = (0..<100).map { RepositoryRecord(path: "/fixture/\($0)") }
    let task = Task { try await service.search(records: records, query: "literal", kinds: [.file]) }
    try await Task.sleep(for: .milliseconds(10)); task.cancel()
    do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    let stats = await probe.stats(); XCTAssertEqual(stats.0, 0); XCTAssertLessThanOrEqual(stats.2, 3)
  }
  func testOversizedAndNULQueriesAreRejectedWithoutGit() async {
    let service = WorkspaceSearchService()
    for query in ["invalid\0query", String(repeating: "私", count: 200)] {
      do { _ = try await service.search(records: [record], query: query, kinds: [.commit]); XCTFail() }
      catch { XCTAssertTrue(error is GitPierError) }
    }
  }
  func testScopesFollowVisibleContextAndExcludeRemovedSelections() {
    var first = record!; first.group = "Engineering"
    var second = RepositoryRecord(path: "/operations"); second.group = "Operations"
    let records = [first, second]
    func scoped(_ scope: WorkspaceSearchScope, dashboard: Bool = false, organization: String? = "Engineering") -> [UUID] {
      scope.records(from: records, dashboard: dashboard, organization: organization, currentID: second.id, selected: [first.id, UUID()]).map(\.id)
    }
    XCTAssertEqual(scoped(.all), [first.id, second.id]); XCTAssertEqual(scoped(.current), [second.id])
    XCTAssertEqual(scoped(.selected), [first.id]); XCTAssertEqual(scoped(.organization), [second.id])
    XCTAssertEqual(scoped(.organization, dashboard: true), [first.id])
    XCTAssertTrue(scoped(.organization, dashboard: true, organization: nil).isEmpty)
  }
}
