import Darwin
import XCTest

@testable import GitPierCore

private actor SchedulingProbe {
  private var order: [String] = []
  private var continuation: CheckedContinuation<Void, Never>?
  private var started: CheckedContinuation<Void, Never>?
  func load(_ record: RepositoryRecord) async -> WorkspaceSnapshot {
    order.append(record.name)
    if order.count == 1 {
      await withCheckedContinuation { continuation in
        self.continuation = continuation
        started?.resume(); started = nil
      }
    }
    var status = RepositoryStatus(); status.branch = record.name
    return WorkspaceSnapshot(record: record, status: status,
      gitDirectory: record.path + "/.git", commonDirectory: record.path + "/.git")
  }
  func waitUntilStarted() async {
    if continuation != nil { return }
    await withCheckedContinuation { started = $0 }
  }
  func release() { continuation?.resume(); continuation = nil }
  func names() -> [String] { order }
}

final class WorkspaceSchedulingTests: XCTestCase {
  func testPriorityPromotionKeepsFIFOWithinEachPriority() async {
    let probe = SchedulingProbe()
    let service = WorkspaceStatusService(concurrency: 1, loader: { await probe.load($0) })
    let records = (0..<6).map { RepositoryRecord(path: "/fixture/\($0)", name: "repo-\($0)") }
    await service.reconcile(records)
    await service.request(records.map(\.id))
    await probe.waitUntilStarted()
    await service.request([records[4].id, records[2].id], priority: .userInitiated)
    await service.request([records[5].id], priority: .visible)
    await probe.release()
    await service.waitUntilIdle()
    let names = await probe.names()
    XCTAssertEqual(names, ["repo-0", "repo-2", "repo-4", "repo-5", "repo-1", "repo-3"])
    await service.shutdown()
  }

  /// Opt-in measurements use a zero-I/O loader, so they measure queue overhead,
  /// not Git, disk or UI speed. No timing threshold is imposed on other machines.
  func testLargeInventorySchedulingCompletesWithoutLosingEntries() async throws {
    let output = ProcessInfo.processInfo.environment["GITPIER_QUALITY_BENCHMARK_OUTPUT"]
    let sizes = output == nil ? [300] : [1000, 3000]
    let repeats = output == nil ? 1 : 3
    var samples: [[String: Any]] = []
    for count in sizes {
      let records = (0..<count).map { RepositoryRecord(path: "/fixture/\($0)", name: "repo-\($0)") }
      for sample in 0..<repeats {
        let service = WorkspaceStatusService(loader: { record in
          var status = RepositoryStatus(); status.branch = record.name
          return WorkspaceSnapshot(record: record, status: status,
            gitDirectory: record.path + "/.git", commonDirectory: record.path + "/.git")
        })
        let start = ContinuousClock.now
        await service.reconcile(records)
        await service.request(records.map(\.id))
        await service.waitUntilIdle()
        let elapsed = start.duration(to: .now)
        let components = elapsed.components
        let milliseconds = Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
        let entries = await service.current()
        XCTAssertEqual(entries.count, count)
        XCTAssertEqual(entries.values.filter { $0.state == .fresh }.count, count)
        XCTAssertTrue(records.allSatisfy { entries[$0.id]?.snapshot?.branch == $0.name })
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        samples.append(["entries": count, "sample": sample, "schedulerMS": milliseconds,
          "processPeakRSSMiB": Double(usage.ru_maxrss) / 1024 / 1024, "gitLaunches": 0])
        await service.shutdown()
      }
    }
    if let output {
      let report: [String: Any] = ["method": "WorkspaceStatusService, concurrency 3, immediate synthetic loader, no Git or filesystem IO; three samples per size",
        "memory": "cumulative process high-water RSS, not live allocations or per-case delta",
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "cpuCount": ProcessInfo.processInfo.processorCount, "samples": samples]
      let url = URL(fileURLWithPath: output)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
      print("Scheduler measurements saved (\(samples.count) samples).")
    }
  }
}
