import AppKit
import GitPierCore
import SwiftUI

struct TaskWorkspacesView: View {
  @ObservedObject var model: RepositoryModel
  @ObservedObject var manager: TaskWorkspaceManager
  @EnvironmentObject var store: AppStore
  @StateObject private var request = WorkflowRequest()
  @State private var common = ""
  @State private var creating = false
  @State private var includeArchived = false
  @State private var selected: UUID?
  private var tasks: [TaskWorkspace] {
    manager.tasks.filter { $0.commonDirectory == common && (includeArchived || !$0.archived) }
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(store.text("Task Workspaces", "任务工作空间")).font(.headline)
        Spacer()
        Toggle(store.text("Archived", "已归档"), isOn: $includeArchived).toggleStyle(.checkbox)
        Button(store.text("New Task…", "新建任务…")) { creating = true }.disabled(!manager.ready || manager.problem != nil || model.busy)
      }.padding(12)
      if let problem = manager.problem { Text(localizedUI(problem)).foregroundStyle(.orange).textSelection(.enabled).padding(12) }
      WorkflowProblem(request: request)
      HSplitView {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            if tasks.isEmpty {
              Text(store.text("Create an independent task worktree, or associate an existing linked worktree. Codex CLI is optional.", "创建独立任务工作树，或关联已有工作树。Codex CLI 完全可选。"))
                .foregroundStyle(.secondary).padding(16)
            }
            ForEach(tasks) { task in
              Button { selected = task.id; manager.selectedID = task.id } label: {
                VStack(alignment: .leading, spacing: 6) {
                  HStack { Text(task.name).font(.headline).lineLimit(2); Spacer(); Text(taskStatusTitle(manager.displayStatus(task), store: store)).font(.caption) }
                  Text(task.branch.isEmpty ? store.text("Detached HEAD", "分离 HEAD") : String(task.branch.dropFirst("refs/heads/".count))).font(.caption).lineLimit(1)
                  Text(task.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                  if let state = manager.summaries[task.id] {
                    Text(String((state.head ?? "").prefix(8)) + " · " + store.text("\(state.files.filter(\.isUnstaged).count) unstaged / \(state.staged.count) staged / \(state.files.filter(\.isConflicted).count) conflicts", "\(state.files.filter(\.isUnstaged).count) 未暂存 / \(state.staged.count) 已暂存 / \(state.files.filter(\.isConflicted).count) 冲突")).font(.caption2).foregroundStyle(.secondary)
                  }
                  if let agent = task.agent { Text("Codex · " + agentStateTitle(agent.state, store: store)).font(.caption2) }
                  Text(task.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                  .background(selected == task.id ? Color.accentColor.opacity(0.12) : Color.clear)
                  .contentShape(Rectangle())
              }.buttonStyle(.plain).accessibilityIdentifier("gitpier.task." + task.id.uuidString)
                .task(id: task.updatedAt) { await manager.observe(task.id) }
              Divider()
            }
          }
        }.frame(minWidth: 210, idealWidth: 270, maxWidth: 320)
        if let selected, let task = tasks.first(where: { $0.id == selected }) {
          TaskWorkspaceDetail(taskID: task.id, manager: manager).id(task.id)
        } else {
          EmptyState(symbol: "square.stack.3d.up", title: store.text("Select a task", "选择任务"), detail: store.text("Each task keeps its own baseline and worktree.", "每个任务保留独立基准与工作树。"))
        }
      }
    }.task(id: model.record.path) {
      await manager.restore()
      request.start { ticket in
        let value = try await model.git().commonDirectory().path
        guard request.current(ticket) else { return }
        common = value
        selected = tasks.first { $0.id == manager.selectedID }?.id ?? tasks.first?.id
      }
    }.onChange(of: manager.selectedID) { _, value in
      if tasks.contains(where: { $0.id == value }) { selected = value }
    }.onDisappear { request.cancel() }
      .sheet(isPresented: $creating) { TaskWorkspaceCreationSheet(model: model, manager: manager).environmentObject(store).modifier(AppAppearance(store: store)) }
      .accessibilityIdentifier("gitpier.tasks")
  }
}

struct TaskWorkspaceDetail: View {
  let taskID: UUID
  @ObservedObject var manager: TaskWorkspaceManager
  @EnvironmentObject var store: AppStore
  @StateObject private var request = WorkflowRequest()
  @State private var snapshot: TaskWorkspaceSnapshot?
  @State private var launching = false
  @State private var confirmArchive = false
  private var task: TaskWorkspace? { manager.task(taskID) }
  var body: some View {
    ScrollView {
      if let task {
        VStack(alignment: .leading, spacing: 12) {
          Text(task.name).font(.title2.bold()).textSelection(.enabled)
          Label(taskStatusTitle(manager.displayStatus(task), store: store), systemImage: task.agent?.state.active == true ? "play.circle" : "square.stack.3d.up")
          field(store.text("Repository", "仓库"), task.repositoryRoot)
          field(store.text("Branch", "分支"), task.branch.isEmpty ? "Detached HEAD" : task.branch)
          field(store.text("Worktree", "工作树"), task.path)
          field(store.text("Baseline", "基准"), task.baseCommit)
          field(store.text("Current HEAD", "当前 HEAD"), snapshot?.head ?? store.text("Refresh to inspect", "刷新后查看"))
          Text(task.binding.managed ? store.text("GitPier-created worktree · removal requires a separate safety review.", "GitPier 创建的工作树 · 移除需要单独安全审查。") : store.text("Associated external worktree · association grants no removal permission.", "已关联外部工作树 · 关联不授予移除权限。"))
            .font(.caption).foregroundStyle(.secondary)
          if let description = task.savedDescription { Text(description).textSelection(.enabled) }
          HStack { Text(store.text("Created", "创建时间")); Text(task.createdAt, style: .date); Text(task.createdAt, style: .time) }.font(.caption)
          HStack { Text(store.text("Last activity", "最后活动")); Text(task.updatedAt, style: .date); Text(task.updatedAt, style: .time) }.font(.caption)
          if let snapshot {
            Text(store.text("\(snapshot.status.files.filter(\.isUnstaged).count) unstaged · \(snapshot.status.staged.count) staged · \(snapshot.status.untracked.count) untracked · \(snapshot.status.files.filter(\.isConflicted).count) conflicts", "\(snapshot.status.files.filter(\.isUnstaged).count) 未暂存 · \(snapshot.status.staged.count) 已暂存 · \(snapshot.status.untracked.count) 未跟踪 · \(snapshot.status.files.filter(\.isConflicted).count) 冲突"))
            Text(store.text("Baseline → HEAD: \(snapshot.comparison.files.count) files · \(snapshot.comparison.rightOnlyCount) new commits", "基准 → HEAD：\(snapshot.comparison.files.count) 文件 · \(snapshot.comparison.rightOnlyCount) 新提交"))
          }
          WorkflowProblem(request: request)
          ViewThatFits(in: .horizontal) {
            HStack { openButtons(task) }
            VStack(alignment: .leading, spacing: 8) { openButtons(task) }
          }
          Divider()
          Text(store.text("Review", "审查")).font(.headline)
          Text(store.text("Inspect both comparisons. New local commits can contain task changes even when the worktree is clean.", "请检查两种比较。即使工作树干净，新建的本地提交仍可能包含任务变更。"))
            .font(.callout).foregroundStyle(.secondary)
          Button(store.text("Baseline → Current HEAD / Commits", "基准 → 当前 HEAD / 提交")) { perform { try await manager.review(taskID, baseline: true) } }.disabled(task.archived)
          Button(store.text("Current HEAD → Index / Working Tree", "当前 HEAD → Index / 工作树")) { perform { try await manager.review(taskID, baseline: false) } }.disabled(task.archived)
          Button(store.text("Mark Current Snapshot Reviewed", "将当前快照标为已审查")) { perform { try await manager.markReviewed(taskID) } }
            .disabled(task.archived || task.agent?.state.active == true || manager.busy.contains(taskID))
          if let review = task.review {
            HStack { Text(store.text("Last reviewed snapshot", "上次已审查快照")); Text(String(review.head.prefix(8))); Text(review.reviewedAt, style: .time) }.font(.caption).foregroundStyle(.secondary)
          }
          Text(store.text("No verified tests recorded. Open Terminal to run tests; agent output is not a verified test result.", "尚无已核验的测试记录。可打开终端执行测试；Agent 输出不等于已核验的测试结果。"))
            .font(.caption).foregroundStyle(.secondary)
          Divider()
          Text(store.text("Codex CLI (optional)", "Codex CLI（可选）")).font(.headline)
          if let session = task.agent {
            Text(agentStateTitle(session.state, store: store) + (session.exitCode.map { " · \($0)" } ?? ""))
            Text(session.executableVersion).font(.caption).foregroundStyle(.secondary)
          }
          if task.agent?.state.active == true {
            Button(store.text("Stop Agent…", "停止 Agent…")) { stopAgent(task) }
            Button(task.agent?.state == .waitingForInput ? store.text("Mark Running", "标记为运行中") : store.text("Mark Waiting for Input", "标记为等待输入")) {
              perform { try await manager.setWaitingForInput(taskID, waiting: task.agent?.state != .waitingForInput) }
            }.disabled(manager.busy.contains(taskID))
            Text(store.text("Waiting for input is a manual annotation; GitPier does not infer Codex intent from terminal output.", "等待输入是手动标记；GitPier 不从终端输出推断 Codex 的意图。")).font(.caption).foregroundStyle(.secondary)
          } else {
            Button(store.text("Start Codex…", "启动 Codex…")) { launching = true }.disabled(task.archived || manager.busy.contains(taskID))
          }
          Divider()
          Button(store.text(task.archived ? "Reopen Task" : "Archive Task…", task.archived ? "重新打开任务" : "归档任务…")) {
            if task.archived { perform { try await manager.archive(taskID, archived: false) } } else { confirmArchive = true }
          }.disabled(task.agent?.state.active == true || manager.busy.contains(taskID))
          Text(store.text("Archive changes task metadata only. To remove a GitPier-created worktree, use Worktrees → Remove and review it separately.", "归档仅改变任务元数据。移除 GitPier 创建的工作树，请进入工作树 → 移除并单独审查。"))
            .font(.caption).foregroundStyle(.secondary)
          if task.binding.managed {
            Button(store.text("Review Worktree Removal…", "审查移除工作树…")) { perform { try await manager.requestRemoval(taskID) } }
              .disabled(task.agent?.state.active == true || manager.busy.contains(taskID))
          }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
      }
    // Launching and Running can share updatedAt. Refresh on every record transition,
    // so a superseded snapshot is replaced without requiring a manual Refresh.
    }.onChange(of: task, initial: true) { _, _ in refresh() }.onDisappear { request.cancel() }
      .sheet(isPresented: $launching) { CodexLaunchSheet(taskID: taskID, manager: manager).environmentObject(store).modifier(AppAppearance(store: store)) }
      .confirmationDialog(store.text("Archive task?", "归档任务？"), isPresented: $confirmArchive) {
        Button(store.text("Archive", "归档")) { perform { try await manager.archive(taskID, archived: true) } }
      } message: { Text(store.text("The worktree, branch, commits and all files will be preserved.", "将保留工作树、分支、提交及全部文件。")) }
  }
  private func field(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
  }
  @ViewBuilder private func openButtons(_ task: TaskWorkspace) -> some View {
    Button(store.text("Open Worktree", "打开工作树")) { perform { _ = try await manager.open(taskID, page: "commit") } }.disabled(task.archived)
    Button(store.text("Open Terminal", "打开终端")) { perform { _ = try await manager.open(taskID, terminal: true) } }.disabled(task.archived)
    Menu(store.text("Open in Editor", "在编辑器中打开")) {
      ForEach(ExternalEditors.available(settings: store.settings)) { editor in
        Button(editor.name) { perform {
          _ = try await manager.git(task).validateTaskWorkspace(task)
          NSWorkspace.shared.open([URL(fileURLWithPath: task.path)], withApplicationAt: editor.url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        } }
      }
    }.disabled(task.archived)
    Button(store.text("Refresh", "刷新")) { refresh() }
  }
  private func perform(_ action: @escaping () async throws -> Void) { request.start { _ in try await action() } }
  private func refresh() {
    snapshot = nil
    request.start { ticket in let value = try await manager.snapshot(taskID); guard request.current(ticket) else { return }; snapshot = value }
  }
  private func stopAgent(_ task: TaskWorkspace) {
    let alert = NSAlert(); alert.messageText = store.text("Stop Codex?", "停止 Codex？")
    alert.informativeText = store.text("Attached jobs will be stopped. Changes and incomplete Git operations may remain.", "将停止关联作业；可能保留文件修改及未完成的 Git 操作。") + "\n\n" + task.path
    alert.addButton(withTitle: store.text("Stop", "停止")); alert.addButton(withTitle: store.text("Cancel", "取消"))
    alert.buttons[0].keyEquivalent = ""; alert.buttons[1].keyEquivalent = "\r"
    if alert.runModal() == .alertFirstButtonReturn { manager.stop(taskID) }
  }
}

struct TaskWorkspaceCreationSheet: View {
  @ObservedObject var model: RepositoryModel
  @ObservedObject var manager: TaskWorkspaceManager
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @StateObject private var request = WorkflowRequest()
  @State private var name = ""
  @State private var description = ""
  @State private var saveDescription = false
  @State private var branch = "task/" + String(UUID().uuidString.prefix(8)).lowercased()
  @State private var base = "HEAD"
  @State private var destination: String
  @State private var associate = false
  @State private var trees: [GitWorktree] = []
  @State private var existing = ""
  @State private var openAfter = true
  init(model: RepositoryModel, manager: TaskWorkspaceManager) {
    self.model = model; self.manager = manager
    _destination = State(initialValue: URL(fileURLWithPath: model.record.path).deletingLastPathComponent().appendingPathComponent("GitPier-task-" + UUID().uuidString.lowercased()).path)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(store.text("New Task Workspace", "新建任务工作空间")).font(.title2.bold())
      Text(model.record.name).foregroundStyle(.secondary)
      TextField(store.text("Task name", "任务名称"), text: $name)
      Toggle(store.text("Associate an existing linked worktree", "关联已有工作树"), isOn: $associate)
      if associate {
        Picker(store.text("Worktree", "工作树"), selection: $existing) {
          Text(store.text("Select", "选择")).tag("")
          ForEach(trees.filter { !$0.main && !$0.bare && !$0.missing && !$0.prunable }) { Text($0.path).tag($0.path) }
        }
        Text(store.text("Association never grants ownership of an external worktree.", "关联不会授予外部工作树的所有权。" )).font(.caption).foregroundStyle(.secondary)
      } else {
        TextField(store.text("Local base branch / commit", "本地基准分支 / 提交"), text: $base)
        TextField(store.text("New task branch", "新任务分支"), text: $branch)
        HStack {
          TextField(store.text("New absolute worktree location", "新的工作树绝对路径"), text: $destination)
          Button(store.text("Choose…", "选择…")) {
            let panel = NSSavePanel(); panel.canCreateDirectories = true; panel.nameFieldStringValue = URL(fileURLWithPath: destination).lastPathComponent
            if panel.runModal() == .OK, let url = panel.url { destination = url.path }
          }
        }
        Text(store.text("Uses existing local references. No automatic Fetch or agent launch.", "使用已有本地引用，不自动获取远程或启动 Agent。" )).font(.caption).foregroundStyle(.secondary)
      }
      Toggle(store.text("Save a private task description", "保存私有任务描述"), isOn: $saveDescription)
      if saveDescription { TextField(store.text("Description (saved locally, never passed as a command)", "描述（仅本地保存，不作为命令执行）"), text: $description, axis: .vertical).lineLimit(3...5) }
      Toggle(store.text("Open after creating", "创建后打开"), isOn: $openAfter)
      WorkflowProblem(request: request)
      HStack {
        Spacer()
        Button(store.text("Cancel", "取消")) { request.cancel(); dismiss() }.keyboardShortcut(.cancelAction).disabled(request.loading)
        Button(store.text("Create Task", "创建任务")) { create() }
          .disabled(request.loading || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (associate ? existing.isEmpty : branch.isEmpty || base.isEmpty || !destination.hasPrefix("/")))
      }
    }.padding(22).textFieldStyle(.roundedBorder).frame(width: 590)
      .task { do { trees = try await model.git().worktrees(includeStatus: false) } catch { store.error = error.localizedDescription } }
      .interactiveDismissDisabled(request.loading)
  }
  private func create() {
    let name = name, note = saveDescription ? description : nil, existing = existing, associate = associate
    let location = destination, branch = branch, base = base, openAfter = openAfter
    request.start { _ in
      guard manager.ready, manager.problem == nil, !manager.tasks.contains(where: { $0.path == (associate ? existing : location) }) else { throw TaskWorkspaceError.changed }
      let git = await model.git()
      let task = try await manager.create(repositoryID: model.record.id) {
        if associate {
          guard let tree = trees.first(where: { $0.path == existing }) else { throw TaskWorkspaceError.changed }
          let receipt = store.configuration.ownedWorktrees.first { $0.path == existing }
          return try await git.associateTaskWorkspace(name: name, savedDescription: note, repositoryID: model.record.id, worktree: tree, receipt: receipt)
        } else {
          return try await git.createTaskWorkspace(name: name, savedDescription: note, repositoryID: model.record.id,
            destination: URL(fileURLWithPath: location), branch: branch, startAt: base)
        }
      }
      if openAfter { _ = try await manager.open(task.id) }
      dismiss()
    }
  }
}

struct CodexLaunchSheet: View {
  let taskID: UUID
  @ObservedObject var manager: TaskWorkspaceManager
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @StateObject private var request = WorkflowRequest()
  @State private var executablePath = ""
  @State private var detected: AgentExecutable?
  @State private var snapshot: TaskWorkspaceSnapshot?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(store.text("Review Codex Launch", "确认启动 Codex")).font(.title2.bold())
      if let task = manager.task(taskID) {
        Text(task.name).font(.headline)
        Text(task.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
        Text(task.branch).font(.caption).textSelection(.enabled)
        Text(snapshot?.head ?? store.text("Inspect the worktree before starting.", "启动前请检查工作树。" )).font(.caption).textSelection(.enabled)
      }
      HStack {
        TextField(store.text("Executable path (empty uses PATH)", "可执行文件路径（留空使用 PATH）"), text: $executablePath)
        Button(store.text("Choose…", "选择…")) { let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; if panel.runModal() == .OK, let url = panel.url { executablePath = url.path } }
        Button(store.text("Detect", "检测")) { detect() }.disabled(request.loading)
      }
      if let detected {
        Text(detected.path).font(.caption).textSelection(.enabled)
        Text(detected.version).font(.caption)
      }
      if let snapshot { Text(store.text("\(snapshot.status.files.count) uncommitted files", "\(snapshot.status.files.count) 个未提交文件")) }
      Text("--no-daemon --sandbox workspace-write --ask-for-approval on-request").font(.system(size: 11, design: .monospaced))
      Text(store.text("Codex runs in the foreground with this worktree as its project root. Its own permissions, approvals and existing local configuration apply, and may permit reading other files. GitPier does not inspect that configuration or credentials, and its Git confirmations do not constrain commands inside Codex. This dialog passes no prompt.", "Codex 在前台运行，并以此工作树为项目根目录。其自身权限、审批和已有本地配置生效，也可能允许读取其他文件。GitPier 不检查该配置或凭证，其 Git 确认不能约束 Codex 内部命令。此对话框不传递 Prompt。"))
        .font(.callout).foregroundStyle(.secondary)
      Link(store.text("Official installation and login guide", "官方安装与登录指南"), destination: URL(string: "https://developers.openai.com/codex/cli")!)
      WorkflowProblem(request: request)
      HStack {
        Spacer()
        Button(store.text("Cancel", "取消")) { request.cancel(); dismiss() }.keyboardShortcut(.cancelAction).disabled(request.loading)
        Button(store.text("Start Codex", "启动 Codex")) { launch() }.disabled(detected == nil || snapshot == nil || request.loading)
      }
    }.padding(22).frame(width: 620).textFieldStyle(.roundedBorder)
      .onAppear { executablePath = store.settings.codexExecutablePath }
      .onChange(of: executablePath) { _, _ in detected = nil; snapshot = nil; request.cancel() }
      .onDisappear { request.cancel() }.interactiveDismissDisabled(request.loading)
  }
  private func detect() {
    let path = executablePath; detected = nil; snapshot = nil
    request.start { ticket in
      let executable = try await AgentExecutable.detect(explicitPath: path)
      let state = try await manager.snapshot(taskID)
      guard request.current(ticket), executablePath == path else { return }
      detected = executable; snapshot = state
    }
  }
  private func launch() {
    guard let detected, let snapshot, let task = manager.task(taskID) else { return }
    request.start { _ in
      let configuration = try AgentLaunchConfiguration(executable: detected, task: task, snapshot: snapshot)
      try await manager.launch(taskID, configuration: configuration); dismiss()
    }
  }
}

struct CodexSettingsSection: View {
  @EnvironmentObject var store: AppStore
  @State private var result = ""
  @State private var checking = false
  var body: some View {
    Section(store.text("Codex CLI (optional)", "Codex CLI（可选）")) {
      TextField(store.text("Executable path (empty uses PATH)", "可执行文件路径（留空使用 PATH）"), text: Binding(
        get: { store.settings.codexExecutablePath },
        set: { var settings = store.settings; settings.codexExecutablePath = $0; store.updateSettings(settings); result = "" }))
      Button(store.text("Detect Codex CLI", "检测 Codex CLI")) {
        checking = true
        let path = store.settings.codexExecutablePath
        Task {
          defer { checking = false }
          do { let executable = try await AgentExecutable.detect(explicitPath: path); if store.settings.codexExecutablePath == path { result = executable.version + "\n" + executable.path } }
          catch { if store.settings.codexExecutablePath == path { result = localizedUI(error.localizedDescription) } }
        }
      }.disabled(checking)
      if !result.isEmpty { Text(result).font(.caption).textSelection(.enabled) }
      Text(store.text("Detection runs bounded version and help probes. GitPier never installs Codex or reads its login credentials. Start a session explicitly from a Task Workspace.", "检测执行有界的版本及帮助查询。GitPier 不安装 Codex，也不读取其登录凭证。请从任务工作空间主动启动会话。"))
        .font(.caption).foregroundStyle(.secondary)
      Link(store.text("Official Codex CLI guide", "Codex CLI 官方指南"), destination: URL(string: "https://developers.openai.com/codex/cli")!)
    }
  }
}

@MainActor func taskStatusTitle(_ status: TaskWorkspaceStatus, store: AppStore) -> String {
  switch status {
  case .ready: store.text("Ready", "就绪")
  case .running: store.text("Agent running", "Agent 运行中")
  case .needsAttention: store.text("Needs attention", "需要处理")
  case .agentExited: store.text("Agent exited", "Agent 已退出")
  case .changesAvailable: store.text("Changes available", "有待审查变更")
  case .reviewed: store.text("Reviewed", "已审查")
  case .archived: store.text("Archived", "已归档")
  case .interrupted: store.text("Interrupted", "已中断")
  case .unavailable: store.text("Unavailable", "不可用")
  }
}
@MainActor func agentStateTitle(_ state: AgentProcessState, store: AppStore) -> String {
  switch state {
  case .idle: store.text("Idle", "空闲")
  case .launching: store.text("Launching", "启动中")
  case .running: store.text("Running", "运行中")
  case .waitingForInput: store.text("Waiting for input", "等待输入")
  case .exited: store.text("Exited", "已退出")
  case .failed: store.text("Failed", "失败")
  case .interrupted: store.text("Interrupted", "已中断")
  }
}
