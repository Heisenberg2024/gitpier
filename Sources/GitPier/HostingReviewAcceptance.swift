import AppKit
import GitPierCore
import SwiftUI

/// All HTTP and credentials are synthetic. No provider URL is contacted by this fixture.
private actor HostingReviewAcceptanceTransport: HostingTransport {
  var head = String(repeating: "a", count: 40)
  let patch = "@@ -1,2 +1,3 @@\n struct Review {\n+  let value = 1\n }\n"
  var writes = 0
  var unknownNext = false
  var savedComments: [(Int, String)] = []
  var holdConversation = false
  var conversationGate: CheckedContinuation<Void, Never>?
  var pendingEnabled = false
  var pendingState = "PENDING"
  var pendingSummary = ""
  func count() -> Int { writes }
  func makeUnknown() { unknownNext = true }
  func hold() { holdConversation = true }
  func held() -> Bool { conversationGate != nil }
  func advance() { head = String(repeating: "b", count: 40) }
  func pending() { pendingEnabled = true; pendingSummary = "Original platform pending summary" }
  func release() { holdConversation = false; conversationGate?.resume(); conversationGate = nil }
  func send(_ request: URLRequest, limit: Int) async throws -> HostingHTTPResponse {
    guard request.url?.host == "api.github.com" else { throw HostingError.invalidInstance }
    let path = request.url!.path
    func response(_ value: Any, headers: [String: String] = [:]) throws -> HostingHTTPResponse { HostingHTTPResponse(data: try JSONSerialization.data(withJSONObject: value), headers: headers) }
    func comment(_ id: Int, _ body: String) -> [String: Any] {
      ["id": id, "body": body, "user": ["id": 42, "login": "review-fixture"], "created_at": "2026-10-18T01:00:00Z", "html_url": "https://github.com/example/review/pull/17#issuecomment-\(id)"]
    }
    func review() -> [String: Any] { ["id": 500, "user": ["id": 42, "login": "review-fixture"], "state": pendingState, "body": pendingSummary, "commit_id": head] }
    if request.httpMethod == "POST" {
      writes += 1
      let object = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
      let body = object["body"] as? String ?? ""
      if path.hasSuffix("/reviews/500/events") {
        pendingSummary = body
        pendingState = object["event"] as? String == "APPROVE" ? "APPROVED" : "COMMENTED"
        return try response(review())
      }
      let id = 1000 + writes
      savedComments.append((id, body))
      if unknownNext { unknownNext = false; throw HostingError.networkFailure }
      return try response(comment(id, body))
    }
    if path.hasSuffix("/example/review") { return try response(["id": 100, "private": false]) }
    if path.hasSuffix("/pulls/17") {
      return try response(["id": 200, "number": 17, "title": "Review native collaboration safely", "body": "Synthetic request. Remote content stays plain text.", "state": "open", "user": ["id": 99, "login": "author"], "head": ["sha": head, "ref": "review", "repo": ["full_name": "example/review"]], "base": ["ref": "main", "sha": String(repeating: "c", count: 40), "repo": ["id": 100]], "html_url": "https://github.com/example/review/pull/17", "updated_at": head])
    }
    if path.hasSuffix("/files") { return try response([["filename": "Sources/Review.swift", "status": "modified", "patch": patch, "additions": 1, "deletions": 0]]) }
    if path.hasSuffix("/reviews/500") { return try response(review()) }
    if path.hasSuffix("/reviews") { return try response(pendingEnabled ? [review()] : []) }
    if path.hasSuffix("/issues/17/comments") {
      if holdConversation {
        holdConversation = false
        await withCheckedContinuation { conversationGate = $0 }
        return try response([comment(999, "obsolete timeline must never return")])
      }
      let rows = (1...110).map { comment($0, "Synthetic conversation \($0) · 中文 English\n" + String(repeating: "Long review body with selectable plain text. ", count: $0 == 1 ? 12 : 1)) }
      let all = rows + savedComments.map { comment($0.0, $0.1) }
      let page = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value ?? "1") ?? 1
      let start = min(all.count, max(0, page - 1) * 50), end = min(all.count, start + 50)
      return try response(Array(all[start..<end]), headers: ["x-next-page": end < all.count ? String(page + 1) : ""])
    }
    if path.hasSuffix("/comments") { return try response([]) }
    throw HostingError.notFound
  }
}

extension UIAcceptance {
  static func verifyHostingReview(root: URL, output: URL) async throws {
    guard root.resolvingSymlinksInPath().deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui.") else { throw HostingError.invalidInstance }
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-review-ui-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let persistence = ConfigurationStore(url: fixture.appendingPathComponent("workspace.json"))
    var config = WorkspaceConfiguration(); config.settings.completionNotifications = false; try persistence.save(config)
    let store = AppStore(persistence: persistence), transport = HostingReviewAcceptanceTransport(), vault = HostingAcceptanceVault()
    defer { store.shutdown() }
    let account = HostingAccount(instance: try HostingInstance(provider: .github, url: "https://github.com"), user: HostingUser(stableID: "42", login: "review-fixture"), kind: .pat, scopes: ["public_repo"], storageMode: .keychain)
    let binding = try RepositoryHostingBinding(repositoryID: UUID(), accountID: account.id, remote: "origin", repository: "example/review")
    var metadata = HostingMetadata(); metadata.accounts = [account]; metadata.bindings = [binding]
    try HostingMetadataStore(url: fixture.appendingPathComponent("workspace.hosting.json")).save(metadata)
    let token = HostingToken(accessToken: "synthetic-review-only", scopes: ["public_repo"])
    try await vault.save(token, account: account)
    let hosting = HostingModel(store: store, http: HostingHTTPClient(transport: transport), vault: vault, openExternalURL: { _ in false }); store.hosting = hosting
    try await hosting.tokens.unlock(account)
    let request = try await hosting.api.request(binding, number: 17, account: account, token: token)
    let session = store.reviewSessions.session(hosting: hosting, binding: binding, account: account, request: request)
    let git = GitService(root: root)
    let index = try await git.read(["ls-files", "--stage", "-z"]).stdout
    let head = try await git.read(["rev-parse", "HEAD"]).stdout
    let branch = try await git.read(["symbolic-ref", "HEAD"]).stdout
    let status = try await git.read(["status", "--porcelain=v1", "-z"]).stdout
    let host = NSHostingView(rootView: HostingRequestDetail(hosting: hosting, binding: binding, account: account, request: request, initialTab: 2).environmentObject(store))
    host.sizingOptions = []; host.autoresizingMask = [.width, .height]
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.title = "GitPier Review Acceptance · Synthetic HTTP"; window.contentView = host
    window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); defer { window.close() }
    func diagnose(_ stage: String, title: String, button: NSObject? = nil, evidence: [String: Bool] = [:]) async throws {
      try await captureHostingWindow(window, to: output.appendingPathComponent("review-control-failure-parent.png"))
      for (index, sheet) in window.sheets.enumerated() {
        try await captureHostingWindow(sheet, to: output.appendingPathComponent("review-control-failure-sheet-\(index).png"))
      }
      // Fixed control labels and window state only; never dump text fields or private bodies.
      let buttons = ([window] + window.sheets).flatMap { $0.contentView.map { descendants($0).compactMap { $0 as? NSButton }.map(\.title) } ?? [] }
      var diagnostic: [String: Any] = ["stage": stage, "requestedFixedButtonLabel": title,
        "buttonFound": button != nil, "supportsPress": button?.responds(to: NSSelectorFromString("accessibilityPerformPress")) == true,
        "confirmationPresent": session.confirmation != nil, "sheetCount": window.sheets.count,
        "parentIsKey": window.isKeyWindow, "parentIsVisible": window.isVisible,
        "sheetIsKey": window.sheets.map(\.isKeyWindow), "nativeButtonTitles": buttons,
        "identityValid": session.identityValid, "submitting": session.submitting, "language": store.settings.language.rawValue]
      for (key, value) in evidence { diagnostic[key] = value }
      try JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("review-control-diagnostic.json"))
    }
    func press(_ title: String, in root: NSView? = nil, fromSheet: Bool = false,
      acknowledgement: (() async -> (targetBlocked: Bool, coordinatorBlocked: Bool, noNewPOST: Bool))? = nil) async throws {
      let deadline = Date().addingTimeInterval(8)
      while Date() < deadline {
        NSApp.activate(ignoringOtherApps: true)
        let target: NSWindow?
        if fromSheet { target = window.sheets.last }
        else { target = window.sheets.isEmpty ? window : nil }
        if let target, target.isVisible {
          target.makeKeyAndOrderFront(nil)
          let content = root ?? target.contentView
          content?.layoutSubtreeIfNeeded()
          if let content, accessibleButton(content, title: title, enabled: true) != nil {
            // SwiftUI can expose its AX proxy before the presentation/key transition completes.
            try await Task.sleep(for: .milliseconds(160))
            guard target.isVisible, target.isKeyWindow || window.isKeyWindow,
              fromSheet ? window.sheets.last === target : window.sheets.isEmpty,
              let button = accessibleButton(content, title: title, enabled: true),
              button.responds(to: NSSelectorFromString("accessibilityPerformPress")) else { continue }
            let selector = NSSelectorFromString("accessibilityPerformPress")
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            let action = unsafeBitCast(button.method(for: selector), to: Press.self)
            let returned = action(button, selector) // Exactly one real AX action; never retry it.
            if let acknowledgement {
              let until = Date().addingTimeInterval(8)
              var evidence: [String: Bool] = ["axPressReturned": returned]
              while Date() < until {
                let observed = await acknowledgement()
                evidence["targetBlocked"] = observed.targetBlocked; evidence["coordinatorBlocked"] = observed.coordinatorBlocked
                evidence["postCountUnchanged"] = observed.noNewPOST; evidence["sheetDismissed"] = window.sheets.isEmpty
                if !observed.targetBlocked && !observed.coordinatorBlocked && observed.noNewPOST && window.sheets.isEmpty {
                  // SwiftUI may remove an alert's AX proxy during its action and return false.
                  // Only this non-network acknowledgement accepts its verified state transition.
                  var record: [String: Any] = evidence; record["singleRealAXPress"] = true; record["sheetCount"] = window.sheets.count
                  try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("review-acknowledgement-evidence.json"))
                  return
                }
                try await Task.sleep(for: .milliseconds(50))
              }
              try await diagnose("AcknowledgementTransitionMissing", title: title, button: button, evidence: evidence)
              throw GitPierError.invalidInput("Native platform acknowledgement did not complete after one AX press")
            }
            guard returned else {
              try await diagnose("AXPressReturnedFalse", title: title, button: button)
              throw GitPierError.invalidInput("Native review button press failed: " + title)
            }
            return
          }
        }
        try await Task.sleep(for: .milliseconds(50))
      }
      try await diagnose("AXButtonNotReady", title: title)
      throw GitPierError.invalidInput("Native review button unavailable: " + title)
    }
    try await waitFor { session.context != nil && descendants(host).contains { $0 is DiffSplitContainer } }
    try await settle()
    guard let diff = descendants(host).compactMap({ $0 as? DiffSplitContainer }).first,
      diff.tables.allSatisfy({ $0.selectLine == nil && $0.lineAction == nil }),
      let table = diff.tables.last else { throw GitPierError.invalidInput("Remote review diff unavailable or staging selection enabled") }
    let point = table.convert(NSPoint(x: 10, y: table.rect(ofRow: 2).midY), to: nil)
    let event = try XCTHostingUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
    table.mouseMoved(with: event)
    guard let hover = descendants(table).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityIdentifier() == "hosting.diff.add-comment" && !$0.isHidden }) else { throw GitPierError.invalidInput("Native inline hover control unavailable") }
    hover.performClick(nil)
    guard case .inline(let anchor) = session.composer, anchor.side == .new, anchor.newLine == 2 else { throw GitPierError.invalidInput("Hover did not use the exact parsed file coordinate") }
    session.composerBody = "Synthetic inline draft · 中文"
    session.saveInlineDraft()
    guard session.draft?.comments.count == 1, session.hasUnsavedContent,
      store.reviewSessions.session(hosting: hosting, binding: binding, account: account, request: request) === session,
      await transport.count() == 0 else { throw GitPierError.invalidInput("Saving a local draft wrote remotely or lost its identity") }
    try await captureHostingWindow(window, to: output.appendingPathComponent("review-inline-hover-draft.png"))
    session.draft?.comments = []; session.begin(.comment); session.composerBody = "Synthetic confirmed comment"
    session.prepareComposer()
    guard session.confirmation != nil, await transport.count() == 0 else { throw GitPierError.invalidInput("Preview performed a remote write") }
    try await press("Edit / Cancel", fromSheet: true)
    try await waitFor { session.confirmation == nil && window.sheets.isEmpty }
    guard await transport.count() == 0, session.composerBody == "Synthetic confirmed comment" else { throw GitPierError.invalidInput("Cancelling preview lost input or sent a write") }
    session.prepareComposer()
    session.composerBody = "Unsent comment edited after confirmation preview"
    try await press("Confirm & Submit", fromSheet: true)
    try await waitFor { !session.submitting && session.report != nil }
    guard session.report?.complete == true, await transport.count() == 1, session.composerBody == "Unsent comment edited after confirmation preview" else { throw GitPierError.invalidInput("Successful confirmation cleared input edited after preview") }
    session.composer = nil; session.composerBody = ""

    // Deliberately uncooperative old HTTP cannot repopulate the refreshed target's timeline.
    await transport.hold(); session.start(refresh: true)
    for _ in 0..<200 { if await transport.held() { break }; try await Task.sleep(for: .milliseconds(20)) }
    guard await transport.held() else { throw GitPierError.invalidInput("Old timeline gate did not start") }
    await transport.advance(); session.start(refresh: true)
    try await waitFor { session.context?.revision.headSHA == String(repeating: "b", count: 40) && session.states[.conversation]?.loaded == true }
    await transport.release(); try await settle()
    guard !session.orderedThreads.flatMap(\.comments).contains(where: { $0.id == "999" }) else { throw GitPierError.invalidInput("Old timeline response contaminated the new revision") }
    while session.nextPages[.conversation] != nil {
      session.load(.conversation, more: true)
      try await waitFor { session.states[.conversation]?.loading == false }
    }

    for language in [AppLanguage.english, .simplifiedChinese] {
      for appearance in [AppearanceMode.light, .dark] {
        var settings = store.settings; settings.language = language; settings.appearance = appearance; store.updateSettings(settings)
        let reviewHost = NSHostingView(rootView: HostingReviewView(session: session).environmentObject(store).modifier(AppAppearance(store: store)))
        reviewHost.sizingOptions = []; reviewHost.autoresizingMask = [.width, .height]; window.contentView = reviewHost
        window.setContentSize(NSSize(width: 960, height: 640)); try await settle()
        guard session.orderedThreads.flatMap(\.comments).count >= 100 else { throw GitPierError.invalidInput("Large timeline fixture did not load") }
        guard let scroll = descendants(reviewHost).compactMap({ $0 as? NSScrollView }).first(where: { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 100 }), let document = scroll.documentView,
          let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -180, wheel2: 0, wheel3: 0).flatMap({ NSEvent(cgEvent: $0) }) else { throw GitPierError.invalidInput("Review timeline native scroll view unavailable") }
        let top = scroll.contentView.bounds.minY
        scroll.scrollWheel(with: wheel); try await Task.sleep(for: .milliseconds(180))
        guard scroll.contentView.bounds.minY > top else { throw GitPierError.invalidInput("Review timeline native mouse wheel did not scroll") }
        for _ in 0..<20 {
          if let end = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -100_000, wheel2: 0, wheel3: 0).flatMap({ NSEvent(cgEvent: $0) }) { scroll.scrollWheel(with: end) }
          try await Task.sleep(for: .milliseconds(30))
        }
        try await settle()
        guard scroll.contentView.bounds.maxY >= document.bounds.maxY - 2 else { throw GitPierError.invalidInput("Review timeline bottom is not reachable by native scrolling") }
        try await captureHostingWindow(window, to: output.appendingPathComponent("review-timeline-\(language.rawValue)-\(appearance.rawValue)-960.png"))
      }
    }
    // Submitting an existing platform Pending Review clears only the summary/decision it sent.
    let current = try XCTHostingUnwrap(session.context)
    let file = try XCTHostingUnwrap(try await hosting.api.files(binding, number: 17, account: account, token: token).items.first)
    let document = DiffParser.parse(Data((file.patch ?? "").utf8))
    let line = try XCTHostingUnwrap(document.hunks.flatMap(\.lines).first(where: { $0.kind == .addition }))
    let remaining = HostingReviewDraftComment(body: "Unsent inline draft must survive pending submission", anchor: try HostingDiffAnchor.make(context: current, file: file, document: document, lineID: line.id, side: .new))
    session.draft?.comments = [remaining]; session.draft?.summary = ""; session.draft?.decision = .approve
    session.begin(.comment); session.composerBody = "Independent unsent ordinary comment"
    await transport.pending()
    let pending = try XCTHostingUnwrap(try await hosting.api.reviewTimeline(binding, number: 17, account: account, token: token, source: .reviews).items.first)
    session.preparePending(pending)
    let pendingConfirmation = try XCTHostingUnwrap(session.confirmation)
    guard case .submitPending(_, let preservedSummary, _) = pendingConfirmation.items.first?.mutation,
      preservedSummary == "Original platform pending summary" else { throw GitPierError.invalidInput("Pending submission silently replaced the original platform summary") }
    session.submit(pendingConfirmation)
    try await waitFor { !session.submitting }
    guard session.report?.complete == true, session.draft?.summary.isEmpty == true, session.draft?.decision == .comment,
      session.draft?.comments == [remaining], session.composerBody == "Independent unsent ordinary comment", await transport.count() == 2 else { throw GitPierError.invalidInput("Pending submission cleared unsent work or retained its published summary") }
    session.draft?.comments = []; session.composer = nil; session.composerBody = ""
    await transport.makeUnknown(); session.begin(.comment); session.composerBody = "Synthetic ambiguous comment"; session.prepareComposer()
    let unknown = try XCTHostingUnwrap(session.confirmation); session.submit(unknown)
    try await waitFor { !session.submitting }
    guard session.report?.hasUnknown == true, session.composerBody == "Synthetic ambiguous comment", await transport.count() == 3 else { throw GitPierError.invalidInput("Unknown result did not preserve the draft") }
    session.submit(unknown); try await waitFor { !session.submitting }
    guard await transport.count() == 3 else { throw GitPierError.invalidInput("Unknown submission was posted twice") }
    let sibling = HostingReviewSession(hosting: hosting, binding: binding, account: account, request: request, coordinator: store.reviewSessions.coordinator)
    sibling.start(loadTimeline: false)
    try await waitFor { !sibling.contextLoading }
    guard sibling.context != nil, sibling.targetBlocked, !sibling.canCompose, sibling.report == nil else { throw GitPierError.invalidInput("New session did not inherit the target's unknown-result block") }
    let recoveryHost = NSHostingView(rootView: HostingReviewStatus(session: sibling).environmentObject(store).padding(20))
    try await waitFor { window.sheets.isEmpty }
    recoveryHost.sizingOptions = []; recoveryHost.autoresizingMask = [.width, .height]; window.contentView = recoveryHost
    window.setContentSize(NSSize(width: 760, height: 420)); window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true); try await settle()
    let checkedTitle = store.text("I Checked the Platform…", "我已在平台核实…")
    try await press(checkedTitle, in: recoveryHost)
    guard sibling.targetBlocked, await transport.count() == 3 else { throw GitPierError.invalidInput("Opening platform acknowledgement unlocked or repeated a write") }
    let recoveryTarget = try XCTHostingUnwrap(sibling.context?.target)
    try await press(store.text("I Verified What Was Published", "我已核实实际发布内容"), fromSheet: true, acknowledgement: {
      let blocked = await store.reviewSessions.coordinator.isBlocked(recoveryTarget)
      let writes = await transport.count()
      return (targetBlocked: sibling.targetBlocked, coordinatorBlocked: blocked, noNewPOST: writes == 3)
    })
    try await waitFor { !sibling.targetBlocked && window.sheets.isEmpty }
    guard sibling.canCompose, session.composerBody == "Synthetic ambiguous comment", await transport.count() == 3 else { throw GitPierError.invalidInput("Explicit cross-session recovery lost a draft or posted again") }
    guard try await git.read(["ls-files", "--stage", "-z"]).stdout == index,
      try await git.read(["rev-parse", "HEAD"]).stdout == head,
      try await git.read(["symbolic-ref", "HEAD"]).stdout == branch,
      try await git.read(["status", "--porcelain=v1", "-z"]).stdout == status else { throw GitPierError.invalidInput("Remote review changed local Git state") }
    try JSONSerialization.data(withJSONObject: ["syntheticHTTPOnly": true, "nativeHoverExactAnchor": true, "confirmationBeforePOST": true, "singlePOSTAndReadback": true, "draftRegistryShared": true, "lateTimelineRejected": true, "hundredCommentsEnglishChineseLightDark": true, "unknownNoDuplicatePOST": true, "indexHeadBranchWorktreePreserved": true, "realProviderVerified": false], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("review-results.json"))
  }
}
