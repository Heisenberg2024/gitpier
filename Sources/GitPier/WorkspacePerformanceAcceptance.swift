import AppKit
import Darwin
import GitPierCore
import SwiftUI

extension UIAcceptance {
  static func verifyWorkspacePerformance(output: URL) async throws {
    guard ProcessTrace.enabled else { throw GitPierError.invalidInput("Workspace measurements require GITPIER_PERFORMANCE_TRACE=1") }
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-workspace-performance-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    NSApp.setActivationPolicy(.regular)
    let preparationWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 130), styleMask: [.titled], backing: .buffered, defer: false)
    preparationWindow.isReleasedWhenClosed = false; preparationWindow.title = "GitPier Performance Fixture"
    preparationWindow.contentView = NSHostingView(rootView: Text("Preparing disposable workspace repositories…").padding(24))
    preparationWindow.center(); preparationWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    defer { preparationWindow.close() }
    let seed = fixture.appendingPathComponent("seed"); try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
    let seedGit = GitService(root: seed)
    try await seedGit.perform(["init", "-b", "main"])
    // One controlled fast-import process creates 1,000 commits in this disposable seed.
    var stream = ""
    for index in 0..<1000 {
      let message = "workspace fixture commit \(index)\n", contents = "value \(index)\n"
      stream += "commit refs/heads/main\ncommitter Workspace Fixture <fixture@example.invalid> \(1_700_000_000 + index) +0000\ndata \(message.utf8.count)\n\(message)M 100644 inline tracked.txt\ndata \(contents.utf8.count)\n\(contents)\n"
    }
    try await seedGit.read(["fast-import", "--quiet"], input: Data(stream.utf8))
    try await seedGit.perform(["reset", "--hard", "HEAD"])
    let commits = try await seedGit.read(["rev-list", "--count", "HEAD"]).text.trimmingCharacters(in: .newlines)
    guard commits == "1000" else { throw GitPierError.invalidInput("Unexpected workspace fixture commit count") }
    var records: [RepositoryRecord] = []
    for index in 0..<100 {
      let path = fixture.appendingPathComponent("repository-\(index)")
      try await seedGit.perform(["clone", "--shared", "--quiet", "--", seed.path, path.path])
      var record = RepositoryRecord(path: path.path, name: "Fixture \(index)"); record.group = index.isMultiple(of: 2) ? "Even" : "Odd"
      records.append(record)
    }
    let manyFiles = URL(fileURLWithPath: records[0].path).appendingPathComponent("untracked")
    try FileManager.default.createDirectory(at: manyFiles, withIntermediateDirectories: true)
    for index in 0..<10000 { try Data("fixture\n".utf8).write(to: manyFiles.appendingPathComponent("file-\(index).txt")) }
    let mainGit = await GitServiceRegistry.shared.service(for: URL(fileURLWithPath: records[1].path))
    let linkedPath = fixture.appendingPathComponent("linked")
    _ = try await mainGit.createWorktree(destination: linkedPath, branch: "linked", newBranch: true)
    let linked = RepositoryRecord(path: linkedPath.path, name: "Linked Fixture")
    let missing = RepositoryRecord(path: fixture.appendingPathComponent("missing").path, name: "Missing Fixture")
    let invalidPath = fixture.appendingPathComponent("invalid"); try FileManager.default.createDirectory(at: invalidPath, withIntermediateDirectories: true)
    let invalid = RepositoryRecord(path: invalidPath.path, name: "Invalid Fixture")
    var reports: [[String: Any]] = []
    for count in [10, 50, 100] {
      // Exactly 10/50/100 physical repositories, plus a linked worktree and two unavailable entries.
      let selected = Array(records.prefix(count)) + [linked, missing, invalid]
      var config = WorkspaceConfiguration(); config.repositories = selected; config.settings.launchPage = "dashboard"; config.settings.appearance = .light
      let persistence = ConfigurationStore(url: fixture.appendingPathComponent("workspace-\(count).json")); try persistence.save(config)
      GitProcessActivity.reset()
      let heartbeat = MainLoopProbe(); heartbeat.start()
      let start = ContinuousClock.now
      let store = AppStore(persistence: persistence)
      let host = NSHostingView(rootView: RootView().environmentObject(store).modifier(AppAppearance(store: store)))
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = host; window.title = "GitPier Workspace Performance Fixture"
      window.center(); window.makeKeyAndOrderFront(nil)
      FileHandle.standardError.write(Data("Workspace performance \(count): native readiness\n".utf8))
      do { try await PerformanceAcceptance.wait({ accessibleButton(host, title: "Refresh Local Status", enabled: true) != nil }) }
      catch {
        try accessibilityLabels(host).write(to: output.appendingPathComponent("readiness-\(count).txt"), atomically: true, encoding: .utf8)
        throw GitPierError.invalidInput("Workspace performance \(count): native readiness timed out; labels saved.")
      }
      let ready = PerformanceAcceptance.ms(start)
      FileHandle.standardError.write(Data("Workspace performance \(count): local scan\n".utf8))
      try await PerformanceAcceptance.wait({ WorkspaceSummary(Array(store.workspace.entries.values)).scanned == selected.count }, timeout: 60)
      let scan = PerformanceAcceptance.ms(start)
      let activity = GitProcessActivity.snapshot()
      guard activity.peak <= 3, store.models.values.allSatisfy({ $0.refreshCount == 0 }), store.workspace.entries[records[0].id]?.snapshot?.untracked == 10000 else {
        throw GitPierError.invalidInput("Workspace scan exceeded its process budget or activated full sessions")
      }
      let refreshStart = ContinuousClock.now
      let refreshDate = Date()
      await store.workspace.refresh(selected.map(\.id))
      store.dashboardOrganization = "Even"
      host.layoutSubtreeIfNeeded(); await Task.yield()
      let switchMS = PerformanceAcceptance.ms(refreshStart)
      try await PerformanceAcceptance.wait({ store.workspace.entries.values.allSatisfy {
        $0.state == .failed || $0.state == .fresh && ($0.snapshot?.collectedAt ?? .distantPast) >= refreshDate
      } }, timeout: 60)
      let refreshMS = PerformanceAcceptance.ms(refreshStart)
      FileHandle.standardError.write(Data("Workspace performance \(count): failed Fetch\n".utf8))
      // An explicit failed transport is isolated; no startup request goes to a remote.
      try await mainGit.perform(["remote", "set-url", "origin", fixture.appendingPathComponent("missing-remote.git").path])
      let reviewed = try await mainGit.reviewWorkspaceFetch(records[1])
      let queue = BatchFetchCoordinator(executor: { try await mainGit.workspaceFetch($0) })
      let failedStart = ContinuousClock.now; await queue.submit(reviewed); await queue.waitUntilIdle()
      let failureMS = PerformanceAcceptance.ms(failedStart)
      let failedJobs = await queue.current(); guard failedJobs.allSatisfy({ $0.state == .failed }) else { throw GitPierError.invalidInput("Missing remote did not fail") }
      await queue.shutdown()
      try await mainGit.perform(["remote", "set-url", "origin", seed.path])
      heartbeat.stop()
      var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
      let sorted = heartbeat.samples.sorted()
      let summary = WorkspaceSummary(Array(store.workspace.entries.values))
      reports.append(["requestedPhysicalRepositories": count, "entries": selected.count, "available": count + 1, "unavailable": 2,
        "physicalRepositories": summary.physicalRepositories, "dashboardInteractiveMS": ready,
        "initialLocalScanMS": scan, "refreshMS": refreshMS, "organizationSwitchDuringRefreshMS": switchMS,
        "peakGitProcessLaunches": activity.peak, "initialGitLaunches": activity.launches,
        "failedFetchMS": failureMS, "failedFetchCount": failedJobs.count,
        "peakRSSMiB": Double(usage.ru_maxrss) / 1024 / 1024,
        "mainLoopP95ExcessMS": sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
        "mainLoopMaxExcessMS": sorted.last ?? 0, "fullRepositoryRefreshes": store.models.values.reduce(0) { $0 + $1.refreshCount }])
      store.shutdown(); window.close()
      // Flush cancelled operations before measuring the next independent startup.
      try await PerformanceAcceptance.wait({ GitProcessActivity.snapshot().active == 0 })
    }
    let report: [String: Any] = ["version": AppResources.version, "build": AppResources.build, "configuration": "Release when invoked with the packaged Release executable; otherwise Debug",
      "os": ProcessInfo.processInfo.operatingSystemVersionString, "cpuCount": ProcessInfo.processInfo.processorCount,
      "startupMeasurement": "Each case constructs a new AppStore with empty snapshot/session caches in a warmed native test process; excludes fixture creation and process launch.",
      "fixture": ["untrackedFiles": 10000, "commitsPerClone": 1000, "linkedWorktrees": 1],
      "processMeasurement": "Opt-in ProcessRunner lifetime counters include Git launch setup, stop on termination, and contain no arguments or paths.",
      "memoryMeasurement": "ru_maxrss is cumulative process high-water RSS, not per-case live allocation.", "cases": reports]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("workspace-performance.json"), options: .atomic)
  }
}
