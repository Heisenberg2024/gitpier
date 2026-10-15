import XCTest
@testable import GitPierCore

final class WorkspaceListingTests: XCTestCase {
  private func entry(_ name: String, group: String = "Engineering", favorite: Bool = false,
                     modified: Bool = false, staged: Bool = false, common: String? = nil,
                     worktree: Bool = false, branch: String = "main") -> WorkspaceEntry {
    var record = RepositoryRecord(path: "/fixture/" + name, name: name)
    record.group = group; record.favorite = favorite
    var status = RepositoryStatus(); status.branch = branch; status.upstream = "origin/main"
    if modified { status.files = [FileChange(path: "file.txt", index: staged ? "M" : ".", worktree: "M", kind: .modified)] }
    var value = WorkspaceEntry(record: record); value.state = .fresh
    value.snapshot = WorkspaceSnapshot(record: record, status: status,
      gitDirectory: worktree ? "/fixture/common/worktrees/" + name : (common ?? record.path + "/.git"),
      commonDirectory: common ?? record.path + "/.git", remoteNames: ["origin"])
    return value
  }
  private func listing(_ entries: [WorkspaceEntry], search: String = "", filters: Set<WorkspaceFilter> = [],
                       organization: String? = nil, sort: String = "manual", collapsed: Set<String> = []) -> WorkspaceListing {
    WorkspaceListing(records: entries.map(\.record), entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.record.id, $0) }),
      organization: organization, search: search, filters: filters, sort: sort, collapsed: collapsed)
  }
  func testSearchAndFiltersIntersectWhileCountsStayOrganizationScoped() {
    let entries = [entry("api", favorite: true, modified: true, staged: true), entry("web", modified: true),
      entry("other-api", group: "Design", favorite: true, modified: true)]
    let result = listing(entries, search: "API", filters: [.modified, .favorites], organization: "Engineering")
    XCTAssertEqual(result.matchingIDs, [entries[0].record.id])
    XCTAssertEqual(result.summary.total, 2)
    XCTAssertEqual(result.summary.counts[.modified], 2)
    XCTAssertEqual(result.summary.counts[.staged], 1)
    XCTAssertEqual(result.summary.counts[.favorites], 1)
    XCTAssertTrue(listing(entries, search: "web", filters: [.staged]).matching.isEmpty)
    XCTAssertEqual(listing(entries, search: "origin").matching.count, 3)
    XCTAssertEqual(listing(entries, search: "/fixture/api").matching.count, 1)
  }
  func testCollapsedWorktreesKeepMatchingAndSelectionScope() {
    let entries = [entry("app", common: "/common"), entry("feature", modified: true, common: "/common", worktree: true),
      entry("release", common: "/common", worktree: true), entry("tools")]
    let result = listing(entries, collapsed: ["/common"])
    XCTAssertEqual(result.rows.map(\.id), [entries[0].record.id, entries[3].record.id])
    XCTAssertEqual(result.hiddenCount, 2)
    XCTAssertEqual(result.matchingIDs.count, 4)
    XCTAssertEqual(result.rows[0].relatedCount, 3)
    XCTAssertTrue(result.rows[0].canCollapse)
    // Filtering to one child must not hide that match just because its parent was collapsed.
    let filtered = listing(entries, filters: [.modified], collapsed: ["/common"])
    XCTAssertEqual(filtered.rows.map(\.id), [entries[1].record.id])
    XCTAssertFalse(filtered.rows[0].isChild)
    XCTAssertEqual(filtered.rows[0].relatedCount, 3)
  }
  func testStatusUpdatesPreserveManualIdentityAndSortingTies() {
    var entries = [entry("same"), entry("same"), entry("api")]
    let ids = listing(entries).rows.map(\.id)
    entries[1].state = .collecting; entries[2].state = .stale
    XCTAssertEqual(listing(entries).rows.map(\.id), ids)
    let named = listing(entries, sort: "name")
    XCTAssertEqual(named.rows.map(\.id), [ids[2], ids[0], ids[1]])
    XCTAssertEqual(named.scanning, 1)
    XCTAssertEqual(named.summary.fresh, 1)
  }
  func testFailedCachedSnapshotCannotAppearCleanOrMatchStatusFilter() {
    var unavailable = entry("broken", modified: true)
    unavailable.state = .failed; unavailable.failure = WorkspaceFailure(.gitQuery, "fixture failure")
    var unscanned = entry("new"); unscanned.state = .unscanned; unscanned.snapshot = nil
    let result = listing([unavailable, unscanned])
    XCTAssertEqual(result.summary.scanned, 1)
    XCTAssertEqual(result.summary.fresh, 0)
    XCTAssertEqual(result.summary.counts[.modified], 0)
    XCTAssertEqual(result.summary.counts[.unavailable], 1)
    XCTAssertNil(result.rows[0].entry.usable)
    XCTAssertTrue(listing([unavailable], filters: [.modified]).matching.isEmpty)
    XCTAssertEqual(listing([unavailable], filters: [.unavailable]).matchingIDs, [unavailable.record.id])
  }
  func testRapidFilterChangesHaveNoProjectionStateOrSelectionSideEffects() {
    let entries = [entry("api", favorite: true, modified: true), entry("web")]
    let selected = Set(entries.map { $0.record.id })
    for _ in 0..<20 {
      XCTAssertEqual(listing(entries, filters: [.modified, .favorites]).matching.count, 1)
      XCTAssertEqual(listing(entries, filters: [.conflicts]).matching.count, 0)
      XCTAssertEqual(listing(entries).matchingIDs, selected)
    }
    XCTAssertTrue(listing([], organization: "empty").rows.isEmpty)
  }
}
