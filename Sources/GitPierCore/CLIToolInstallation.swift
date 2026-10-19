import CryptoKit
import Darwin
import Foundation

public struct CLIToolReceipt: Codable, Sendable {
  public let version: Int
  public let digest: String
  public let applicationPath: String
  public let applicationBookmark: Data
  public let bundleIdentifier: String
  public init(executable: Data, application: URL, bundleIdentifier: String) throws {
    version = 1; digest = Self.hash(executable)
    applicationPath = application.path
    applicationBookmark = try application.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    self.bundleIdentifier = bundleIdentifier
  }
  public func application() throws -> URL {
    func available(_ url: URL) -> Bool {
      guard url.isFileURL, url.pathExtension == "app", let bundle = Bundle(url: url),
        bundle.bundleIdentifier == bundleIdentifier,
        FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/GitPier").path),
        let volume = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]), volume.volumeIsReadOnly != true else { return false }
      return true
    }
    // Sparkle may move the old app to Trash. A valid replacement at the selected installation
    // location takes precedence over a bookmark that still follows that old inode.
    let installed = URL(fileURLWithPath: applicationPath)
    if available(installed) { return installed }
    var stale = false
    let moved = try URL(resolvingBookmarkData: applicationBookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
    guard available(moved) else {
      throw GitPierError.invalidInput("Selected GitPier app is unavailable or on a read-only volume. Install GitPier in a writable location and reinstall the command line tool from your chosen app.")
    }
    return moved
  }
  static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}

enum CLIToolFileBoundary: Sendable {
  case filesReserved
  case takingCustody(String)
  case deletingOwnedFile(String)
}

/// Descriptor-relative, no-follow installation. Never overwrites an existing tool or receipt.
/// No sudo, shell configuration writes, symlink launcher, or executable app-version path.
public struct CLIToolInstallation: Sendable {
  public let directory: URL
  var fileBoundary: (@Sendable (CLIToolFileBoundary) throws -> Void)?
  public var executable: URL { directory.appendingPathComponent("gitpier") }
  public static let receiptName = ".gitpier-install.json"
  public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")) { self.directory = directory.absoluteURL }
  private var failure: GitPierError { .invalidInput("Command line tool is missing, changed, or owned by another installer. Existing files were preserved. Move them yourself before installing again.") }
  private func openDirectory(create: Bool) throws -> Int32 {
    guard directory.isFileURL, directory.path.hasPrefix("/"),
      directory.host == nil || directory.host == "" || directory.host == "localhost",
      !directory.path.utf8.contains(0), !directory.pathComponents.contains(".."), !directory.pathComponents.contains(".") else { throw failure }
    var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw failure }
    do {
      for part in directory.pathComponents.dropFirst() {
        var child = stat()
        if fstatat(fd, part, &child, AT_SYMLINK_NOFOLLOW) != 0 {
          guard create, errno == ENOENT, mkdirat(fd, part, 0o700) == 0 else {
            throw GitPierError.invalidInput("CLI installation directory could not be created (\(errno)).")
          }
        }
        let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard next >= 0 else { throw GitPierError.invalidInput("CLI installation directory contains an inaccessible component or symbolic link (\(errno)).") }
        var state = stat()
        guard fstat(next, &state) == 0, state.st_uid == getuid() || state.st_uid == 0,
          state.st_mode & 0o022 == 0 || (state.st_uid == 0 && state.st_mode & 0o1000 != 0) else {
          close(next); throw failure
        }
        close(fd); fd = next
      }
      var state = stat()
      guard fstat(fd, &state) == 0, state.st_uid == getuid(), state.st_mode & 0o022 == 0 else { throw failure }
      return fd
    } catch { close(fd); throw error }
  }
  private func read(_ name: String, in directory: Int32, maximum: Int) throws -> (Data, stat) {
    let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw failure }; defer { close(fd) }
    var state = stat()
    guard fstat(fd, &state) == 0, state.st_mode & S_IFMT == S_IFREG, state.st_uid == getuid(),
      state.st_nlink == 1, state.st_mode & 0o022 == 0, state.st_size > 0, state.st_size <= maximum else { throw failure }
    var bytes = Data(count: Int(state.st_size))
    let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
    guard count == state.st_size else { throw failure }
    return (bytes, state)
  }
  public func receipt() throws -> CLIToolReceipt {
    let fd = try openDirectory(create: false); defer { close(fd) }
    let data = try read(Self.receiptName, in: fd, maximum: 65536).0
    let receipt = try JSONDecoder().decode(CLIToolReceipt.self, from: data)
    guard receipt.version == 1, CLIToolReceipt.hash(try read("gitpier", in: fd, maximum: 100 * 1024 * 1024).0) == receipt.digest else { throw failure }
    return receipt
  }
  public func install(source: URL, application: URL, bundleIdentifier: String) throws {
    let bytes = try Data(contentsOf: source)
    guard !bytes.isEmpty, bytes.count <= 100 * 1024 * 1024 else { throw failure }
    let receipt = try CLIToolReceipt(executable: bytes, application: application, bundleIdentifier: bundleIdentifier)
    _ = try receipt.application()
    let encoded = try JSONEncoder().encode(receipt)
    let fd = try openDirectory(create: true); defer { close(fd) }
    var state = stat()
    guard fstatat(fd, "gitpier", &state, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT,
      fstatat(fd, Self.receiptName, &state, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw failure }
    // Reserve the receipt first; another installer cannot race ownership of the same basename.
    let receiptFD = openat(fd, Self.receiptName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard receiptFD >= 0 else { throw failure }
    var toolFD: Int32 = -1, complete = false
    defer {
      if !complete {
        if toolFD >= 0 { unlinkIfSame("gitpier", in: fd, opened: toolFD) }
        unlinkIfSame(Self.receiptName, in: fd, opened: receiptFD)
      }
      if toolFD >= 0 { close(toolFD) }
      close(receiptFD)
    }
    toolFD = openat(fd, "gitpier", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard toolFD >= 0 else { throw failure }
    try fileBoundary?(.filesReserved)
    try write(bytes, to: toolFD); try write(encoded, to: receiptFD)
    guard fsync(toolFD) == 0, fsync(receiptFD) == 0, fchmod(toolFD, 0o700) == 0, fsync(toolFD) == 0, fsync(fd) == 0 else { throw failure }
    complete = true
  }
  private func unlinkIfSame(_ name: String, in directory: Int32, opened: Int32) {
    var original = stat()
    guard fstat(opened, &original) == 0 else { return }
    try? withRemovalDirectory(in: directory) { custody in
      try takeForRemoval(name, from: directory, into: custody, expected: original)
      do {
        try fileBoundary?(.deletingOwnedFile(name))
        guard unlinkat(custody, name, 0) == 0 else { throw failure }
      } catch {
        restore(name, from: custody, into: directory)
        throw error
      }
    }
  }
  private func withRemovalDirectory(in directory: Int32, operation: (Int32) throws -> Void) throws {
    let name = ".gitpier-removing-" + UUID().uuidString
    guard mkdirat(directory, name, 0o700) == 0 else { throw failure }
    defer {
      // A failed non-overwriting restoration retains its files for manual repair.
      _ = unlinkat(directory, name, AT_REMOVEDIR)
    }
    let fd = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw failure }
    defer { close(fd) }
    var state = stat()
    guard fstat(fd, &state) == 0, state.st_mode & S_IFMT == S_IFDIR,
      state.st_uid == getuid(), state.st_mode & 0o077 == 0 else { throw failure }
    try operation(fd)
    guard fsync(fd) == 0 else { throw failure }
  }
  private func sameOwnedFile(_ current: stat, _ expected: stat) -> Bool {
    current.st_dev == expected.st_dev && current.st_ino == expected.st_ino
      && current.st_mode & S_IFMT == S_IFREG && current.st_uid == getuid()
      && current.st_nlink == 1 && current.st_mode & 0o022 == 0
  }
  private func restore(_ name: String, from custody: Int32, into directory: Int32) {
    _ = renameatx_np(custody, name, directory, name, UInt32(RENAME_EXCL))
  }
  private func takeForRemoval(_ name: String, from directory: Int32, into custody: Int32,
                             expected: stat, bytes: Data? = nil) throws {
    var current = stat()
    guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
      sameOwnedFile(current, expected) else { throw failure }
    try fileBoundary?(.takingCustody(name))
    guard renameatx_np(directory, name, custody, name, UInt32(RENAME_EXCL)) == 0 else { throw failure }
    do {
      guard fstatat(custody, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
        sameOwnedFile(current, expected) else { throw failure }
      if let bytes {
        let taken = try read(name, in: custody, maximum: bytes.count)
        guard sameOwnedFile(taken.1, expected), taken.0 == bytes else { throw failure }
      }
    } catch {
      restore(name, from: custody, into: directory)
      throw error
    }
  }
  private func write(_ bytes: Data, to fd: Int32) throws {
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw failure }; offset += n
      }
    }
  }
  public func uninstall() throws {
    _ = try receipt()
    let fd = try openDirectory(create: false); defer { close(fd) }
    let encoded = try read(Self.receiptName, in: fd, maximum: 65536)
    let receipt = try JSONDecoder().decode(CLIToolReceipt.self, from: encoded.0)
    let tool = try read("gitpier", in: fd, maximum: 100 * 1024 * 1024)
    guard receipt.version == 1, CLIToolReceipt.hash(tool.0) == receipt.digest else { throw failure }
    // Capture and revalidate both names before deleting either. Public names may
    // then be reused by another installer without becoming our deletion targets.
    try withRemovalDirectory(in: fd) { custody in
      do {
        try takeForRemoval("gitpier", from: fd, into: custody, expected: tool.1, bytes: tool.0)
        try takeForRemoval(Self.receiptName, from: fd, into: custody, expected: encoded.1, bytes: encoded.0)
        try fileBoundary?(.deletingOwnedFile("gitpier"))
        guard unlinkat(custody, "gitpier", 0) == 0 else { throw failure }
        try fileBoundary?(.deletingOwnedFile(Self.receiptName))
        guard unlinkat(custody, Self.receiptName, 0) == 0 else { throw failure }
      } catch {
        restore(Self.receiptName, from: custody, into: fd)
        restore("gitpier", from: custody, into: fd)
        throw error
      }
    }
    guard fsync(fd) == 0 else { throw failure }
  }
}
