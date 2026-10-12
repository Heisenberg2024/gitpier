import AppKit
import GitPierCore
import SwiftUI

extension UIAcceptance {
  static func verifyVersion110(store: AppStore, model: RepositoryModel, output: URL) async throws {
    for selector in [
      "updater:mayPerformUpdateCheck:error:", "updater:shouldProceedWithUpdate:updateCheck:error:",
      "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:", "updater:didAbortWithError:",
      "allowedChannelsForUpdater:", "allowedSystemProfileKeysForUpdater:",
      "standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:",
    ] {
      guard store.updates.responds(to: NSSelectorFromString(selector)) else {
        throw GitPierError.invalidInput("Sparkle lifecycle delegate is not registered: " + selector)
      }
    }
    guard !store.updates.configured, !store.updates.canCheck else {
      throw GitPierError.invalidInput("Unconfigured SwiftPM launch enabled production updating")
    }
    var query = HistoryQuery()
    query.message = "no-matches-" + UUID().uuidString
    model.historyQuery = query
    let stale = Task { await model.loadHistory(reset: true) }
    await Task.yield()
    model.historyQuery = nil
    let stateBeforeConfirmation = try await model.git().reviewOperation()
    let workingFile = URL(fileURLWithPath: model.record.path).appendingPathComponent(
      "Sources/workspace.swift")
    let workingBeforeConfirmation = try Data(contentsOf: workingFile)
    model.perform(["reset", "--hard", "HEAD"], confirmation: "Acceptance hard reset — cancel only")
    try await waitFor { model.confirmation != nil }
    guard model.confirmation?.destructive == true,
      model.confirmation?.detail.contains(String((stateBeforeConfirmation.head ?? "").prefix(8)))
        == true
    else {
      throw GitPierError.invalidInput("Destructive confirmation omitted the reviewed HEAD")
    }
    model.confirmation = nil
    guard try await model.git().reviewOperation() == stateBeforeConfirmation,
      try Data(contentsOf: workingFile) == workingBeforeConfirmation
    else {
      throw GitPierError.invalidInput("Cancelling a destructive confirmation modified Git")
    }
    model.setPage("remotes")
    await model.refresh()
    model.confirmForcePush(remote: "origin")
    try await waitFor { model.confirmation != nil }
    guard model.confirmation?.destructive == true,
      model.confirmation?.detail.contains("origin/main") == true
    else {
      throw GitPierError.invalidInput("Force with Lease omitted the reviewed destination")
    }
    model.confirmation = nil
    guard try await model.git().reviewOperation() == stateBeforeConfirmation else {
      throw GitPierError.invalidInput("Cancelling Force with Lease modified Git")
    }
    await model.loadHistory(reset: true)
    await stale.value
    guard !model.history.isEmpty, model.historyError == nil else {
      throw GitPierError.invalidInput("A stale history query replaced a newer result")
    }
    model.run { _ in try await Task.sleep(for: .milliseconds(120)) }
    guard store.hasRunningGitOperations else {
      throw GitPierError.invalidInput("Update gate missed active Git work")
    }
    let gate = UpdateManager(store: store)
    var installed = false
    guard gate.postponeInstallation({ installed = true }), !installed else {
      throw GitPierError.invalidInput("Update install handler ran during Git work")
    }
    gate.resumeInstallation()
    guard !installed else {
      throw GitPierError.invalidInput("Busy update resume invoked the installer")
    }
    try await waitFor { !model.busy }
    gate.resumeInstallation()
    guard installed else { throw GitPierError.invalidInput("Safe explicit update resume was lost") }
    let fixture = URL(fileURLWithPath: model.record.path).deletingLastPathComponent()
      .appendingPathComponent("stash-preview-v110")
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    let preview = RepositoryModel(record: RepositoryRecord(path: fixture.path), store: store)
    let git = await preview.git()
    try await git.perform(["init", "-b", "main"])
    try await git.perform(["config", "user.name", "GitPier Preview Acceptance"])
    try await git.perform(["config", "user.email", "preview@example.invalid"])
    try await git.perform(["config", "commit.gpgsign", "false"])
    let source = fixture.appendingPathComponent("preview.swift")
    try "let value = \"base\"\n".write(to: source, atomically: true, encoding: .utf8)
    try await git.stage(try await git.status().files)
    _ = try await git.commit(message: "seed preview", expected: git.snapshot())
    try "let value = \"first-preview\"\n".write(to: source, atomically: true, encoding: .utf8)
    try await git.perform(["stash", "push", "-m", "first"])
    let first = try await git.stashes()[0]
    try "let value = \"second-preview\"\n".write(to: source, atomically: true, encoding: .utf8)
    try await git.perform(["stash", "push", "-m", "second"])
    let second = try await git.stashes()[0]
    await preview.refresh()
    let stashHost = NSHostingView(
      rootView: AnyView(
        StashPreviewView(model: preview, stash: first).id(first.hash).environmentObject(store)))
    stashHost.frame = NSRect(x: 0, y: 0, width: 960, height: 340)
    let stashWindow = NSWindow(
      contentRect: stashHost.frame, styleMask: [.titled], backing: .buffered, defer: false)
    stashWindow.isReleasedWhenClosed = false
    stashWindow.contentView = stashHost
    stashWindow.setFrameOrigin(NSPoint(x: -2000, y: -2000))
    stashWindow.orderFront(nil)
    await Task.yield()
    stashHost.rootView = AnyView(
      StashPreviewView(model: preview, stash: second).id(second.hash).environmentObject(store))
    try await settle()
    try await waitFor {
      descendants(stashHost).compactMap { $0 as? NSTableView }
        .compactMap { $0.dataSource as? DiffTable.Coordinator }
        .contains {
          $0.document.raw.contains("second-preview") && !$0.document.raw.contains("first-preview")
        }
    }
    try capture(stashHost, to: output.appendingPathComponent("stash-latest-preview.png"))
    stashWindow.close()
    preview.shutdown()
    var all = HistoryQuery()
    all.scope = .allReferences
    let historyHost = NSHostingView(
      rootView: HistoryView(model: model, fullHistory: true, query: all)
        .environmentObject(store))
    historyHost.frame = NSRect(x: 0, y: 0, width: 960, height: 480)
    let historyWindow = NSWindow(
      contentRect: historyHost.frame, styleMask: [.titled], backing: .buffered, defer: false)
    historyWindow.isReleasedWhenClosed = false
    historyWindow.contentView = historyHost
    historyWindow.setFrameOrigin(NSPoint(x: -2000, y: -2000))
    historyWindow.orderFront(nil)
    try await settle()
    try await waitFor { !model.historyLoading }
    guard !model.history.isEmpty, model.historyError == nil else {
      throw GitPierError.invalidInput("Native full-history query did not render real results")
    }
    try capture(historyHost, to: output.appendingPathComponent("history-query-compact.png"))
    historyWindow.close()
    model.historyQuery = nil
    for language in AppLanguage.allCases {
      var settings = store.settings
      settings.language = language
      store.updateSettings(settings)
      for dark in [false, true] {
        let view = NSHostingView(
          rootView: SettingsView(initialTab: 7).environmentObject(store)
            .environment(\.colorScheme, dark ? .dark : .light))
        view.frame = NSRect(x: 0, y: 0, width: 760, height: 580)
        view.layoutSubtreeIfNeeded()
        try await settle()
        try capture(
          view,
          to: output.appendingPathComponent(
            "about-updates-\(language.rawValue)-\(dark ? "dark" : "light").png"))
      }
    }
    try
      "Sparkle delegate selectors, missing-key gate, active-Git gate, stale history response isolation and bilingual About update captures passed.\n"
      .write(
        to: output.appendingPathComponent("v110-acceptance.txt"), atomically: true, encoding: .utf8)
  }
}
