import GitPierCore
import SwiftUI

struct InteractiveRebaseRequest: Identifiable {
  let id = UUID()
  var upstream: String
}

struct InteractiveRebaseView: View {
  @ObservedObject var model: RepositoryModel
  let initialUpstream: String
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @StateObject private var request = WorkflowRequest()
  @State private var upstream = ""
  @State private var candidate: InteractiveRebaseCandidate?
  @State private var steps: [RebaseStep] = []
  @State private var selected: String?
  @State private var confirming = false
  @State private var problem: String?
  init(model: RepositoryModel, initialUpstream: String) {
    self.model = model; self.initialUpstream = initialUpstream
    _upstream = State(initialValue: initialUpstream)
  }
  var plan: InteractiveRebasePlan? { candidate.map { InteractiveRebasePlan(candidate: $0, steps: steps) } }
  var valid: Bool { plan.map { (try? $0.validate()) != nil } ?? false }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(store.text("Interactive Rebase", "交互式变基")).font(.title2.weight(.semibold))
      HStack {
        Text(store.text("Starting point", "起点"))
        TextField(store.text("Ancestor commit or upstream", "祖先提交或 Upstream"), text: $upstream)
          .textFieldStyle(.roundedBorder).onSubmit { load() }
          .accessibilityIdentifier("rebase.upstream")
        Button(store.text("Review Range", "审查范围")) { load() }.disabled(request.loading || model.busy)
      }
      Text(store.text("Commits after the starting point will be rewritten. Only clean, linear local branches are supported.",
                      "将改写起点之后的提交。仅支持工作区与 Index 干净的线性本地分支。"))
        .font(.caption).foregroundStyle(.secondary)
      WorkflowProblem(request: request)
      if let candidate {
        HStack {
          Text(candidate.review.branch).font(.headline)
          Text("HEAD " + String((candidate.review.head ?? "").prefix(12)))
          Text("← " + String(candidate.upstream.prefix(12)))
          Spacer()
          Button { move(-1) } label: { Image(systemName: "arrow.up") }
            .help(store.text("Move selected commit up", "上移所选提交"))
            .disabled(selectedIndex == nil || selectedIndex == 0)
          Button { move(1) } label: { Image(systemName: "arrow.down") }
            .help(store.text("Move selected commit down", "下移所选提交"))
            .disabled(selectedIndex == nil || selectedIndex == steps.count - 1)
        }.font(.caption)
        Text(store.text("Remote-tracking refs contain \(candidate.sharedCommits.count) of these commits. Other commits may also have been shared; refs may be stale. Never force-push automatically.",
                        "远程跟踪引用包含其中 \(candidate.sharedCommits.count) 个提交。其他提交也可能已经共享，引用可能过期；不会自动强制推送。"))
          .font(.caption).foregroundStyle(.orange)
        List(selection: $selected) {
          ForEach($steps) { $step in
            VStack(alignment: .leading, spacing: 8) {
              HStack(alignment: .top, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                  Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                  Picker(store.text("Action", "操作"), selection: $step.action) {
                    ForEach(RebaseAction.allCases, id: \.self) { action in
                      Text(actionTitle(action)).tag(action)
                    }
                  }
                  .labelsHidden().frame(width: 105)
                    .accessibilityIdentifier("rebase.action." + step.id)
                }
                VStack(alignment: .leading, spacing: 4) {
                  Text(step.commit.subject).lineLimit(2)
                  Text(commitMetadata(step, candidate: candidate))
                    .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
              }
              if step.action == .reword || step.action == .squash {
                Text(store.text(step.action == .squash ? "Final combined message" : "New commit message",
                                step.action == .squash ? "最终合并消息" : "新的提交消息")).font(.caption)
                TextEditor(text: $step.message).font(uiFont(size: 12, design: .monospaced))
                  .frame(height: 76).border(Color.secondary.opacity(0.25))
                  .accessibilityIdentifier("rebase.message." + step.id)
              }
            }.padding(.vertical, 6).tag(step.id)
              .accessibilityElement(children: .contain)
          }.onMove { source, destination in steps.move(fromOffsets: source, toOffset: destination) }
        }.listStyle(.inset).accessibilityIdentifier("rebase.plan")
      } else { Spacer() }
      if let problem { Text(problem).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
      if !steps.isEmpty && !valid {
        Text(store.text("Squash/Fixup need a preceding kept commit. Reword/Squash need a nonempty message.",
                        "Squash/Fixup 前必须有保留的提交，Reword/Squash 消息不能为空。"))
          .font(.caption).foregroundStyle(.orange)
      }
      HStack {
        Text(store.text("Drag commits or use the arrows to reorder.", "拖动提交或使用箭头调整顺序。")).font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button(store.text("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(store.text("Review & Rewrite History…", "审查并改写历史…")) { confirming = true }
          .disabled(!valid || model.busy || request.loading).accessibilityIdentifier("rebase.rewrite")
      }
    }.padding(20).frame(minWidth: 700, idealWidth: 860, minHeight: 480, idealHeight: 650)
      .onAppear { load() }
      .onDisappear { request.cancel() }
      .onChange(of: upstream) { _, _ in request.cancel(); candidate = nil; steps = []; selected = nil }
      .onChange(of: store.current?.record.id) { _, id in if id != model.record.id { dismiss() } }
      .alert(store.text("Rewrite commit history?", "改写提交历史？"), isPresented: $confirming) {
        Button(store.text("Rewrite History", "改写历史")) { execute() }
        Button(store.text("Cancel", "取消"), role: .cancel) {}.keyboardShortcut(.defaultAction)
      } message: {
        Text(rewriteDetail)
      }
  }
  private func commitMetadata(_ step: RebaseStep, candidate: InteractiveRebaseCandidate) -> String {
    let number = (candidate.commits.firstIndex { $0.hash == step.id } ?? 0) + 1
    let date = step.commit.date.formatted(date: .abbreviated, time: .omitted)
    return [String(step.id.prefix(12)), step.commit.author, date, "#" + String(number)].joined(separator: " · ")
  }
  private var rewriteDetail: String {
    let branch = candidate?.review.branch ?? ""
    let head = String((candidate?.review.head ?? "").prefix(12))
    let warning = store.text("Rewrite \(steps.count) commits in the displayed order. Shared history may require a separately reviewed Force with Lease push.",
                             "按显示顺序改写 \(steps.count) 个提交。已共享历史后续可能需要单独审查固定租约强制推送。")
    let plan = steps.map { step in
      [step.action.rawValue, String(step.id.prefix(8)), step.commit.subject].joined(separator: " ")
    }.joined(separator: "\n")
    return "\(branch) · \(head)\n\(warning)\n\n\(plan)"
  }
  var selectedIndex: Int? { steps.firstIndex { $0.id == selected } }
  func move(_ delta: Int) {
    guard let index = selectedIndex, steps.indices.contains(index + delta) else { return }
    steps.swapAt(index, index + delta)
  }
  func actionTitle(_ action: RebaseAction) -> String {
    switch action {
    case .pick: return store.text("Pick", "保留")
    case .reword: return store.text("Reword", "改消息")
    case .squash: return store.text("Squash", "合并并改消息")
    case .fixup: return store.text("Fixup", "合并保留消息")
    case .drop: return store.text("Drop", "移除")
    }
  }
  func load() {
    candidate = nil; steps = []; selected = nil; problem = nil
    let value = upstream
    request.start { ticket in
      let candidate = try await model.git().interactiveRebaseCandidate(upstream: value)
      guard request.current(ticket), store.current === model else { return }
      self.candidate = candidate; steps = candidate.commits.map { RebaseStep(commit: $0) }
    }
  }
  func execute() {
    guard let plan, store.current === model, !model.busy else { return }
    do { try plan.validate() } catch { problem = localizedUI(error.localizedDescription); return }
    dismiss()
    model.run(label: store.text("Interactive rebase", "交互式变基"),
              completion: store.text("Interactive rebase completed. Review the rewritten history before pushing.", "交互式变基完成，请在推送前审查改写后的历史。")) { git in
      model.output = try await git.startInteractiveRebase(plan)
    }
  }
}

struct RebaseRecoveryView: View {
  @ObservedObject var model: RepositoryModel
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @StateObject private var request = WorkflowRequest()
  @State private var state: RebaseState?
  @State private var message = ""
  @State private var editMessage = false
  @State private var control: RebaseControl?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(store.text("Rebase in Progress", "变基进行中")).font(.title2.weight(.semibold))
        Spacer(); Button(store.text("Refresh Review", "刷新审查")) { load() }.disabled(request.loading || model.busy)
      }
      WorkflowProblem(request: request)
      if let state {
        Text(rangeSummary(state))
          .font(.caption).textSelection(.enabled)
        Text(store.text("Step \(state.current) of \(state.total). State is read from Git metadata and survives application restarts.",
                        "第 \(state.current)/\(state.total) 步。状态读取自 Git 元数据，可在应用重启后恢复。"))
          .font(.caption).foregroundStyle(.secondary)
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            Text(store.text("Completed / current", "已执行 / 当前")).font(.headline)
            Text(state.done.isEmpty ? "—" : state.done).font(uiFont(size: 11, design: .monospaced)).textSelection(.enabled)
            Text(store.text("Remaining plan", "剩余计划")).font(.headline)
            Text(state.todo.isEmpty ? "—" : state.todo).font(uiFont(size: 11, design: .monospaced)).textSelection(.enabled)
          }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: .infinity)
        Toggle(store.text("Edit the current commit message on Continue", "继续时修改当前提交消息"), isOn: $editMessage)
          .toggleStyle(.checkbox)
        if editMessage {
          TextEditor(text: $message).font(uiFont(size: 12, design: .monospaced)).frame(height: 100)
            .border(Color.secondary.opacity(0.25))
        }
        if !model.conflictEditor.unsavedPaths.isEmpty {
          Text(store.text("Save or explicitly discard your conflict drafts before controlling rebase.",
                          "继续、跳过或中止前，请保存或明确丢弃冲突草稿。")).font(.caption).foregroundStyle(.orange)
        }
      } else if !request.loading { Text(store.text("No rebase is in progress.", "没有正在进行的变基。")) }
      HStack {
        Button(store.text("Done", "完成")) { dismiss() }.keyboardShortcut(.cancelAction)
        if model.status.files.contains(where: \.isConflicted) {
          Button(store.text("Resolve Conflicts…", "解决冲突…")) { dismiss(); model.openConflicts() }
        }
        Spacer()
        HStack {
        Button(store.text("Abort…", "中止…")) { control = .abort }
        Button(store.text("Skip Commit…", "跳过提交…")) { control = .skip }
        Button(store.text("Continue…", "继续…")) { control = .continue }
          .disabled(model.status.files.contains(where: \.isConflicted) || (editMessage && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        }.disabled(state == nil || request.loading || model.busy || !model.conflictEditor.unsavedPaths.isEmpty)
      }
    }.padding(20).frame(minWidth: 660, idealWidth: 820, minHeight: 420, idealHeight: 600)
      .onAppear { load() }.onDisappear { request.cancel() }
      .onChange(of: store.current?.record.id) { _, id in if id != model.record.id { dismiss() } }
      .alert(controlTitle, isPresented: Binding(get: { control != nil }, set: { if !$0 { control = nil } })) {
        Button(controlTitle) { execute() }
        Button(store.text("Cancel", "取消"), role: .cancel) { control = nil }.keyboardShortcut(.defaultAction)
      } message: { Text(controlDetail) }
  }
  private func rangeSummary(_ state: RebaseState) -> String {
    let original = String(state.originalHead.prefix(12)), upstream = String(state.upstream.prefix(12))
    return "\(state.branch) · \(original) → \(upstream)"
  }
  var controlTitle: String {
    switch control {
    case .abort: return store.text("Abort Rebase", "中止变基")
    case .skip: return store.text("Skip Current Commit", "跳过当前提交")
    default: return store.text("Continue Rebase", "继续变基")
    }
  }
  var controlDetail: String {
    switch control {
    case .abort: return store.text("Git restores the starting branch and discards current rebase resolution edits. Unrelated files are protected by Git. Review the displayed state before continuing.",
                                   "Git 将恢复起始分支并丢弃当前变基的冲突处理修改；其他文件由 Git 保护。请审查显示的状态。")
    case .skip: return store.text("Git drops the current commit from this rebase and discards its resolution edits. Remaining commits will be replayed.",
                                  "Git 将从此次变基中移除当前提交并丢弃其冲突处理修改，然后重放剩余提交。")
    default: return store.text("Continue the displayed Git plan using the reviewed Index. Hooks and commit signing remain enabled. No push will run.",
                               "使用已审查的 Index 继续显示的 Git 计划，保留 Hooks 与提交签名，不会执行推送。")
    }
  }
  func load() {
    state = nil; editMessage = false
    request.start { ticket in
      let value = try await model.git().rebaseState()
      guard request.current(ticket), store.current === model else { return }
      state = value; message = value?.message ?? ""
    }
  }
  func execute() {
    guard let control, let state, store.current === model, !model.busy,
      model.conflictEditor.unsavedPaths.isEmpty else { return }
    let edited = editMessage ? message : nil
    let label = controlTitle
    self.control = nil; dismiss()
    model.run(label: label) { git in model.output = try await git.controlRebase(control, expected: state, message: edited) }
  }
}
