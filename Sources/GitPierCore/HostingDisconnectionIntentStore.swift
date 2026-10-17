import Foundation

extension HostingMetadataStore {
  private struct DisconnectionIntent: Codable {
    let version: Int
    let record: HostingDisconnectedAccount
  }
  private var disconnectionDirectory: URL {
    url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".disconnects", isDirectory: true)
  }
  /// Commit this small, independent journal before suspending or attempting credential deletion.
  /// A failed main metadata replacement cannot make its account active after a process restart.
  public func recordDisconnection(_ record: HostingDisconnectedAccount) throws {
    do {
      try validateDisconnection(record)
      let directory = try HostingPrivateDirectory(disconnectionDirectory); defer { directory.closeDirectory() }
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      try directory.write(encoder.encode(DisconnectionIntent(version: 1, record: record)), name: record.id.uuidString + ".json")
    } catch { throw HostingError.storageFailure }
  }
  /// Call only after the account's removal has been committed to the main metadata file.
  /// Removing a journal never touches the credential stores or another account's journal.
  public func removeDisconnectionIntent(_ id: UUID) throws {
    do {
      let directory = try HostingPrivateDirectory(disconnectionDirectory); defer { directory.closeDirectory() }
      try directory.remove(id.uuidString + ".json")
    } catch { throw HostingError.storageFailure }
  }
  private func validateDisconnection(_ record: HostingDisconnectedAccount) throws {
    try record.account.validateCredentialContext()
    let possible = Set(HostingDisconnectedAccount(account: record.account).remainingStorage)
    guard Set(record.remainingStorage).count == record.remainingStorage.count,
      Set(record.remainingStorage).isSubset(of: possible) else { throw HostingError.configurationUnreadable }
  }
  func applyingDisconnectionIntents(to metadata: HostingMetadata) throws -> HostingMetadata {
    let directory = try HostingPrivateDirectory(disconnectionDirectory); defer { directory.closeDirectory() }
    let names = directory.names().filter { $0.hasSuffix(".json") }.sorted()
    guard names.count <= 1024 else { throw HostingError.configurationUnreadable }
    var value = metadata
    for name in names {
      guard let id = UUID(uuidString: String(name.dropLast(5))), let data = try directory.read(name) else { throw HostingError.configurationUnreadable }
      let intent = try JSONDecoder().decode(DisconnectionIntent.self, from: data)
      guard intent.version == 1, intent.record.id == id else { throw HostingError.configurationUnreadable }
      try validateDisconnection(intent.record)
      if let active = value.accounts.first(where: { $0.id == id }), active.identity != intent.record.account.identity {
        throw HostingError.configurationUnreadable
      }
      value.accounts.removeAll { $0.id == id }
      value.bindings.removeAll { $0.accountID == id }
      if let index = value.disconnectedAccounts.firstIndex(where: { $0.id == id }) {
        guard value.disconnectedAccounts[index].account.identity == intent.record.account.identity else { throw HostingError.configurationUnreadable }
        // Progress only removes storage modes. Either independently saved checkpoint may be newer.
        value.disconnectedAccounts[index].remainingStorage.removeAll { !intent.record.remainingStorage.contains($0) }
      } else { value.disconnectedAccounts.append(intent.record) }
    }
    return value
  }
}
