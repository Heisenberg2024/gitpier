import AppKit
import GitPierCore
import Security
import SwiftUI

extension UIAcceptance {
  static func verifyVersion144(root source: URL, output: URL) async throws {
    let env = ProcessInfo.processInfo.environment
    guard source.resolvingSymlinksInPath().deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui."),
      let remoteURL = env["GITPIER_AUTH_ACCEPTANCE_URL"], remoteURL.hasPrefix("https://127.0.0.1:"),
      let cert = env["GITPIER_AUTH_ACCEPTANCE_CERT"], cert.hasPrefix("/private/tmp/GitPier-auth-ui.") else {
      throw GitPierError.invalidInput("Authentication acceptance requires the isolated TLS fixture script")
    }
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-auth-native-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let root = fixture.appendingPathComponent("repository")
    _ = try await GitService(root: source).perform(["clone", "--", source.path, root.path])
    let git = GitService(root: root)
    _ = try await git.perform(["remote", "set-url", "origin", remoteURL])
    _ = try await git.perform(["config", "http.sslCAInfo", cert])
    let parts = URLComponents(string: remoteURL)!
    let profile = CredentialProfile(name: "Synthetic acceptance", host: "127.0.0.1:\(parts.port!)", username: "alice")
    try KeychainStore().save("gitpier-synthetic-token", id: profile.id)
    defer { try? KeychainStore().delete(id: profile.id) }
    var record = RepositoryRecord(path: root.path)
    record.useDefaultCredential = true
    var configuration = WorkspaceConfiguration()
    configuration.repositories = [record]; configuration.selectedRepository = record.id
    configuration.credentials = [profile]; configuration.settings.defaultCredentialID = profile.id
    configuration.settings.remoteCheckScope = "current"
    let persistence = ConfigurationStore(url: fixture.appendingPathComponent("workspace.json"))
    try persistence.save(configuration)
    let store = AppStore(persistence: persistence)
    defer { store.shutdown() }
    let model = store.models[record.id]!
    let host = NSHostingView(rootView: AnyView(SettingsView(initialTab: 2).environmentObject(store).modifier(AppAppearance(store: store))))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    window.title = "GitPier 1.4.4 · Disposable Authentication Fixture"
    NSApp.setActivationPolicy(.regular); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    defer { host.rootView = AnyView(EmptyView()); window.close() }
    try await waitFor { store.workspace.entries[record.id]?.state == .fresh }
    await model.activate()
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    model.setPage("history"); model.editDraft("Preserved authentication acceptance draft")
    func enable(_ value: Bool) { var settings = store.settings; settings.automaticFetch = value; store.updateSettings(settings) }
    enable(true)
    try await waitFor { store.workspace.remoteCheck(record.id).lastSuccess != nil }
    guard store.workspace.authenticationInfo(record.id)?.source == "managedKeychain",
      store.workspace.fetchJobs.isEmpty, model.record.draft == "Preserved authentication acceptance draft",
      model.page == "history", try Data(contentsOf: root.appendingPathComponent(".git/index")) == index else {
      throw GitPierError.invalidInput("First managed/default automatic HTTPS Fetch changed session data or used manual Fetch")
    }
    print("v144: packaged default managed credential first automatic HTTPS Fetch passed")
    enable(false); await store.workspace.stopAutomaticChecks()
    let repositoryProfile = CredentialProfile(name: "Independent synthetic account", host: profile.host, username: "alice")
    try store.saveCredential(repositoryProfile, token: "gitpier-synthetic-token")
    defer { try? KeychainStore().delete(id: repositoryProfile.id) }
    // A valid default must not mask a broken repository binding in this test.
    try KeychainStore().save("invalid-synthetic-default", id: profile.id)
    record = model.record; record.credentialID = repositoryProfile.id; record.useDefaultCredential = false; model.record = record; store.update(record)
    _ = await model.configure()
    let independentTarget = try await model.git().upstreamFetchTarget(record)!
    await store.workspace.refresh([record.id])
    try await waitFor { store.workspace.entries[record.id]?.usable?.remoteTarget?.id == independentTarget.id }
    let beforeRetry = store.workspace.remoteCheck(record.id).lastSuccess
    enable(true); store.workspace.retryAuthentication(record.id)
    try await waitFor { store.workspace.remoteCheck(record.id).lastSuccess != beforeRetry && !store.workspace.authenticationIsBusy(record.id) }
    print("v144: repository credential and Retry recovered without manual Fetch")
    enable(false); await store.workspace.stopAutomaticChecks()
    let internet: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
      kSecAttrServer as String: "127.0.0.1", kSecAttrPort as String: parts.port!,
      kSecAttrProtocol as String: kSecAttrProtocolHTTPS, kSecAttrAuthenticationType as String: kSecAttrAuthenticationTypeDefault,
      kSecAttrAccount as String: "alice"]
    var add = internet; add[kSecValueData as String] = Data("gitpier-synthetic-token".utf8)
    guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw GitPierError.invalidInput("Synthetic Internet Password fixture unavailable") }
    defer { SecItemDelete(internet as CFDictionary) }
    _ = try await git.perform(["config", "credential.helper", "osxkeychain"])
    record = model.record; record.credentialID = nil; record.useDefaultCredential = false; model.record = record; store.update(record)
    _ = await model.configure(); await store.workspace.refresh([record.id])
    enable(true)
    try await waitFor { store.workspace.remoteCheck(record.id).lastSuccess != nil && store.workspace.authenticationInfo(record.id)?.source == "systemKeychain" }
    print("v144: packaged system Keychain first automatic HTTPS Fetch passed")
    enable(false); await store.workspace.stopAutomaticChecks()
    // A separate synthetic ACL-blocked item must never produce authorization UI in background.
    let blockedHost = "gitpier-native-blocked-" + UUID().uuidString.lowercased() + ".invalid"
    var access: SecAccess?
    guard SecAccessCreate("GitPier synthetic ACL refusal" as CFString, [] as CFArray, &access) == errSecSuccess, let access else { throw GitPierError.invalidInput("Synthetic ACL unavailable") }
    let blocked: [String: Any] = [kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: blockedHost,
      kSecAttrPort as String: 0, kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
      kSecAttrAuthenticationType as String: kSecAttrAuthenticationTypeDefault, kSecAttrAccount as String: "alice"]
    var blockedAdd = blocked; blockedAdd[kSecAttrAccess as String] = access; blockedAdd[kSecValueData as String] = Data("synthetic-blocked".utf8)
    guard SecItemAdd(blockedAdd as CFDictionary, nil) == errSecSuccess else { throw GitPierError.invalidInput("Synthetic blocked item unavailable") }
    defer { SecItemDelete(blocked as CFDictionary) }
    _ = try await git.perform(["remote", "set-url", "origin", "https://alice@" + blockedHost + "/repo.git"])
    await store.workspace.refresh([record.id])
    // Workspace refresh requests collection; it does not await publication of a new snapshot.
    try await waitFor { store.workspace.entries[record.id]?.usable?.remoteTarget?.remote.fetchURL.contains(blockedHost) == true }
    store.workspace.retryAuthentication(record.id)
    try await waitFor { store.workspace.authenticationInfo(record.id)?.state == .requiresForegroundAuthorization && !store.workspace.authenticationIsBusy(record.id) }
    let scrolls = descendants(host).compactMap { $0 as? NSScrollView }
    for scroll in scrolls {
      if let document = scroll.documentView { document.scroll(NSPoint(x: 0, y: document.bounds.height)); scroll.reflectScrolledClipView(scroll.contentView) }
    }
    for language in [AppLanguage.english, .simplifiedChinese] {
      for appearance in [AppearanceMode.light, .dark] {
        var settings = store.settings; settings.language = language; settings.appearance = appearance; store.updateSettings(settings)
        try await settle()
        let name = "v144-\(language.rawValue)-\(appearance.rawValue)"
        try capture(host, to: output.appendingPathComponent(name + ".png"))
        try accessibilityLabels(host).write(to: output.appendingPathComponent(name + "-ax.txt"), atomically: true, encoding: .utf8)
      }
    }
    print("v144: ACL refusal, retry and bilingual settings rendered; no foreground ACL approval automated")
    if env["GITPIER_UI_ACCEPTANCE_INTERACTIVE_V144"] == "1" {
      let finish = output.appendingPathComponent("finish-gui")
      try Data("Disposable authentication fixture ready\n".utf8).write(to: output.appendingPathComponent("ready-gui"))
      while !FileManager.default.fileExists(atPath: finish.path) { try await Task.sleep(for: .milliseconds(250)) }
    }
    try Data("Managed default/repository and system Keychain first automatic HTTPS Fetch; Retry; unchanged Index/draft/page; ACL refusal and bilingual settings passed. Foreground ACL approval, cross-version ACL transfer and real private servers are not claimed.\n".utf8).write(to: output.appendingPathComponent("v144-results.txt"))
  }
}
