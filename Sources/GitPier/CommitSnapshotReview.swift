import GitPierCore

/// Only operations with a known local effect may advance the review baseline.
enum CommitStateUpdate {
  case index, history, checkout, reset
  case commit(head: String, branch: String, acceptsIndex: Bool)

  func accepts(_ before: IndexSnapshot, _ after: IndexSnapshot) -> Bool {
    switch self {
    case .index:
      return before.head == after.head && before.branch == after.branch
    case .history:
      return before.branch == after.branch && after.paths.isEmpty
    case .checkout:
      return after.paths.isEmpty || before.tree == after.tree
    case .reset:
      return before.branch == after.branch && (after.paths.isEmpty || before.tree == after.tree)
    case .commit(let head, let branch, let acceptsIndex):
      return acceptsIndex && after.head == head && after.branch == branch
    }
  }
}

/// The review baseline is explicit and process-local. Refreshing never acknowledges a notice.
struct CommitSnapshotReview {
  private(set) var reviewed: IndexSnapshot?
  private(set) var current: IndexSnapshot?

  var requiresReview: Bool {
    guard let reviewed, let current else { return false }
    return reviewed.identity != current.identity
  }

  mutating func observe(_ snapshot: IndexSnapshot, ownedChangeFrom: String?) {
    current = snapshot
    // A read can already have observed our write in flight. Accept that write only
    // when its entry snapshot was reviewed; it cannot consume an earlier external change.
    if reviewed == nil || (ownedChangeFrom != nil && reviewed?.identity == ownedChangeFrom
      && ownedChangeFrom != snapshot.identity) {
      reviewed = snapshot
    }
  }

  mutating func acknowledge(_ snapshot: IndexSnapshot) {
    // Never let an older open sheet acknowledge a newer, unseen state.
    guard current?.identity == snapshot.identity else { return }
    reviewed = snapshot
  }
}

@MainActor extension RepositoryModel {
  func commitReviewDetail(expected: IndexSnapshot, selection: [FileChange]) -> String {
    var sections: [String] = []
    if amend {
      sections.append(store.text(
        "This rewrites commit history. Ensure the last commit has not been shared.",
        "这会重写历史，请确认最后一次提交尚未共享。"))
    }
    if let previous = indexReview.reviewed, previous.identity != expected.identity {
      var changes = [store.text("Changes since your last review:", "自上次审查后发生的变化：")]
      if previous.branch != expected.branch {
        changes.append(store.text("Branch: ", "分支: ") + previous.branch + " → " + expected.branch)
      }
      if previous.head != expected.head {
        let unborn = store.text("No commits", "尚无提交")
        changes.append("HEAD: " + (previous.head.map { String($0.prefix(8)) } ?? unborn)
          + " → " + (expected.head.map { String($0.prefix(8)) } ?? unborn))
      }
      if previous.tree != expected.tree {
        changes.append("Index: " + String(previous.tree.prefix(8)) + " → " + String(expected.tree.prefix(8))
          + store.text(" (staged files: ", "（暂存文件数: ") + "\(previous.paths.count) → \(expected.paths.count)"
          + store.text(")", "）"))
      }
      changes.append(store.text(
        "Review this snapshot now, or acknowledge it and commit later. Further changes require another review.",
        "请审查当前快照后提交，也可先标记已审查、稍后提交。之后如有新变化，将重新要求审查。"))
      sections.append(changes.joined(separator: "\n"))
    }
    let none = store.text("None", "无")
    sections.append(store.text("Staged files (\(expected.paths.count))", "当前暂存文件（\(expected.paths.count)）")
      + "\n" + (expected.paths.isEmpty ? none : expected.paths.joined(separator: "\n")))
    sections.append(store.text("Selected files (\(selection.count))", "本次选择文件（\(selection.count)）")
      + "\n" + selection.map(\.path).joined(separator: "\n"))
    return sections.joined(separator: "\n\n")
  }
}
