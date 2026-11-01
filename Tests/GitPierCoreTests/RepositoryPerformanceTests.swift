import XCTest
@testable import GitPierCore

final class RepositoryPerformanceTests: XCTestCase {
  func testGraphMergeGeometryRemainsStable() {
    let parents = [["B", "C"], ["D"], ["D"], []]
    let records = zip(["A", "B", "C", "D"], parents).map { hash, parents in
      CommitRecord(hash: hash, parents: parents, author: "Fixture", email: "fixture@example.invalid", date: .distantPast, subject: hash, body: "", decorations: "")
    }
    let rows = CommitGraph.layout(records).map { row in
      "\(row.node):\(row.width):" + row.edges.map { "\($0.from)>\($0.to):\($0.color):\($0.startsAtNode):\($0.endsAtNode)" }.joined(separator: ",")
    }
    XCTAssertEqual(rows, [
      "0:2:0>0:0:false:true,0>0:0:true:false,0>1:1:true:false",
      "0:2:0>0:0:false:true,1>1:1:false:false,0>0:0:true:false",
      "1:2:0>0:0:false:false,1>1:1:false:true,1>0:0:true:false",
      "0:1:0>0:0:false:true"
    ])
  }
  func testLargeBranchInventoryAndPagedHistory() async throws {
    let fixture = CommitReplayTests(); try await fixture.setUp()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    GitProcessActivity.reset()
    _ = try await fixture.git.branchHealth(mergedInto: "refs/heads/main")
    let smallLaunches = GitProcessActivity.snapshot().launches
    let commands = (0..<1024).map { "create refs/heads/benchmark/\($0) \(fixture.base!)\n" }.joined()
    _ = try await fixture.git.read(["update-ref", "--stdin"], input: Data(commands.utf8))
    var samples: [Double] = []
    GitProcessActivity.reset()
    for _ in 0..<5 {
      let start = ContinuousClock.now
      let health = try await fixture.git.branchHealth(mergedInto: "refs/heads/main")
      let duration = start.duration(to: .now).components
      samples.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
      XCTAssertEqual(health.branches.count, 1026)
      XCTAssertEqual(health.branches.filter { $0.mergedIntoTarget == true }.count, 1025)
    }
    let largeLaunches = GitProcessActivity.snapshot().launches
    if ProcessTrace.enabled { XCTAssertEqual(largeLaunches, smallLaunches * 5) }
    print("BRANCH_HEALTH_BENCHMARK branches=1026 ms=\(samples) launches=\(largeLaunches) smallScanLaunches=\(smallLaunches)")
    let first = try await fixture.git.history(count: 1)
    let next = try await fixture.git.history(skip: 1, count: 1)
    XCTAssertEqual(first.count, 1); XCTAssertTrue(next.isEmpty)
  }
  func testGraphDeterministicWideHistory() {
    let lanes = 64, count = 8192
    let records = (0..<count).map { i in
      CommitRecord(hash: "c\(i)", parents: i + lanes < count ? ["c\(i + lanes)"] : [],
        author: "Fixture", email: "fixture@example.invalid", date: Date(timeIntervalSince1970: 0), subject: "Commit \(i)", body: "", decorations: "")
    }
    var samples: [Double] = []
    for _ in 0..<5 {
      let start = ContinuousClock.now
      let graph = CommitGraph.layout(records)
      let duration = start.duration(to: .now).components
      samples.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
      XCTAssertEqual(graph.count, count)
      XCTAssertEqual(graph[63].width, 64)
      XCTAssertEqual(graph.last?.width, 1)
    }
    print("GRAPH_BENCHMARK count=\(count) lanes=\(lanes) ms=\(samples)")
  }
}
