import Foundation
import GitPierCore
import SwiftUI

/// Live pane sizes are independent of repository state, file choices and Diff loading.
@MainActor final class WorkspacePanels: ObservableObject {
  @Published var trackedExpanded = true
  @Published var untrackedExpanded = true
  @Published var layout: PanelLayout
  init(_ layout: PanelLayout) { self.layout = layout }
}

struct DiffCacheKey: Hashable {
  let path: String
  let comparison: DiffComparison
  let ignoreWhitespace: Bool
}

struct FileStamp: Equatable {
  let modified: Date?
  let size: UInt64?
  let inode: UInt64?
  init(root: String, path: String) {
    let attributes = try? FileManager.default.attributesOfItem(
      atPath: URL(fileURLWithPath: root).appendingPathComponent(path).path)
    modified = attributes?[.modificationDate] as? Date
    size = attributes?[.size] as? UInt64
    inode = attributes?[.systemFileNumber] as? UInt64
  }
}

struct CachedDiff {
  let bytes: Data
  let document: DiffDocument
  let stamp: FileStamp
  var cost: Int {
    bytes.count + document.raw.utf8.count * 2 + document.pairs.count * 256
      + document.hunks.reduce(0) { $0 + $1.patch.count + 128 }
  }
}

struct RepositoryFileIndex: Sendable {
  let ordered: [FileChange]
  let byPath: [String: FileChange]
  let stagedCount: Int
  let trackedCount: Int
  let untrackedCount: Int
  let hasConflicts: Bool
  init(_ files: [FileChange]) {
    ordered = files.sorted {
      if $0.isUntracked != $1.isUntracked { return !$0.isUntracked }
      return $0.path.localizedStandardCompare($1.path) == .orderedAscending
    }
    byPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
    stagedCount = files.filter(\.isStaged).count
    untrackedCount = files.filter(\.isUntracked).count
    trackedCount = files.count - untrackedCount
    hasConflicts = files.contains(where: \.isConflicted)
  }
}
