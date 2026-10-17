import AppKit
import GitPierCore
import SwiftUI

@MainActor private final class HostingCredentialEvents {
  weak var model: HostingModel?
  func failed(_ account: HostingAccount) { model?.markSessionOnly(account) }
}

/// Uses the user's ordinary browser and the application's registered URL callback.
@MainActor final class HostingBrowserSession {
  private var callback: OAuthBrowserCallback?
  func authorize(_ session: OAuthPKCESession, scopes: [String], openURL: @MainActor (URL) -> Bool) async throws -> URL {
    guard callback == nil else { throw HostingError.operationInProgress }
    try Task.checkCancellation()
    let receiver = OAuthBrowserCallback(session: session)
    callback = receiver
    let anchor = NSApp.keyWindow
    defer { if callback === receiver { callback = nil } }
    guard openURL(try session.authorizationURL(scopes: scopes)) else { await receiver.cancel(); throw HostingError.unsupported }
    let url = try await receiver.wait()
    try Task.checkCancellation()
    anchor?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    return url
  }
  func receive(_ url: URL) async -> Bool {
    guard let callback else { return false }
    return await callback.receive(url)
  }
  func cancel() {
    let previous = callback; callback = nil
    Task { await previous?.cancel() }
  }
}

@MainActor final class HostingModel: ObservableObject {
  @Published private(set) var metadata = HostingMetadata()
  @Published private(set) var states: [UUID: HostingAccountState] = [:]
  @Published private(set) var busy: Set<UUID> = []
  @Published private(set) var authorizing = false
  @Published private(set) var credentialWarnings: [UUID: String] = [:]
  @Published var device: GitHubDeviceAuthorization?
  @Published var error: String?
  @Published private(set) var revision = UUID()
  let api: HostingAPIClient
  let oauth: OAuthAuthorizationCoordinator
  let tokens: OAuthTokenManager
  let cache = HostingAPICache()
  let detailCache = HostingRequestDetailCache()
  let publicConfiguration: HostingOAuthConfiguration
  private let persistence: HostingMetadataStore
  private var canSave = true
  private var authorization: Task<Void, Never>?
  private var authorizationID: UUID?
  private var connectionRevision = UUID()
  private var loopback: OAuthLoopbackListener?
  private let browser = HostingBrowserSession()
  private let openExternalURL: @MainActor (URL) -> Bool
  private var accountTasks: [UUID: Task<Void, Never>] = [:]
  private var accountTaskIDs: [UUID: UUID] = [:]
  private var apiCancellations: [UUID: [UUID: () -> Void]] = [:]
  private var connectionCancellations: [UUID: () -> Void] = [:]
  // A separate API budget never consumes the local Git scan/Fetch budget.
  let networkBudget = WorkspaceOperationBudget(limit: 2)
  private var signalCache: [String: (Date, HostingRequestSignals)] = [:]
  unowned let store: AppStore
  init(store: AppStore, http: HostingHTTPClient = HostingHTTPClient(), vault: (any HostingCredentialStore)? = nil, publicConfiguration: HostingOAuthConfiguration? = nil,
    openExternalURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
    self.store = store
    self.openExternalURL = openExternalURL
    api = HostingAPIClient(http: http); oauth = OAuthAuthorizationCoordinator(http: http)
    let events = HostingCredentialEvents()
    tokens = OAuthTokenManager(vault: vault ?? HostingCredentialRouter(root: store.persistence.url.deletingLastPathComponent().appendingPathComponent("HostingCredentials")), oauth: oauth,
      persistenceFailed: { account in await events.failed(account) })
    persistence = HostingMetadataStore(url: store.persistence.url.deletingPathExtension().appendingPathExtension("hosting.json"))
    self.publicConfiguration = publicConfiguration ?? Self.loadConfiguration()
    do {
      metadata = try persistence.load()
      states = Dictionary(uniqueKeysWithValues: metadata.accounts.map { ($0.id, $0.credentialRecoveryRequired ? .reauthorize : $0.storageMode == .localVault ? .connected : .credentialsLocked) })
    } catch { canSave = false; self.error = message(error) }
    events.model = self
  }
  static func loadConfiguration() -> HostingOAuthConfiguration {
    guard let url = AppResources.bundle.url(forResource: "HostingOAuthConfiguration", withExtension: "json"),
      let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(HostingOAuthConfiguration.self, from: data) else { return HostingOAuthConfiguration() }
    return config
  }
  func message(_ error: Error) -> String {
    guard store.settings.language != .english, let e = error as? HostingError else { return error.localizedDescription }
    switch e {
    case .missingClientID: return "维护者尚未配置公共 OAuth Client ID，可使用 PAT 备用方式。"
    case .invalidInstance: return "请输入不含凭证、查询参数或片段的 HTTPS 实例地址。"
    case .unsupported: return "此实例或版本不支持所选 OAuth 能力，请使用 PAT。"
    case .invalidCallback: return "OAuth 回调与当前授权会话不匹配。"
    case .expired: return "授权已过期，请重新开始。"
    case .denied: return "用户拒绝了授权。"
    case .invalidClient: return "实例拒绝了公共 Client ID 或回调配置。"
    case .deviceDisabled: return "此 GitHub OAuth 应用尚未启用 Device Flow。"
    case .invalidResponse: return "托管平台返回了无效响应。"
    case .insecureURL: return "目标不属于此账号已授权的 HTTPS 实例。"
    case .redirectRejected: return "已拒绝 HTTP 重定向，请检查实例地址。"
    case .responseTooLarge: return "内容超过预览上限，请在浏览器中打开。"
    case .unauthorized: return "Token 无效或已过期，请重新授权。"
    case .permissionRequired: return "需要权限，请检查 Scope 并主动重新授权。"
    case .scopeConflict: return "Gitea 已有不同 Scope 的授权。请自行在平台应用设置中处理旧授权，或使用独立 OAuth Client / PAT。GitPier 不会自动撤销授权，当前会话已保留。"
    case .notFound: return "内容不存在，或此账号没有私有仓库访问权限。"
    case .rateLimited: return "已达到平台请求限额，请稍后重试。"
    case .serverFailure: return "托管平台暂时不可用。"
    case .networkFailure: return "平台请求失败，请检查网络和系统证书信任。"
    case .credentialsLocked: return "请先点击“验证连接”解锁此账号，再读取平台数据。"
    case .keychainDenied: return "钥匙串访问被拒绝或取消，原凭证已保留。"
    case .vaultCorrupt: return "本地凭证或密钥缺失、损坏或与账号不匹配，请重新授权此账号。"
    case .vaultUnavailable: return "本地凭证目录不可用，或归属、权限、链接不安全；原文件已保留。"
    case .sessionOnly: return "凭证仅在当前会话有效：保存失败，请在退出前重新授权。重启可能需要再次授权。"
    case .storageFailure: return "无法保存托管账号元数据或凭证。"
    case .configurationUnreadable: return "无法读取托管配置，原文件已保留。"
    case .accountChanged: return "账号或仓库关联已改变，请重新审查。"
    case .pushRequired: return "请先通过 Git 推送当前来源分支，再创建请求；不会自动推送。"
    case .branchMissing: return "所选平台仓库不存在来源分支或目标分支。"
    case .duplicateRequest: return "这些分支已有打开的请求。"
    case .operationInProgress: return "请先完成当前操作。"
    case .creationUnknown: return "请求可能已创建，请先刷新并检查是否已有对应请求，再尝试创建。"
    }
  }
  func stateTitle(_ state: HostingAccountState) -> String {
    switch state {
    case .connected: store.text("Connected", "已连接")
    case .credentialsLocked: store.text("Verify to Unlock", "验证以解锁")
    case .expired: store.text("Token Expired", "Token 已过期")
    case .reauthorize: store.text("Reauthorize", "需要重新授权")
    case .permissionRequired: store.text("Permission Required", "需要权限")
    case .networkFailure: store.text("Network Error", "网络错误")
    case .keychainDenied: store.text("Keychain Access Denied", "钥匙串访问被拒绝")
    }
  }
  private func persist(_ value: HostingMetadata) throws {
    guard canSave else { throw HostingError.configurationUnreadable }
    try persistence.save(value); metadata = value; revision = UUID()
  }
  func saveConfiguration(_ configuration: OAuthConfiguration) throws {
    try configuration.validate()
    var value = metadata; value.configurations.removeAll { $0.id == configuration.id }; value.configurations.append(configuration)
    try persist(value)
  }
  func account(_ id: UUID) -> HostingAccount? { metadata.accounts.first { $0.id == id } }
  func openAuthorizationPage(_ url: URL) {
    error = openExternalURL(url) ? nil : store.text("Could not open the browser. Use Open GitHub to try again.", "无法打开浏览器，请点击“打开 GitHub”重试。")
  }
  func binding(_ id: UUID) -> RepositoryHostingBinding? { metadata.bindings.first { $0.repositoryID == id } }
  /// Own each account's API task so disconnect can cancel transport even while its view stays open.
  func performAPI<T: Sendable>(account: HostingAccount, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    guard self.account(account.id) == account else { throw HostingError.accountChanged }
    try Task.checkCancellation()
    let id = UUID(), task = Task { try await operation() }
    apiCancellations[account.id, default: [:]][id] = { task.cancel() }
    defer {
      apiCancellations[account.id]?[id] = nil
      if apiCancellations[account.id]?.isEmpty == true { apiCancellations[account.id] = nil }
    }
    let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    try Task.checkCancellation()
    guard self.account(account.id) == account else { throw HostingError.accountChanged }
    return result
  }
  private func cancelAPI(_ id: UUID) {
    let tasks = apiCancellations.removeValue(forKey: id) ?? [:]
    for cancel in tasks.values { cancel() }
  }
  func connect(configuration: OAuthConfiguration, level: HostingAuthorizationLevel, reauthorizing: HostingAccount? = nil, storageMode: HostingStorageMode? = nil) {
    guard !authorizing, canSave else { return }
    error = nil; authorizing = true; device = nil
    let id = UUID(); authorizationID = id
    authorization = Task { [weak self] in
      guard let self else { return }
      defer { if authorizationID == id { authorizing = false; device = nil; authorization = nil; authorizationID = nil } }
      do {
        try configuration.validate()
        let scopes = level.scopes(for: configuration.instance.provider)
        let token: HostingToken
        if configuration.instance.provider == .github {
          token = try await oauth.github(configuration: configuration, scopes: scopes) { [weak self] device in
            await MainActor.run {
              guard let self, self.authorizationID == id else { return }
              self.device = device
              self.openAuthorizationPage(device.verificationURL)
            }
          }
        } else {
          if configuration.instance.provider == .gitea, try await !oauth.giteaSupportsGranularScopes(configuration.instance) { throw HostingError.unsupported }
          var session: OAuthPKCESession
          let callback: URL
          switch configuration.redirect {
          case .application:
            session = try OAuthPKCESession(configuration: configuration, redirectURL: URL(string: configuration.redirect.registrationURL(for: configuration.instance.provider))!)
            callback = try await browser.authorize(session, scopes: scopes, openURL: openExternalURL)
          case .loopback(let port):
            let listener = OAuthLoopbackListener(); loopback = listener
            let actual = try await listener.start(port: port)
            let redirect = URL(string: "http://127.0.0.1:\(actual)/oauth/\(configuration.instance.provider.rawValue)/callback")!
            session = try OAuthPKCESession(configuration: configuration, redirectURL: redirect)
            try await listener.configure(session)
            guard openExternalURL(try session.authorizationURL(scopes: scopes)) else { await listener.cancel(); throw HostingError.unsupported }
            do { callback = try await listener.callback() } catch { await listener.cancel(); throw error }
            if authorizationID == id { loopback = nil }
          }
          let code = try session.consume(callback)
          token = try await oauth.exchange(session: session, code: code, scopes: scopes)
        }
        try Task.checkCancellation(); guard authorizationID == id else { throw CancellationError() }
        try await finishConnect(token: token, instance: configuration.instance, kind: .oauth, configuration: configuration, expected: reauthorizing, storageMode: storageMode)
      } catch is CancellationError {} catch { if authorizationID == id { self.error = message(error) } }
      if authorizationID == id, let listener = loopback { loopback = nil; await listener.cancel() }
    }
  }
  func connectPAT(instance: HostingInstance, secret: String, expected: HostingAccount? = nil, storageMode: HostingStorageMode? = nil) async throws {
    guard canSave else { throw HostingError.configurationUnreadable }
    guard !secret.isEmpty, secret.count <= 16384 else { throw HostingError.invalidResponse }
    try await finishConnect(token: HostingToken(accessToken: secret, tokenType: instance.provider == .gitea ? "token" : "bearer"), instance: instance, kind: .pat, configuration: nil, expected: expected, storageMode: storageMode)
  }
  private func finishConnect(token: HostingToken, instance: HostingInstance, kind: HostingAuthenticationKind, configuration: OAuthConfiguration?, expected: HostingAccount?, storageMode: HostingStorageMode?) async throws {
    let connectionTicket = connectionRevision
    let api = api, userTask = Task { try await api.user(instance: instance, token: token) }, connectionID = UUID()
    connectionCancellations[connectionID] = { userTask.cancel() }
    defer { connectionCancellations[connectionID] = nil }
    let user = try await withTaskCancellationHandler { try await userTask.value } onCancel: { userTask.cancel() }
    try Task.checkCancellation()
    guard connectionRevision == connectionTicket else { throw HostingError.accountChanged }
    if let expected, expected.instance != instance || expected.user.stableID != user.stableID { throw HostingError.accountChanged }
    let existing = metadata.accounts.first { $0.instance == instance && $0.user.stableID == user.stableID }
    if let expected, self.account(expected.id) != expected { throw HostingError.accountChanged }
    var account = HostingAccount(id: existing?.id ?? UUID(), instance: instance, user: user, kind: kind, scopes: token.scopes, oauth: configuration,
      storageMode: existing?.storageMode ?? storageMode ?? metadata.defaultStorageMode)
    account.pendingCleanup = existing?.pendingCleanup ?? []
    account.pendingMigration = existing?.pendingMigration
    guard !busy.contains(account.id) else { throw HostingError.operationInProgress }
    busy.insert(account.id); defer { busy.remove(account.id) }
    if let existing, expected?.id == existing.id, let storageMode, existing.storageMode != storageMode {
      // A fresh authorization can migrate without reading the old Keychain item.
      do { account = try await migrateCredential(existing, to: storageMode, replacement: token, authorizedAccount: account, allowStoredRead: false) }
      catch HostingError.sessionOnly {
        account.pendingMigration = self.account(account.id)?.pendingMigration
        account.credentialRecoveryRequired = true; credentialWarnings[account.id] = message(HostingError.sessionOnly)
      }
    } else {
      do { try await tokens.install(token, account: account); credentialWarnings[account.id] = nil }
      catch HostingError.sessionOnly { account.credentialRecoveryRequired = true; credentialWarnings[account.id] = message(HostingError.sessionOnly) }
    }
    try Task.checkCancellation()
    guard !metadata.disconnectedAccounts.contains(where: { $0.id == account.id }),
      existing == nil || self.account(account.id) != nil else { throw HostingError.accountChanged }
    var value = metadata; value.accounts.removeAll { $0.id == account.id }; value.accounts.append(account)
    if let configuration { value.configurations.removeAll { $0.id == configuration.id }; value.configurations.append(configuration) }
    do { try persist(value) }
    catch {
      // Keep the validated memory session visible, but never claim metadata was saved.
      metadata = value; revision = UUID(); credentialWarnings[account.id] = message(HostingError.sessionOnly)
    }
    states[account.id] = .connected; await clearCaches(account: account)
  }
  func setDefaultStorage(_ mode: HostingStorageMode) {
    do { var value = metadata; value.defaultStorageMode = mode; try persist(value) }
    catch { self.error = message(error) }
  }
  func changeStorage(_ account: HostingAccount, to mode: HostingStorageMode, allowStoredRead: Bool, cleanup: Bool) async throws {
    guard self.account(account.id) == account, !busy.contains(account.id), !authorizing else { throw HostingError.operationInProgress }
    busy.insert(account.id); defer { busy.remove(account.id) }
    let changed = try await migrateCredential(account, to: mode, replacement: nil, allowStoredRead: allowStoredRead)
    if cleanup { try await cleanupCredential(changed, mode: account.storageMode) }
  }
  private func migrateCredential(_ account: HostingAccount, to mode: HostingStorageMode, replacement: HostingToken?, authorizedAccount: HostingAccount? = nil, allowStoredRead: Bool) async throws -> HostingAccount {
    let changed = try await tokens.migrate(account, to: mode, replacement: replacement, authorizedAccount: authorizedAccount, allowStoredRead: allowStoredRead,
      beforeWrite: { @MainActor [self] in
        guard self.account(account.id) == account else { throw HostingError.accountChanged }
        var value = metadata
        guard let i = value.accounts.firstIndex(where: { $0.id == account.id }) else { throw HostingError.accountChanged }
        value.accounts[i].pendingMigration = mode; try persist(value)
      }, commit: { @MainActor [self] destination in
        guard let current = self.account(account.id), current.identity == account.identity,
          current.storageMode == account.storageMode, current.pendingMigration == mode else { throw HostingError.accountChanged }
        var value = metadata
        guard let i = value.accounts.firstIndex(where: { $0.id == account.id }) else { throw HostingError.accountChanged }
        value.accounts[i] = destination; try persist(value)
      })
    states[changed.id] = .connected; credentialWarnings[changed.id] = nil
    await clearCaches(account: changed)
    return changed
  }
  func cleanupCredential(_ account: HostingAccount, mode: HostingStorageMode) async throws {
    guard self.account(account.id) == account else { throw HostingError.accountChanged }
    try await tokens.cleanup(account, mode: mode)
    guard self.account(account.id) == account else { throw HostingError.accountChanged }
    var value = metadata
    guard let i = value.accounts.firstIndex(where: { $0.id == account.id }) else { throw HostingError.accountChanged }
    value.accounts[i].pendingCleanup.removeAll { $0 == mode }
    if value.accounts[i].pendingMigration == mode { value.accounts[i].pendingMigration = nil }
    try persist(value)
  }
  func receiveOAuthCallback(_ url: URL) async -> Bool { await browser.receive(url) }
  func cancelAuthorization() {
    authorizationID = nil; authorization?.cancel(); authorization = nil; authorizing = false; device = nil; browser.cancel()
    let listener = loopback; loopback = nil
    Task { await listener?.cancel() }
  }
  func verify(_ account: HostingAccount) {
    guard self.account(account.id) == account, !busy.contains(account.id) else { return }; busy.insert(account.id); error = nil
    let taskID = UUID(); accountTaskIDs[account.id] = taskID
    accountTasks[account.id] = Task { [weak self] in
      guard let self else { return }
      defer {
        if accountTaskIDs[account.id] == taskID {
          busy.remove(account.id); accountTasks[account.id] = nil; accountTaskIDs[account.id] = nil
        }
      }
      do {
        try await tokens.unlock(account)
        let token = try await tokens.token(for: account)
        let user = try await api.user(instance: account.instance, token: token)
        guard user.stableID == account.user.stableID, self.account(account.id) == account else { throw HostingError.accountChanged }
        var value = metadata
        if let i = value.accounts.firstIndex(where: { $0.id == account.id }) {
          value.accounts[i].user = user; value.accounts[i].lastVerified = Date(); value.accounts[i].scopes = token.scopes
        }
        try persist(value); states[account.id] = .connected
      } catch {
        guard self.account(account.id) == account, !Task.isCancelled else { return }
        await failed(error, account: account); self.error = message(error)
      }
    }
  }
  func disconnect(_ account: HostingAccount) async throws {
    guard let current = self.account(account.id), current.identity == account.identity else { throw HostingError.accountChanged }
    connectionRevision = UUID(); cancelAuthorization()
    for cancel in connectionCancellations.values { cancel() }; connectionCancellations.removeAll()
    cancelAPI(account.id)
    accountTaskIDs[account.id] = nil
    accountTasks.removeValue(forKey: account.id)?.cancel()
    busy.insert(account.id); defer { busy.remove(account.id) }
    var value = metadata
    value.accounts.removeAll { $0.id == current.id }; value.bindings.removeAll { $0.accountID == current.id }
    value.disconnectedAccounts.removeAll { $0.id == current.id }
    value.disconnectedAccounts.append(HostingDisconnectedAccount(account: current))
    // Publish disconnection before the first suspension. Late UI/API results now fail identity checks.
    metadata = value; states[current.id] = nil; credentialWarnings[current.id] = nil; revision = UUID()
    try await tokens.stopSession(current)
    await clearCaches(account: current)
    await cleanupDisconnected(current.id)
  }
  /// Never loads a credential or restores an account. Each successful deletion is checkpointed;
  /// denied copies stay visible here across restart until the user retries cleanup explicitly.
  func cleanupDisconnected(_ id: UUID) async {
    guard let record = metadata.disconnectedAccounts.first(where: { $0.id == id }) else { return }
    busy.insert(id); defer { busy.remove(id) }
    var metadataFailed = false
    func checkpoint(_ value: HostingMetadata) {
      do { try persist(value); metadataFailed = false }
      catch { metadata = value; revision = UUID(); metadataFailed = true }
    }
    checkpoint(metadata) // Journal all possible copies before attempting deletion.
    var cleanupError: Error?
    do {
      try await tokens.forget(record.account, modes: record.remainingStorage) { @MainActor [self] mode in
        var value = metadata
        guard let i = value.disconnectedAccounts.firstIndex(where: { $0.id == id }) else { return }
        value.disconnectedAccounts[i].remainingStorage.removeAll { $0 == mode }
        checkpoint(value)
      }
    } catch { cleanupError = error }
    var value = metadata
    value.disconnectedAccounts.removeAll { $0.id == id && $0.remainingStorage.isEmpty }
    checkpoint(value)
    if metadataFailed {
      error = store.text("The account is disconnected in this session, but its cleanup record could not be saved. If any credential copy remains, restart may still show the old account. Retry cleanup before quitting. ", "账号在当前会话已断开，但无法保存清理记录。若仍有凭证副本，重启可能再次显示旧账号，请在退出前重试清理。")
        + (cleanupError.map(message) ?? message(HostingError.storageFailure))
    } else if let cleanupError {
      error = store.text("Account disconnected. Credential copies listed below remain for explicit cleanup. ", "账号已断开。下方列出的凭证副本仍需主动清理。") + message(cleanupError)
    } else { error = nil }
  }
  func bind(_ binding: RepositoryHostingBinding, account: HostingAccount) async throws {
    let api = api, tokens = tokens
    try await performAPI(account: account) {
      let token = try await tokens.token(for: account); try Task.checkCancellation()
      try await api.validateRepository(binding, account: account, token: token)
    }
    guard self.account(account.id) == account else { throw HostingError.accountChanged }
    var value = metadata; value.bindings.removeAll { $0.id == binding.id }; value.bindings.append(binding); try persist(value)
  }
  func unbind(_ id: UUID) throws {
    var value = metadata; value.bindings.removeAll { $0.id == id }; try persist(value)
  }
  func requests(_ binding: RepositoryHostingBinding, account: HostingAccount, filter: HostingRequestFilter, page: Int, refresh: Bool) async throws -> HostingPage<HostingPullRequest> {
    let ticket = revision
    do {
      guard binding.accountID == account.id, self.account(account.id) == account else { throw HostingError.accountChanged }
      let token = try await tokens.token(for: account)
      if !refresh, let result = await cache.get(account: account, binding: binding, filter: filter, page: page) { return result }
      let api = api
      let result = try await performAPI(account: account) { try await api.requests(binding, account: account, token: token, filter: filter, page: page) }
      guard revision == ticket, self.account(account.id) == account, self.binding(binding.id) == binding else { throw HostingError.accountChanged }
      await cache.put(result, account: account, binding: binding, filter: filter, page: page); return result
    } catch { await failed(error, account: account); throw error }
  }
  func failed(_ error: Error, account: HostingAccount) async {
    guard self.account(account.id) == account, !busy.contains(account.id) || accountTasks[account.id] != nil else { return }
    switch error as? HostingError {
    case .unauthorized:
      states[account.id] = .reauthorize; revision = UUID(); signalCache.removeAll()
      await tokens.lock(account.id); await cache.clear(account: account)
    case .keychainDenied:
      states[account.id] = .keychainDenied; revision = UUID(); signalCache.removeAll()
      await tokens.lock(account.id); await cache.clear(account: account)
    case .expired:
      states[account.id] = .expired; revision = UUID(); signalCache.removeAll()
      await tokens.lock(account.id); await cache.clear(account: account)
    case .sessionOnly:
      markSessionOnly(account)
    case .vaultCorrupt, .vaultUnavailable:
      states[account.id] = .reauthorize; revision = UUID(); await cache.clear(account: account)
    case .permissionRequired: states[account.id] = .permissionRequired
    case .networkFailure: states[account.id] = .networkFailure
    default: break
    }
  }
  func markSessionOnly(_ account: HostingAccount) {
    guard let current = self.account(account.id), current.identity == account.identity, current.storageMode == account.storageMode else { return }
    states[account.id] = .connected; credentialWarnings[account.id] = message(HostingError.sessionOnly)
    var value = metadata
    guard let i = value.accounts.firstIndex(where: { $0.id == account.id }) else { return }
    value.accounts[i].credentialRecoveryRequired = true
    do { try persist(value) } catch { /* Keep the visible session warning if metadata is also unwritable. */ }
  }
  func signals(_ request: HostingPullRequest, binding: RepositoryHostingBinding, account: HostingAccount) async throws -> HostingRequestSignals {
    let ticket = revision
    let key = account.identity + "|\(account.id)|" + binding.repository + "|\(request.number)|" + request.sha + "|" + request.updatedAt
    if let (date, value) = signalCache[key], Date().timeIntervalSince(date) < 60 { return value }
    let api = api, tokens = tokens
    let budget = networkBudget
    let result = try await performAPI(account: account) { try await budget.perform {
      let token = try await tokens.token(for: account)
      try Task.checkCancellation()
      var result = HostingRequestSignals()
      do { result.checks = try await api.checks(binding, sha: request.sha, account: account, token: token) }
      catch is CancellationError { throw CancellationError() } catch { result.ciError = error as? HostingError ?? .networkFailure }
      do {
        try Task.checkCancellation()
        var page: Int? = 1
        var latest: [String: HostingReview] = [:]
        while let current = page {
          try Task.checkCancellation()
          guard current <= 20 else { throw HostingError.responseTooLarge }
          let reviews = try await api.reviews(binding, number: request.number, account: account, token: token, page: current)
          for review in reviews.items where !review.state.isEmpty && review.state.uppercased() != "COMMENTED" {
            if let old = latest[review.author], (Int64(old.id) ?? 0) > (Int64(review.id) ?? 0) { continue }
            latest[review.author] = review
          }
          page = reviews.nextPage
        }
        result.reviewStates = latest.values.map(\.state)
      } catch is CancellationError { throw CancellationError() } catch { result.reviewError = error as? HostingError ?? .networkFailure }
      return result
    } }
    try Task.checkCancellation()
    guard revision == ticket, self.account(account.id) == account, self.binding(binding.id) == binding else { throw HostingError.accountChanged }
    if result.ciError == .unauthorized || result.reviewError == .unauthorized { await failed(HostingError.unauthorized, account: account); throw HostingError.unauthorized }
    if signalCache.count > 200 { signalCache.removeAll() }; signalCache[key] = (Date(), result); return result
  }
  func clearCaches(account: HostingAccount) async { signalCache.removeAll(); await cache.clear(account: account); await detailCache.clear(account: account) }
  func shutdown() {
    cancelAuthorization(); accountTasks.values.forEach { $0.cancel() }
    for id in Array(apiCancellations.keys) { cancelAPI(id) }
    for cancel in connectionCancellations.values { cancel() }; connectionCancellations.removeAll()
  }
}

struct HostingRequestSignals: Sendable {
  var checks: [HostingCheck] = []
  var ciError: HostingError?
  var reviewStates: [String] = []
  var reviewError: HostingError?
  var ciState: HostingCIState {
    if checks.isEmpty { return .noChecks }
    for state in [HostingCIState.failed, .running, .pending, .cancelled, .unknown] where checks.contains(where: { $0.state == state }) { return state }
    return checks.allSatisfy { $0.state == .skipped } ? .skipped : .success
  }
}
