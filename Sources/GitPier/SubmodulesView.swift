import GitPierCore
import SwiftUI

struct SubmodulesView: View {
  @ObservedObject var model: RepositoryModel
  @EnvironmentObject var store: AppStore
  @StateObject private var request = WorkflowRequest()
  @State private var modules: [GitSubmodule] = []
  @State private var selected: String?
  @State private var nested = true
  @State private var adding = false
  @State private var review: SubmoduleReview?
  var current: GitSubmodule? { modules.first { $0.path == selected } }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(store.text("Submodules", "子模块")).font(.title3.weight(.semibold))
        Spacer()
        Toggle(store.text("Show nested", "显示嵌套"), isOn: $nested).toggleStyle(.checkbox)
        Button(store.text("Refresh", "刷新")) { load() }.disabled(request.loading || model.busy)
        Button(store.text("Add Submodule…", "添加子模块…")) { adding = true }.disabled(model.busy || model.status.operation != nil)
      }
      Text(store.text("Parent commits record a gitlink; child files and Index remain independent. No force, automatic recursion, Deinit or removal is performed.",
                      "父提交只记录 gitlink，子仓库文件和 Index 相互独立。不使用强制、自动递归、Deinit 或移除操作。"))
        .font(.caption).foregroundStyle(.secondary)
      WorkflowProblem(request: request)
      List(modules, selection: $selected) { module in
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Image(systemName: "shippingbox").foregroundStyle(.secondary)
            Text(module.name).font(.headline).lineLimit(1)
            Text(module.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Badge(text: store.text(module.initialized ? "Ready" : module.registered ? "Not Checked Out" : "Not Initialized",
                                   module.initialized ? "就绪" : module.registered ? "尚未检出" : "未初始化"))
            if let changes = module.changes, changes > 0 { Badge(text: store.text("\(changes) changes", "\(changes) 项修改"), color: .orange) }
          }
          Text(module.url.isEmpty ? store.text("Missing URL", "缺少 URL") : module.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          if let problem = module.problem { Text(localizedUI(problem)).font(.caption).foregroundStyle(.orange).lineLimit(2) }
        }.padding(.vertical, 5).padding(.leading, CGFloat(module.depth * 14)).tag(module.path)
          .contextMenu { openMenu(module) }
      }.listStyle(.inset)
      if modules.count >= 100 { Text(store.text("Listing is limited to 100 entries and three nested levels.", "列表最多显示 100 条及三层嵌套。")).font(.caption).foregroundStyle(.orange) }
      if modules.isEmpty && !request.loading && request.problem == nil {
        Text(store.text("No submodules are configured.", "没有配置子模块。")).font(.callout).foregroundStyle(.secondary)
      }
      if let module = current {
        VStack(alignment: .leading, spacing: 8) {
          Text(module.path).font(.headline).textSelection(.enabled)
          HStack {
            hash(store.text("Child HEAD", "子仓库 HEAD"), module.currentHead)
            hash(store.text("Index Gitlink", "Index gitlink"), module.indexCommit)
            hash(store.text("Parent HEAD Gitlink", "父 HEAD gitlink"), module.parentCommit)
          }
          if !module.configuredURL.isEmpty && module.configuredURL != module.url {
            Text(store.text("Registered URL: ", "已登记 URL：") + module.configuredURL).font(.caption).textSelection(.enabled)
          }
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
              Menu(store.text("Open", "打开")) { openMenu(module) }
              if module.depth == 0 {
                Button(store.text("Init Settings…", "初始化配置…")) { prepare(module, action: .initialize) }.disabled(module.registered)
                Button(store.text("Checkout Recorded Commit…", "检出记录提交…")) { prepare(module, action: .recorded) }
                Button(store.text("Update from Remote…", "从远程更新…")) { prepare(module, action: .remote) }.disabled(!module.initialized)
                Button(store.text("Sync URLs…", "同步 URL…")) { prepare(module, action: .sync) }
              } else {
                Button(store.text("Open Parent to Manage", "打开父仓库以管理")) { openParent(module) }
              }
            }.disabled(model.busy || module.problem != nil || model.status.operation != nil || request.loading)
          }
        }.padding(12).background(Color.primary.opacity(0.035))
      }
    }.padding(18)
      .onAppear { load() }.onDisappear { request.cancel() }
      .onChange(of: nested) { _, _ in load() }
      .onChange(of: model.busy) { _, busy in if !busy { load() } }
      .sheet(isPresented: $adding) { SubmoduleAddView(model: model).environmentObject(store) }
      .sheet(isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } })) {
        if let review { SubmoduleReviewView(model: model, review: review).environmentObject(store) }
      }
  }
  func hash(_ title: String, _ value: String?) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value.map { String($0.prefix(12)) } ?? "—").font(uiFont(size: 11, design: .monospaced)).textSelection(.enabled)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  @ViewBuilder func openMenu(_ module: GitSubmodule) -> some View {
    Button(store.text("Open in GitPier", "在 GitPier 中打开")) {
      Task { await store.addRepository(URL(fileURLWithPath: model.record.path).appendingPathComponent(module.path), group: model.record.group) }
    }.disabled(!module.initialized || module.problem != nil)
    Button(store.text("Open in Editor", "在编辑器中打开")) { model.openEditor(module.path) }.disabled(!module.initialized || module.problem != nil)
    Button(store.text("Open in Terminal", "在终端中打开")) {
      Task {
        await store.addRepository(URL(fileURLWithPath: model.record.path).appendingPathComponent(module.path), group: model.record.group)
        guard let target = store.current else { return }
        var layout = target.panels.layout; layout.terminalVisible = true; target.editLayout(layout)
        var settings = store.settings; settings.terminalDirectory = "repository"; target.terminal.add(settings: settings)
      }
    }.disabled(!module.initialized || module.problem != nil)
  }
  func openParent(_ module: GitSubmodule) {
    let relative = String(module.path.dropLast(module.localPath.count))
    Task { await store.addRepository(URL(fileURLWithPath: model.record.path).appendingPathComponent(relative), group: model.record.group) }
  }
  func load() {
    let nested = nested
    request.start { ticket in
      let result = try await model.git().submodules(includeNested: nested)
      guard request.current(ticket), store.current === model else { return }
      modules = result
      if selected == nil || !result.contains(where: { $0.path == selected }) { selected = result.first?.path }
    }
  }
  func prepare(_ module: GitSubmodule, action: SubmoduleAction) {
    request.start { ticket in
      try store.validateSubmoduleSession(module.path, parent: model)
      let value = try await model.git().reviewSubmodule(module.path, action: action)
      guard request.current(ticket), store.current === model, !model.busy else { return }; review = value
    }
  }
}

@MainActor extension AppStore {
  func validateSubmoduleSession(_ path: String, parent: RepositoryModel) throws {
    let target = ProfessionalWorkflowParser.canonicalPath(URL(fileURLWithPath: parent.record.path).appendingPathComponent(path).path)
    guard !models.values.contains(where: { ProfessionalWorkflowParser.canonicalPath($0.record.path) == target && ($0.busy || !$0.conflictEditor.unsavedPaths.isEmpty) }) else {
      throw GitPierError.invalidInput(text("Finish the child's Git operation and preserve its conflict drafts before changing the submodule.", "修改子模块前，请完成子仓库 Git 操作并保存冲突草稿。"))
    }
  }
}

struct SubmoduleReviewView: View {
  @ObservedObject var model: RepositoryModel
  let review: SubmoduleReview
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @State private var confirming = false
  var title: String {
    switch review.action {
    case .initialize: return store.text("Initialize Submodule Settings", "初始化子模块配置")
    case .sync: return store.text("Sync Submodule URLs", "同步子模块 URL")
    case .recorded: return store.text("Checkout Recorded Gitlink", "检出已记录 gitlink")
    case .remote: return store.text("Checkout Reviewed Remote Commit", "检出已审查远程提交")
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(title).font(.title2.weight(.semibold))
      Text(review.module.path).font(.headline).textSelection(.enabled)
      Text(review.module.url).font(.caption).textSelection(.enabled)
      Text(commitSummary)
        .font(uiFont(size: 11, design: .monospaced)).textSelection(.enabled)
      Text(detail).font(.callout)
      Text(store.text("Local modifications, the parent Index, other child worktrees, hooks and SSH/HTTPS verification remain protected. No recursive update, force or commit runs.",
                      "保护本地修改、父 Index、其他子工作树、Hooks 和 SSH/HTTPS 验证，不递归更新、不强制、不创建提交。"))
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button(store.text("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer(); Button(store.text("Confirm Operation…", "确认操作…")) { confirming = true }.disabled(model.busy)
      }
    }.padding(22).frame(minWidth: 650, idealWidth: 780)
      .alert(title, isPresented: $confirming) {
        Button(store.text("Proceed", "继续")) { execute() }
        Button(store.text("Cancel", "取消"), role: .cancel) {}.keyboardShortcut(.defaultAction)
      } message: { Text(detail) }
  }
  private var commitSummary: String {
    let head = "HEAD " + (review.module.currentHead ?? "—")
    let index = "Index gitlink " + (review.module.indexCommit ?? "—")
    let target = store.text("Target: ", "目标：") + (review.target ?? "—")
    return [head, index, target].joined(separator: "\n")
  }
  var detail: String {
    switch review.action {
    case .initialize: return store.text("Register this .gitmodules entry in local repository configuration. This action does not download or check out files.", "将此 .gitmodules 条目登记到仓库本地配置，不下载或检出文件。")
    case .sync: return store.text("Synchronize the selected declared URL into registered parent/child settings. Existing working files are retained.", "将选中的声明 URL 同步到父 / 子仓库登记配置，保留工作文件。")
    case .recorded: return store.text("Check out the reviewed Index gitlink as detached HEAD. Missing objects may be downloaded. Uninitialized directories must be empty; existing modifications and ignored-file collisions are refused.", "以分离 HEAD 检出已审查的 Index gitlink，可能下载缺失对象。未初始化目录必须为空；拒绝覆盖本地修改及忽略文件冲突。")
    case .remote: return store.text("Download and check out the displayed fixed remote commit. The parent's recorded gitlink stays unchanged until you review and stage it separately.", "下载并检出显示的固定远程提交。父仓库记录的 gitlink 保持不变，需另行审查和暂存。")
    }
  }
  func execute() {
    guard store.current === model, !model.busy else { return }
    do { try store.validateSubmoduleSession(review.module.path, parent: model) }
    catch { model.error = error.localizedDescription; return }
    dismiss()
    model.run(label: title) { git in
      model.output = try await git.performSubmodule(review, progress: model.activity.receiver())
      if review.module.initialized {
        let child = await GitServiceRegistry.shared.service(for: URL(fileURLWithPath: model.record.path).appendingPathComponent(review.module.path))
        if let common = try? await child.commonDirectory().path { await store.refreshWorktreeFamily(common) }
      }
    }
  }
}

struct SubmoduleAddView: View {
  @ObservedObject var model: RepositoryModel
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @StateObject private var request = WorkflowRequest()
  @State private var url = ""
  @State private var path = ""
  @State private var review: SubmoduleAddReview?
  @State private var confirming = false
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(store.text("Add Submodule", "添加子模块")).font(.title2.weight(.semibold))
      TextField(store.text("Absolute repository URL or path", "绝对仓库 URL 或路径"), text: $url).textFieldStyle(.roundedBorder)
      TextField(store.text("New relative directory", "新的相对目录"), text: $path).textFieldStyle(.roundedBorder)
      Text(store.text("A clone is downloaded first, then .gitmodules and the new gitlink are staged after state revalidation. Other staging is preserved. No commit runs. Interrupted clones remain available for review.",
                      "先下载克隆，重查状态后暂存 .gitmodules 与新 gitlink，保留其他暂存、不创建提交。中断的克隆目录会保留以便审查。"))
        .font(.caption).foregroundStyle(.secondary)
      WorkflowProblem(request: request)
      if let review {
        Text(configurationSummary(review))
          .font(uiFont(size: 11, design: .monospaced)).textSelection(.enabled)
      }
      HStack {
        Button(store.text("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer(); Button(store.text("Review", "审查")) { prepare() }.disabled(url.isEmpty || path.isEmpty || request.loading || model.busy)
        Button(store.text("Add Reviewed Submodule…", "添加已审查子模块…")) { confirming = true }.disabled(review == nil || request.loading || model.busy)
      }
    }.padding(22).frame(minWidth: 650, idealWidth: 780)
      .onDisappear { request.cancel() }
      .onChange(of: url) { _, _ in request.cancel(); review = nil }
      .onChange(of: path) { _, _ in request.cancel(); review = nil }
      .alert(store.text("Clone & Add Submodule?", "克隆并添加子模块？"), isPresented: $confirming) {
        Button(store.text("Clone & Add", "克隆并添加")) {
          guard let review, store.current === model, !model.busy else { return }; dismiss()
          model.run(label: store.text("Adding Submodule", "添加子模块")) { git in model.output = try await git.addSubmodule(review, progress: model.activity.receiver()) }
        }
        Button(store.text("Cancel", "取消"), role: .cancel) {}.keyboardShortcut(.defaultAction)
      } message: { Text(store.text("This downloads a repository into the displayed new directory and stages its configuration/gitlink. Existing directories are never replaced. No commit is created.", "将仓库下载到显示的新目录并暂存配置 / gitlink，绝不替换已有目录，不创建提交。")) }
  }
  private func configurationSummary(_ review: SubmoduleAddReview) -> String {
    let path = "  path = " + review.path
    let url = "  url = " + GitService.redact(review.url)
    let parent = store.text("Parent HEAD: ", "父 HEAD：") + (review.parent.head ?? "—")
    return [".gitmodules", path, url, "", parent].joined(separator: "\n")
  }
  func prepare() {
    let url = url, path = path
    request.start { ticket in
      let value = try await model.git().reviewSubmoduleAdd(url: url, path: path)
      guard request.current(ticket), store.current === model, !model.busy else { return }; review = value
    }
  }
}
