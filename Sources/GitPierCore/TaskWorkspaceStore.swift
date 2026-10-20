import Darwin
import Foundation

/// Uses the existing descriptor-relative private-file primitive, never the credential backend.
/// Per-record atomic writes keep recovery bounded and preserve every unreadable original.
public actor TaskWorkspaceStore {
  public let root: URL
  public static let maximumRecords = 512
  private var owner: Int32?
  private var ownedDirectory: TaskDirectoryIdentity?
  private struct Record: Codable { let version: Int; let task: TaskWorkspace }
  public init(root: URL) { self.root = root }
  deinit { if let owner { close(owner) } }
  private func withFiles<T>(_ action: (HostingPrivateDirectory) throws -> T) throws -> T {
    let directory: HostingPrivateDirectory
    do { directory = try HostingPrivateDirectory(root) } catch { throw TaskWorkspaceError.corrupt }
    defer { directory.closeDirectory() }
    if owner == nil {
      do {
        owner = try directory.lock("owner.lock")
        ownedDirectory = try TaskDirectoryIdentity.read(root.standardizedFileURL.resolvingSymlinksInPath().path)
      } catch { throw TaskWorkspaceError.inUse }
    }
    guard try TaskDirectoryIdentity.read(root.standardizedFileURL.resolvingSymlinksInPath().path) == ownedDirectory else { throw TaskWorkspaceError.changed }
    let lock: Int32
    do { lock = try directory.lock("tasks.lock") } catch { throw TaskWorkspaceError.changed }
    defer { close(lock) }
    return try action(directory)
  }
  private func readAll(_ directory: HostingPrivateDirectory, recover: Bool) throws -> [TaskWorkspace] {
    let names = directory.names().filter { $0.hasSuffix(".json") }
    guard names.count <= Self.maximumRecords else { throw TaskWorkspaceError.capacity }
    var records: [TaskWorkspace] = []
    for name in names.sorted() {
      guard let id = UUID(uuidString: String(name.dropLast(5))) else { throw TaskWorkspaceError.corrupt }
      let record: Record
      do {
        guard let data = try directory.read(name) else { throw TaskWorkspaceError.corrupt }
        record = try JSONDecoder().decode(Record.self, from: data)
      } catch { throw TaskWorkspaceError.corrupt }
      // The schema-zero import format uses the same identity payload; saves migrate to one.
      guard (0...1).contains(record.version) else { throw TaskWorkspaceError.unsupportedVersion }
      var task = record.task
      guard task.id == id else { throw TaskWorkspaceError.corrupt }
      do { try task.validate() } catch { throw TaskWorkspaceError.corrupt }
      if recover { task.recoverInterruptedSession() }
      records.append(task)
    }
    guard Set(records.map(\.id)).count == records.count,
      Set(records.map(\.path)).count == records.count else { throw TaskWorkspaceError.corrupt }
    return records.sorted { $0.createdAt > $1.createdAt }
  }
  /// Recovery changes only the returned projection; damaged files are never rewritten or deleted.
  public func load() throws -> [TaskWorkspace] { try withFiles { try readAll($0, recover: true) } }
  /// Callers pass the last persisted value, not the crash-recovery projection.
  public func records() throws -> [TaskWorkspace] { try withFiles { try readAll($0, recover: false) } }
  public func save(_ task: TaskWorkspace, replacing expected: TaskWorkspace? = nil) throws {
    try task.validate()
    try withFiles { directory in
      let records = try readAll(directory, recover: false)
      let previous = records.first { $0.id == task.id }
      guard previous == expected, !records.contains(where: { $0.id != task.id && $0.path == task.path }) else { throw TaskWorkspaceError.changed }
      guard previous != nil || records.count < Self.maximumRecords else { throw TaskWorkspaceError.capacity }
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      let bytes = try encoder.encode(Record(version: 1, task: task))
      guard bytes.count <= 131072 else { throw TaskWorkspaceError.capacity }
      do { try directory.write(bytes, name: task.id.uuidString + ".json") }
      catch { throw TaskWorkspaceError.corrupt }
    }
  }
  /// Explicit startup recovery, under the same file lock; no executable is resumed.
  public func recover() throws -> [TaskWorkspace] {
    try withFiles { directory in
      let records = try readAll(directory, recover: false)
      var recovered: [TaskWorkspace] = []
      for original in records {
        var task = original; task.recoverInterruptedSession()
        if task != original {
          let bytes = try JSONEncoder().encode(Record(version: 1, task: task))
          do { try directory.write(bytes, name: task.id.uuidString + ".json") }
          catch { throw TaskWorkspaceError.corrupt }
        }
        recovered.append(task)
      }
      return recovered
    }
  }
}
