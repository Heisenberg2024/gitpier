import AppKit
import Darwin
import GitPierCore

/// Filesystem identity is cached with the existing refresh. Toolbar rendering
/// uses memory only; no path resolution, stat, Git process or network request.
struct WorkflowFilesystem: Equatable, Sendable {
  let path: String
  let identity: String
  static func read(_ path: String) async -> Self? {
    await Task.detached(priority: .utility) {
      let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
      var attributes = stat()
      guard lstat(canonical, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFDIR else { return nil as Self? }
      return Self(path: canonical, identity: "\(attributes.st_dev):\(attributes.st_ino)")
    }.value
  }
}

struct WorkflowBranchRequest: Identifiable {
  enum Intent { case create, upstream, retainingCommit }
  let id = UUID()
  let intent: Intent
  let context: ContextWorkflowReview
}
struct WorkflowRemoteRequest: Identifiable {
  let id = UUID()
  let context: ContextWorkflowReview
}
struct WorkflowComparisonRequest: Identifiable {
  let id = UUID()
  let left: String
  let right: String
  let leftTitle: String
  let rightTitle: String
  let mode: BranchComparisonMode
  let targets: [String: BranchComparisonTarget]
}

@MainActor extension RepositoryModel {
  func workflowRemoteCheck() -> RemoteCheckRecord {
    guard let snapshot = store.workspace.entries[record.id]?.usable,
      snapshot.branch == status.branch, snapshot.upstream == status.upstream,
      let target = snapshot.remoteTarget, remotes.contains(where: { $0.name == target.remote.name && $0.fetchURL == target.remote.fetchURL }) else { return RemoteCheckRecord() }
    return store.workspace.remoteCheck(record.id)
  }
  func validateWorkflowSelection(_ context: ContextWorkflowReview?) throws {
    guard let context else { return }
    guard store.current === self, !store.showDashboard, store.models[record.id] === self,
      store.settings.gitPath == context.gitExecutable,
      URL(fileURLWithPath: record.path).resolvingSymlinksInPath().path == context.workingTree else { throw GitPierError.indexChanged }
  }
  func workflowInput(now: Date = Date()) -> ContextWorkflowInput {
    var value = ContextWorkflowInput()
    value.currentPage = page
    value.repositoryID = record.id
    value.workingTree = workflowFilesystem?.path ?? record.path
    value.filesystemIdentity = workflowFilesystem?.identity
    value.linkedWorktree = store.workspace.entries[record.id]?.usable?.isWorktree ?? false
    value.status = status; value.available = available && workflowFilesystem != nil
    value.busy = busy || store.workspace.authenticationIsBusy(record.id)
    value.refreshing = refreshing; value.stale = hasExternalChanges
    value.remoteCount = remotes.count
    let remote = workflowRemoteCheck()
    value.remotePhase = remote.phase
    value.remoteFresh = !remote.isStale(now: now, interval: store.workspace.remoteInterval(record.id))
    value.retainingBranches = branches.filter { !$0.remote && $0.hash == status.head }.map(\.name).sorted()
    return value
  }

  /// Review an immutable target before handing off to an existing workflow.
  /// Rendering the advice does not configure credentials, invoke Git, or fetch.
  func prepareWorkflow(_ action: ContextWorkflowAction, displayed: ContextWorkflowInput) async {
    guard !workflowPreparing, workflowSelectionMatches(displayed),
      (action == .refresh || ContextWorkflowAdvice.evaluate(displayed).actions.contains(action)) else { return }
    workflowMessage = nil
    if action == .refresh {
      guard !busy, !refreshing else { return }
      await activate(refresh: true); return
    }
    guard !busy, !refreshing else { return }
    if action == .compareIncoming || action == .compareOutgoing {
      guard let head = displayed.status.head, let upstream = displayed.status.upstream else { workflowChanged(); return }
      let incoming = action == .compareIncoming
      let upstreamKey = "upstream:" + displayed.status.branch
      workflowComparison = WorkflowComparisonRequest(left: incoming ? head : upstreamKey,
        right: incoming ? upstreamKey : head,
        leftTitle: incoming ? displayed.status.branch : upstream,
        rightTitle: incoming ? upstream : displayed.status.branch,
        mode: displayed.status.ahead > 0 && displayed.status.behind > 0 ? .mergeBase : .tips,
        targets: [head: .commit(head), upstreamKey: .upstream(branch: displayed.status.branch, head: head, name: upstream)])
      setPage("compare")
      return
    }
    // Present the existing confirmation immediately; its write button remains
    // disabled until the immutable review has completed. Cancelling owns this ID.
    let reviewID: UUID?
    if action == .reviewPull || action == .reviewPush {
      let push = action == .reviewPush
      let loading = PendingAction(title: store.text(push ? "Review Push" : "Review Pull", push ? "审查推送" : "审查拉取"),
        detail: store.text("Checking the current branch, upstream and Index…", "正在核对当前分支、上游和 Index…") + "\n\n" + displayed.workingTree + "\n" + displayed.status.branch,
        confirmTitle: store.text(push ? "Push" : "Pull", push ? "推送" : "拉取"), destructive: false, canConfirm: false, asynchronousReview: true, action: {})
      confirmation = loading; reviewID = loading.id
    } else { reviewID = nil }
    workflowPreparing = true
    defer {
      workflowPreparing = false
      if let reviewID, confirmation?.id == reviewID, confirmation?.canConfirm == false { confirmation = nil }
    }
    let observedRemotes = remotes, executable = store.settings.gitPath
    let context: ContextWorkflowReview
    do {
      context = try await git().reviewContextWorkflow()
    } catch {
      if !Task.isCancelled, reviewID == nil || confirmation?.id == reviewID,
        workflowSelectionMatches(displayed), status.branch == displayed.status.branch, page == displayed.currentPage { workflowChanged(); await refresh() }
      return
    }
    if let reviewID, confirmation?.id != reviewID { return }
    guard !Task.isCancelled, workflowSelectionMatches(displayed), !busy, !refreshing,
      store.settings.gitPath == executable, page == displayed.currentPage, status == displayed.status,
      ContextWorkflowAdvice.evaluate(workflowInput()).actions.contains(action),
      context.workingTree == displayed.workingTree,
      context.filesystemIdentity.first == displayed.filesystemIdentity,
      context.status == displayed.status, context.remotes == observedRemotes else {
      if !Task.isCancelled, workflowSelectionMatches(displayed), status.branch == displayed.status.branch, page == displayed.currentPage { workflowChanged(); await refresh() }
      return
    }
    switch action {
    case .refresh: break
    case .reviewChanges:
      setPage("commit")
      let staged = !context.status.staged.isEmpty
      filter = staged ? "staged" : "unstaged"
      comparison = staged ? .staged : .unstaged
      if let file = context.status.files.first(where: { staged ? $0.isStaged : $0.isUnstaged }) { select(file) }
    case .resolveConflicts: openConflicts()
    case .continueOperation:
      switch context.status.operation {
      case .rebase: showRebaseRecovery = true
      case .merge: reviewMergeContinuation()
      case .cherryPick, .revert:
        let command = context.status.operation == .cherryPick ? "cherry-pick" : "revert"
        perform([command, "--continue"], confirmation: workflowReviewDetails(context), context: context)
      case nil: workflowChanged()
      }
    case .createBranch, .chooseBranch, .setUpstream:
      workflowBranchRequest = WorkflowBranchRequest(intent: action == .createBranch ? .create : action == .setUpstream ? .upstream : .retainingCommit, context: context)
      setPage("branches")
    case .addRemote:
      workflowRemoteRequest = WorkflowRemoteRequest(context: context); setPage("remotes")
    case .reviewAuthentication:
      setPage("repository")
      workflowMessage = store.text("Review this repository's credential selection, then retry Fetch explicitly.", "请检查此仓库的凭证选择，然后主动重试获取。")
    case .reviewFetch:
      store.workspace.prepareFetch([record.id])
    case .compareIncoming, .compareOutgoing:
      break // Read-only handoff above never needs the write-review preflight.
    case .mergeUpstream, .rebaseUpstream:
      guard let upstream = context.upstreamHash else { workflowChanged(); return }
      let merge = action == .mergeUpstream
      let detail = workflowReviewDetails(context) + "\n\n" + store.text(
        merge ? "Merge the reviewed tracking commit into this branch. Conflicts stop for resolution; no Push follows." : "Replay local commits onto the reviewed tracking commit. This rewrites local history; no Push follows.",
        merge ? "将已审查的跟踪提交合并到此分支。冲突时停止等待处理，不会接着推送。" : "将本地提交变基到已审查的跟踪提交；这会改写本地历史，不会接着推送。")
      perform(merge ? ["merge", "--no-edit", upstream] : ["rebase", upstream], confirmation: detail, context: context)
    case .reviewPull, .reviewPush:
      let push = action == .reviewPush
      guard context.upstreamRemote != nil, context.upstreamHash != nil,
        (push ? context.singleBranchPush : context.singleBranchPull) else {
        workflowMessage = store.text("The configured synchronization does not resolve to one reviewed upstream branch. Review branch, destination, refspec and tag/submodule rules in Git before continuing.", "当前同步配置无法限定为已审查的单个上游分支。请先检查分支、目标、自定义 RefSpec、标签及子模块规则。")
        return
      }
      let strategy = store.settings.pullStrategy
      confirmation = PendingAction(id: reviewID ?? UUID(), title: store.text(push ? "Review Push" : "Review Pull", push ? "审查推送" : "审查拉取"),
        detail: workflowReviewDetails(context) + "\n\n" + store.text(
          push ? "Push this reviewed branch using the existing Git configuration. Uncommitted files are excluded. Hooks, signing and normal rejection handling remain enabled." : "Pull into this reviewed branch using the existing strategy (\(strategy)). Git may stop for conflicts. No Push follows.",
          push ? "按现有 Git 配置推送已审查的分支，不包含未提交文件。Hooks、签名和正常拒绝处理保持启用。" : "按现有策略（\(strategy)）拉取到已审查的分支。Git 可能停在冲突处，不会接着推送。"),
        confirmTitle: store.text(push ? "Push" : "Pull", push ? "推送" : "拉取"), destructive: false, asynchronousReview: true) { [weak self] in
          guard let self else { return }
          guard self.workflowSelectionMatches(displayed), self.store.settings.pullStrategy == strategy,
            ContextWorkflowAdvice.evaluate(self.workflowInput()).actions.contains(action) else { self.workflowChanged(); return }
          self.network(push ? "push" : "pull", context: context, reviewedStrategy: strategy)
        }
    }
  }
  private func workflowSelectionMatches(_ input: ContextWorkflowInput) -> Bool {
    store.current === self && !store.showDashboard && store.models[record.id] === self
      && store.repositories.contains { $0.id == input.repositoryID && $0.path == record.path }
      && record.id == input.repositoryID
      && URL(fileURLWithPath: record.path).resolvingSymlinksInPath().path == input.workingTree
  }
  private func workflowChanged() {
    workflowMessage = store.text("The repository, worktree, branch or snapshot changed. Refresh and review the updated suggestion before continuing.", "仓库、工作树、分支或快照已变化，请刷新并审查更新后的建议再继续。")
  }
  func workflowReviewDetails(_ context: ContextWorkflowReview) -> String {
    let state = context.status
    let remote = workflowRemoteCheck()
    let destination = context.remotes.first { $0.name == context.upstreamRemote }
    let details: [String] = [
      store.text("Working tree", "工作树") + ": " + context.workingTree,
      store.text("Branch / HEAD", "分支 / HEAD") + ": " + state.branch + " · " + String((state.head ?? "unborn").prefix(12)),
      store.text("Upstream", "上游") + ": " + (state.upstream ?? "—") + " · " + String((context.upstreamHash ?? "—").prefix(12)),
      store.text("Remote / destination", "远程 / 目标") + ": " + (context.upstreamRemote ?? "—") + " / " + (context.upstreamDestination ?? "—"),
      store.text("Fetch / Push URL", "获取 / 推送地址") + ": " + GitService.redact(destination?.fetchURL ?? "—") + " / " + GitService.redact(destination?.pushURL ?? "—"),
      store.text("Ahead / behind", "领先 / 落后") + ": \(state.ahead) / \(state.behind)",
      store.text("Staged / unstaged files", "已暂存 / 未暂存文件") + ": \(state.staged.count) / \(state.files.filter(\.isUnstaged).count)",
      store.text("Last successful Fetch", "上次成功获取") + ": " + (remote.lastSuccess?.formatted(date: .abbreviated, time: .shortened) ?? store.text("Unknown", "未知")),
      store.text("Tracking counts are a local Fetch snapshot, not a live server guarantee. Changes invalidate this review.", "跟踪计数来自本地 Fetch 快照，不保证服务器实时状态；上下文变化后此次审查失效。"),
    ]
    return details.joined(separator: "\n")
  }
}
