import GitPierCore
import SwiftUI

struct ContextWorkflowView: View {
  @ObservedObject var model: RepositoryModel
  @ObservedObject var workspace: WorkspaceModel
  @EnvironmentObject var store: AppStore
  var onAction: ((ContextWorkflowAction, ContextWorkflowInput) -> Void)?
  var onAbort: ((GitOperation, ContextWorkflowInput) -> Void)?
  @State private var contentHeight: CGFloat = 240
  var body: some View {
    // Age only the already observed Fetch metadata. This never polls Git.
    TimelineView(.periodic(from: .now, by: 60)) { timeline in
      let input = model.workflowInput(now: timeline.date)
      let advice = ContextWorkflowAdvice.evaluate(input)
      ScrollView {
        content(advice, input)
          .padding(18)
          .background(GeometryReader { geometry in
            Color.clear
              .onAppear { updateHeight(geometry.size.height) }
              .onChange(of: geometry.size.height) { _, height in updateHeight(height) }
          })
      }
      .scrollContentBackground(.hidden)
      .frame(width: 400, height: min(440, max(110, contentHeight)))
      .transaction { $0.disablesAnimations = true }
      .accessibilityIdentifier("gitpier.workflow.guidance")
    }
  }
  private func updateHeight(_ height: CGFloat) {
    guard height.isFinite, height > 0 else { return }
    if abs(contentHeight - height) > 0.5 { contentHeight = height }
  }
  private func content(_ advice: ContextWorkflowAdvice, _ input: ContextWorkflowInput) -> some View {
    let status = ContextWorkflowPresentation(advice: advice, input: input, store: store, hasNotice: model.workflowMessage != nil)
    let reviewing = advice.isReviewingChanges(input)
    let quiet = [.aligned, .localOnly, .addFiles].contains(advice.kind)
    return VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 9) {
        Image(systemName: status.symbol).foregroundStyle(status.color).font(.system(size: 15, weight: .semibold))
          .accessibilityHidden(true)
        Text(model.workflowMessage != nil && status.level != .blocked ? store.text("Review updated context", "审查更新后的上下文")
          : reviewing ? store.text("Changes are already open for review", "已在当前页面审查修改")
          : quiet ? store.text("No priority suggestions", "当前没有需要优先处理的建议") : title(advice, input))
          .font(.headline).fixedSize(horizontal: false, vertical: true)
        if model.workflowPreparing { ProgressView().controlSize(.small) }
      }.accessibilityElement(children: .combine).accessibilityValue(status.label)
      Text(reviewing
        ? store.text("\(input.status.staged.count) staged and \(input.status.files.filter(\.isUnstaged).count) unstaged files (\(input.status.untracked.count) untracked). Use the open Diff and commit controls to choose the next commit. These changes remain uncommitted.",
          "\(input.status.staged.count) 个已暂存、\(input.status.files.filter(\.isUnstaged).count) 个未暂存文件（含 \(input.status.untracked.count) 个未跟踪文件）。请使用当前 Diff 和提交控件选择提交范围；这些修改仍未提交。")
        : reason(advice, input))
        .font(.callout).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("gitpier.workflow.reason")
      VStack(alignment: .leading, spacing: 4) {
        Text(model.title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle).help(model.title)
        Label(input.status.branch.isEmpty ? store.text("No branch", "无分支") : input.status.branch, systemImage: "arrow.triangle.branch")
          .font(.caption.weight(.medium)).lineLimit(2).truncationMode(.middle).help(input.status.branch)
        Text((input.linkedWorktree ? store.text("Linked Worktree", "关联工作树") : store.text("Working tree", "工作树")) + ": " + input.workingTree)
          .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).help(input.workingTree)
        if input.status.upstream != nil && !advice.isRoutineChangeReview && !input.busy && !input.refreshing {
          Text(trackingLabel(input)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          Text(store.text("Last Fetch", "上次获取") + ": " + fetchDate).font(.caption).foregroundStyle(.secondary)
        }
      }
      let actions = advice.visibleActions(in: input)
      if !actions.isEmpty {
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          ForEach(actions, id: \.self) { action in
            Button { dispatch(action, input) } label: {
              HStack(spacing: 8) {
                Image(systemName: action == .compareIncoming || action == .compareOutgoing ? "arrow.left.arrow.right" : "arrow.right.circle")
                  .foregroundStyle(action == .compareIncoming || action == .compareOutgoing ? Color.accentColor : Color.secondary)
                Text(actionTitle(action, input)).frame(maxWidth: .infinity, alignment: .leading)
              }.padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
            }.disabled(model.workflowPreparing || input.busy || input.refreshing)
              .accessibilityIdentifier("gitpier.workflow." + action.rawValue)
          }
          if let operation = input.status.operation, operation != .rebase,
             input.available, !input.stale {
            Button(store.text("Abort…", "中止…")) {
              if let onAbort { onAbort(operation, input) }
              else { model.perform([operation == .cherryPick ? "cherry-pick" : operation.rawValue, "--abort"],
                confirmation: store.text("Abort the operation and restore its starting state?", "中止操作并恢复起始状态？")) }
            }.disabled(input.busy || input.refreshing || model.workflowPreparing)
              .accessibilityIdentifier("gitpier.workflow.abort")
          }
        }.buttonStyle(.workspace).controlSize(.regular)
      }
      if let message = model.workflowMessage {
        Text(message).font(.callout).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("gitpier.workflow.notice")
      }
      if !actions.contains(.refresh), !input.busy, !input.refreshing {
        HStack {
          Spacer()
          Button(store.text("Refresh analysis", "刷新分析")) { dispatch(.refresh, input) }
            .buttonStyle(.link).disabled(model.workflowPreparing)
            .accessibilityIdentifier("gitpier.workflow.refreshAnalysis")
        }
      }
    }
  }
  private func dispatch(_ action: ContextWorkflowAction, _ input: ContextWorkflowInput) {
    if let onAction { onAction(action, input) }
    else { Task { await model.prepareWorkflow(action, displayed: input) } }
  }
  private func trackingLabel(_ input: ContextWorkflowInput) -> String {
    let counts = input.status.upstreamComparable ? "↑\(input.status.ahead) ↓\(input.status.behind)" : store.text("Not comparable", "不可比较")
    return store.text("Tracking snapshot", "跟踪快照") + ": " + (input.status.upstream ?? "—")
      + " · " + counts
  }
  private var fetchDate: String {
    model.workflowRemoteCheck().lastSuccess?.formatted(
      .dateTime.locale(Locale(identifier: store.settings.language == .english ? "en" : "zh_CN")).month().day().hour().minute())
      ?? store.text("Unknown", "未知")
  }
  private func title(_ advice: ContextWorkflowAdvice, _ input: ContextWorkflowInput) -> String {
    switch advice.kind {
    case .busy: return store.text("Git operation in progress", "Git 操作进行中")
    case .refreshing, .checkingRemote: return store.text("Updating workflow analysis", "正在更新工作流分析")
    case .conflicts:
      let name = ContextWorkflowPresentation(advice: advice, input: input, store: store).operationName
      return store.text("Resolve \(name.lowercased()) conflicts first", "先解决\(name)冲突")
    case .unfinishedOperation:
      return ContextWorkflowPresentation(advice: advice, input: input, store: store).operationName + store.text(" in progress", " 进行中")
    case .detached: return store.text("Retain detached work on a branch", "先用分支保留游离提交")
    case .preserveBeforeSync: return store.text("Preserve local changes before integrating", "整合远端提交前先保留本地修改")
    case .stagedChanges, .firstCommit: return store.text("Review the Index before committing", "提交前审查暂存区")
    case .localChanges: return store.text("Choose the changes for your next commit", "选择下一次提交的修改")
    case .diverged: return store.text("Review diverged histories before choosing a strategy", "审查分叉后再选择整合策略")
    case .incoming: return store.text("Review incoming commits before Pull", "拉取前审查传入提交")
    case .outgoing: return store.text("Review outgoing commits before Push", "推送前审查待发布提交")
    case .aligned: return store.text("No Git action is needed for this snapshot", "当前快照无需额外 Git 操作")
    default: return store.text("Suggested next step", "建议下一步")
    }
  }
  private func reason(_ advice: ContextWorkflowAdvice, _ input: ContextWorkflowInput) -> String {
    let state = input.status
    let staged = state.staged.count, unstaged = state.files.filter(\.isUnstaged).count
    switch advice.kind {
    case .unavailable: return store.text("This working tree cannot be read. Recheck its location and permissions before starting Git work.", "无法读取此工作树。开始 Git 操作前，请先核查位置和权限。")
    case .refreshing: return store.text("Reading this working tree. Suggestions resume after the local snapshot is ready.", "正在读取此工作树，本地快照就绪后更新建议。")
    case .busy: return store.text("An operation or remote check already owns this target. Wait for its result before starting another step.", "此目标已有操作或远端检查正在执行，请等待结果后再进行下一步。")
    case .stale: return store.text("External changes were reported. The displayed branch, Index or tracking snapshot may be outdated; refresh before acting.", "检测到外部变更，当前分支、暂存区或跟踪快照可能已过时，请先刷新。")
    case .conflicts: return store.text("\(state.files.filter(\.isConflicted).count) paths remain unmerged. Resolve and review the intended result before continuing; synchronization is blocked.", "仍有 \(state.files.filter(\.isConflicted).count) 个未合并路径。先解决并审查结果，再继续操作；此时不建议同步。")
    case .unfinishedOperation: return store.text("The previous Git operation has not finished. Review its staged result and use the original continuation controls before starting other work.", "上一次 Git 操作尚未完成。请审查暂存结果，并通过原有恢复流程继续或中止，再开始其他工作。")
    case .detached: return store.text("HEAD is detached at \(String((state.head ?? "").prefix(8))). \(input.retainingBranches.isEmpty ? "No local branch names this tip; create one to retain it." : "A local branch already retains this tip; review it before switching.") Commit and Push are not suggested while detached.", "HEAD 游离于 \(String((state.head ?? "").prefix(8)))。\(input.retainingBranches.isEmpty ? "没有本地分支指向此提交，请先创建分支保留它。" : "已有本地分支指向此提交，请审查后切换。")游离状态下不建议继续提交或推送。")
    case .addFiles: return store.text("This branch has no commits and the working tree is empty. Add project files here before preparing an initial commit; synchronization has no local commit to use.", "此分支尚无提交，工作树为空。请先在此目录添加项目文件，再准备首次提交；目前没有可同步的本地提交。")
    case .firstCommit: return store.text("The branch has no commit yet: \(staged) staged and \(unstaged) unstaged files. Review the initial Index; no files are staged automatically.", "此分支尚无提交：\(staged) 个已暂存、\(unstaged) 个未暂存文件。请审查首次提交的暂存区，不会自动暂存任何文件。")
    case .stagedChanges: return store.text("\(staged) staged and \(unstaged) unstaged files. Review exactly the staged content; remaining edits and partial staging stay separate.", "\(staged) 个已暂存、\(unstaged) 个未暂存文件。请审查实际暂存内容，保留其余修改及部分暂存边界。")
    case .localChanges: return store.text("\(state.files.count) changed paths, including \(state.untracked.count) untracked, with nothing staged. Review files or hunks and choose what belongs in the next commit.", "\(state.files.count) 个变更路径，含 \(state.untracked.count) 个未跟踪文件，暂存区为空。请审查文件或差异块，选择本次提交范围。")
    case .preserveBeforeSync: return store.text("Local edits coexist with \(state.behind) incoming commits. Commit or explicitly Stash the intended work before integrating; Pull and Rebase are not suggested yet.", "本地修改与 \(state.behind) 个传入提交同时存在。请先提交或主动 Stash 需要保留的内容，再整合；此时不建议拉取或变基。")
    case .localOnly: return store.text("The working tree is clean and has no configured remote. Local work is complete; add a remote only when you intend to share it.", "工作树干净，未配置远程。本地工作已就绪；需要共享时再添加远程。")
    case .noUpstream: return store.text("This branch does not track an upstream. Choose an existing remote branch, or review Fetch to discover one; this does not publish a branch automatically.", "当前分支未设置上游。请选择已有远程分支，或先审查获取以发现目标；不会自动发布分支。")
    case .authentication: return store.text("The last check requires foreground authentication. Review this repository's credential selection before retrying Fetch.", "最近一次检查需要前台认证，请先核查此仓库的凭证选择，再主动重试获取。")
    case .fetchFailed: return store.text("The last Fetch failed, so old counts cannot establish the remote state. Review the target before an explicit retry.", "最近一次获取失败，旧计数不能确认远端状态。请审查目标后再主动重试。")
    case .checkingRemote: return store.text("The existing Fetch is still queued or checking. Wait for its authoritative result; do not start duplicate synchronization.", "既有获取仍在排队或检查中，请等待其结果，避免重复同步。")
    case .verifyRemote: return store.text("The current remote check is unconfirmed or outdated. Review Fetch before deciding whether to Pull or Push; cached counts are not live server state.", "当前远端检查尚未确认或已过期。请先审查获取，再决定是否拉取或推送；缓存计数不代表服务器实时状态。")
    case .missingUpstream: return store.text("The configured upstream has no comparable local tracking commit, even after the recorded check. Review its branch configuration instead of guessing a Pull or Push target.", "配置的上游没有可比较的本地跟踪提交。请核查分支设置，不猜测拉取或推送目标。")
    case .diverged: return store.text("This branch has \(state.ahead) local-only and \(state.behind) tracking-only commits. Compare the fixed tips, then explicitly choose Merge or Rebase. Neither path automatically pushes.", "此分支有 \(state.ahead) 个本地独有、\(state.behind) 个跟踪分支独有提交。先比较固定提交，再明确选择合并或变基；两者均不会自动推送。")
    case .incoming: return store.text("The clean branch is behind its tracking snapshot by \(state.behind) commits. Compare the incoming changes, then review Pull into this exact branch.", "工作树干净，当前分支落后跟踪快照 \(state.behind) 个提交。请先比较传入修改，再审查拉取到此分支。")
    case .outgoing: return store.text("The clean branch is ahead of its tracking snapshot by \(state.ahead) commits. Compare the outgoing changes and review the configured single-branch Push destination.", "工作树干净，当前分支领先跟踪快照 \(state.ahead) 个提交。请先比较待发布修改，再审查配置的单分支推送目标。")
    case .aligned: return store.text("The working tree is clean and the branch matches its local tracking tip at the recorded Fetch. This does not promise that the server has not changed since.", "工作树干净，分支与已记录获取时的本地跟踪提交一致；这不保证服务器此后没有变化。")
    }
  }
  private func actionTitle(_ action: ContextWorkflowAction, _ input: ContextWorkflowInput) -> String {
    switch action {
    case .refresh: return store.text("Refresh local state", "刷新本地状态")
    case .reviewChanges: return store.text(input.status.staged.isEmpty ? "Review changes" : "Review staged content", input.status.staged.isEmpty ? "审查修改" : "审查暂存内容")
    case .resolveConflicts: return store.text("Resolve Conflicts…", "解决冲突…")
    case .continueOperation: return store.text(input.status.operation == .rebase ? "Review Rebase…" : "Continue", input.status.operation == .rebase ? "审查变基…" : "继续")
    case .createBranch: return store.text("Create retaining branch…", "创建保留分支…")
    case .chooseBranch: return store.text("Review retaining branches", "审查保留此提交的分支")
    case .addRemote: return store.text("Add Remote…", "添加 Remote…")
    case .setUpstream: return store.text("Choose upstream…", "选择上游…")
    case .reviewFetch: return store.text("Review Fetch…", "审查获取…")
    case .reviewAuthentication: return store.text("Review repository credentials", "核查仓库凭证")
    case .compareIncoming: return store.text("Compare incoming commits", "比较传入提交")
    case .compareOutgoing: return store.text("Compare outgoing commits", "比较待发布提交")
    case .reviewPull: return store.text("Review Pull…", "审查拉取…")
    case .reviewPush: return store.text("Review Push…", "审查推送…")
    case .mergeUpstream: return store.text("Review Merge…", "审查合并…")
    case .rebaseUpstream: return store.text("Review Rebase…", "审查变基…")
    }
  }
}
