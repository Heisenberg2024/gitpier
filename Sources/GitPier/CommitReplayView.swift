import GitPierCore
import SwiftUI

struct CommitReplayRequest: Identifiable {
  let id = UUID()
  let commits: [String]
}

/// Reads belong to this sheet; confirmed writes belong to the original repository model.
struct CommitReplayView: View {
  @ObservedObject var model: RepositoryModel
  let input: CommitReplayRequest
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @StateObject private var request = WorkflowRequest()
  @State private var review: CommitReplayReview?
  @State private var order: [String] = []
  @State private var selected: String?
  @State private var confirming = false
  @State private var confirmed: CommitReplayReview?
  var selectedIndex: Int? { order.firstIndex { $0 == selected } }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(store.text("Review Cherry-pick", "审查 Cherry-pick")).font(.title2.weight(.semibold))
      if let review {
        reviewSummary(review)
        orderControls
        commitList(review)
        if let commit = review.commits.first(where: { $0.hash == selected }) {
          CommitDetailView(model: model, commit: commit, replayReview: review, onClose: {}).id(commit.hash)
            .frame(minHeight: 240)
        }
      } else { WorkflowProblem(request: request); Spacer() }
      footer
    }.padding(20).frame(minWidth: 850, idealWidth: 1050, minHeight: 650, idealHeight: 800)
      .modifier(AppAppearance(store: store))
      .onAppear { load() }.onDisappear { request.cancel() }
      .onChange(of: store.selectionIdentity) { _, _ in dismiss() }
      .onChange(of: model.pageIdentity) { _, _ in dismiss() }
      .sheet(isPresented: $confirming) { confirmation }
  }
  @ViewBuilder private func reviewSummary(_ review: CommitReplayReview) -> some View {
    Text(model.title + " · " + review.operation.branch).font(.headline)
    Text([review.workingTree, "\n", review.gitDirectory, "\nHEAD ", review.operation.head ?? ""].joined())
      .font(.caption.monospaced()).textSelection(.enabled)
    Text(store.text("Commits run from top to bottom. Duplicate patches or empty results stop for an explicit Skip or Abort. Merge commits are not supported. No Push follows.",
      "提交将从上到下执行。重复补丁或空结果会停止，等待明确跳过或中止。不支持合并提交，不会接着推送。"))
      .font(.caption).foregroundStyle(.secondary)
    if !review.alreadyReachable.isEmpty {
      Text(store.text("\(review.alreadyReachable.count) selected commits are already reachable from HEAD; inspect their changes before applying again.",
        "所选提交中有 \(review.alreadyReachable.count) 个已可从 HEAD 到达，请先审查改动再决定是否再次应用。"))
        .font(.caption).foregroundStyle(.orange)
    }
  }
  private var orderControls: some View {
    HStack {
      Text(store.text("Execution order", "执行顺序")).font(.headline)
      Spacer()
      Button { move(-1) } label: { Image(systemName: "arrow.up") }
        .disabled(selectedIndex == nil || selectedIndex == 0).accessibilityIdentifier("replay.move.up")
        .help(store.text("Move selected commit up", "上移所选提交"))
      Button { move(1) } label: { Image(systemName: "arrow.down") }
        .disabled(selectedIndex == nil || selectedIndex == order.count - 1).accessibilityIdentifier("replay.move.down")
        .help(store.text("Move selected commit down", "下移所选提交"))
    }
  }
  private func commitList(_ review: CommitReplayReview) -> some View {
    // The review is bounded to 200 rows. Eager geometry keeps the shared thumb's
    // end stable; List estimates can grow the document after an end drag.
    ScrollViewReader { proxy in
      ScrollView {
        VStack(spacing: 2) {
          ForEach(Array(order.enumerated()), id: \.element) { index, hash in
            if let commit = review.commits.first(where: { $0.hash == hash }) {
              commitRow(commit, index: index, hash: hash)
            }
          }
        }.padding(4)
      }.onMoveCommand { direction in
        let index = selectedIndex ?? 0
        let next = direction == .up ? max(0, index - 1) : direction == .down ? min(order.count - 1, index + 1) : index
        if order.indices.contains(next) { selected = order[next] }
      }.onChange(of: selected) { _, hash in if let hash { proxy.scrollTo(hash) } }
    }.frame(minHeight: 100, idealHeight: 160, maxHeight: 210)
  }
  private func commitRow(_ commit: CommitRecord, index: Int, hash: String) -> some View {
    Button { selected = hash } label: {
      VStack(alignment: .leading, spacing: 4) {
        Text("\(index + 1). " + commit.subject).lineLimit(2)
        Text(hash).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
      }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        .background(selected == hash ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
    }.buttonStyle(.plain).id(hash).accessibilityIdentifier("replay.commit." + hash)
  }
  private var footer: some View {
    HStack {
      Spacer()
      Button(store.text("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
      Button(store.text("Apply Reviewed Commits…", "应用已审查提交…")) {
        confirmed = try? review?.reordered(order); confirming = confirmed != nil
      }.disabled(review == nil || model.busy || request.loading).accessibilityIdentifier("replay.apply")
    }
  }
  private var confirmation: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(store.text("Apply commits to this branch?", "将提交应用到此分支？")).font(.headline)
      ScrollView {
        Text(confirmationDetail).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
      }.frame(maxHeight: 280)
      HStack {
        Spacer()
        Button(store.text("Cancel", "取消")) { confirming = false }.keyboardShortcut(.defaultAction)
        Button(store.text("Cherry-pick", "Cherry-pick")) { execute() }.disabled(model.busy)
          .accessibilityIdentifier("replay.confirm")
      }
    }.padding(24).frame(width: 620).modifier(AppAppearance(store: store))
  }
  private var confirmationDetail: String {
    guard let confirmed else { return "" }
    let commits = confirmed.commits.enumerated().map { "\($0.offset + 1). \($0.element.subject)\n\($0.element.hash)" }.joined(separator: "\n\n")
    return [confirmed.workingTree, "\n", confirmed.operation.branch, " · HEAD ", confirmed.operation.head ?? "", "\n\n", commits].joined()
  }
  private func move(_ delta: Int) {
    guard let index = selectedIndex, order.indices.contains(index + delta) else { return }
    order.swapAt(index, index + delta)
  }
  private func load() {
    let selection = store.selectionIdentity, page = model.pageIdentity, path = model.record.path, executable = store.settings.gitPath
    request.start { ticket in
      let value = try await model.git().reviewCommitReplay(.cherryPick, commits: input.commits, expectedIndex: model.snapshot)
      guard request.current(ticket), store.current === model, !store.showDashboard, store.selectionIdentity == selection,
        model.pageIdentity == page, model.record.path == path, store.settings.gitPath == executable else { return }
      review = value; order = value.commits.map(\.hash); selected = order.first
    }
  }
  private func execute() {
    guard let confirmed, !model.busy, store.current === model, !store.showDashboard else { return }
    self.confirmed = nil; confirming = false; dismiss()
    model.run(label: "Cherry-pick", updatesCommitState: .history) { git in
      model.output = try await git.executeCommitReplay(confirmed)
    }
  }
}

struct SequencerBanner: View {
  @ObservedObject var model: RepositoryModel
  @EnvironmentObject var store: AppStore
  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 3) {
        Text(model.status.operation == .cherryPick ? store.text("Cherry-pick in progress", "Cherry-pick 尚未完成") : store.text("Revert in progress", "Revert 尚未完成")).font(.callout.weight(.semibold))
        if let state = model.sequencer {
          Text((state.currentHash ?? "") + (state.remaining.isEmpty ? store.text(" · single commit", " · 单提交")
            : store.text(" · \(state.remaining.count) in native todo (including current)", " · 原生待办中 \(state.remaining.count) 个（含当前）")))
            .font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
        }
      }
      Spacer()
      Button(store.text("Review Recovery…", "审查恢复…")) { model.showSequencerRecovery = true }.disabled(model.busy)
        .accessibilityIdentifier("replay.recovery")
    }.padding(10).background(Color.orange.opacity(0.07))
  }
}

struct SequencerRecoveryView: View {
  @ObservedObject var model: RepositoryModel
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @StateObject private var request = WorkflowRequest()
  @State private var state: GitSequencerState?
  @State private var control: SequencerControlReview?
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(store.text("Review Git Recovery", "审查 Git 恢复")).font(.title2.weight(.semibold))
      Text(model.record.path).font(.caption).textSelection(.enabled)
      WorkflowProblem(request: request)
      if let state {
        Text((state.operation == .cherryPick ? "Cherry-pick" : "Revert") + " · " + state.review.branch).font(.headline)
        recoveryPlan(state)
        recoveryControls
      } else { Spacer() }
      HStack { Spacer(); Button(store.text("Close", "关闭")) { dismiss() }.keyboardShortcut(.cancelAction) }
    }.padding(20).frame(width: 740, height: 520).modifier(AppAppearance(store: store))
      .onAppear { load() }.onDisappear { request.cancel() }
      .onChange(of: store.selectionIdentity) { _, _ in dismiss() }
      .onChange(of: model.pageIdentity) { _, _ in dismiss() }
      .sheet(isPresented: Binding(get: { control != nil }, set: { if !$0 { control = nil } })) {
        confirmation
      }
  }
  private func recoveryPlan(_ state: GitSequencerState) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text(currentCommitDetail(state)).font(.caption.monospaced()).textSelection(.enabled)
        ForEach(Array(state.remaining.enumerated()), id: \.offset) { index, step in
          Text("\(index + 1). \(step.subject)\n\(step.hash)").font(.callout).textSelection(.enabled)
        }
        Text(store.text("The native todo includes the stopped commit. Resolve and stage conflicts before Continue. Empty results require Skip or Abort. Hook or signing errors may require recovery in the repository terminal; requirements remain enabled.",
          "原生待办包含停止的提交。请解决并暂存冲突后再继续；空结果需跳过或中止。Hooks 或签名错误可能需要在仓库终端恢复，相应要求保持启用。"))
          .font(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  private var recoveryControls: some View {
    HStack {
      Button(store.text("Resolve Conflicts", "解决冲突")) { dismiss(); model.openConflicts() }
      Spacer()
      ForEach(SequencerControl.allCases, id: \.self) { action in
        Button(title(action) + "…") { prepare(action) }.disabled(model.busy || request.loading)
          .accessibilityIdentifier("replay.control." + action.rawValue)
      }
    }
  }
  private var confirmation: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title(control?.action ?? .continue)).font(.headline)
      Text(confirmationReason)
      if let control {
        ScrollView {
          Text(confirmationDetail(control))
            .font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 260)
      }
      HStack { Spacer()
        Button(store.text("Cancel", "取消")) { control = nil }.keyboardShortcut(.defaultAction)
        Button(title(control?.action ?? .continue)) { execute() }.accessibilityIdentifier("replay.control.confirm")
      }
    }.padding(24).frame(width: 580).modifier(AppAppearance(store: store))
  }
  private var confirmationReason: String {
    switch control?.action ?? .continue {
    case .abort: return store.text("Restore the sequence's starting state. Changes made while resolving may be lost.", "恢复序列起始状态，解决冲突期间的修改可能丢失。")
    case .skip: return store.text("Discard the current replay's changes and continue with the remaining commits.", "放弃当前重放提交的改动，继续执行剩余提交。")
    case .continue: return store.text("Create the reviewed commit and continue the native sequence. Hooks and signing remain enabled.", "创建已审查提交并继续原生序列，保持 Hooks 与签名启用。")
    }
  }
  private func currentCommitDetail(_ state: GitSequencerState) -> String {
    ["HEAD ", state.review.head ?? "", "\n", store.text("Current", "当前"), ": ", state.currentHash ?? store.text("Unknown", "未知")].joined()
  }
  private func confirmationDetail(_ control: SequencerControlReview) -> String {
    let operation = control.state.operation == .cherryPick ? "Cherry-pick" : "Revert"
    let remaining = control.state.remaining.enumerated().map { "\($0.offset + 1). \($0.element.subject)\n\($0.element.hash)" }.joined(separator: "\n")
    return [control.workingTree, "\n", operation, " · ", control.state.review.branch, "\n", currentCommitDetail(control.state), "\n", remaining].joined()
  }
  private func title(_ action: SequencerControl) -> String {
    switch action { case .continue: store.text("Continue", "继续"); case .skip: store.text("Skip", "跳过"); case .abort: store.text("Abort", "中止") }
  }
  private func load() {
    let selection = store.selectionIdentity, page = model.pageIdentity, path = model.record.path, executable = store.settings.gitPath
    request.start { ticket in
      let value = try await model.git().sequencerState()
      guard request.current(ticket), store.current === model, !store.showDashboard,
        store.selectionIdentity == selection, model.pageIdentity == page,
        model.record.path == path, store.settings.gitPath == executable else { return }
      state = value
    }
  }
  private func prepare(_ action: SequencerControl) {
    let selection = store.selectionIdentity, page = model.pageIdentity, path = model.record.path, executable = store.settings.gitPath
    request.start { ticket in
      let value = try await model.git().reviewSequencerControl(action)
      guard request.current(ticket), store.current === model, !store.showDashboard,
        store.selectionIdentity == selection, model.pageIdentity == page,
        model.record.path == path, store.settings.gitPath == executable else { return }
      guard state == value.state else {
        state = value.state; control = nil
        throw GitPierError.invalidInput("The sequence changed. Review the updated recovery state before choosing an action again.")
      }
      control = value
    }
  }
  private func execute() {
    guard let control, !model.busy, store.current === model, !store.showDashboard else { return }
    self.control = nil; dismiss()
    model.run(label: title(control.action), updatesCommitState: .history) { git in
      model.output = try await git.controlSequencer(control)
    }
  }
}
