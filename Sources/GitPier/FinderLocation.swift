import AppKit

enum FinderLocation: Equatable {
  case openFolder(URL)
  case selectFile(URL)

  static func repository(_ path: String) throws -> Self {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    let target = url.resolvingSymlinksInPath()
    guard try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url])
    }
    guard
      FileManager.default.isReadableFile(atPath: path), FileManager.default.isExecutableFile(atPath: path) else {
      throw CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: url])
    }
    return .openFolder(url)
  }

  static func file(_ path: String, in repository: String) throws -> Self {
    let url = URL(fileURLWithPath: repository, isDirectory: true).appendingPathComponent(path)
    // Inspect the directory entry so Finder can select a symbolic link even if its target is absent.
    _ = try FileManager.default.attributesOfItem(atPath: url.path)
    return .selectFile(url)
  }

  @MainActor func show(reportError: @escaping @MainActor @Sendable (Error) -> Void) {
    switch self {
    case .openFolder(let url):
      NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
        if let error { Task { @MainActor in reportError(error) } }
      }
    case .selectFile(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
    }
  }
}
