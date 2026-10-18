import AppKit
import Darwin
import GitPierCore

struct OperationNavigationSnapshot: Equatable {
  let root: String
  let common: String
  let review: GitOperationReview
  let remotes: [GitRemote]
  let metadataDirectories: [String]
  let filesystemIdentity: String
}
@MainActor extension RepositoryModel {
  func operationNavigationSnapshot() async throws -> OperationNavigationSnapshot {
    let git = await git()
    let root = try await git.validate().path
    let common = try await git.commonDirectory().path
    let review = try await git.reviewOperation()
    let remotes = try await git.remotes()
    let directories = try await git.metadataDirectories().map(\.path)
    let identity = try ([root, common] + directories).map { path in
      var attributes = stat()
      guard lstat(path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFDIR else { throw GitPierError.indexChanged }
      return "\(attributes.st_dev):\(attributes.st_ino)"
    }.joined(separator: ":")
    return OperationNavigationSnapshot(root: root, common: common, review: review, remotes: remotes,
      metadataDirectories: directories, filesystemIdentity: identity)
  }
  func captureOperationRecovery(_ id: UUID) async {
    guard let state = try? await operationNavigationSnapshot() else { return }
    store.operationNavigation[id] = state
    let action: OperationRecoveryAction = status.files.contains(where: \.isConflicted) ? .conflicts
      : status.operation == .rebase ? .rebase : needsUpstream ? .upstream : .repository
    store.operations.update(id, recovery: action)
    let live = Set(store.operations.records.map(\.id))
    store.operationNavigation = store.operationNavigation.filter { live.contains($0.key) }
  }
}
@MainActor extension AppStore {
  /// Navigation only. Every mutating button remains in the original reviewed workflow.
  func openOperation(_ record: WorkflowOperationRecord) async {
    guard let id = record.repositoryID, let model = models[id],
      repositories.contains(where: { $0.id == id && $0.path == model.record.path }) else {
      error = text("The repository is no longer available.", "仓库已不可用。"); return
    }
    do {
      let state = try await model.operationNavigationSnapshot()
      guard models[id] === model, !model.busy,
        repositories.contains(where: { $0.id == id && $0.path == state.root }) else { throw GitPierError.indexChanged }
      if record.recovery != .repository && record.recovery != .credentials {
        guard let expected = operationNavigation[record.id], expected == state else { throw GitPierError.indexChanged }
      }
      select(id)
      await model.activate(refresh: true)
      guard models[id] === model, selectedID == id else { return }
      if record.recovery != .repository && record.recovery != .credentials {
        guard try await model.operationNavigationSnapshot() == state else { throw GitPierError.indexChanged }
      }
      switch record.recovery {
      case .conflicts: model.setPage("conflicts")
      case .rebase: model.showRebaseRecovery = true
      case .upstream: model.setPage("branches")
      case .credentials: showCredentials = true
      case .repository: model.setPage("commit")
      case .reviewJournal: showReviewRecovery = true
      }
    } catch { self.error = text("The operation context changed. Refresh the repository and review its current state.", "操作上下文已变化，请刷新仓库并审查当前状态。") }
  }
}
