import AppKit
import Darwin
import GitPierCore
import SwiftUI

@MainActor enum PerformanceAcceptance {
  static var enabled: Bool { CommandLine.arguments.contains("--performance-acceptance") }
  struct Summary: Codable {
    let samples: Int
    let medianMS: Double
    let p95MS: Double
    let maxMS: Double
  }
  static var results: [String: Summary] = [:]
  static var allSamples: [String: [Double]] = [:]
  static var counters: [String: Int] = [:]
  static var phase = "initial"
  static var components: [String: [Double]] = [:]
  static func component(_ name: String, start: ContinuousClock.Instant) {
    guard enabled else { return }
    components[name, default: []].append(ms(start))
  }
  static func ms(_ start: ContinuousClock.Instant) -> Double {
    let parts = start.duration(to: .now).components
    return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
  }
  static func record(_ name: String, _ values: [Double]) {
    allSamples[name, default: []].append(contentsOf: values)
    let sorted = allSamples[name, default: []].sorted()
    guard !sorted.isEmpty else { return }
    results[name] = Summary(
      samples: sorted.count, medianMS: sorted[sorted.count / 2],
      p95MS: sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], maxMS: sorted.last!)
    print(
      "\(name): median \(String(format: "%.2f", sorted[sorted.count / 2])) ms; max \(String(format: "%.2f", sorted.last!)) ms"
    )
  }
  static func measure(_ name: String, samples: Int = 1, _ body: () async throws -> Void)
    async throws
  {
    phase = name
    var times: [Double] = []
    for _ in 0..<samples {
      let start = ContinuousClock.now
      try await body()
      times.append(ms(start))
    }
    record(name, times)
  }
  static func wait(_ condition: () -> Bool, timeout: Double = 30) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() > deadline { throw GitPierError.invalidInput("Performance fixture timed out") }
      try await Task.sleep(for: .milliseconds(1))
    }
  }
  static func views<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
    UIAcceptance.descendants(root).compactMap { $0 as? T }
  }
  static func run() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    Task {
      let store = AppStore.shared
      var window: NSWindow?
      do {
        let args = CommandLine.arguments
        guard let rootIndex = args.firstIndex(of: "--repository"),
          let outputIndex = args.firstIndex(of: "--output"),
          args.count > max(rootIndex, outputIndex) + 1,
          ProcessInfo.processInfo.environment["GITPIER_WORKSPACE_FILE"] != nil
        else {
          throw GitPierError.invalidInput("Performance acceptance requires an isolated fixture")
        }
        let root = URL(fileURLWithPath: args[rootIndex + 1])
        let fixtureBase = root.deletingLastPathComponent().resolvingSymlinksInPath()
        let temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        guard fixtureBase.lastPathComponent.hasPrefix("GitPier-performance."),
          fixtureBase.path.hasPrefix(temporaryRoot.path + "/"),
          let marker = try? Data(
            contentsOf: fixtureBase.appendingPathComponent("performance-fixture.json")),
          let object = try? JSONSerialization.jsonObject(with: marker) as? [String: String],
          object["kind"] == "GitPier disposable performance fixture"
        else {
          throw GitPierError.invalidInput(
            "Performance writes are restricted to the generated temporary fixture")
        }
        let output = URL(fileURLWithPath: args[outputIndex + 1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var settings = store.settings
        settings.appearance = .dark
        settings.terminalFont = "Menlo"
        settings.automaticRefresh = false
        settings.loginShell = false
        store.updateSettings(settings)
        let openStart = ContinuousClock.now
        await store.addRepository(root)
        guard let model = store.current else {
          throw GitPierError.invalidInput("Missing fixture repository")
        }
        await model.activate()
        guard model.available else {
          throw GitPierError.invalidInput(model.error ?? "Fixture unavailable")
        }
        record("repository.open.backend", [ms(openStart)])
        let host = NSHostingView(
          rootView: RootView().environmentObject(store).modifier(AppAppearance(store: store)))
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        host.autoresizingMask = [.width, .height]
        let nativeWindow = NSWindow(
          contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered,
          defer: false)
        window = nativeWindow
        nativeWindow.title = "GitPier Performance Fixture"
        nativeWindow.contentView = host
        nativeWindow.setFrameOrigin(NSPoint(x: -2400, y: -2400))
        nativeWindow.orderFront(nil)
        let heartbeat = MainLoopProbe()
        heartbeat.start()
        try await wait { views(host, FileMouseDownView.self).count >= 6 }
        record("repository.open.native-ready", [ms(openStart)])
        let git = await model.git()
        try await measure("git.head.process", samples: 20) {
          _ = try await git.read(["rev-parse", "HEAD"])
        }
        try await measure("git.identity", samples: 5) { _ = try await git.identity() }
        try await measure("repository.refresh", samples: 5) { await model.refresh() }
        try await wait { !model.diffLoading }
        counters["nativeFileRowsBeforeClicks"] = views(host, FileMouseDownView.self).count
        let files = Array(model.filteredFiles.prefix(12))
        // Warm exactly the files tested below, without relying on background warm-up timing.
        for file in files {
          model.select(file)
          try await wait { !model.diffLoading }
        }
        var eventTimes: [Double] = []
        var renderTimes: [Double] = []
        var clickTimes: [Double] = []
        phase = "diff.cached-click.native-update"
        let reads = model.diffReadCount
        let misses = model.foregroundDiffMissCount
        for _ in 0..<3 {
          for file in files {
            guard
              let hit = views(host, FileMouseDownView.self).first(where: { $0.path == file.path })
            else {
              throw GitPierError.invalidInput("Visible performance file missing: " + file.path)
            }
            let point = hit.convert(NSPoint(x: hit.bounds.midX, y: hit.bounds.midY), to: nil)
            let start = ContinuousClock.now
            let event = NSEvent.mouseEvent(
              with: .leftMouseDown, location: point, modifierFlags: [],
              timestamp: ProcessInfo.processInfo.systemUptime,
              windowNumber: nativeWindow.windowNumber,
              context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            NSApp.postEvent(event, atStart: false)
            try await wait {
              hit.selected && model.selectedPath == file.path
                && !model.diffLoading
                && views(host, DiffSplitContainer.self).first?.renderedPath == file.path
            }
            components["click-before-forced-draw", default: []].append(ms(start))
            let draw = ContinuousClock.now
            host.displayIfNeeded()
            component("forced-draw", start: draw)
            let total = ms(start)
            clickTimes.append(total)
            eventTimes.append(hit.lastDispatchDuration * 1000)
            renderTimes.append(max(0, total - hit.lastDispatchDuration * 1000))
            let up = NSEvent.mouseEvent(
              with: .leftMouseUp, location: point, modifierFlags: [],
              timestamp: ProcessInfo.processInfo.systemUptime,
              windowNumber: nativeWindow.windowNumber,
              context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
            NSApp.postEvent(up, atStart: false)
          }
        }
        counters["nativeFileRowsAfterClicks"] = views(host, FileMouseDownView.self).count
        record("diff.cached-click.native-update", clickTimes)
        record("diff.cached-click.event-dispatch", eventTimes)
        record("diff.cached-click.after-dispatch-render", renderTimes)
        counters["diffReadsDuringClicksIncludingPrefetch"] = model.diffReadCount - reads
        counters["foregroundMissesDuringWarmClicks"] = model.foregroundDiffMissCount - misses
        try await measure("selection.toggle-1000", samples: 20) {
          model.toggleIncluded(model.status.files)
        }
        try await measure("files.filter-sort", samples: 50) { _ = model.filteredFiles }
        for query in ["file_00", "file_01", "file_04", "file_000"] {
          try await measure("files.search.native-update", samples: 4) {
            model.query = query
            try await Task.sleep(for: .milliseconds(1))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
          }
        }
        model.query = ""
        if let long = model.status.files.first(where: { $0.path == "large.swift" }) {
          try await measure("diff.large.cold-to-native") {
            model.select(long)
            try await wait {
              !model.diffLoading
                && views(host, DiffSplitContainer.self).first?.renderedPath == long.path
            }
            host.displayIfNeeded()
          }
        }
        var dragTimes: [Double] = []
        phase = "panels.resize.native-update"
        for i in 0..<40 {
          let start = ContinuousClock.now
          var layout = model.panels.layout
          layout.changesWidth = 280 + Double(i % 12) * 10
          model.editLayout(layout, persist: false)
          try await Task.sleep(for: .milliseconds(1))
          host.layoutSubtreeIfNeeded()
          host.displayIfNeeded()
          dragTimes.append(ms(start))
        }
        record("panels.resize.native-update", dragTimes)
        model.persistLayout()
        try await measure("history.load-100") { await model.loadHistory(reset: true) }
        for _ in 0..<9 { await model.loadHistory() }
        let historyStart = ContinuousClock.now
        phase = "history.1000.native-update"
        model.setPage("history")
        try await wait { views(host, PerformancePageView.self).contains { $0.page == "history" } }
        host.displayIfNeeded()
        record("history.1000.native-update", [ms(historyStart)])
        try await Task.sleep(for: .milliseconds(100))
        try await measure("page.switch.native-update", samples: 3) {
          for page in ["commit", "branches", "remotes", "stash", "tags", "repository", "history"] {
            model.setPage(page)
            try await wait { views(host, PerformancePageView.self).contains { $0.page == page } }
            host.displayIfNeeded()
          }
        }
        model.setPage("commit")
        for repo in 1...8 {
          await store.addRepository(
            root.deletingLastPathComponent().appendingPathComponent("repo_\(repo)"))
          await store.current?.activate()
        }
        await store.addRepository(root.deletingLastPathComponent().appendingPathComponent("linked"))
        await store.current?.activate()
        let ids = store.repositories.map(\.id)
        try await measure("repositories.switch-native-10", samples: 3) {
          for id in ids {
            store.select(id)
            try await wait {
              views(host, PerformancePageView.self).contains { $0.repositoryID == id }
            }
            host.displayIfNeeded()
          }
        }
        // Include all eight system settings tabs, plus organization and credentials views.
        let settingsHost = NSHostingView(rootView: AnyView(EmptyView()))
        settingsHost.frame = NSRect(x: 0, y: 0, width: 760, height: 580)
        let settingsWindow = NSWindow(
          contentRect: settingsHost.frame, styleMask: [.titled], backing: .buffered, defer: false)
        settingsWindow.contentView = settingsHost
        settingsWindow.setFrameOrigin(NSPoint(x: -2400, y: -2400))
        settingsWindow.orderFront(nil)
        for tab in 0...7 {
          try await measure("settings.tab-\(tab).native-update") {
            settingsHost.rootView = AnyView(
              SettingsView(initialTab: tab).id(tab).environmentObject(store)
                .modifier(AppAppearance(store: store)).background(
                  PerformancePageProbe(page: "settings-\(tab)", repositoryID: model.record.id)))
            try await wait {
              views(settingsHost, PerformancePageView.self).contains {
                $0.page == "settings-\(tab)"
              }
            }
            settingsHost.displayIfNeeded()
          }
        }
        settingsWindow.close()
        store.showDashboard = true
        try await measure("dashboard.native-update") {
          try await Task.sleep(for: .milliseconds(10))
          host.layoutSubtreeIfNeeded()
          host.displayIfNeeded()
        }
        store.select(model.record.id)
        try await wait {
          views(host, PerformancePageView.self).contains { $0.repositoryID == model.record.id }
        }
        let first = model.status.files.first { $0.path == "Sources/file_00000.swift" }!
        model.toggleIncluded(model.status.files.filter { model.includedPaths.contains($0.path) })
        model.toggleIncluded([first])
        model.editDraft("perf: selected fixture commit")
        try await measure("commit.selected-plus-refresh") {
          model.commit(push: false)
          try await wait { !model.busy }
          if let error = model.error { throw GitPierError.invalidInput(error) }
        }
        for operation in ["push", "fetch", "pull"] {
          try await measure("network.local-\(operation)-plus-refresh") {
            model.network(operation)
            try await wait { !model.busy }
            if let error = model.error { throw GitPierError.invalidInput(error) }
          }
        }
        var terminalLayout = model.panels.layout
        terminalLayout.terminalVisible = true
        model.editLayout(terminalLayout)
        model.terminal.add(settings: settings)
        guard let session = model.terminal.selected else {
          throw GitPierError.invalidInput("Missing PTY")
        }
        var terminalBytes = 0
        var ended = false
        var terminalTail = Data()
        session.view.acceptanceOutput = { chunk in
          terminalBytes += chunk.count
          terminalTail.append(chunk)
          terminalTail = Data(terminalTail.suffix(256))
          if String(decoding: terminalTail, as: UTF8.self).contains("\r\nGITPIER_FLOOD_DONE\r\n") {
            ended = true
          }
        }
        try await Task.sleep(for: .milliseconds(100))
        let floodStart = ContinuousClock.now
        phase = "terminal.100000-lines"
        session.view.send(
          txt:
            "python3 -c 'import sys; sys.stdout.write(\"0123456789abcdef0123456789abcdef\\n\" * 100000); print(\"GITPIER_FLOOD_DONE\")'\n"
        )
        try await wait({ ended }, timeout: 60)
        record("terminal.100000-lines", [ms(floodStart)])
        guard terminalBytes > 3_000_000, session.view.process.running else {
          throw GitPierError.invalidInput("PTY flood did not complete")
        }
        session.view.acceptanceOutput = nil
        heartbeat.stop()
        for (name, values) in components { record("component." + name, values) }
        for (command, samples) in Dictionary(grouping: ProcessTrace.take(), by: \.command) {
          record("process." + command + ".launch", samples.map(\.launchMS))
          record("process." + command + ".wait", samples.map(\.waitMS))
          record("process." + command + ".drain", samples.map(\.drainMS))
        }
        record("main-loop.excess-lag", heartbeat.samples)
        for (phase, values) in heartbeat.byPhase { record("main-loop." + phase, values) }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = [
          "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            ?? "development",
          "os": ProcessInfo.processInfo.operatingSystemVersionString,
          "processorCount": ProcessInfo.processInfo.processorCount,
          "fixture": [
            "trackedFiles": 10001, "changedFiles": 1001, "historyCommits": 1000, "repositories": 10,
            "terminalLines": 100000,
          ],
          "counters": counters,
          "peakRSSMiB": Double(usage.ru_maxrss) / 1024 / 1024,
          "metrics": try JSONSerialization.jsonObject(with: JSONEncoder().encode(results)),
        ]
        let data = try JSONSerialization.data(
          withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("performance.json"), options: .atomic)
        try UIAcceptance.capture(
          host, to: output.appendingPathComponent("performance-terminal.png"))
        store.shutdown()
        nativeWindow.close()
        print("Performance acceptance completed: \(output.path)")
        exit(0)
      } catch {
        store.shutdown()
        window?.close()
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
      }
    }
    NSApp.run()
  }
}

@MainActor final class MainLoopProbe {
  var samples: [Double] = []
  var byPhase: [String: [Double]] = [:]
  var task: Task<Void, Never>?
  func start() {
    task = Task { [weak self] in
      while !Task.isCancelled {
        let start = ContinuousClock.now
        do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
        let lag = max(0, PerformanceAcceptance.ms(start) - 10)
        self?.samples.append(lag)
        self?.byPhase[PerformanceAcceptance.phase, default: []].append(lag)
      }
    }
  }
  func stop() {
    task?.cancel()
    task = nil
  }
}

struct PerformancePageProbe: NSViewRepresentable {
  let page: String
  let repositoryID: UUID
  func makeNSView(context: Context) -> PerformancePageView { PerformancePageView() }
  func updateNSView(_ view: PerformancePageView, context: Context) {
    view.page = page
    view.repositoryID = repositoryID
  }
}
final class PerformancePageView: NSView {
  var page = ""
  var repositoryID: UUID?
}
