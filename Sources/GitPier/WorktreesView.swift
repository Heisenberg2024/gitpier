import AppKit
import GitPierCore
import SwiftUI

struct WorktreesView: View {
  @ObservedObject var model: RepositoryModel
  @EnvironmentObject var store: AppStore
  @StateObject private var request = WorkflowRequest()
  @StateObject private var removalNavigation = WorkflowRequest()
  @State private var records: [GitWorktree] = []
  @State private var common = ""
  @State private var creating = false
  @State private var lockTarget: GitWorktree?
  @State private var reason = ""
  @State private var showingTasks = false
  var body: some View {
    VStack(spacing: 0) {
      Picker(store.text("Workspace", "工作空间"), selection: $showingTasks) {
        Text(store.text("Worktrees", "工作树")).tag(false)
        Text(store.text("Tasks", "任务")).tag(true)
      }.pickerStyle(.segmented).frame(width: 250).padding(10)
      Divider()
      if showingTasks { TaskWorkspacesView(model: model, manager: store.taskWorkspaces) }
      else { worktreesContent }
    }.onAppear {
      if let id = store.taskWorkspaces.selectedID, store.taskWorkspaces.task(id)?.path == model.record.path { showingTasks = true }
    }.onChange(of: store.taskRemovalRequest, initial: true) { _, route in
      guard let route, let task = store.taskWorkspaces.task(route.taskID), route.sourcePath == model.record.path else { return }
      let id = route.taskID
      store.taskRemovalRequest = nil; showingTasks = false
      removalNavigation.start { ticket in
        let trees = try await model.git().worktrees(includeStatus: false)
        guard removalNavigation.current(ticket), store.taskWorkspaces.task(id) == task,
          let tree = trees.first(where: { $0.path == task.path }) else { throw TaskWorkspaceError.changed }
        common = task.commonDirectory
        reviewRemoval(tree)
      }
    }.onDisappear { removalNavigation.cancel() }
  }
  private var worktreesContent: some View {
    VStack(spacing: 0) {
      HStack {
        Text(store.text("Worktrees", "工作树")).font(.headline)
        Spacer()
        Button(store.text("Repair Moved Worktree…", "修复已移动工作树…")) { repair() }.disabled(model.busy)
        Button(store.text("New Worktree…", "新建工作树…")) { creating = true }.disabled(model.busy)
        Button(store.text("Refresh", "刷新")) { reload() }
      }.padding(12)
      Text(store.text("Removal is available only for worktrees created by GitPier. Missing entries are preserved; repair their location instead of pruning.", "仅可移除由 GitPier 创建的工作树。缺失记录会保留；请修复位置，不会自动清理。"))
        .font(uiFont(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 10)
      Divider()
      WorkflowProblem(request: request)
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(records) { record in
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Label(record.main ? store.text("Main repository", "主仓库") : URL(fileURLWithPath: record.path).lastPathComponent, systemImage: "arrow.triangle.branch").font(.headline).lineLimit(1)
                Text(record.branch.isEmpty ? store.text("Detached HEAD", "分离 HEAD") : String(record.branch.dropFirst("refs/heads/".count))).lineLimit(1)
                Spacer()
                Text(String(record.head.prefix(8))).font(.system(size: 11, design: .monospaced))
              }
              Text(record.path).font(uiFont(size: 11)).textSelection(.enabled).lineLimit(2)
              HStack {
                if record.locked { Badge(text: store.text("Locked", "已锁定"), color: .orange) }
                if record.missing { Badge(text: store.text("Missing", "缺失"), color: .orange) }
                if record.prunable { Badge(text: store.text("Prunable", "可清理"), color: .orange) }
                if let count = record.changeCount { Text(count == 0 ? store.text("Clean", "干净") : store.text("\(count) changes", "\(count) 项修改")) }
                else { Text(store.text("Status unavailable", "状态不可用")) }
                if !record.lockReason.isEmpty { Text(record.lockReason).lineLimit(1) }
                if !record.pruneReason.isEmpty { Text(record.pruneReason).lineLimit(1) }
              }.font(uiFont(size: 11)).foregroundStyle(.secondary)
              ScrollView(.horizontal) {
                HStack(spacing: 10) {
                  Button(store.text("Open in GitPier", "在 GitPier 中打开")) { Task { await store.addRepository(URL(fileURLWithPath: record.path), group: model.record.group) } }.disabled(record.missing || record.bare)
                  Menu(store.text("Open in Editor", "在编辑器中打开")) {
                    ForEach(ExternalEditors.available(settings: store.settings)) { editor in
                      Button(editor.name) { openEditor(record, application: editor.url) }
                    }
                  }.disabled(record.missing || record.bare)
                  Button(store.text("Open in Terminal", "在终端中打开")) {
                    Task {
                      await store.addRepository(URL(fileURLWithPath: record.path), group: model.record.group)
                      guard let target = store.current, target.record.path == record.path else { return }
                      var layout = target.panels.layout; layout.terminalVisible = true; target.editLayout(layout)
                      var settings = store.settings; settings.terminalDirectory = "repository"
                      target.terminal.add(settings: settings)
                    }
                  }.disabled(record.missing || record.bare)
                  if !record.main && !record.bare {
                    Button(store.text(record.locked ? "Unlock" : "Lock…", record.locked ? "解锁" : "锁定…")) {
                      if record.locked { model.run { git in try await git.setWorktreeLock(record, locked: false) } }
                      else { reason = ""; lockTarget = record }
                    }.disabled(model.busy)
                    Button(store.text("Remove…", "移除…"), role: .destructive) { reviewRemoval(record) }
                      .disabled(model.busy || record.locked || record.missing || record.prunable || record.changeCount != 0 || ownership(record) == nil || record.path == model.record.path)
                  }
                }.controlSize(.small)
              }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
              .accessibilityIdentifier("worktree-" + record.path)
            Divider()
          }
        }
      }
    }.task { reload() }.onChange(of: model.busy) { if !model.busy { reload() } }
      .onDisappear { request.cancel() }
      .sheet(isPresented: $creating) { WorktreeCreationSheet(model: model).environmentObject(store) }
      .alert(store.text("Lock Worktree", "锁定工作树"), isPresented: Binding(get: { lockTarget != nil }, set: { if !$0 { lockTarget = nil } })) {
        TextField(store.text("Reason (optional)", "原因（可选）"), text: $reason)
        Button(store.text("Lock", "锁定")) {
          if let record = lockTarget { let value = reason; model.run { git in try await git.setWorktreeLock(record, locked: true, reason: value) } }
          lockTarget = nil
        }
        Button(store.text("Cancel", "取消"), role: .cancel) { lockTarget = nil }
      }
  }
  private func ownership(_ record: GitWorktree) -> WorktreeOwnership? { store.configuration.ownedWorktrees.first { $0.path == record.path && $0.commonDirectory == common } }
  private func reload() {
    request.start { ticket in
      let git = await model.git(), directory = try await git.commonDirectory().path
      let trees = try await git.worktrees()
      guard request.current(ticket) else { return }
      records = trees; common = directory
    }
  }
  private func reviewRemoval(_ record: GitWorktree) {
    guard let owned = ownership(record) else { return }
    request.start { ticket in
      try store.validateWorktreeSessions(record.path)
      try store.taskWorkspaces.validateRemoval(record.path)
      let tasks = try store.taskWorkspaces.removalTasks(record.path)
      let review = try await model.git().reviewWorktreeRemoval(record, ownership: owned)
      guard request.current(ticket), !model.busy, store.current === model, model.page == "worktrees",
        try store.taskWorkspaces.removalTasks(record.path) == tasks else { return }
      model.confirmation = PendingAction(title: store.text("Remove Worktree?", "移除工作树？"), detail: store.text("This deletes the clean linked directory and its Git registration. Existing branches are retained. Detached commits must have a retaining reference. Affected path: ", "将删除干净的关联工作目录及 Git 注册，已有分支会保留，分离 HEAD 提交必须有引用保留。受影响路径：") + "\n\n" + record.path) {
        model.run(kind: .removeWorktree) { git in
          let lease = try store.reserveWorktreeLifecycle(record.path)
          defer { store.releaseWorktreeLifecycle(record.path, reservation: lease) }
          try store.validateWorktreeSessions(record.path, reservation: lease)
          try store.taskWorkspaces.validateRemoval(record.path)
          guard try store.taskWorkspaces.removalTasks(record.path) == tasks else { throw TaskWorkspaceError.changed }
          try await git.removeWorktree(review)
          await store.taskWorkspaces.worktreeRemoved(record.path)
          store.forgetWorktree(owned)
          await store.refreshWorktreeFamily(owned.commonDirectory)
        }
      }
    }
  }
  private func repair() {
    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
    panel.title = store.text("Select Moved Worktree", "选择已移动的工作树")
    guard panel.runModal() == .OK, let target = panel.url else { return }
    request.start { ticket in
      let review = try await model.git().reviewWorktreeRepair(at: target)
      try store.validateWorktreeSessions(review.previous.path)
      try store.validateWorktreeRepairRecords(previous: review.previous.path, destination: review.ownership.path)
      guard request.current(ticket), !model.busy, store.current === model, model.page == "worktrees" else { return }
      model.confirmation = PendingAction(title: store.text("Repair Worktree Metadata?", "修复工作树元数据？"), detail: store.text("Update Git metadata for this moved linked worktree without moving or deleting files: ", "更新此已移动关联工作树的 Git 元数据，不移动或删除文件：") + "\n\n" + review.previous.path + " → " + target.path, destructive: false) {
        model.run { git in
          let lease = try store.reserveWorktreeLifecycle(review.previous.path)
          defer { store.releaseWorktreeLifecycle(review.previous.path, reservation: lease) }
          let destinationLease = review.ownership.path == review.previous.path ? nil : try store.reserveWorktreeLifecycle(review.ownership.path)
          defer { if let destinationLease { store.releaseWorktreeLifecycle(review.ownership.path, reservation: destinationLease) } }
          try store.validateWorktreeSessions(review.previous.path, reservation: lease)
          try store.validateWorktreeRepairRecords(previous: review.previous.path, destination: review.ownership.path)
          let repaired = try await git.repairWorktree(review)
          await store.reconcileMovedWorktree(repaired, previousPath: review.previous.path)
          await store.refreshWorktreeFamily(repaired.commonDirectory)
        }
      }
    }
  }
  private func openEditor(_ record: GitWorktree, application: URL) {
    NSWorkspace.shared.open([URL(fileURLWithPath: record.path)], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
      if let error { Task { @MainActor in model.error = error.localizedDescription } }
    }
  }
}

/// Own sheet inputs here so text edits invalidate the validation button immediately.
struct WorktreeCreationSheet: View {
  @ObservedObject var model: RepositoryModel
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var destination = ""
  @State private var branch: String
  @State private var newBranch = false
  @State private var startAt = "HEAD"
  init(model: RepositoryModel) {
    self.model = model
    _branch = State(initialValue: model.branches.first { !$0.remote && !$0.current }?.name ?? "")
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(store.text("New Worktree", "新建工作树")).font(.headline)
      Toggle(store.text("Create a new branch", "同时创建新分支"), isOn: $newBranch)
      if newBranch {
        TextField(store.text("Branch name", "分支名称"), text: $branch)
        TextField(store.text("Start at", "起始提交"), text: $startAt)
      } else {
        Picker(store.text("Local branch", "本地分支"), selection: $branch) {
          Text(store.text("Select a branch", "选择分支")).tag("")
          ForEach(model.branches.filter { !$0.remote }) { Text($0.name).tag($0.name) }
        }
      }
      HStack {
        TextField(store.text("New absolute directory path", "新的绝对目录路径"), text: $destination)
        Button(store.text("Choose…", "选择…")) {
          let panel = NSSavePanel(); panel.canCreateDirectories = true; panel.nameFieldStringValue = branch.replacingOccurrences(of: "/", with: "-")
          panel.title = store.text("Choose New Worktree Directory", "选择新工作树目录")
          if panel.runModal() == .OK, let url = panel.url { destination = url.path }
        }
      }
      Text(store.text("Git refuses branches already checked out elsewhere. Existing directories will not be overwritten.", "Git 会拒绝已在其他工作树检出的分支；不会覆盖现有目录。" )).font(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button(store.text("Cancel", "取消")) { dismiss() }
        Button(store.text("Create", "创建")) {
          let path = destination, name = branch, new = newBranch, start = startAt
          dismiss()
          model.run(kind: .createWorktree) { git in
            let owned = try await git.createWorktree(destination: URL(fileURLWithPath: path), branch: name, newBranch: new, startAt: start)
            store.rememberWorktree(owned)
            await store.addRepository(URL(fileURLWithPath: owned.path), group: model.record.group)
            await store.refreshWorktreeFamily(owned.commonDirectory)
          }
        }.disabled(branch.isEmpty || !destination.hasPrefix("/"))
      }
    }.padding(22).textFieldStyle(.roundedBorder).frame(width: 540)
  }
}
