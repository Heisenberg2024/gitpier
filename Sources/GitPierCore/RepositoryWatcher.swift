import CoreServices
import Foundation

/// Watches both the working tree and resolved Git metadata (including worktree common directories).
public final class RepositoryWatcher: @unchecked Sendable {
  private var stream: FSEventStreamRef?
  private let queue = DispatchQueue(label: "GitPier.file-events")
  private var pending: DispatchWorkItem?
  private let changed: @Sendable () -> Void
  private let ignoredObjectDirectories: [String]
  public init(paths: [URL], changed: @escaping @Sendable () -> Void) {
    self.changed = changed
    ignoredObjectDirectories = paths.dropFirst().map {
      $0.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("objects").path
    }
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
      guard let info else { return }
      let watcher = Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
      let paths = unsafeBitCast(eventPaths, to: CFArray.self) as! [String]
      guard
        paths.contains(where: { path in
          !watcher.ignoredObjectDirectories.contains(where: {
            path == $0 || path.hasPrefix($0 + "/")
          })
        })
      else { return }
      watcher.schedule()
    }
    stream = FSEventStreamCreate(
      nil, callback, &context, paths.map(\.path) as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
      FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
          | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes))
    if let stream {
      FSEventStreamSetDispatchQueue(stream, queue)
      FSEventStreamStart(stream)
    }
  }
  private func schedule() {
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.changed() }
    pending = work
    queue.asyncAfter(deadline: .now() + 0.35, execute: work)
  }
  public func stop() {
    pending?.cancel()
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
    }
  }
  deinit { stop() }
}
