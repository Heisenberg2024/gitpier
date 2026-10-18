import CryptoKit
import Darwin
import Foundation

/// POSIX descriptor-relative IO: never follows a credential-directory/file symlink.
/// New sensitive files are private from open(O_EXCL, 0600), including temporary files.
struct HostingPrivateDirectory {
  let fd: Int32
  init(_ url: URL, durableCreation: Bool = false, durabilityCheckpoint: @Sendable (String) throws -> Void = { _ in }) throws {
    var path = url.standardizedFileURL.path
    // macOS system aliases, not arbitrary user-controlled symlink resolution.
    if path.hasPrefix("/var/") { path = "/private" + path }
    if path.hasPrefix("/tmp/") { path = "/private" + path }
    var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard current >= 0 else { throw HostingError.vaultUnavailable }
    var ancestors: [Int32] = []
    defer { for ancestor in ancestors { close(ancestor) } }
    do {
      let parts = path.split(separator: "/").map(String.init)
      if durableCreation {
        guard !parts.isEmpty, parts.count <= 128 else { throw HostingError.vaultUnavailable }
      }
      for (index, part) in parts.enumerated() {
        let last = index == parts.count - 1
        var next = openat(current, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if next < 0, errno == ENOENT {
          guard mkdirat(current, part, 0o700) == 0 || errno == EEXIST else { throw HostingError.vaultUnavailable }
          next = openat(current, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard next >= 0 else { throw HostingError.vaultUnavailable }
        var info = stat()
        guard fstat(next, &info) == 0,
          info.st_uid == getuid() || (!last && info.st_uid == 0),
          info.st_mode & 0o022 == 0 || (!last && info.st_uid == 0 && info.st_mode & S_ISVTX != 0)
        else { close(next); throw HostingError.vaultUnavailable }
        if last, fchmod(next, 0o700) != 0 { close(next); throw HostingError.vaultUnavailable }
        if durableCreation { ancestors.append(current) } else { close(current) }
        current = next
      }
      if durableCreation {
        var rootInfo = stat()
        guard fstat(current, &rootInfo) == 0 else { throw HostingError.vaultUnavailable }
        // Keep every parent open until the final device is known. System/sealed
        // ancestors on another filesystem are not part of this write's barrier.
        // Sync existing paths too: an earlier mkdir/EEXIST attempt may have failed
        // before syncing its parent, and a retry must finish that namespace work.
        for ancestor in ancestors {
          var info = stat()
          guard fstat(ancestor, &info) == 0 else { throw HostingError.vaultUnavailable }
          if info.st_dev == rootInfo.st_dev {
            try durabilityCheckpoint("namespaceSync")
            guard fsync(ancestor) == 0 else { throw HostingError.storageFailure }
          }
        }
      }
      fd = current
    } catch { close(current); throw error }
  }
  func closeDirectory() { close(fd) }
  func child(_ name: String) throws -> HostingPrivateDirectory {
    guard mkdirat(fd, name, 0o700) == 0 || errno == EEXIST else { throw HostingError.vaultUnavailable }
    let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard next >= 0 else { throw HostingError.vaultUnavailable }
    var info = stat()
    guard fstat(next, &info) == 0, info.st_uid == getuid(), fchmod(next, 0o700) == 0 else { close(next); throw HostingError.vaultUnavailable }
    return HostingPrivateDirectory(fd: next)
  }
  private init(fd: Int32) { self.fd = fd }
  private func validate(_ file: Int32) throws -> stat {
    var info = stat()
    guard fstat(file, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
      info.st_mode & 0o777 == 0o600, info.st_nlink == 1, info.st_size <= 131072 else { throw HostingError.vaultUnavailable }
    return info
  }
  func read(_ name: String) throws -> Data? {
    let file = openat(fd, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    if file < 0, errno == ENOENT { return nil }
    guard file >= 0 else { throw HostingError.vaultUnavailable }
    defer { close(file) }
    let info = try validate(file)
    var data = Data(count: Int(info.st_size))
    let count = data.count
    try data.withUnsafeMutableBytes { bytes in
      var offset = 0
      while offset < count {
        let n = Darwin.read(file, bytes.baseAddress!.advanced(by: offset), count - offset)
        if n < 0, errno == EINTR { continue }
        guard n > 0 else { throw HostingError.vaultUnavailable }; offset += n
      }
    }
    return data
  }
  func write(_ data: Data, name: String, fullSync: Bool = false, durabilityCheckpoint: @Sendable (String) throws -> Void = { _ in }) throws {
    guard data.count <= 131072 else { throw HostingError.storageFailure }
    _ = try read(name) // Reject symlinks, hard links and unsafe existing targets, without following them.
    let temporary = ".write-" + UUID().uuidString
    let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard file >= 0 else { throw HostingError.storageFailure }
    defer { close(file); unlinkat(fd, temporary, 0) }
    if fullSync {
      // open's mode is filtered by umask. Never authorize a POST with a newly
      // written intent that recovery would later reject as unreadable/unsafe.
      _ = try validate(file)
      try durabilityCheckpoint("fileValidated")
    }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < data.count {
        let n = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), data.count - offset)
        if n < 0, errno == EINTR { continue }
        guard n > 0 else { throw HostingError.storageFailure }; offset += n
      }
    }
    if fullSync {
      try durabilityCheckpoint("fileSync")
      guard fsync(file) == 0 else { throw HostingError.storageFailure }
      try durabilityCheckpoint("rename")
      guard renameat(fd, temporary, fd, name) == 0 else { throw HostingError.storageFailure }
      try durabilityCheckpoint("directorySync")
      guard fsync(fd) == 0 else { throw HostingError.storageFailure }
      // After data and namespace fsync, require the drive-cache barrier on the
      // still-open regular file. Unsupported/failed F_FULLFSYNC is not a fallback.
      try durabilityCheckpoint("fullSync")
      guard fcntl(file, F_FULLFSYNC) == 0 else { throw HostingError.storageFailure }
    } else {
      guard fsync(file) == 0, renameat(fd, temporary, fd, name) == 0 else { throw HostingError.storageFailure }
      // Rename is the commit point. A directory fsync failure must not be reported as rollback.
      _ = fsync(fd)
    }
  }
  func remove(_ name: String) throws {
    guard try read(name) != nil else { return }
    guard unlinkat(fd, name, 0) == 0 else { throw HostingError.storageFailure }
    _ = fsync(fd)
  }
  func lock(_ name: String) throws -> Int32 {
    let file = openat(fd, name, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
    guard file >= 0 else { throw HostingError.vaultUnavailable }
    do {
      _ = try validate(file)
      guard flock(file, LOCK_EX | LOCK_NB) == 0 else { throw HostingError.operationInProgress }
      return file
    } catch { close(file); throw error }
  }
  func names() -> [String] {
    guard let directory = fdopendir(dup(fd)) else { return [] }
    defer { closedir(directory) }
    var result: [String] = []
    while let entry = readdir(directory) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
      result.append(name)
    }
    return result
  }
}

public actor LocalEncryptedCredentialStore: HostingCredentialStore {
  public let root: URL
  private let checkpoint: @Sendable (String) throws -> Void
  struct Record: Codable {
    let version: Int
    let key: UUID
    let generation: UUID
  }
  private struct AssociatedData: Codable {
    let version: Int
    let provider: HostingProvider
    let instance: String
    let account: UUID
    let user: String
    let key: UUID
    let generation: UUID
  }
  public init(root: URL) { self.root = root; checkpoint = { _ in } }
  init(root: URL, checkpoint: @escaping @Sendable (String) throws -> Void) { self.root = root; self.checkpoint = checkpoint }
  private func aad(_ account: HostingAccount, _ record: Record) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(AssociatedData(version: record.version, provider: account.instance.provider,
      instance: account.instance.baseURL.absoluteString, account: account.id, user: account.user.stableID,
      key: record.key, generation: record.generation))
  }
  private func withFiles<T>(_ account: HostingAccount, _ body: (HostingPrivateDirectory, HostingPrivateDirectory, HostingPrivateDirectory) throws -> T) throws -> T {
    let directory = try HostingPrivateDirectory(root); defer { directory.closeDirectory() }
    let lock = try directory.lock(account.id.uuidString + ".lock"); defer { close(lock) }
    let keys = try directory.child("keys"); defer { keys.closeDirectory() }
    let vault = try directory.child("vault"); defer { vault.closeDirectory() }
    return try body(directory, keys, vault)
  }
  private func record(_ account: HostingAccount, in vault: HostingPrivateDirectory) throws -> Record? {
    guard let data = try vault.read(account.id.uuidString + ".json") else { return nil }
    guard let record = try? JSONDecoder().decode(Record.self, from: data), record.version == 1 else { throw HostingError.vaultCorrupt }
    return record
  }
  private func keyName(_ account: HostingAccount, _ record: Record) -> String { account.id.uuidString + "." + record.key.uuidString + ".key" }
  private func cipherName(_ account: HostingAccount, _ record: Record) -> String { account.id.uuidString + "." + record.generation.uuidString + ".sealed" }
  private func load(_ account: HostingAccount, _ record: Record, keys: HostingPrivateDirectory, vault: HostingPrivateDirectory) throws -> (HostingToken, SymmetricKey) {
    guard let keyData = try keys.read(keyName(account, record)), keyData.count == 32,
      let cipher = try vault.read(cipherName(account, record)) else { throw HostingError.vaultCorrupt }
    do {
      let key = SymmetricKey(data: keyData)
      let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: cipher), using: key, authenticating: aad(account, record))
      return (try JSONDecoder().decode(HostingToken.self, from: plain), key)
    } catch { throw HostingError.vaultCorrupt }
  }
  public func read(account: HostingAccount) throws -> HostingToken? {
    try withFiles(account) { _, keys, vault in
      guard let record = try record(account, in: vault) else { return nil }
      return try load(account, record, keys: keys, vault: vault).0
    }
  }
  public func save(_ token: HostingToken, account: HostingAccount) throws { try write(token, account: account, rotate: false) }
  public func replace(_ token: HostingToken, account: HostingAccount) async throws { try write(token, account: account, rotate: true) }
  private func write(_ token: HostingToken, account: HostingAccount, rotate: Bool) throws {
    try withFiles(account) { _, keys, vault in
      let old: Record?
      do { old = try record(account, in: vault) }
      catch HostingError.vaultCorrupt where rotate { old = nil }
      let key: SymmetricKey
      if let old, !rotate { key = try load(account, old, keys: keys, vault: vault).1 }
      else { key = SymmetricKey(size: .bits256) }
      let next = Record(version: 1, key: rotate ? UUID() : old?.key ?? UUID(), generation: UUID())
      let keyData = key.withUnsafeBytes { Data($0) }
      // CryptoKit generates a fresh random 96-bit nonce for every seal, including refresh.
      guard let cipher = try AES.GCM.seal(JSONEncoder().encode(token), using: key, authenticating: aad(account, next)).combined else { throw HostingError.storageFailure }
      if old?.key != next.key { try keys.write(keyData, name: keyName(account, next)) }
      try checkpoint("key")
      try vault.write(cipher, name: cipherName(account, next))
      try checkpoint("cipher")
      try vault.write(JSONEncoder().encode(next), name: account.id.uuidString + ".json")
      // The old pair remains intact until the pointer commit; cleanup never invalidates the new pair.
      if let old {
        try? vault.remove(cipherName(account, old))
        if old.key != next.key { try? keys.remove(keyName(account, old)) }
      }
      cleanupOrphans(account, keeping: next, keys: keys, vault: vault)
    }
  }
  public func delete(account: HostingAccount) throws {
    try withFiles(account) { _, keys, vault in
      // Includes interrupted writes and damaged records without decrypting any token.
      for name in materialNames(account, directory: vault, extension: "sealed") { try vault.remove(name) }
      for name in materialNames(account, directory: keys, extension: "key") { try keys.remove(name) }
      try vault.remove(account.id.uuidString + ".json")
    }
  }
  private func materialNames(_ account: HostingAccount, directory: HostingPrivateDirectory, extension suffix: String) -> [String] {
    directory.names().filter {
      let parts = $0.split(separator: ".")
      return parts.count == 3 && parts[0] == Substring(account.id.uuidString) && UUID(uuidString: String(parts[1])) != nil && parts[2] == Substring(suffix)
    }
  }
  private func cleanupOrphans(_ account: HostingAccount, keeping record: Record, keys: HostingPrivateDirectory, vault: HostingPrivateDirectory) {
    for name in materialNames(account, directory: vault, extension: "sealed") where name != cipherName(account, record) { try? vault.remove(name) }
    for name in materialNames(account, directory: keys, extension: "key") where name != keyName(account, record) { try? keys.remove(name) }
  }
}

/// Providers and API clients see one store; only this router knows the persistence medium.
public struct HostingCredentialRouter: HostingCredentialStore {
  public let local: any HostingCredentialStore
  public let keychain: any HostingCredentialStore
  public init(root: URL, keychain: any HostingCredentialStore = HostingKeychainStore()) {
    local = LocalEncryptedCredentialStore(root: root); self.keychain = keychain
  }
  public init(local: any HostingCredentialStore, keychain: any HostingCredentialStore) { self.local = local; self.keychain = keychain }
  private func store(_ account: HostingAccount) -> any HostingCredentialStore { account.storageMode == .localVault ? local : keychain }
  public func read(account: HostingAccount) async throws -> HostingToken? { try await store(account).read(account: account) }
  public func save(_ token: HostingToken, account: HostingAccount) async throws { try await store(account).save(token, account: account) }
  public func replace(_ token: HostingToken, account: HostingAccount) async throws { try await store(account).replace(token, account: account) }
  public func delete(account: HostingAccount) async throws { try await store(account).delete(account: account) }
}
