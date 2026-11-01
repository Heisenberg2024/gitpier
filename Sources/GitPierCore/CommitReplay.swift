import Foundation
import Darwin

public enum CommitReplayKind: String, Sendable { case cherryPick, revert
  public var command: String { self == .cherryPick ? "cherry-pick" : "revert" }
}

/// Immutable objects and original destination. Reordering never resolves moving references.
public struct CommitReplayReview: Sendable {
  public let id: UUID
  public let kind: CommitReplayKind
  public let workingTree: String
  public let gitDirectory: String
  public let operation: GitOperationReview
  public let commits: [CommitRecord]
  public let parents: [CommitRecord]
  public let alreadyReachable: Set<String>
  let executable: String
  let authenticationRevision: UUID
  let directories: ReplayRepositoryIdentity
  let objectView: ReplayObjectView
  public func reordered(_ hashes: [String]) throws -> CommitReplayReview {
    guard hashes.count == commits.count, Set(hashes).count == hashes.count,
      Set(hashes) == Set(commits.map(\.hash)) else { throw GitPierError.indexChanged }
    let byID = Dictionary(uniqueKeysWithValues: commits.map { ($0.hash, $0) })
    return CommitReplayReview(id: id, kind: kind, workingTree: workingTree, gitDirectory: gitDirectory,
      operation: operation, commits: hashes.compactMap { byID[$0] }, parents: parents,
      alreadyReachable: alreadyReachable, executable: executable, authenticationRevision: authenticationRevision, directories: directories, objectView: objectView)
  }
}

public struct GitSequencerStep: Sendable, Equatable {
  public let hash: String
  public let subject: String
}
public struct GitSequencerState: Sendable, Equatable {
  public let operation: GitOperation
  public let currentHash: String?
  /// Native todo includes the stopped commit. Never inferred from application progress counters.
  public let remaining: [GitSequencerStep]
  public let review: GitOperationReview
  public let workingFingerprint: Data
  let objectView: ReplayObjectView
}

/// Git object IDs are immutable, but replace refs and ancestry overlays alter their
/// effective meaning. Bind the native view without disabling configured Git behavior.
struct ReplayObjectView: Sendable, Equatable {
  struct File: Sendable, Equatable { let path: String; let bytes: Data? }
  let replacements: Data
  let configuration: Data
  let environment: [String: String]
  let files: [File]
}
public enum SequencerControl: String, CaseIterable, Sendable { case `continue`, skip, abort }
public struct SequencerControlReview: Sendable {
  public let action: SequencerControl
  public let state: GitSequencerState
  public let workingTree: String
  let executable: String
  let authenticationRevision: UUID
  let directories: ReplayRepositoryIdentity
}

struct ReplayRepositoryIdentity: Equatable, Sendable {
  let paths: [String]
  let identities: [TaskDirectoryIdentity]
  let gitEntry: Data
  func validate() throws {
    guard try paths.map({ try TaskDirectoryIdentity.read($0) }) == identities,
      let root = paths.first, try Self.readGitEntry(root) == gitEntry else { throw GitPierError.indexChanged }
  }
  /// Bind the worktree's .git pointer itself as well as its resolved directories.
  /// Reads are synchronous at the final gate, bounded, and never follow a file link.
  static func readGitEntry(_ root: String) throws -> Data {
    let path = URL(fileURLWithPath: root).appendingPathComponent(".git").path
    var before = stat()
    guard lstat(path, &before) == 0 else { throw GitPierError.indexChanged }
    func identity(_ info: stat) -> String {
      let basic = "\(info.st_dev):\(info.st_ino):\(info.st_mode)"
      if info.st_mode & S_IFMT == S_IFDIR { return basic }
      return basic + ":\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }
    let original = identity(before)
    var data = Data((original + "\0").utf8)
    switch before.st_mode & S_IFMT {
    case S_IFDIR: break
    case S_IFLNK:
      let target = try FileManager.default.destinationOfSymbolicLink(atPath: path)
      guard target.utf8.count <= 65536 else { throw GitPierError.indexChanged }
      data.append(Data(target.utf8))
    case S_IFREG:
      guard before.st_size >= 0, before.st_size <= 65536 else { throw GitPierError.indexChanged }
      let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
      guard fd >= 0 else { throw GitPierError.indexChanged }
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      defer { try? handle.close() }
      var opened = stat(), after = stat()
      guard fstat(fd, &opened) == 0, identity(opened) == original else { throw GitPierError.indexChanged }
      let bytes = try handle.read(upToCount: 65537) ?? Data()
      guard bytes.count <= 65536, bytes.starts(with: Data("gitdir: ".utf8)),
        fstat(fd, &after) == 0, identity(after) == original else { throw GitPierError.indexChanged }
      data.append(bytes)
    default: throw GitPierError.indexChanged
    }
    var live = stat()
    guard lstat(path, &live) == 0, identity(live) == original else { throw GitPierError.indexChanged }
    return data
  }
}
