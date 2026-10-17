import AppKit
import GitPierCore
import SwiftUI

/// Explicit, isolated real-provider acceptance. Never selected by a normal application launch.
actor HostingLiveKeychainProbe: HostingCredentialStore {
  private let backend: HostingKeychainStore
  private var counts = ["read": 0, "save": 0, "replace": 0, "delete": 0]
  init(service: String) { backend = HostingKeychainStore(service: service) }
  func read(account: HostingAccount) async throws -> HostingToken? {
    counts["read", default: 0] += 1; return try await backend.read(account: account)
  }
  func save(_ token: HostingToken, account: HostingAccount) async throws {
    counts["save", default: 0] += 1; try await backend.save(token, account: account)
  }
  func replace(_ token: HostingToken, account: HostingAccount) async throws {
    counts["replace", default: 0] += 1; try await backend.replace(token, account: account)
  }
  func delete(account: HostingAccount) async throws {
    counts["delete", default: 0] += 1; try await backend.delete(account: account)
  }
  func snapshot() -> [String: Int] { counts }
}

@MainActor final class HostingLiveAcceptanceController: ObservableObject {
  let store: AppStore
  let hosting: HostingModel
  let probe: HostingLiveKeychainProbe
  let root: URL
  @Published var status = "Real provider endpoints. Approve authorization in the browser yourself."
  @Published var checking = false
  init(root: URL) throws {
    self.root = root
    let store = AppStore.shared
    self.store = store
    probe = HostingLiveKeychainProbe(service: "GitPier.hosting.oauth.acceptance." + root.lastPathComponent)
    let router = HostingCredentialRouter(local: LocalEncryptedCredentialStore(root: root.appendingPathComponent("HostingCredentials")), keychain: probe)
    hosting = HostingModel(store: store, vault: router)
    store.hosting = hosting
  }
  func checkpoint() async {
    guard !checking else { return }; checking = true; defer { checking = false }
    var accounts: [[String: Any]] = []
    var verified = 0
    for account in hosting.metadata.accounts {
      var row: [String: Any] = ["id": account.id.uuidString, "provider": account.instance.provider.rawValue,
        "login": account.user.login, "mode": account.storageMode.rawValue, "kind": account.kind.rawValue,
        "pendingCleanup": account.pendingCleanup.map(\.rawValue)]
      do {
        let token = try await hosting.tokens.token(for: account)
        let api = hosting.api
        let user = try await hosting.performAPI(account: account) { try await api.user(instance: account.instance, token: token) }
        guard hosting.account(account.id) == account else { throw HostingError.accountChanged }
        let matches = user.stableID == account.user.stableID
        row["currentUserVerified"] = matches
        if matches { verified += 1 }
        row["hasRefreshToken"] = token.refreshToken != nil
        row["expiresAt"] = token.expiresAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none"
      } catch { row["error"] = (error as? HostingError)?.rawValue ?? "requestFailed" }
      // Pointers contain public generation IDs, never the key or encrypted token data.
      let pointer = root.appendingPathComponent("HostingCredentials/vault/" + account.id.uuidString + ".json")
      if let data = try? Data(contentsOf: pointer), let object = try? JSONSerialization.jsonObject(with: data) { row["vaultPointer"] = object }
      accounts.append(row)
    }
    let report: [String: Any] = ["realOAuthTransport": true, "mockTransport": false,
      "timestamp": ISO8601DateFormatter().string(from: Date()), "processID": ProcessInfo.processInfo.processIdentifier,
      "accounts": accounts, "keychainCallsThisProcess": await probe.snapshot()]
    do {
      let url = root.appendingPathComponent("checkpoint-" + UUID().uuidString + ".json")
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
      status = "Checkpoint saved: \(verified)/\(accounts.count) identities verified. No secrets exported."
    } catch { status = "Checkpoint could not be saved." }
  }
}

private struct HostingLiveAcceptanceView: View {
  @ObservedObject var controller: HostingLiveAcceptanceController
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading) {
          Text("GitPier 1.5.1 — Isolated Real OAuth Acceptance").font(.headline)
          Text(controller.status).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Verify & Save Checkpoint") { Task { await controller.checkpoint() } }.disabled(controller.checking)
        Button("Quit Test App") { controller.store.shutdown(); NSApp.terminate(nil) }
      }.padding(12)
      Divider()
      TabView {
        HostingSettingsView(hosting: controller.hosting).tabItem { Text("Code Hosting") }
        RootView().tabItem { Text("Test Repositories") }
      }
    }.environmentObject(controller.store).modifier(AppAppearance(store: controller.store))
  }
}

extension UIAcceptance {
  static func runLiveHostingAcceptance() async throws {
    guard let path = ProcessInfo.processInfo.environment["GITPIER_WORKSPACE_FILE"] else { throw HostingError.invalidInstance }
    let root = URL(fileURLWithPath: path).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let controller = try HostingLiveAcceptanceController(root: root)
    let repositories = root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("test-repositories")
    for name in ["github", "gitlab", "gitea"] {
      let path = repositories.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: path.appendingPathComponent(".git").path),
        !controller.store.configuration.repositories.contains(where: { $0.path == path.path }) {
        await controller.store.addRepository(path)
      }
    }
    let host = NSHostingView(rootView: HostingLiveAcceptanceView(controller: controller))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.title = "GitPier Isolated OAuth Acceptance"
    window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    try Data("ready".utf8).write(to: root.appendingPathComponent("ready"), options: .atomic)
    // Keep the native window/controller alive while the user approves real browser grants.
    while !FileManager.default.fileExists(atPath: root.appendingPathComponent("finish").path) {
      try await Task.sleep(for: .milliseconds(250))
    }
    await controller.checkpoint(); controller.store.shutdown(); window.close(); NSApp.terminate(nil)
  }
}
