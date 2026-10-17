import AppKit
import GitPierCore
import SwiftUI

/// Synthetic HTTP only; reached from the disposable, explicit native UI acceptance entry point.
private actor HostingDetailAcceptanceTransport: HostingTransport {
  let sha = String(repeating: "a", count: 40)
  let giteaPreview: Bool
  var paths: [String] = []
  var overviewHeld = false
  var overviewWaiters: [CheckedContinuation<Void, Never>] = []
  var cancelledCommits = 0
  var previewAttempts = 0
  var previewWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
  var releasedPreviews: Set<Int> = []
  var completedPreviews: Set<Int> = []
  var cancelledPreviews: Set<Int> = []
  var overviewRequests = 0
  init(giteaPreview: Bool = false) { self.giteaPreview = giteaPreview }
  func holdOverview() { overviewHeld = true }
  func releaseOverview() { overviewHeld = false; let values = overviewWaiters; overviewWaiters = []; values.forEach { $0.resume() } }
  func captured() -> [String] { paths }
  func cancellations() -> Int { cancelledCommits }
  func previewState() -> (attempts: Int, completed: Set<Int>, cancelled: Set<Int>) { (previewAttempts, completedPreviews, cancelledPreviews) }
  func cancelPreview(_ attempt: Int) { cancelledPreviews.insert(attempt) }
  func releasePreview(_ attempt: Int) { releasedPreviews.insert(attempt); previewWaiters.removeValue(forKey: attempt)?.resume() }
  func releaseAllPreviews() { let values = previewWaiters; previewWaiters = [:]; values.values.forEach { $0.resume() } }
  func send(_ request: URLRequest, limit: Int) async throws -> HostingHTTPResponse {
    let path = request.url!.path; paths.append(path)
    func response(_ object: Any, status: Int = 200, headers: [String: String] = [:]) throws -> HostingHTTPResponse {
      HostingHTTPResponse(data: try JSONSerialization.data(withJSONObject: object), status: status, headers: headers)
    }
    if path.hasSuffix("/example/fixture") { return try response(["id": 100, "private": false]) }
    if path.hasSuffix("/version") { return try response(["version": "1.27.3"]) }
    if giteaPreview {
      if path.hasSuffix(".diff") {
        previewAttempts += 1; let attempt = previewAttempts
        // Intentionally ignore cancellation until explicitly released, like a late transport callback.
        await withTaskCancellationHandler {
          await withCheckedContinuation { continuation in
            if releasedPreviews.contains(attempt) { continuation.resume() } else { previewWaiters[attempt] = continuation }
          }
        } onCancel: { Task { await self.cancelPreview(attempt) } }
        completedPreviews.insert(attempt)
        if attempt == 1 { return try response([:], status: 403) }
        let patch = "diff --git a/Sources/Preview.swift b/Sources/Preview.swift\n--- a/Sources/Preview.swift\n+++ b/Sources/Preview.swift\n@@ -1 +1 @@\n-old preview\n+current preview\n"
        return HostingHTTPResponse(data: Data(patch.utf8))
      }
      if path.hasSuffix("/files") { return try response([["filename": "Sources/Preview.swift", "status": "modified"]]) }
      if path.hasSuffix("/status") { return try response(["sha": sha, "total_count": 0, "statuses": NSNull()]) }
      return try response(["id": 200, "number": 17, "title": "Gitea cancelled preview fixture", "body": "Late preview errors must not replace the current attempt.", "state": "open", "updated_at": "gitea-preview-revision", "head": ["sha": sha, "ref": "topic"], "base": ["ref": "main", "sha": sha, "repo": ["id": 100]], "user": ["id": 99, "login": "fixture"]])
    }
    if path.hasSuffix("/commits") {
      do { try await Task.sleep(for: .seconds(60)) } catch { cancelledCommits += 1; throw CancellationError() }
      return try response([])
    }
    if path.hasSuffix("/reviews") || path.hasSuffix("/check-runs") { return try response([:], status: path.hasSuffix("/reviews") ? 404 : 403) }
    if path.hasSuffix("/comments") { return try response([["id": 1, "body": "Conversation survives unsupported reviews", "user": ["id": 42, "login": "fixture"]]]) }
    if path.hasSuffix("/files") {
      let rows = (0..<50).map { ["filename": "Sources/File\($0).swift", "status": "modified", "patch": "@@ -1 +1 @@\n-old\n+new"] }
      return try response(rows, headers: ["link": "<https://ignored.example.invalid>; rel=\"next\""])
    }
    if path.hasSuffix("/status") { return try response(["sha": sha, "statuses": []]) }
    overviewRequests += 1
    if overviewHeld && overviewRequests == 2 { await withCheckedContinuation { overviewWaiters.append($0) } }
    return try response(["id": 200, "number": 17, "title": "Hosting stability fixture", "body": "Overview remains usable during slow module requests.", "state": "open", "updated_at": "fixture-revision", "head": ["sha": sha, "ref": "topic"], "base": ["ref": "main", "sha": sha, "repo": ["id": 100]], "user": ["id": 99, "login": "fixture"]])
  }
}

extension UIAcceptance {
  static func verifyHostingDetailStability(root: URL, output: URL) async throws {
    guard root.resolvingSymlinksInPath().deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui.") else { throw HostingError.invalidInstance }
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-detail-ui-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let persistence = ConfigurationStore(url: fixture.appendingPathComponent("workspace.json"))
    var configuration = WorkspaceConfiguration(); configuration.settings.language = .english
    try persistence.save(configuration)
    let store = AppStore(persistence: persistence), transport = HostingDetailAcceptanceTransport(), vault = HostingAcceptanceVault()
    defer { store.shutdown() }
    let account = HostingAccount(instance: try HostingInstance(provider: .github, url: "https://github.com"), user: HostingUser(stableID: "42", login: "fixture"), kind: .pat, scopes: [], storageMode: .keychain)
    let binding = try RepositoryHostingBinding(repositoryID: UUID(), accountID: account.id, remote: "origin", repository: "example/fixture")
    var metadata = HostingMetadata(); metadata.accounts = [account]; metadata.bindings = [binding]
    try HostingMetadataStore(url: persistence.url.deletingPathExtension().appendingPathExtension("hosting.json")).save(metadata)
    let token = HostingToken(accessToken: "synthetic-detail-only")
    try await vault.save(token, account: account)
    let http = HostingHTTPClient(transport: transport)
    let hosting = HostingModel(store: store, http: http, vault: vault, openExternalURL: { _ in false }); store.hosting = hosting
    try await hosting.tokens.unlock(account)
    let item = try await hosting.api.request(binding, number: 17, account: account, token: token)
    await transport.holdOverview()
    var host = NSHostingView(rootView: HostingRequestDetail(hosting: hosting, binding: binding, account: account, request: item).environmentObject(store))
    host.sizingOptions = []; host.autoresizingMask = [.width, .height]
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.title = "GitPier 1.5.1 · Lazy Hosting Detail (Synthetic HTTP)"; window.contentView = host
    NSApp.setActivationPolicy(.regular); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    defer { window.close() }
    func capture(_ name: String) async throws {
      let url = output.appendingPathComponent("hosting-detail-" + name + ".png")
      _ = try await ProcessRunner().run(executable: "/usr/sbin/screencapture", arguments: ["-x", "-o", "-l", String(window.windowNumber), url.path], directory: nil, timeout: 15)
      guard FileManager.default.fileExists(atPath: url.path) else { throw GitPierError.invalidInput("Detail screenshot missing") }
    }
    func choose(_ tab: Int) async throws {
      guard let picker = descendants(host).compactMap({ $0 as? NSSegmentedControl }).first(where: { $0.segmentCount == 5 }) else {
        throw GitPierError.invalidInput("Native hosting detail segmented control missing")
      }
      picker.selectedSegment = tab
      guard picker.sendAction(picker.action, to: picker.target) else { throw GitPierError.invalidInput("Native detail tab action failed") }
      try await Task.sleep(for: .milliseconds(150))
    }
    func awaitPath(_ suffix: String, count: Int = 1) async throws {
      let deadline = Date().addingTimeInterval(5)
      while await transport.captured().filter({ $0.hasSuffix(suffix) }).count < count {
        guard Date() < deadline else { throw GitPierError.invalidInput("Lazy module did not request " + suffix) }
        try await Task.sleep(for: .milliseconds(20))
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    try await settle()
    let initial = await transport.captured()
    guard initial.count == 2, initial.allSatisfy({ $0.hasSuffix("/pulls/17") }), detailVisibleText(host).contains(where: { $0.contains("Overview remains usable") }) else {
      throw GitPierError.invalidInput("Overview blocked or unselected modules requested data")
    }
    try await capture("overview-slow-refresh")
    try await choose(1); try await awaitPath("/commits")
    try await choose(0)
    guard detailVisibleText(host).contains(where: { $0.contains("Overview remains usable") }) else { throw GitPierError.invalidInput("Slow commits blocked overview") }
    try await choose(2); try await awaitPath("/files")
    guard await transport.captured().filter({ $0.hasSuffix("/files") }).count == 1 else { throw GitPierError.invalidInput("Large PR eagerly paginated") }
    try await capture("files-first-page")
    try await choose(3); try await awaitPath("/reviews"); try await awaitPath("/comments", count: 2)
    guard detailVisibleText(host).contains(where: { $0.contains("Conversation survives") }) else { throw GitPierError.invalidInput("Unsupported review API hid comments") }
    try await capture("reviews-isolated-error")
    try await choose(4); try await awaitPath("/status"); try await awaitPath("/check-runs")
    guard !detailVisibleText(host).contains("No Checks") else { throw GitPierError.invalidInput("Incomplete CI became No Checks") }
    let ciText = detailVisibleText(host)
    guard ciText.contains(where: { $0.contains("Permission") || $0.contains("permission") }), !ciText.contains("No Checks") else { throw GitPierError.invalidInput("CI 403 did not remain a permission error") }
    try await capture("ci-permission-error")
    try await choose(2); try await choose(0); await transport.releaseOverview(); try await settle()
    guard await transport.cancellations() >= 1 else { throw GitPierError.invalidInput("Tab switch did not cancel slow HTTP") }
    guard await transport.captured().filter({ $0.hasSuffix("/files") }).count == 1 else { throw GitPierError.invalidInput("Cached tab was loaded again") }
    try await capture("overview-after-tabs")

    let previewRoot = fixture.appendingPathComponent("gitea-preview")
    try FileManager.default.createDirectory(at: previewRoot, withIntermediateDirectories: true)
    let previewPersistence = ConfigurationStore(url: previewRoot.appendingPathComponent("workspace.json"))
    try previewPersistence.save(configuration)
    let previewStore = AppStore(persistence: previewPersistence), previewTransport = HostingDetailAcceptanceTransport(giteaPreview: true), previewVault = HostingAcceptanceVault()
    defer { previewStore.shutdown(); Task { await previewTransport.releaseAllPreviews() } }
    let previewAccount = HostingAccount(instance: try HostingInstance(provider: .gitea, url: "https://gitea.detail.example.invalid"), user: HostingUser(stableID: "43", login: "fixture"), kind: .pat, scopes: [], storageMode: .keychain)
    let previewBinding = try RepositoryHostingBinding(repositoryID: UUID(), accountID: previewAccount.id, remote: "origin", repository: "example/fixture")
    var previewMetadata = HostingMetadata(); previewMetadata.accounts = [previewAccount]; previewMetadata.bindings = [previewBinding]
    try HostingMetadataStore(url: previewPersistence.url.deletingPathExtension().appendingPathExtension("hosting.json")).save(previewMetadata)
    try await previewVault.save(token, account: previewAccount)
    let previewHosting = HostingModel(store: previewStore, http: HostingHTTPClient(transport: previewTransport), vault: previewVault, openExternalURL: { _ in false }); previewStore.hosting = previewHosting
    try await previewHosting.tokens.unlock(previewAccount)
    let previewItem = try await previewHosting.api.request(previewBinding, number: 17, account: previewAccount, token: token)
    host = NSHostingView(rootView: HostingRequestDetail(hosting: previewHosting, binding: previewBinding, account: previewAccount, request: previewItem, initialTab: 2).environmentObject(previewStore))
    host.sizingOptions = []; host.autoresizingMask = [.width, .height]
    window.title = "GitPier 1.5.1 · Cancelled Gitea Preview (Synthetic HTTP)"; window.contentView = host
    func awaitPreview(_ predicate: ((attempts: Int, completed: Set<Int>, cancelled: Set<Int>)) -> Bool) async throws {
      let deadline = Date().addingTimeInterval(5)
      while !predicate(await previewTransport.previewState()) {
        guard Date() < deadline else { throw GitPierError.invalidInput("Gitea preview fixture did not reach its expected transport gate") }
        try await Task.sleep(for: .milliseconds(20))
      }
      try await settle()
    }
    try await awaitPreview { $0.attempts == 1 }
    try await choose(4)
    try await awaitPreview { $0.cancelled.contains(1) }
    try await choose(2)
    try await awaitPreview { $0.attempts == 2 }
    await previewTransport.releasePreview(1)
    try await awaitPreview { $0.completed.contains(1) }
    let pendingText = detailVisibleText(host)
    guard pendingText.contains("Read-only Remote Diff"), !pendingText.contains("Preview Unavailable"), !pendingText.contains("Retry Preview"),
      !pendingText.contains(where: { $0.localizedCaseInsensitiveContains("permission") }),
      descendants(host).compactMap({ $0 as? DiffSplitContainer }).isEmpty else {
      throw GitPierError.invalidInput("Cancelled preview error or cleanup changed the replacement preview's loading state")
    }
    try await capture("gitea-preview-pending-after-old-error")
    await previewTransport.releasePreview(2)
    try await awaitPreview { $0.completed.contains(2) }
    guard let previewDiff = descendants(host).compactMap({ $0 as? DiffSplitContainer }).first,
      previewDiff.renderedPath == "Sources/Preview.swift", previewDiff.tables.allSatisfy({ $0.numberOfRows > 0 && $0.actionMenu?(0) == nil }),
      !detailVisibleText(host).contains("Retry Preview"), !detailVisibleText(host).contains(where: { $0.localizedCaseInsensitiveContains("permission") }),
      await previewTransport.previewState().attempts == 2 else { throw GitPierError.invalidInput("Replacement Gitea preview was lost or gained write actions") }
    try await capture("gitea-preview-recovered")
    try JSONSerialization.data(withJSONObject: ["syntheticHTTP": true, "realOAuth": false, "nativeSegmentedControlActions": true,
      "immediateOverviewDuringSlowRefresh": true, "slowCommitsCancelled": true, "largePRFirstPageOnly": true, "reviewFailureIsolated": true,
      "ci403NeverNoChecks": true, "ciFirstPageAutomaticAfterEmptyStatuses": true, "tabCacheReused": true, "remoteDiffReadOnly": true,
      "giteaCancelledPreviewLate403Ignored": true, "giteaReplacementPreviewLoadingPreserved": true, "giteaReplacementPreviewReadOnly": true, "screenshots": 7], options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("hosting-detail-stability-results.json"))
  }
  private static func detailVisibleText(_ host: NSView) -> [String] {
    var visited = Set<ObjectIdentifier>(), result: [String] = []
    func walk(_ object: Any, depth: Int = 0) {
      guard depth < 80, let value = object as? NSObject, visited.insert(ObjectIdentifier(value)).inserted else { return }
      func get(_ name: String) -> Any? { let selector = NSSelectorFromString(name); return value.responds(to: selector) ? value.perform(selector)?.takeUnretainedValue() : nil }
      for key in ["accessibilityValue", "accessibilityLabel", "accessibilityTitle"] { if let text = get(key) as? String { result.append(text) } }
      for child in get("accessibilityChildren") as? [Any] ?? [] { walk(child, depth: depth + 1) }
      if let view = value as? NSView { for child in view.subviews { walk(child, depth: depth + 1) } }
    }
    walk(host); return result
  }
}
