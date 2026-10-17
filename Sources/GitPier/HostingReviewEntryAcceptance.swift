import AppKit
import GitPierCore
import SwiftUI

/// Dedicated account/entry fixtures. All API responses stay inside this actor; the
/// repository and its remote-tracking refs are disposable local test data.
private actor HostingReviewEntryTransport: HostingTransport {
  let head: String
  let base: String
  private var holdNextSearch = false
  private var gate: CheckedContinuation<Void, Never>?
  private var searches = 0
  private var targetReads: [Int: Int] = [:]
  private var writeAttempts = 0
  init(head: String, base: String) { self.head = head; self.base = base }
  func hold() { holdNextSearch = true }
  func held() -> Bool { gate != nil }
  func release() { gate?.resume(); gate = nil }
  func facts() -> (searches: Int, targetReads: [Int: Int], writes: Int) { (searches, targetReads, writeAttempts) }
  private func pull(_ number: Int) -> [String: Any] {
    ["id": 20000 + number, "number": number, "title": number == 17 ? "Exact inbox native target" : "Exact current-branch target",
     "body": "Synthetic entry fixture", "state": "open", "draft": false,
     "user": ["id": 99, "login": "entry-author"],
     "head": ["sha": head, "ref": number == 19 ? "feature/review" : "inbox-review", "repo": ["full_name": "example/entry"]],
     "base": ["sha": base, "ref": "main", "repo": ["id": 12]],
     "html_url": "https://github.com/example/entry/pull/\(number)", "created_at": "2026-10-18T00:00:00Z", "updated_at": "2026-10-18T01:00:00Z"]
  }
  func send(_ request: URLRequest, limit: Int) async throws -> HostingHTTPResponse {
    guard request.url?.host == "api.github.com", request.url?.scheme == "https",
      let auth = request.value(forHTTPHeaderField: "Authorization"), auth.contains("synthetic-entry-") else { throw HostingError.insecureURL }
    guard request.httpMethod == nil || request.httpMethod == "GET" else { writeAttempts += 1; throw HostingError.invalidResponse }
    func response(_ object: Any, status: Int = 200) throws -> HostingHTTPResponse {
      HostingHTTPResponse(data: try JSONSerialization.data(withJSONObject: object), status: status)
    }
    let path = request.url!.path
    if path == "/search/issues" {
      searches += 1
      let obsolete = holdNextSearch; holdNextSearch = false
      if obsolete { await withCheckedContinuation { gate = $0 } } // Deliberately ignores task cancellation.
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
      let login = auth.contains("synthetic-entry-b") ? "entry-b" : "entry-a"
      let title = obsolete ? "Obsolete cancelled inbox response" : query.contains("author:@me") ? "Current my-open snapshot " + login : "Current requested snapshot " + login
      let row: [String: Any] = ["id": 90017, "number": 17, "title": title, "state": "open",
        "user": ["id": login == "entry-a" ? 42 : 43, "login": login], "updated_at": "2026-10-18T01:00:00Z",
        "pull_request": ["url": "https://api.github.com/repos/example/entry/pulls/17"],
        "repository_url": "https://api.github.com/repos/example/entry", "html_url": "https://github.com/example/entry/pull/17"]
      return try response(["items": [row], "total_count": 1, "incomplete_results": false])
    }
    if path == "/repos/example/entry" { return try response(["id": 12, "private": false, "archived": false]) }
    if path == "/repos/example/entry/pulls" { return try response([pull(17), pull(19)]) }
    for number in [17, 19] where path == "/repos/example/entry/pulls/\(number)" {
      targetReads[number, default: 0] += 1; return try response(pull(number))
    }
    if path.hasSuffix("/reviews") || path.hasSuffix("/comments") || path.hasSuffix("/commits") { return try response([]) }
    return try response(["message": "unsupported synthetic entry route"], status: 404)
  }
}

extension UIAcceptance {
  static func verifyHostingReviewEntryPoints(root: URL, output: URL) async throws {
    guard ProcessInfo.processInfo.environment["GITPIER_REVIEW_MENU_INTERACTIVE"] == "1" else {
      throw GitPierError.invalidInput("Entry acceptance requires GITPIER_REVIEW_MENU_INTERACTIVE=1 for real GUI-assisted Picker selection")
    }
    guard root.resolvingSymlinksInPath().deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui.") else { throw HostingError.invalidInstance }
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-review-entry-" + UUID().uuidString)
    let repository = fixture.appendingPathComponent("repository"), destination = output.appendingPathComponent("review-entries")
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let git = GitService(root: repository)
    try await git.perform(["init", "-b", "main"])
    try await git.perform(["config", "user.name", "GitPier Entry Fixture"])
    try await git.perform(["config", "user.email", "entry@example.invalid"])
    try await git.perform(["config", "commit.gpgsign", "false"])
    let source = repository.appendingPathComponent("entry.swift")
    try "let value = \"base\"\n".write(to: source, atomically: true, encoding: .utf8)
    try await git.stage(try await git.status().files)
    _ = try await git.commit(message: "seed entry fixture", expected: git.snapshot())
    let base = String(decoding: try await git.read(["rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    try await git.perform(["update-ref", "refs/remotes/origin/main", base])
    try await git.createBranch("feature/review"); try await git.switchBranch("feature/review")
    try "let value = \"entry-only\"\n".write(to: source, atomically: true, encoding: .utf8)
    try await git.stage(try await git.status().files)
    _ = try await git.commit(message: "entry branch fixture", expected: git.snapshot())
    try await git.perform(["remote", "add", "origin", "https://github.com/example/entry.git"])
    let head = String(decoding: try await git.read(["rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let originalIndex = try await git.read(["ls-files", "--stage", "-z"]).stdout
    let originalStatus = try await git.read(["status", "--porcelain=v1", "-z"]).stdout
    let record = RepositoryRecord(path: repository.path), persistence = ConfigurationStore(url: fixture.appendingPathComponent("workspace.json"))
    var configuration = WorkspaceConfiguration(); configuration.repositories = [record]
    configuration.settings.language = .english; configuration.settings.appearance = .light
    configuration.settings.automaticFetch = false; configuration.settings.completionNotifications = false
    try persistence.save(configuration)
    let instance = try HostingInstance(provider: .github, url: "https://github.com")
    let accountA = HostingAccount(instance: instance, user: HostingUser(stableID: "42", login: "entry-a"), kind: .pat, scopes: ["public_repo"], storageMode: .keychain)
    let accountB = HostingAccount(instance: instance, user: HostingUser(stableID: "43", login: "entry-b"), kind: .pat, scopes: ["public_repo"], storageMode: .keychain)
    let binding = try RepositoryHostingBinding(repositoryID: record.id, accountID: accountA.id, remote: "origin", repository: "example/entry")
    var metadata = HostingMetadata(); metadata.accounts = [accountA, accountB]; metadata.bindings = [binding]
    try HostingMetadataStore(url: fixture.appendingPathComponent("workspace.hosting.json")).save(metadata)
    let vault = HostingAcceptanceVault(), transport = HostingReviewEntryTransport(head: head, base: base)
    try await vault.save(HostingToken(accessToken: "synthetic-entry-a", scopes: ["public_repo"]), account: accountA)
    try await vault.save(HostingToken(accessToken: "synthetic-entry-b", scopes: ["public_repo"]), account: accountB)
    let store = AppStore(persistence: persistence)
    defer { store.shutdown() }
    let hosting = HostingModel(store: store, http: HostingHTTPClient(transport: transport), vault: vault, openExternalURL: { _ in false }); store.hosting = hosting
    try await hosting.tokens.unlock(accountA); try await hosting.tokens.unlock(accountB)
    let model = try XCTHostingUnwrap(store.models[record.id]); store.selectedID = record.id; store.showDashboard = false
    await model.refresh(); model.setPage("hosting")
    var layout = model.panels.layout; layout.terminalVisible = false; model.editLayout(layout, persist: false)
    let host = NSHostingView(rootView: RepositoryWorkspace(model: model).environmentObject(store).modifier(AppAppearance(store: store)))
    host.sizingOptions = []; host.autoresizingMask = [.width, .height]
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1250, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.title = "GitPier Native Review Entry Acceptance"; window.contentView = host
    window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    defer { window.close() }
    var stage = "workspace-render"
    do {
    try await settle()
    stage = "open-inbox-button"
    try await reviewEntryPress(host, title: "Account Review Inbox") { !window.sheets.isEmpty }
    try await waitFor { !window.sheets.isEmpty }
    stage = "inbox-content"
    let inbox = try XCTHostingUnwrap(window.sheets.first?.contentView)
    try await settle()
    try reviewEntryRequire(await transport.facts().searches == 0, "Opening Inbox eagerly queried the platform")
    stage = "account-a-picker"
    try await reviewEntrySelect(inbox, item: "GitHub · @entry-a · github.com", diagnostics: destination)
    stage = "initial-requested-load"
    await transport.hold(); try await reviewEntryPress(inbox, title: "Load") { await transport.held() }
    try await reviewEntryWait { await transport.held() }
    stage = "my-open-scope-picker"
    try await reviewEntrySelect(inbox, item: "My Open PR / MR", diagnostics: destination)
    stage = "my-open-load"
    try await settle(); try await reviewEntryPress(inbox, title: "Load") { reviewAcceptanceText(inbox).contains("Current my-open snapshot entry-a") }
    try await waitFor { reviewAcceptanceText(inbox).contains("Current my-open snapshot entry-a") }
    await transport.release(); try await settle()
    try reviewEntryRequire(!reviewAcceptanceText(inbox).contains("Obsolete cancelled inbox response"), "A cancelled scope response repopulated Inbox")
    stage = "inbox-scope-screenshot"
    try await captureHostingWindow(try XCTHostingUnwrap(window.sheets.first), to: destination.appendingPathComponent("inbox-scope-late-response.png"))

    stage = "requested-scope-picker"
    try await reviewEntrySelect(inbox, item: "Review Requested", diagnostics: destination); try await settle()
    stage = "requested-held-load"
    await transport.hold(); try await reviewEntryPress(inbox, title: "Load") { await transport.held() }
    try await reviewEntryWait { await transport.held() }
    stage = "account-b-picker"
    try await reviewEntrySelect(inbox, item: "GitHub · @entry-b · github.com", diagnostics: destination)
    stage = "account-b-load"
    try await settle(); try await reviewEntryPress(inbox, title: "Load") { reviewAcceptanceText(inbox).contains("Current requested snapshot entry-b") }
    try await waitFor { reviewAcceptanceText(inbox).contains("Current requested snapshot entry-b") }
    await transport.release(); try await settle()
    try reviewEntryRequire(!reviewAcceptanceText(inbox).contains("Obsolete cancelled inbox response"), "An old account response repopulated Inbox")
    stage = "inbox-account-screenshot"
    try await captureHostingWindow(try XCTHostingUnwrap(window.sheets.first), to: destination.appendingPathComponent("inbox-account-late-response.png"))
    stage = "account-a-return-picker"
    try await reviewEntrySelect(inbox, item: "GitHub · @entry-a · github.com", diagnostics: destination)
    stage = "account-a-final-load"
    try await settle(); try await reviewEntryPress(inbox, title: "Load") { reviewAcceptanceText(inbox).contains("Current requested snapshot entry-a") }
    try await waitFor { reviewAcceptanceText(inbox).contains("Current requested snapshot entry-a") }
    stage = "inbox-exact-open"
    try await reviewEntryPress(inbox, title: "Open in GitPier") { window.sheets.isEmpty && store.hostingReviewDestination == nil && reviewAcceptanceText(host).contains("#17 Exact inbox native target") }
    try await waitFor { window.sheets.isEmpty && store.hostingReviewDestination == nil && reviewAcceptanceText(host).contains("#17 Exact inbox native target") }
    try reviewEntryRequire(store.selectedID == record.id && model.page == "hosting", "Inbox opened a different repository or page")
    stage = "inbox-target-screenshot"
    try await captureHostingWindow(window, to: destination.appendingPathComponent("inbox-exact-native-open.png"))

    stage = "current-branch-find"
    try await reviewEntryPress(host, title: "Find Current Branch PR / MR") { accessibleButton(host, title: "#19", enabled: true) != nil }
    try await waitFor { accessibleButton(host, title: "#19", enabled: true) != nil }
    stage = "current-branch-open"
    try await reviewEntryPress(host, title: "#19") { reviewAcceptanceText(host).contains("#19 Exact current-branch target") }
    try await waitFor { reviewAcceptanceText(host).contains("#19 Exact current-branch target") }
    try reviewEntryRequire(reviewAcceptanceText(host).contains(String(head.prefix(12))), "Current-branch shortcut did not expose its actual local SHA snapshot")
    stage = "current-branch-screenshot"
    try await captureHostingWindow(window, to: destination.appendingPathComponent("current-branch-find-open.png"))

    model.comparisonRight = "refs/remotes/origin/main"
    // The existing toolbar menu is not part of this change. Render the real Compare
    // view with actual local/remote-tracking inputs; do not claim a main-menu click.
    let compareHost = NSHostingView(rootView: BranchComparisonView(model: model).environmentObject(store).modifier(AppAppearance(store: store)))
    compareHost.sizingOptions = []; compareHost.autoresizingMask = [.width, .height]; window.contentView = compareHost
    stage = "compare-snapshot-and-diff"
    try await waitFor { reviewAcceptanceText(compareHost).contains("remote-tracking refs reflect your last Fetch") }
    try await waitFor { descendants(compareHost).compactMap { $0 as? NSTableView }.compactMap { $0.dataSource as? DiffTable.Coordinator }.contains { $0.document.raw.contains("entry-only") } }
    stage = "compare-english-screenshot"
    try await captureHostingWindow(window, to: destination.appendingPathComponent("compare-local-snapshot-english-light.png"))
    var settings = store.settings; settings.language = .simplifiedChinese; settings.appearance = .dark; store.updateSettings(settings)
    stage = "compare-chinese-snapshot"
    try await settle()
    try reviewEntryRequire(reviewAcceptanceText(compareHost).contains("远程跟踪引用反映上次 Fetch"), "Compare did not render the localized snapshot explanation")
    stage = "compare-chinese-screenshot"
    try await captureHostingWindow(window, to: destination.appendingPathComponent("compare-local-snapshot-chinese-dark.png"))
    let facts = await transport.facts()
    stage = "local-git-state-and-target-reads"
    try reviewEntryRequire(facts.writes == 0 && (facts.targetReads[17] ?? 0) >= 2 && (facts.targetReads[19] ?? 0) >= 1, "Native Open omitted target revalidation or attempted a write")
    let finalHead = String(decoding: try await git.read(["rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let finalBranch = String(decoding: try await git.read(["symbolic-ref", "--short", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let finalIndex = try await git.read(["ls-files", "--stage", "-z"]).stdout
    let finalStatus = try await git.read(["status", "--porcelain=v1", "-z"]).stdout
    try reviewEntryRequire(finalHead == head && finalBranch == "feature/review" && finalIndex == originalIndex && finalStatus == originalStatus,
      "Review entry navigation changed local Git state")
    try JSONSerialization.data(withJSONObject: ["nativeInboxLoad": true, "guiAssistedPicker": true, "pickerVerification": "Real GUI selection and AX readback", "inboxScopeLateResponseRejected": true,
      "inboxAccountLateResponseRejected": true, "inboxExactNativeOpenRevalidated": true, "nativeCurrentBranchFindOpen": true,
      "nativeCompareViewAndLocalizedSnapshotExplanation": true, "compareMainNavigationTested": false, "windowServerScreenshots": true,
      "localGitStatePreserved": true, "syntheticHTTPOnly": true, "searchRequests": facts.searches, "remoteWriteAttempts": facts.writes], options: [.prettyPrinted, .sortedKeys])
      .write(to: destination.appendingPathComponent("entry-results.json"))
    } catch {
      let originalError = error.localizedDescription
      let windows = [window] + window.sheets
      for (index, current) in windows.enumerated() {
        if let content = current.contentView {
          try? reviewAcceptanceText(content).write(to: destination.appendingPathComponent("entry-failure-window-\(index)-ax.txt"), atomically: true, encoding: .utf8)
        }
      }
      let controls = windows.flatMap { current -> [[String: Any]] in
        guard let content = current.contentView else { return [] }
        return ([content] + descendants(content)).map { view -> [String: Any] in
          var item: [String: Any] = ["class": String(describing: type(of: view)),
            "role": view.accessibilityRole()?.rawValue ?? "", "label": view.accessibilityLabel() ?? ""]
          if let popup = view as? NSPopUpButton { item["itemTitles"] = popup.itemTitles; item["selectedIndex"] = popup.indexOfSelectedItem; item["enabled"] = popup.isEnabled }
          if let button = view as? NSButton { item["title"] = button.title; item["enabled"] = button.isEnabled }
          return item
        }
      }
      let facts = await transport.facts()
      var diagnostic: [String: Any] = ["stage": stage, "error": originalError, "sheetCount": window.sheets.count,
        "applicationActive": NSApp.isActive, "windowKey": window.isKeyWindow, "sheetKey": window.sheets.map(\.isKeyWindow),
        "controls": controls, "searchRequests": facts.searches, "writeAttempts": facts.writes]
      let diagnosticURL = destination.appendingPathComponent("entry-failure-diagnostic.json")
      try? JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys]).write(to: diagnosticURL)
      var screenshotErrors: [String] = []
      for (index, current) in windows.enumerated() {
        do { try await captureHostingWindow(current, to: destination.appendingPathComponent("entry-failure-window-\(index).png")) }
        catch { screenshotErrors.append("window \(index): " + error.localizedDescription) }
      }
      diagnostic["screenshotErrors"] = screenshotErrors
      try? JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys]).write(to: diagnosticURL)
      throw GitPierError.invalidInput("Native review entry stage " + stage + ": " + originalError)
    }
  }

  private static func reviewEntryPress(_ host: NSView, title: String, completed: () async -> Bool) async throws {
    try await waitFor { accessibleButton(host, title: title, enabled: true) != nil }
    let button = try XCTHostingUnwrap(accessibleButton(host, title: title, enabled: true))
    if let native = button as? NSButton { native.performClick(nil) }
    else {
      let selector = NSSelectorFromString("accessibilityPerformPress")
      typealias Press = @convention(c) (AnyObject, Selector) -> Bool
      guard button.responds(to: selector) else { throw GitPierError.invalidInput("Native entry control lacks AXPress: " + title) }
      let press = unsafeBitCast(button.method(for: selector), to: Press.self)
      _ = press(button, selector) // One action; a sheet can destroy the proxy during Open.
    }
    // Every caller supplies a required observable result; never retry an action or set view state.
    try await reviewEntryWait(completed)
  }
  private static func reviewEntrySelect(_ host: NSView, item title: String, diagnostics: URL) async throws {
    guard ProcessInfo.processInfo.environment["GITPIER_REVIEW_MENU_INTERACTIVE"] == "1" else {
      throw GitPierError.invalidInput("Entry Picker acceptance requires GITPIER_REVIEW_MENU_INTERACTIVE=1 and real GUI selection")
    }
    NSApp.activate(ignoringOtherApps: true); host.window?.makeKeyAndOrderFront(nil)
    try await waitFor { NSApp.isActive && host.window?.isKeyWindow == true }
    let file = diagnostics.appendingPathComponent("entry-interactive-picker.json")
    func record(_ state: String) throws {
      let value: [String: Any] = ["state": state, "requestedItem": title, "applicationActive": NSApp.isActive,
        "verification": "GUI-assisted real Picker selection with AX readback",
        "targetWindowKey": host.window?.isKeyWindow == true, "targetIsSheet": host.window?.sheetParent != nil,
        "windowNumber": host.window?.windowNumber ?? 0,
        "pickerValues": reviewAcceptanceNodes(host).filter { ["AXPopUpButton", "AXMenuButton"].contains($0.role) }.map(\.text)]
      try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: file)
    }
    try record("waitingForRealPickerSelection")
    let deadline = Date().addingTimeInterval(120)
    while Date() < deadline {
      if reviewAcceptanceNodes(host).contains(where: { ["AXPopUpButton", "AXMenuButton"].contains($0.role) && $0.text.split(separator: "\n").contains(Substring(title)) }) {
        try record("realSelectionReadBack"); return
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    try record("timedOutWaitingForRealSelection")
    throw GitPierError.invalidInput("Interactive native Picker selection timed out: " + title)
  }
  private static func reviewEntryWait(_ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(8)
    while !(await condition()) { if Date() > deadline { throw GitPierError.invalidInput("Native entry transport condition timed out") }; try await Task.sleep(for: .milliseconds(50)) }
  }
  private static func reviewEntryRequire(_ value: Bool, _ message: String) throws { if !value { throw GitPierError.invalidInput(message) } }

  /// macOS SwiftUI text and Picker selections often live in AXValue/AXTitle, not AXLabel.
  static func reviewAcceptanceNodes(_ host: NSObject) -> [(object: NSObject, role: String, text: String)] {
    var visited = Set<ObjectIdentifier>(), nodes: [(object: NSObject, role: String, text: String)] = []
    func value(_ object: NSObject, _ name: String) -> Any? {
      let selector = NSSelectorFromString(name)
      return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
    }
    func walk(_ object: NSObject, depth: Int = 0) {
      guard depth < 100, visited.insert(ObjectIdentifier(object)).inserted else { return }
      let role = value(object, "accessibilityRole") as? String ?? ""
      let text = ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"].compactMap { value(object, $0) as? String }.joined(separator: "\n")
      nodes.append((object, role, text))
      for key in ["accessibilityChildren", "accessibilityChildrenInNavigationOrder", "accessibilityVisibleChildren", "accessibilityContents"] {
        for child in value(object, key) as? [Any] ?? [] { if let child = child as? NSObject { walk(child, depth: depth + 1) } }
      }
      for key in ["accessibilityFocusedUIElement", "accessibilityFocusedWindow", "accessibilityMenuBar"] {
        if let child = value(object, key) as? NSObject { walk(child, depth: depth + 1) }
      }
      if let view = object as? NSView { for child in view.subviews { walk(child, depth: depth + 1) } }
    }
    walk(host); return nodes
  }
  static func reviewAcceptanceText(_ host: NSObject) -> String { reviewAcceptanceNodes(host).map { $0.role + " " + $0.text }.joined(separator: "\n") }
}
