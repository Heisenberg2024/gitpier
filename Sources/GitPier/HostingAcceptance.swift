import AppKit
import Carbon
import GitPierCore
import SwiftUI

/// Injected only by the existing explicit --ui-acceptance entry point and disposable workspace script.
actor HostingAcceptanceTransport: HostingTransport {
  let sha: String
  private var approved = false
  private var failUser = false
  private var permissionFailure = false
  private var exchanges = 0
  private(set) var posts = 0
  init(sha: String) { self.sha = sha }
  func approve() { approved = true }
  func resetDevice() { approved = false }
  func denyUser(_ value: Bool) { failUser = value }
  func denyPermission(_ value: Bool) { permissionFailure = value }
  func postCount() -> Int { posts }
  func exchangeCount() -> Int { exchanges }
  func send(_ request: URLRequest, limit: Int) async throws -> HostingHTTPResponse {
    let path = request.url!.path, host = request.url!.host ?? ""
    func response(_ object: Any, status: Int = 200) throws -> HostingHTTPResponse {
      HostingHTTPResponse(data: try JSONSerialization.data(withJSONObject: object), status: status)
    }
    if path == "/login/device/code" { return try response(["device_code": "fixture-device-only", "user_code": "TEST-CODE", "verification_uri": "https://github.com/login/device", "interval": 5, "expires_in": 300]) }
    if path == "/login/oauth/access_token" || path == "/oauth/token" {
      if host == "github.com", !approved { return try response(["error": "authorization_pending"]) }
      exchanges += 1
      return try response(["access_token": "synthetic-hosting-token", "refresh_token": "synthetic-refresh", "expires_in": 3600, "token_type": "bearer", "scope": host == "github.com" ? "read:user public_repo" : "read_api read_user"])
    }
    if path.hasSuffix("/user") {
      if failUser { return try response(["message": "fixture"], status: 401) }
      return try response(["id": host == "api.github.com" ? 42 : host.contains("gitlab") ? 51 : 61, "login": "fixture-user", "username": "fixture-user", "name": "Synthetic Account"])
    }
    if permissionFailure { return try response(["message": "fixture"], status: 403) }
    if path.hasSuffix("/version") { return try response(["version": "1.24.7"]) }
    if path.contains("/branches/") { return try response(["commit": [(host == "api.github.com" ? "sha" : "id"): sha]]) }
    if path.hasSuffix("/check-runs") { return try response(["check_runs": [["name": "Build macOS", "head_sha": sha, "conclusion": "success", "html_url": "https://github.com/example/fixture/actions"]]]) }
    if path.hasSuffix("/status") { return try response(["sha": sha, "total_count": 1, "statuses": [["context": "Unit tests", (host == "api.github.com" ? "state" : "status"): "success", "target_url": "https://github.com/example/fixture/actions"]]]) }
    if path.hasSuffix("/pipelines") { return try response([["id": 100, "sha": sha, "status": "running"]]) }
    if path.hasSuffix("/commits") { return try response([["sha": sha, "id": sha, "commit": ["message": "Add native code hosting"], "message": "Add native code hosting"]]) }
    if path.hasSuffix("/files") || path.hasSuffix("/diffs") { return try response([
      ["filename": "Sources/Hosting.swift", "new_path": "Sources/Hosting.swift", "old_path": "Sources/Hosting.swift", "status": "modified", "patch": "@@ -1,2 +1,3 @@\n struct Hosting {\n+  let provider = \"GitHub\"\n }", "diff": "@@ -1,2 +1,3 @@\n struct Hosting {\n+  let provider = \"GitLab\"\n }"],
      ["filename": "Resources/Preview.png", "new_path": "Resources/Preview.png", "status": "added"]]) }
    if path.hasSuffix("/reviews") { return try response([["id": 1, "state": "APPROVED", "user": ["id": 71, "login": "fixture-reviewer"], "body": "Approved the native implementation.", "commit_id": sha]]) }
    if path.hasSuffix("/approvals") { return try response(["approved_by": [["user": ["id": 71, "username": "fixture-reviewer"]]]]) }
    if path.hasSuffix("/comments") || path.hasSuffix("/notes") { return try response([["id": 2, "user": ["id": 71, "login": "fixture-reviewer"], "author": ["id": 71, "username": "fixture-reviewer"], "path": "Sources/Hosting.swift", "line": 2, "commit_id": sha, "body": "Synthetic review comment. <script>never executed</script>"]]) }
    if path.hasSuffix("/discussions") { return try response([]) }
    func pull(_ number: Int = 17, created: Bool = false) -> [String: Any] {
      ["id": number + 200, "number": number, "iid": number, "title": created ? "Add native hosting collaboration" : "Connect repository collaboration", "body": "Review provider requests and exact-commit CI.\n\n<script>remote content is text</script>", "description": "Fixture merge request description", "state": "open", "draft": false,
       "head": ["ref": created ? "main" : "feature/hosting", "sha": sha, "repo": ["full_name": "example/fixture"]], "base": ["ref": created ? "develop" : "main", "sha": sha, "repo": ["id": 12]], "sha": sha,
       "source_branch": "feature/hosting", "target_branch": "main", "source_project_id": 12, "target_project_id": 12,
       "user": ["id": 99, "login": "fixture-user"], "author": ["id": 99, "username": "fixture-user"], "requested_reviewers": [["login": "fixture-reviewer"]],
       "created_at": "2026-10-16T10:00:00Z", "updated_at": "2026-10-16T11:00:00Z", "html_url": "https://github.com/example/fixture/pull/17", "web_url": "https://gitlab.example.invalid/example/fixture/-/merge_requests/17"]
    }
    if request.httpMethod == "POST" && (path.hasSuffix("/pulls") || path.hasSuffix("/merge_requests")) { posts += 1; return try response(pull(18, created: true), status: 201) }
    if path.hasSuffix("/pulls") || path.hasSuffix("/merge_requests") { return try response([pull()]) }
    if path.contains("/pulls/") || path.contains("/merge_requests/") { return try response(pull()) }
    return try response(["id": 12, "full_name": "example/fixture"])
  }
}
actor HostingAcceptanceVault: HostingCredentialStore {
  private var tokens: [UUID: HostingToken] = [:]
  private var reject = false
  private var reads: [UUID: Int] = [:]
  func deny(_ value: Bool) { reject = value }
  func readCount(_ id: UUID) -> Int { reads[id] ?? 0 }
  func read(account: HostingAccount) throws -> HostingToken? {
    reads[account.id, default: 0] += 1
    if reject { throw HostingError.keychainDenied }; return tokens[account.id]
  }
  func save(_ token: HostingToken, account: HostingAccount) throws {
    if reject { throw HostingError.keychainDenied }; tokens[account.id] = token
  }
  func delete(account: HostingAccount) { tokens[account.id] = nil }
}

extension UIAcceptance {
  static func verifyHostingBrowserCallbacks(store: AppStore, output: URL) async throws {
    // Exercise the actual macOS Get URL AppleEvent -> AppDelegate -> active PKCE receiver.
    // Target only this disposable process, without changing the user's default URL handler.
    let transport = HostingAcceptanceTransport(sha: String(repeating: "a", count: 40))
    let vault = HostingAcceptanceVault(), previousHosting = store.hosting
    var opened = 0; var callback: URL?
    func deliver(_ url: URL) throws {
      let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
        targetDescriptor: NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier),
        returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
      event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: AEKeyword(keyDirectObject))
      _ = try event.sendEvent(options: .noReply, timeout: 5)
    }
    let hosting = HostingModel(store: store, http: HostingHTTPClient(transport: transport), vault: vault, openExternalURL: { url in
      opened += 1
      guard let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value else { return false }
      var c = URLComponents(string: "gitpier://oauth/gitlab")!
      c.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "code", value: "fixture-code")]
      callback = c.url
      do {
        try deliver(URL(string: "gitpier://oauth/gitlab?state=wrong&code=unrelated")!)
        try deliver(c.url!)
        return true
      } catch { return false }
    })
    store.hosting = hosting
    defer { hosting.shutdown(); store.hosting = previousHosting }
    let config = OAuthConfiguration(instance: try HostingInstance(provider: .gitlab, url: "https://gitlab.example.invalid"), clientID: "fixture-public-id")
    hosting.connect(configuration: config, level: .read)
    try await waitFor { !hosting.authorizing }
    guard opened == 1, hosting.error == nil, let account = hosting.metadata.accounts.first,
      hosting.states[account.id] == .connected, await transport.exchangeCount() == 1 else { throw GitPierError.invalidInput("Ordinary browser AppleEvent callback did not connect") }
    try deliver(try XCTHostingUnwrap(callback)); try await settle()
    guard await transport.exchangeCount() == 1 else { throw GitPierError.invalidInput("Duplicate browser callback exchanged twice") }
    try JSONSerialization.data(withJSONObject: ["getURLAppleEvent": true, "appDelegateRouting": true, "wrongStateIgnored": true,
      "oauthExchangeMock": true, "duplicateIgnored": true, "realOAuthVerified": false, "defaultURLHandlerChanged": false], options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("hosting-browser-results.json"))
  }
  static func verifyHosting(root: URL, output: URL) async throws {
    guard root.resolvingSymlinksInPath().deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui.") else { throw HostingError.invalidInstance }
    // Ordinary-browser private-scheme callbacks can arrive before the waiter is scheduled.
    let browser = HostingBrowserSession()
    let callbackConfig = OAuthConfiguration(instance: try HostingInstance(provider: .gitlab, url: "https://gitlab.example.invalid"), clientID: "fixture-public-id")
    let callbackSession = try OAuthPKCESession(configuration: callbackConfig, redirectURL: URL(string: "gitpier://oauth/gitlab")!)
    let callbackURL = URL(string: "gitpier://oauth/gitlab?state=\(callbackSession.state)&code=fixture-code")!
    let received = try await browser.authorize(callbackSession, scopes: ["read_api"], openURL: { _ in
      Task { @MainActor in _ = await browser.receive(callbackURL) }
      return true
    })
    guard received == callbackURL, await !browser.receive(callbackURL) else { throw HostingError.invalidCallback }
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-hosting-ui-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let persistence = ConfigurationStore(url: fixture.appendingPathComponent("workspace.json"))
    var config = WorkspaceConfiguration(); let record = RepositoryRecord(path: root.path, name: "Hosting Fixture")
    config.repositories = [record]; config.selectedRepository = record.id; config.settings.launchPage = "commit"
    config.settings.completionNotifications = false
    try persistence.save(config)
    let store = AppStore(persistence: persistence); defer { store.shutdown() }
    let model = store.models[record.id]!
    await model.activate()
    let git = await model.git(), state = try await git.status(localOnly: true)
    let head = try XCTHostingUnwrap(state.head)
    _ = try await git.perform(["remote", "add", "review-source", "https://github.com/example/fork.git"])
    model.remotes = try await git.remotes()
    let indexURL = root.appendingPathComponent(".git/index"), originalIndex = try Data(contentsOf: indexURL)
    let originalRemotes = try await git.remotes()
    let originalDraft = model.record.draft
    let transport = HostingAcceptanceTransport(sha: head), keychain = HostingAcceptanceVault()
    let local = LocalEncryptedCredentialStore(root: fixture.appendingPathComponent("HostingCredentials"))
    let vault = HostingCredentialRouter(local: local, keychain: keychain)
    let http = HostingHTTPClient(transport: transport, sleep: { _ in try await Task.sleep(for: .milliseconds(80)) })
    var metadata = HostingMetadata()
    for provider in HostingProvider.allCases {
      let instance = try HostingInstance(provider: provider, url: provider == .github ? "https://github.com" : "https://\(provider.rawValue).example.invalid")
      let oauth = OAuthConfiguration(instance: instance, clientID: "fixture-public-id", redirect: provider == .gitea ? .loopback(port: 0) : .application)
      let user = HostingUser(stableID: provider == .github ? "42" : provider == .gitlab ? "51" : "61", login: "fixture-user")
      let account = HostingAccount(instance: instance, user: user, kind: .oauth, scopes: provider == .github ? ["read:user", "public_repo"] : provider == .gitlab ? ["read_user", "read_api"] : ["read:user", "read:repository"], oauth: oauth, storageMode: provider == .gitlab ? .keychain : .localVault)
      metadata.accounts.append(account); metadata.configurations.append(oauth)
      try await vault.save(HostingToken(accessToken: "synthetic-hosting-token", scopes: account.scopes), account: account)
    }
    var second = metadata.accounts[0]; second = HostingAccount(instance: second.instance, user: HostingUser(stableID: "43", login: "second-fixture"), kind: .pat, scopes: [])
    metadata.accounts.append(second)
    var account = metadata.accounts[0]
    let binding = try RepositoryHostingBinding(repositoryID: record.id, accountID: account.id, remote: originalRemotes.first!.name, repository: "example/fixture")
    metadata.bindings = [binding]
    try HostingMetadataStore(url: persistence.url.deletingPathExtension().appendingPathExtension("hosting.json")).save(metadata)
    var openedURLs: [URL] = []
    let publicConfiguration = HostingOAuthConfiguration(githubClientID: "fixture-public-id", gitlabClientID: "fixture-public-id")
    let hosting = HostingModel(store: store, http: http, vault: vault, publicConfiguration: publicConfiguration,
      openExternalURL: { openedURLs.append($0); return true })
    let emptyStore = AppStore(persistence: ConfigurationStore(url: fixture.appendingPathComponent("empty/workspace.json")))
    let emptyHosting = HostingModel(store: emptyStore, http: http, vault: vault, publicConfiguration: publicConfiguration, openExternalURL: { _ in true })
    emptyStore.hosting = emptyHosting
    defer { emptyStore.shutdown() }
    for provider in HostingProvider.allCases {
      for dark in [false, true] {
        guard let logo = AppResources.hostingLogo(provider, dark: dark), logo.size.width > 0, logo.size.height > 0 else { throw GitPierError.invalidInput("Missing official hosting logo") }
      }
    }
    store.hosting = hosting
    for account in metadata.accounts.prefix(3) { hosting.verify(account) }
    try await waitFor { hosting.busy.isEmpty && hosting.states[account.id] == .connected }
    account = try XCTHostingUnwrap(hosting.account(account.id))
    // Exercise the same PKCE callback/exchange and account verification with injected provider responses.
    var pkce = try OAuthPKCESession(configuration: metadata.configurations[1], redirectURL: URL(string: "gitpier://oauth/gitlab")!)
    let code = try pkce.consume(URL(string: "gitpier://oauth/gitlab?code=fixture-code&state=\(pkce.state)")!)
    let exchanged = try await hosting.oauth.exchange(session: pkce, code: code, scopes: ["read_api"])
    try await hosting.tokens.install(exchanged, account: metadata.accounts[1])
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.title = "GitPier 1.5 · Synthetic OAuth / API Fixture"
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    host.sizingOptions = []; host.autoresizingMask = [.width, .height]; window.contentView = host
    NSApp.setActivationPolicy(.regular); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    defer { hosting.shutdown(); host.rootView = AnyView(EmptyView()); window.close() }
    var screenshots = 0
    func show(_ view: some View, name: String, width: Int, height: Int) async throws {
      host.rootView = AnyView(view.environmentObject(store).modifier(AppAppearance(store: store)).id(name + store.settings.language.rawValue + store.settings.appearance.rawValue))
      window.setContentSize(NSSize(width: width, height: height)); window.center(); window.makeKeyAndOrderFront(nil)
      try await settle()
      try await captureHostingWindow(window, to: output.appendingPathComponent(name + ".png")); screenshots += 1
    }
    let sizes = [(960, 640), (1440, 900), (1800, 1100)]
    let storageOnly = ProcessInfo.processInfo.environment["GITPIER_HOSTING_STORAGE_ONLY"] == "1"
    if !storageOnly {
    for language in [AppLanguage.english, .simplifiedChinese] {
      for appearance in [AppearanceMode.light, .dark] {
        var settings = store.settings; settings.language = language; settings.appearance = appearance; store.updateSettings(settings)
        for (width, height) in sizes {
          let prefix = "hosting-\(language.rawValue)-\(appearance.rawValue)-\(width)"
          hosting.error = nil
          try await show(SettingsView(initialTab: 8), name: prefix + "-settings", width: width, height: height)
          try await show(HostingSettingsView(hosting: emptyHosting), name: prefix + "-empty-accounts", width: width, height: height)
          try await show(HostingConnectSheet(hosting: emptyHosting, request: HostingConnectionRequest(provider: .gitea)), name: prefix + "-gitea-connect", width: width, height: height)
          try await show(HostingSettingsView(hosting: hosting), name: prefix + "-multi-account", width: width, height: height)
          try await show(HostingStorageSheet(hosting: hosting, account: account), name: prefix + "-storage-local-to-keychain", width: width, height: height)
          try await show(HostingStorageSheet(hosting: hosting, account: metadata.accounts[1]), name: prefix + "-storage-keychain-to-local", width: width, height: height)
          try await show(HostingConnectSheet(hosting: hosting, request: HostingConnectionRequest(provider: .gitea, account: metadata.accounts[2])), name: prefix + "-gitea-config", width: width, height: height)
          try await show(HostingBindingSheet(hosting: hosting, model: model), name: prefix + "-binding", width: width, height: height)
          guard hostingTextFieldValues(host).contains(binding.repository) else { throw GitPierError.invalidInput("Saved manual repository binding was replaced by a Remote suggestion") }
          try await show(HostingWorkspaceView(model: model), name: prefix + "-requests", width: width, height: height)
          let token = try await hosting.tokens.token(for: account)
          let item = try await hosting.api.request(binding, number: 17, account: account, token: token)
          for tab in 0...4 {
            try await show(HostingRequestDetail(hosting: hosting, binding: binding, account: account, request: item, initialTab: tab), name: prefix + "-detail-\(tab)", width: width, height: height)
          }
          let initial = HostingCreateDraft(sourceRepository: binding.repository, source: state.branch, target: "develop", title: "Add native hosting collaboration", body: "Synthetic creation only. No remote Git writes.")
          try await show(HostingCreateSheet(hosting: hosting, model: model, binding: binding, account: account, initialDraft: initial), name: prefix + "-create", width: width, height: height)
          try pressNativeButton(host, title: store.text("Review…", "审查…")); try await settle()
          guard accessibleButton(host, title: store.text("Confirm & Create", "确认并创建"), enabled: true) != nil else { throw GitPierError.invalidInput("Creation confirmation was not shown") }
          try await captureHostingWindow(window, to: output.appendingPathComponent(prefix + "-create-confirm.png")); screenshots += 1
          guard await transport.postCount() == 0 else { throw GitPierError.invalidInput("Review unexpectedly posted a request") }
          await hosting.detailCache.clear(account: account)
          await transport.denyPermission(true)
          try await show(HostingRequestDetail(hosting: hosting, binding: binding, account: account, request: item, initialTab: 4), name: prefix + "-permission", width: width, height: height)
          await transport.denyPermission(false)
          hosting.error = hosting.message(HostingError.invalidClient)
          try await show(HostingConnectSheet(hosting: hosting, request: HostingConnectionRequest(provider: .gitlab)), name: prefix + "-oauth-failure", width: width, height: height)
          hosting.error = nil
        }
      }
    }
    } else {
      for language in [AppLanguage.english, .simplifiedChinese] {
        for appearance in [AppearanceMode.light, .dark] {
          var settings = store.settings; settings.language = language; settings.appearance = appearance; store.updateSettings(settings)
          let prefix = "storage-\(language.rawValue)-\(appearance.rawValue)"
          try await show(HostingSettingsView(hosting: hosting), name: prefix + "-accounts", width: 960, height: 640)
          try await show(HostingStorageSheet(hosting: hosting, account: account), name: prefix + "-to-keychain", width: 960, height: 640)
          try await show(HostingStorageSheet(hosting: hosting, account: metadata.accounts[1]), name: prefix + "-to-local", width: 960, height: 640)
        }
      }
    }
    let glAccount = try XCTHostingUnwrap(hosting.account(metadata.accounts[1].id))
    let glBinding = try RepositoryHostingBinding(repositoryID: record.id, accountID: glAccount.id, remote: binding.remote, repository: "example/fixture")
    try await hosting.bind(glBinding, account: glAccount)
    if !storageOnly {
    for language in [AppLanguage.english, .simplifiedChinese] {
      for appearance in [AppearanceMode.light, .dark] {
        var settings = store.settings; settings.language = language; settings.appearance = appearance; store.updateSettings(settings)
        for (width, height) in sizes {
          let prefix = "hosting-gitlab-\(language.rawValue)-\(appearance.rawValue)-\(width)"
          try await show(HostingWorkspaceView(model: model), name: prefix + "-merge-requests", width: width, height: height)
          let token = try await hosting.tokens.token(for: glAccount)
          let item = try await hosting.api.request(glBinding, number: 17, account: glAccount, token: token)
          try await show(HostingRequestDetail(hosting: hosting, binding: glBinding, account: glAccount, request: item, initialTab: 4), name: prefix + "-pipeline", width: width, height: height)
        }
      }
    }
    }
    try await hosting.bind(binding, account: XCTHostingUnwrap(hosting.account(account.id)))
    // Native device UI and copy action; no browser or real OAuth endpoint is opened by this fixture.
    var settings = store.settings; settings.language = .english; settings.appearance = .light; store.updateSettings(settings)
    let request = HostingConnectionRequest(provider: .github)
    host.rootView = AnyView(HostingConnectSheet(hosting: hosting, request: request).environmentObject(store).modifier(AppAppearance(store: store)))
    window.setContentSize(NSSize(width: 960, height: 640)); try await settle()
    hosting.connect(configuration: metadata.configurations[0], level: .publicWrite)
    try await waitFor { hosting.device != nil }
    guard openedURLs.map(\.absoluteString) == ["https://github.com/login/device"] else { throw GitPierError.invalidInput("GitHub authorization did not automatically open its verified browser URL exactly once") }
    try await settle()
    do {
    let oldClipboard = NSPasteboard.general.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
      let copy = NSPasteboardItem(); for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }; return copy
    } ?? []
    defer { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(oldClipboard) }
    try pressNativeButton(host, title: "Copy Code")
    guard NSPasteboard.general.string(forType: .string) == "TEST-CODE" else { throw GitPierError.invalidInput("Device code Copy failed") }
    }
    if !storageOnly {
    for language in [AppLanguage.english, .simplifiedChinese] {
      for appearance in [AppearanceMode.light, .dark] {
        settings.language = language; settings.appearance = appearance; store.updateSettings(settings)
        for (width, height) in sizes {
          window.setContentSize(NSSize(width: width, height: height)); window.center()
          try await settle(); try await captureHostingWindow(window, to: output.appendingPathComponent("hosting-device-\(language.rawValue)-\(appearance.rawValue)-\(width).png")); screenshots += 1
        }
      }
    }
    }
    await transport.approve(); try await waitFor { !hosting.authorizing }
    guard hosting.metadata.accounts.count == metadata.accounts.count, hosting.error == nil else { throw GitPierError.invalidInput("Duplicate account OAuth did not preserve stable identity") }
    account = try XCTHostingUnwrap(hosting.account(account.id))
    try await show(HostingSettingsView(hosting: hosting), name: "hosting-mock-oauth-success", width: 960, height: 640)
    let initial = HostingCreateDraft(sourceRepository: binding.repository, source: state.branch, target: "develop", title: "Add native hosting collaboration", body: "Synthetic API creation only.")
    try await show(HostingCreateSheet(hosting: hosting, model: model, binding: binding, account: account, initialDraft: initial), name: "hosting-mock-create-ready", width: 960, height: 640)
    try pressNativeButton(host, title: store.text("Review…", "审查…")); try await settle()
    try pressNativeButton(host, title: store.text("Confirm & Create", "确认并创建")); try await settle()
    guard await transport.postCount() == 1 else { throw GitPierError.invalidInput("Confirmed creation did not issue exactly one mock POST") }
    try await captureHostingWindow(window, to: output.appendingPathComponent("hosting-mock-created.png")); screenshots += 1
    guard try Data(contentsOf: indexURL) == originalIndex, try await git.status(localOnly: true).head == head,
      try await git.remotes() == originalRemotes, model.record.draft == originalDraft else { throw GitPierError.invalidInput("Hosting changed Git state") }
    // Real local files, injected Keychain: exercise native confirmation, both directions and restart.
    settings.language = .english; settings.appearance = .light; store.updateSettings(settings)
    let originalModes = hosting.metadata.accounts.map(\.storageMode)
    hosting.setDefaultStorage(.keychain)
    guard hosting.metadata.accounts.map(\.storageMode) == originalModes else { throw HostingError.accountChanged }
    // Duplicate connection from the new-account entry preserves an existing account's actual mode.
    try await hosting.connectPAT(instance: glAccount.instance, secret: "synthetic-reconnected-pat", storageMode: .localVault)
    guard hosting.account(glAccount.id)?.storageMode == .keychain,
      hosting.metadata.accounts.count == metadata.accounts.count else { throw HostingError.accountChanged }
    let current = try XCTHostingUnwrap(hosting.account(account.id))
    try await show(HostingStorageSheet(hosting: hosting, account: current), name: "hosting-storage-confirm-to-keychain", width: 960, height: 640)
    try pressNativeButton(host, title: "Confirm Change")
    try await waitFor { hosting.account(account.id)?.storageMode == .keychain && hosting.busy.isEmpty }
    let inKeychain = try XCTHostingUnwrap(hosting.account(account.id))
    guard try await local.read(account: current) == nil, hosting.binding(record.id) == binding else { throw HostingError.accountChanged }
    try await show(HostingStorageSheet(hosting: hosting, account: inKeychain), name: "hosting-storage-confirm-to-local", width: 960, height: 640)
    try pressNativeButton(host, title: "Confirm Change")
    try await waitFor { hosting.account(account.id)?.storageMode == .localVault && hosting.busy.isEmpty }
    let inLocal = try XCTHostingUnwrap(hosting.account(account.id))
    guard inLocal.pendingCleanup.contains(.keychain) else { throw HostingError.storageFailure }
    let restarted = HostingModel(store: store, http: http, vault: vault, publicConfiguration: publicConfiguration, openExternalURL: { _ in true })
    defer { restarted.shutdown() }
    let restored = try await restarted.tokens.token(for: inLocal)
    guard restored.accessToken == "synthetic-hosting-token", restarted.binding(record.id) == binding,
      restarted.metadata.defaultStorageMode == .keychain, restarted.states[glAccount.id] == .credentialsLocked else { throw HostingError.accountChanged }
    try await hosting.cleanupCredential(inLocal, mode: .keychain)
    let clean = try XCTHostingUnwrap(hosting.account(account.id))
    guard clean.pendingCleanup.isEmpty, try await keychain.read(account: clean) == nil else { throw HostingError.storageFailure }
    try await show(HostingSettingsView(hosting: hosting), name: "hosting-storage-migrated-and-cleaned", width: 960, height: 640)
    let recoveryStore = AppStore(persistence: ConfigurationStore(url: fixture.appendingPathComponent("recovery/workspace.json")))
    let recovery = HostingModel(store: recoveryStore, http: http, vault: vault, publicConfiguration: publicConfiguration, openExternalURL: { _ in true })
    recoveryStore.hosting = recovery
    defer { recoveryStore.shutdown() }
    try await recovery.connectPAT(instance: metadata.accounts[0].instance, secret: "synthetic-local-pat")
    let localPAT = try XCTHostingUnwrap(recovery.metadata.accounts.first)
    guard localPAT.storageMode == .localVault, await keychain.readCount(localPAT.id) == 0 else { throw HostingError.storageFailure }
    recovery.setDefaultStorage(.keychain); await keychain.deny(true)
    try await recovery.connectPAT(instance: metadata.accounts[2].instance, secret: "synthetic-session-only-pat")
    let transient = try XCTHostingUnwrap(recovery.metadata.accounts.first { $0.instance.provider == .gitea })
    guard transient.credentialRecoveryRequired, recovery.credentialWarnings[transient.id] != nil,
      try await recovery.tokens.token(for: transient).accessToken == "synthetic-session-only-pat" else { throw HostingError.storageFailure }
    let recoveryRestart = HostingModel(store: recoveryStore, http: http, vault: vault, publicConfiguration: publicConfiguration, openExternalURL: { _ in true })
    defer { recoveryRestart.shutdown() }
    guard recoveryRestart.states[transient.id] == .reauthorize else { throw HostingError.storageFailure }
    await keychain.deny(false)
    for language in [AppLanguage.english, .simplifiedChinese] {
      for appearance in [AppearanceMode.light, .dark] {
        var active = store.settings; active.language = language; active.appearance = appearance; store.updateSettings(active)
        var settings = recoveryStore.settings; settings.language = language; settings.appearance = appearance; recoveryStore.updateSettings(settings)
        try await show(HostingSettingsView(hosting: recovery).environmentObject(recoveryStore), name: "hosting-storage-session-only-\(language.rawValue)-\(appearance.rawValue)", width: 960, height: 640)
      }
    }
    let result: [String: Any] = ["duplicateConnectPreservedExistingMode": true, "storageOnly": storageOnly, "defaultLocalPATWithoutKeychain": true, "failedPersistenceSessionAndRecoveryMarker": true, "nativeStorageConfirmBothDirections": true, "localFilesRestartRestored": true, "keychainBackend": "injected synthetic store", "existingModesUnaffectedByDefault": true, "bindingsPreservedAcrossMigration": true, "explicitPreviousCopyCleanup": true, "screenshots": screenshots, "fixture": "injected mock OAuth/API; no real browser login", "nativeCopyCode": true, "githubAutomaticBrowserOpen": true, "officialLogosLoaded": true, "pkceCallbackMock": true, "createReviewDidNotPOST": true, "confirmedMockPOST": 1, "gitIndexHeadRemotesDraftPreserved": true, "realOAuthVerified": false]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("hosting-results.json"))
    try await verifyHostingDisconnect(root: root, output: output)
    try await verifyHostingDetailStability(root: root, output: output)
    if ProcessInfo.processInfo.environment["GITPIER_UI_ACCEPTANCE_INTERACTIVE_HOSTING"] == "1" {
      let page = ProcessInfo.processInfo.environment["GITPIER_UI_ACCEPTANCE_INTERACTIVE_HOSTING_PAGE"]
      if page == "storage" { host.rootView = AnyView(HostingSettingsView(hosting: hosting).environmentObject(store).modifier(AppAppearance(store: store))) }
      else if page == "accounts" { host.rootView = AnyView(HostingSettingsView(hosting: emptyHosting).environmentObject(store).modifier(AppAppearance(store: store))) }
      else { host.rootView = AnyView(HostingWorkspaceView(model: model).environmentObject(store).modifier(AppAppearance(store: store))) }
      window.setContentSize(page == "storage" ? NSSize(width: 960, height: 640) : NSSize(width: 1440, height: 900)); window.center(); try await settle()
      try Data("ready".utf8).write(to: output.appendingPathComponent("gui-ready"))
      while !FileManager.default.fileExists(atPath: output.appendingPathComponent("finish-gui").path) { try await Task.sleep(for: .milliseconds(250)) }
    }
  }
  static func XCTHostingUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw GitPierError.invalidInput("Missing synthetic hosting fixture value") }; return value
  }
  static func captureHostingWindow(_ window: NSWindow, to url: URL) async throws {
    // SwiftUI's render-server content is absent from NSView.cacheDisplay on newer macOS.
    // Capture this disposable window through WindowServer, including its real native controls.
    _ = try await ProcessRunner().run(executable: "/usr/sbin/screencapture", arguments: ["-x", "-o", "-l", String(window.windowNumber), url.path], directory: nil, timeout: 15)
    guard let data = try? Data(contentsOf: url), let image = NSBitmapImageRep(data: data), image.pixelsWide > 0, image.pixelsHigh > 0 else { throw GitPierError.invalidInput("Native hosting window screenshot failed") }
  }
  private static func hostingTextFieldValues(_ host: NSView) -> [String] {
    var visited = Set<ObjectIdentifier>(); var values: [String] = []
    func walk(_ object: Any, depth: Int = 0) {
      guard depth < 80, let object = object as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { return }
      func get(_ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
      }
      if get("accessibilityRole") as? String == "AXTextField", let value = get("accessibilityValue") as? String { values.append(value) }
      for child in get("accessibilityChildren") as? [Any] ?? [] { walk(child, depth: depth + 1) }
      if let view = object as? NSView { for child in view.subviews { walk(child, depth: depth + 1) } }
    }
    walk(host); return values
  }
}
