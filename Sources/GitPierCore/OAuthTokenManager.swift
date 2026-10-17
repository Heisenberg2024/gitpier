import Foundation

/// Shared by all windows. Per-account critical sections span persistence and metadata commits.
/// Local restoration is lazy/single-flight; legacy Keychain restoration requires explicit Verify.
public actor OAuthTokenManager {
  private let vault: any HostingCredentialStore
  private let oauth: OAuthAuthorizationCoordinator
  private let persistenceFailed: @Sendable (HostingAccount) async -> Void
  private var tokens: [UUID: HostingToken] = [:]
  private var accounts: [UUID: HostingAccount] = [:]
  private var removed: Set<UUID> = []
  private var revisions: [UUID: UUID] = [:]
  private var refreshes: [UUID: (UUID, Task<HostingToken, Error>)] = [:]
  private var loads: [UUID: (UUID, Task<HostingToken?, Error>)] = [:]
  private var saving: Set<UUID> = []
  private var transient: Set<UUID> = []
  public init(vault: any HostingCredentialStore = HostingCredentialRouter(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GitPier/HostingCredentials")), oauth: OAuthAuthorizationCoordinator = OAuthAuthorizationCoordinator(), persistenceFailed: @escaping @Sendable (HostingAccount) async -> Void = { _ in }) {
    self.vault = vault; self.oauth = oauth; self.persistenceFailed = persistenceFailed
  }
  private func validate(_ account: HostingAccount) throws {
    try account.validateCredentialContext()
    guard !removed.contains(account.id) else { throw HostingError.accountChanged }
    if let known = accounts[account.id], known.identity != account.identity || known.storageMode != account.storageMode
      || known.kind != account.kind || known.oauth != account.oauth { throw HostingError.accountChanged }
    accounts[account.id] = account
  }
  private func invalidate(_ id: UUID) -> UUID {
    let revision = UUID(); revisions[id] = revision
    refreshes.removeValue(forKey: id)?.1.cancel(); loads.removeValue(forKey: id)?.1.cancel()
    return revision
  }
  public func isSessionOnly(_ id: UUID) -> Bool { transient.contains(id) }
  public func hasSession(_ account: HostingAccount) -> Bool { accounts[account.id]?.identity == account.identity && tokens[account.id] != nil }
  public func unlock(_ account: HostingAccount) async throws {
    try validate(account)
    guard !saving.contains(account.id) else { throw HostingError.operationInProgress }
    if tokens[account.id] != nil { return }
    guard !account.credentialRecoveryRequired else { throw HostingError.unauthorized }
    let revision = revisions[account.id] ?? UUID(); revisions[account.id] = revision
    let load: (UUID, Task<HostingToken?, Error>)
    if let active = loads[account.id] { load = active }
    else {
      let vault = vault
      load = (UUID(), Task { try await vault.read(account: account) }); loads[account.id] = load
    }
    defer { if loads[account.id]?.0 == load.0 { loads[account.id] = nil } }
    let token = try await load.1.value
    guard revisions[account.id] == revision else { throw HostingError.accountChanged }
    guard let token else { throw HostingError.unauthorized }
    tokens[account.id] = token
  }
  public func install(_ token: HostingToken, account: HostingAccount) async throws {
    try account.validateCredentialContext()
    guard !saving.contains(account.id) else { throw HostingError.operationInProgress }
    saving.insert(account.id); defer { saving.remove(account.id) }
    let revision = invalidate(account.id); removed.remove(account.id); accounts[account.id] = account
    tokens[account.id] = token // Keep a usable session even when persistence is refused.
    do { try await vault.replace(token, account: account) }
    catch { transient.insert(account.id); await persistenceFailed(account); throw HostingError.sessionOnly }
    guard revisions[account.id] == revision else { throw HostingError.accountChanged }
    transient.remove(account.id)
  }
  public func token(for account: HostingAccount) async throws -> HostingToken {
    try validate(account)
    if let task = refreshes[account.id] { return try await task.1.value }
    guard !saving.contains(account.id) else { throw HostingError.operationInProgress }
    if tokens[account.id] == nil {
      guard account.storageMode == .localVault else { throw HostingError.credentialsLocked }
      try await unlock(account)
    }
    // An await above can install a new generation, begin a migration or disconnect.
    try validate(account)
    if let task = refreshes[account.id] { return try await task.1.value }
    guard !saving.contains(account.id), let token = tokens[account.id] else { throw HostingError.operationInProgress }
    if token.expiresAt.map({ $0.timeIntervalSinceNow > 60 }) ?? true { return token }
    guard account.kind == .oauth, let config = account.oauth, token.refreshToken != nil else { throw HostingError.expired }
    let revision = revisions[account.id] ?? UUID(); revisions[account.id] = revision
    let id = UUID()
    let task = Task { try await self.refresh(token, account: account, config: config, revision: revision) }
    refreshes[account.id] = (id, task)
    defer { if refreshes[account.id]?.0 == id { refreshes[account.id] = nil } }
    return try await task.value
  }
  private func refresh(_ old: HostingToken, account: HostingAccount, config: OAuthConfiguration, revision: UUID) async throws -> HostingToken {
    let next = try await oauth.refresh(configuration: config, token: old)
    try Task.checkCancellation()
    guard revisions[account.id] == revision, !saving.contains(account.id) else { throw HostingError.accountChanged }
    saving.insert(account.id); defer { saving.remove(account.id) }
    do { try await vault.save(next, account: account) }
    catch {
      // The server may have invalidated the old pair. Never restore or retry that pair.
      guard revisions[account.id] == revision else { throw HostingError.accountChanged }
      tokens[account.id] = next; revisions[account.id] = UUID(); transient.insert(account.id)
      await persistenceFailed(account)
      throw HostingError.sessionOnly
    }
    guard revisions[account.id] == revision else { throw HostingError.accountChanged }
    revisions[account.id] = UUID(); tokens[account.id] = next; transient.remove(account.id); return next
  }
  /// beforeWrite journals intent; commit atomically switches account metadata. Source is never deleted here.
  public func migrate(_ account: HostingAccount, to mode: HostingStorageMode, replacement: HostingToken? = nil, authorizedAccount: HostingAccount? = nil, allowStoredRead: Bool = false,
    beforeWrite: @Sendable () async throws -> Void = {}, commit: @Sendable (HostingAccount) async throws -> Void) async throws -> HostingAccount {
    try validate(account)
    try authorizedAccount?.validateCredentialContext()
    if let authorizedAccount, authorizedAccount.id != account.id || authorizedAccount.identity != account.identity { throw HostingError.accountChanged }
    guard account.storageMode != mode, !saving.contains(account.id), refreshes[account.id] == nil else { throw HostingError.operationInProgress }
    saving.insert(account.id); defer { saving.remove(account.id) }
    let revision = invalidate(account.id)
    let token: HostingToken
    if let replacement { token = replacement }
    else if let cached = tokens[account.id] { token = cached }
    else {
      guard allowStoredRead, let stored = try await vault.read(account: account) else { throw HostingError.credentialsLocked }
      token = stored
    }
    try Task.checkCancellation()
    guard revisions[account.id] == revision else { throw HostingError.accountChanged }
    var destination = authorizedAccount ?? account; destination.storageMode = mode; destination.pendingMigration = nil
    destination.credentialRecoveryRequired = false
    destination.pendingCleanup.removeAll { $0 == mode }
    if !destination.pendingCleanup.contains(account.storageMode) { destination.pendingCleanup.append(account.storageMode) }
    do {
      try await beforeWrite()
      try Task.checkCancellation()
      try await vault.replace(token, account: destination)
      try Task.checkCancellation()
      guard revisions[account.id] == revision else { throw HostingError.accountChanged }
      try await commit(destination)
    } catch {
      if error is CancellationError || error as? HostingError == .accountChanged { throw error }
      if replacement != nil, revisions[account.id] == revision {
        var session = authorizedAccount ?? account; session.storageMode = account.storageMode
        accounts[account.id] = session; tokens[account.id] = token; transient.insert(account.id)
        await persistenceFailed(session)
        throw HostingError.sessionOnly
      }
      throw error
    }
    accounts[account.id] = destination; tokens[account.id] = token; transient.remove(account.id)
    return destination
  }
  /// Separate explicit user action: deleting an old Keychain copy may request system authorization.
  public func cleanup(_ account: HostingAccount, mode: HostingStorageMode) async throws {
    try validate(account)
    guard mode != account.storageMode, account.pendingCleanup.contains(mode) || account.pendingMigration == mode,
      !saving.contains(account.id) else { throw HostingError.operationInProgress }
    saving.insert(account.id); defer { saving.remove(account.id) }
    var old = account; old.storageMode = mode
    try await vault.delete(account: old)
  }
  public func forget(_ account: HostingAccount) async throws {
    if removed.contains(account.id) { return } // Retry a failed metadata deletion without restoring credentials.
    try validate(account)
    guard !saving.contains(account.id) else { throw HostingError.operationInProgress }
    saving.insert(account.id); defer { saving.remove(account.id) }
    _ = invalidate(account.id); tokens[account.id] = nil
    for mode in Set(account.pendingCleanup + [account.pendingMigration].compactMap { $0 }) where mode != account.storageMode {
      var old = account; old.storageMode = mode; try await vault.delete(account: old)
    }
    try await vault.delete(account: account)
    removed.insert(account.id); transient.remove(account.id)
  }
  public func lock(_ id: UUID) { _ = invalidate(id); tokens[id] = nil; transient.remove(id) }
}
