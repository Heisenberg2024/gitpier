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
  @State private var forgetting: TaskWorkspaceCreation?
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
            ForEach(manager.pendingCreations.filter { $0.commonDirectory == common }) { creation in
              VStack(alignment: .leading, spacing: 5) {
                Text(store.text("Task registration incomplete", "任务登记尚未完成")).font(.headline)
                Text(creation.name + " · " + creation.path).font(.caption).textSelection(.enabled)
                Text(store.text("Files and branches are preserved. Resume verifies the original identity. Without a saved identity, inspect Worktrees and associate it as an external worktree.", "文件与分支已保留。继续登记将核对原始身份；缺少已保存身份时，请检查工作树并以外部工作树关联。"))
                  .font(.caption).foregroundStyle(.secondary)
                HStack {
                  Button(store.text("Resume Registration", "继续登记")) { request.start { _ in try await manager.resumeCreation(creation) } }
                    .disabled(creation.workspace == nil || request.loading || manager.busy.contains(creation.id))
                  Button(store.text("Forget Creation Record…", "忘记创建记录…")) { forgetting = creation }.disabled(request.loading)
                }
              }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
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
      .confirmationDialog(store.text("Forget this creation record?", "忘记此创建记录？"), isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
        Button(store.text("Forget Record", "忘记记录")) { if let creation = forgetting { request.start { _ in try await manager.forgetCreation(creation) }; forgetting = nil } }
      } message: { Text(store.text("Only the private pending record is removed. Inspect and preserve any worktree, branch and files before associating it again. This does not grant ownership.", "仅移除私有待登记记录。再次关联前请检查并保留工作树、分支及文件；此操作不授予所有权。")) }
      .sheet(isPresented: $creating) { TaskWorkspaceCreationSheet(model: model, manager: manager).environmentObject(store).modifier(AppAppearance(store: store)) }
      .accessibilityIdentifier("gitpier.tasks")
  }
}

struct TaskWorkspaceDetail: View {
  let taskID: UUID
  @ObservedObject var manager: TaskWorkspaceManager
  @EnvironmentObject var store: AppStore
  @StateObject private var request = WorkflowRequest()
  @ObservedObject private var mutation: WorkflowMutationRequest
  @State private var snapshot: TaskWorkspaceSnapshot?
  @State private var launching = false
  @State private var confirmArchive = false
  init(taskID: UUID, manager: TaskWorkspaceManager) {
    self.taskID = taskID; self.manager = manager
    mutation = manager.detailMutation(taskID)
  }
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
          if let problem = mutation.problem {
            Text(problem).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
          }
          if mutation.loading { ProgressView().controlSize(.small) }
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
    }.onChange(of: task, initial: true) { _, _ in refresh() }
      .onChange(of: mutation.revision) { _, _ in refresh() }
      .onDisappear { request.cancel() }
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
  private func perform(_ action: @escaping () async throws -> Void) { mutation.start(action) }
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
  @StateObject private var request: TaskWorkspaceCreationRequest
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
  init(model: RepositoryModel, manager: TaskWorkspaceManager, request: TaskWorkspaceCreationRequest = TaskWorkspaceCreationRequest()) {
    self.model = model; self.manager = manager
    _request = StateObject(wrappedValue: request)
    _destination = State(initialValue: URL(fileURLWithPath: model.record.path).deletingLastPathComponent().appendingPathComponent("GitPier-task-" + UUID().uuidString.lowercased()).path)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let task = request.created {
        Label(store.text("Task created", "任务已创建"), systemImage: "checkmark.circle").font(.title2.bold())
        Text(task.name).font(.headline)
        Text(task.path).font(.caption).textSelection(.enabled)
        if let problem = request.navigationProblem {
          Text(store.text("The task is saved, but could not be opened. You can retry here or use Tasks / Operations Center.", "任务已保存，但未能打开。可在此重试，或从任务列表／操作中心重新打开。"))
          Text(problem).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
        }
        if request.opening { ProgressView().controlSize(.small) }
        HStack {
          Spacer()
          Button(store.text("Done", "完成")) { request.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
          Button(store.text("Open Task", "打开任务")) {
            request.retryOpen { task in _ = try await manager.open(task.id); dismiss() }
          }.disabled(request.opening)
        }
      } else {
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
        if let problem = request.problem { Text(problem).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        if request.loading { ProgressView().controlSize(.small) }
        HStack {
          Spacer()
          Button(store.text("Cancel", "取消")) { request.cancel(); dismiss() }.keyboardShortcut(.cancelAction).disabled(request.loading)
          Button(store.text("Create Task", "创建任务")) { create() }
            .disabled(request.loading || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (associate ? existing.isEmpty : branch.isEmpty || base.isEmpty || !destination.hasPrefix("/")))
        }
      }
    }.padding(22).textFieldStyle(.roundedBorder).frame(width: 590)
      .task { do { trees = try await model.git().worktrees(includeStatus: false) } catch { store.error = error.localizedDescription } }
      .interactiveDismissDisabled(request.loading)
      .onDisappear { request.cancel() }
  }
  private func create() {
    let name = name, note = saveDescription ? description : nil, existing = existing, associate = associate
    let location = destination, branch = branch, base = base, openAfter = openAfter
    let sourceID = store.selectedID
    request.start(create: {
      guard manager.ready, manager.problem == nil, !manager.tasks.contains(where: { $0.path == (associate ? existing : location) }) else { throw TaskWorkspaceError.changed }
      let git = await model.git()
      return try await manager.create(repositoryID: model.record.id) {
        if associate {
          guard let tree = trees.first(where: { $0.path == existing }) else { throw TaskWorkspaceError.changed }
          let receipt = store.configuration.ownedWorktrees.first { $0.path == existing }
          return try await git.associateTaskWorkspace(name: name, savedDescription: note, repositoryID: model.record.id, worktree: tree, receipt: receipt)
        } else {
          return try await git.createTaskWorkspace(name: name, savedDescription: note, repositoryID: model.record.id,
            destination: URL(fileURLWithPath: location), branch: branch, startAt: base, registration: manager.persistence)
        }
      }
    }, open: openAfter ? { task in
      _ = try await manager.open(task.id, isCurrent: { store.selectedID == sourceID })
      dismiss()
    } : nil)
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
  @State private var login: AgentLoginStatus = .notChecked
  @State private var starting = false
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
        CodexEnvironmentSummary(environment: detected.environment)
        CodexLoginSummary(status: login)
        Button(store.text("Check Login Status", "检查登录状态")) {
          login = .notChecked
          request.start { ticket in
            let value = try await detected.checkLogin()
            guard request.current(ticket), self.detected == detected else { return }; login = value
          }
        }.disabled(request.loading)
      }
      if let snapshot { Text(store.text("\(snapshot.status.files.count) uncommitted files", "\(snapshot.status.files.count) 个未提交文件")) }
      Text(AgentLaunchConfiguration.safeArguments.joined(separator: " ")).font(.system(size: 11, design: .monospaced))
      Text(store.text("Codex runs in the foreground with this worktree as its project root. Its own permissions, approvals and existing local configuration apply, and may permit reading other files. GitPier does not inspect that configuration or credentials, and its Git confirmations do not constrain commands inside Codex. This dialog passes no prompt.", "Codex 在前台运行，并以此工作树为项目根目录。其自身权限、审批和已有本地配置生效，也可能允许读取其他文件。GitPier 不检查该配置或凭证，其 Git 确认不能约束 Codex 内部命令。此对话框不传递 Prompt。"))
        .font(.callout).foregroundStyle(.secondary)
      Link(store.text("Official installation and login guide", "官方安装与登录指南"), destination: URL(string: "https://developers.openai.com/codex/cli")!)
      WorkflowProblem(request: request)
      HStack {
        Spacer()
        Button(store.text("Cancel", "取消")) { request.cancel(); dismiss() }.keyboardShortcut(.cancelAction).disabled(starting)
        Button(store.text("Start Codex", "启动 Codex")) { launch() }.disabled(detected == nil || snapshot == nil || request.loading)
      }
    }.padding(22).frame(width: 620).textFieldStyle(.roundedBorder)
      .onAppear { executablePath = store.settings.codexExecutablePath }
      .onChange(of: executablePath) { _, _ in invalidate() }
      .onChange(of: store.settings.codexHomePath) { _, _ in invalidate() }
      .onDisappear { request.cancel() }.interactiveDismissDisabled(starting)
  }
  private func detect() {
    let path = executablePath, home = store.settings.codexHomePath; detected = nil; snapshot = nil; login = .notChecked
    request.start { ticket in
      let environment = try AgentEnvironment(codexHome: home)
      let executable = try await AgentExecutable.detect(explicitPath: path, environment: environment)
      let state = try await manager.snapshot(taskID)
      guard request.current(ticket), executablePath == path, store.settings.codexHomePath == home else { return }
      detected = executable; snapshot = state
    }
  }
  private func invalidate() { detected = nil; snapshot = nil; login = .notChecked; request.cancel() }
  private func launch() {
    guard !starting, let detected, let snapshot, let task = manager.task(taskID) else { return }
    starting = true
    request.start { _ in
      defer { starting = false }
      let configuration = try AgentLaunchConfiguration(executable: detected, task: task, snapshot: snapshot)
      try await manager.launch(taskID, configuration: configuration); dismiss()
    }
  }
}

struct CodexSettingsSection: View {
  @EnvironmentObject var store: AppStore
  @StateObject private var request = WorkflowRequest()
  @State private var detected: AgentExecutable?
  @State private var login: AgentLoginStatus = .notChecked
  var body: some View {
    Section(store.text("Codex CLI (optional)", "Codex CLI（可选）")) {
      TextField(store.text("Executable path (empty uses PATH)", "可执行文件路径（留空使用 PATH）"), text: Binding(
        get: { store.settings.codexExecutablePath },
        set: { var settings = store.settings; settings.codexExecutablePath = $0; store.updateSettings(settings) }))
      DisclosureGroup(store.text("Advanced Environment", "高级环境")) {
        TextField(store.text("Codex Home (empty inherits CODEX_HOME)", "Codex Home（留空继承 CODEX_HOME）"), text: Binding(
          get: { store.settings.codexHomePath }, set: { var settings = store.settings; settings.codexHomePath = $0; store.updateSettings(settings) }))
        Text(store.text("Choose an existing absolute directory. This affects only Codex processes started by GitPier; no files or system settings are changed.", "请选择已存在的绝对目录。仅影响 GitPier 启动的 Codex 进程，不改动文件或系统设置。"))
          .font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Button(store.text("Detect Codex CLI", "检测 Codex CLI")) { detect() }.disabled(request.loading)
        Button(store.text("Check Login Status", "检查登录状态")) {
          guard let detected else { return }; login = .notChecked
          request.start { ticket in
            let value = try await detected.checkLogin()
            guard request.current(ticket), self.detected == detected else { return }; login = value
          }
        }.disabled(detected == nil || request.loading)
        if request.loading { Button(store.text("Cancel Check", "取消检查")) { request.cancel() } }
      }
      if let detected {
        Text(detected.version + "\n" + detected.path).font(.caption).textSelection(.enabled)
        CodexEnvironmentSummary(environment: detected.environment)
        CodexLoginSummary(status: login)
      }
      WorkflowProblem(request: request)
      Text(store.text("Checks run only on request. Codex manages login, credential storage and renewal. GitPier never reads or copies credentials. Start a session explicitly from a Task Workspace.", "仅主动检查。Codex 负责登录、凭证保存及刷新；GitPier 不读取或复制凭证。请从任务工作空间主动启动会话。"))
        .font(.caption).foregroundStyle(.secondary)
      Text(store.text("Finder and Dock do not inherit variables set only in shell profiles. HOME and PATH come from this app's environment, with standard command folders appended. If your shell uses a custom CODEX_HOME, configure it above or launch GitPier from that environment.", "Finder 与 Dock 不会继承仅在 Shell 配置中设置的变量。HOME 与 PATH 来自应用环境，并补充标准命令目录。如 Shell 使用自定义 CODEX_HOME，请在上方配置或从该环境启动 GitPier。"))
        .font(.caption).foregroundStyle(.secondary)
      Link(store.text("Official Codex CLI guide", "Codex CLI 官方指南"), destination: URL(string: "https://developers.openai.com/codex/cli")!)
    }.onChange(of: store.settings.codexExecutablePath) { _, _ in invalidate() }
      .onChange(of: store.settings.codexHomePath) { _, _ in invalidate() }.onDisappear { request.cancel() }
  }
  private func invalidate() { request.cancel(); detected = nil; login = .notChecked }
  private func detect() {
    invalidate()
    let path = store.settings.codexExecutablePath, home = store.settings.codexHomePath
    request.start { ticket in
      let executable = try await AgentExecutable.detect(explicitPath: path, environment: AgentEnvironment(codexHome: home))
      guard request.current(ticket), store.settings.codexExecutablePath == path, store.settings.codexHomePath == home else { return }
      detected = executable
    }
  }
}

struct CodexEnvironmentSummary: View {
  let environment: AgentEnvironment
  @EnvironmentObject var store: AppStore
  var body: some View {
    Text(environment.customHome ? store.text("Codex Home: explicit GitPier setting", "Codex Home：GitPier 显式设置") : environment.inheritedCodexHome ? store.text("Codex Home: inherited CODEX_HOME", "Codex Home：继承 CODEX_HOME") : store.text("Codex Home: CLI default (CODEX_HOME is not inherited)", "Codex Home：CLI 默认值（未继承 CODEX_HOME）"))
      .font(.caption).foregroundStyle(.secondary)
  }
}
struct CodexLoginSummary: View {
  let status: AgentLoginStatus
  @EnvironmentObject var store: AppStore
  private var title: String {
    switch status {
    case .notChecked: store.text("Installed · login not checked", "已安装 · 尚未检查登录")
    case .loggedIn: store.text("Logged in · CLI credentials available", "已登录 · CLI 凭证可用")
    case .loginRequired: store.text("Login required. Run codex login in a terminal with the same Codex Home, using the official login guide.", "需要登录。请按官方指南在使用相同 Codex Home 的终端运行 codex login。")
    case .unconfirmed(.timedOut): store.text("Login status unconfirmed · check timed out", "登录状态无法确认 · 检查超时")
    case .unconfirmed(.outputLimit): store.text("Login status unconfirmed · CLI output exceeded the limit", "登录状态无法确认 · CLI 输出超限")
    case .unconfirmed(.executionFailed): store.text("Login status unconfirmed · CLI execution failed or this version does not support the check", "登录状态无法确认 · CLI 执行失败或此版本不支持检查")
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.caption)
      if status == .loggedIn { Text(store.text("This does not verify network access, account permissions or model calls.", "这不代表网络、账号权限或模型调用已通过验证。")).font(.caption).foregroundStyle(.secondary) }
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
