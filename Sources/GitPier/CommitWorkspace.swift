import AppKit
import GitPierCore
import SwiftUI

struct RepositoryWorkspace: View {
  @ObservedObject var model: RepositoryModel
  @ObservedObject var panels: WorkspacePanels
  init(model: RepositoryModel) {
    self.model = model
    panels = model.panels
  }
  @EnvironmentObject var store: AppStore
  @Environment(\.colorScheme) var scheme
  @State private var importedPatch: PatchImportRequest?
  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      if model.status.operation == .merge {
        MergeStateBanner(model: model)
        Divider()
      }
      if let output = model.output {
        HStack(alignment: .center, spacing: 10) {
          Image(
            systemName: model.outputResult == .needsAttention
              ? "exclamationmark.triangle"
              : model.outputResult == .cancelled ? "stop.circle" : "checkmark.circle"
          )
          .font(.system(size: 14)).foregroundStyle(
            model.outputResult == .needsAttention
              ? Color.orange : model.outputResult == .cancelled ? Color.secondary : Color.mint
          )
          .frame(width: 20, height: 20)
          Text(output.trimmingCharacters(in: .whitespacesAndNewlines)).font(uiFont(size: 11))
            .lineLimit(3).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          Spacer()
          if let rejection = model.rejectedPush {
            Button(store.text("Merge & Push…", "合并并推送…")) { model.confirmMergeAndPush(rejection) }
              .disabled(model.busy)
          } else if model.pushFailed {
            Button(store.text("Retry Push", "重试推送")) { model.retryPush() }
              .disabled(model.busy || model.status.operation != nil || model.status.files.contains(where: \.isConflicted))
          }
          if model.needsUpstream {
            Button(store.text("Choose Upstream…", "选择 Upstream…")) { model.needsUpstream = true }
          }
          IconButton("xmark", help: localizedUI("Dismiss")) { model.output = nil }
        }.frame(minHeight: 28, alignment: .center).padding(.horizontal, 10).padding(.vertical, 6)
          .background(Color.accentColor.opacity(0.05))
        Divider()
      }
      GeometryReader { geometry in
        VStack(spacing: 0) {
          if !panels.layout.terminalMaximized || !panels.layout.terminalVisible {
            pageContent(height: geometry.size.height)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          if panels.layout.terminalVisible {
            if !panels.layout.terminalMaximized {
              ResizeHandle(
                vertical: false,
                onDrag: { delta in
                  var layout = panels.layout
                  layout.terminalHeight = min(
                    max(130, layout.terminalHeight - delta), max(130, geometry.size.height - 160))
                  model.editLayout(layout, persist: false)
                }, onEnd: { model.persistLayout() })
            }
            TerminalPanel(model: model, manager: model.terminal).id(model.record.id).frame(
              height: panels.layout.terminalMaximized
                ? geometry.size.height
                : min(panels.layout.terminalHeight, max(130, geometry.size.height - 420)))
          }
        }
      }
      Divider()
      statusBar
    }
    .sheet(isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } }))
    {
      ErrorSheet(title: store.text("Git Operation", "Git 操作"), detail: model.error ?? "") {
        model.error = nil
      }
    }
    .sheet(isPresented: $model.needsUpstream) {
      PushUpstreamSheet(model: model).environmentObject(store)
    }
    .sheet(isPresented: $model.showRebaseRecovery) { RebaseRecoveryView(model: model).environmentObject(store) }
    .sheet(item: $importedPatch) { PatchImportView(model: model, input: $0).environmentObject(store) }
    .sheet(isPresented: Binding(
      get: { model.confirmation != nil },
      set: { if !$0 { model.confirmation = nil } })
    ) { workflowReview }
    .task { await model.activate() }
    .background {
      if PerformanceAcceptance.enabled {
        PerformancePageProbe(page: model.page, repositoryID: model.record.id)
      }
    }
  }
  @ViewBuilder func pageContent(height: Double) -> some View {
    switch model.page {
    case "history": HistoryView(model: model)
    case "branches": BranchesView(model: model)
    case "reflog": ReflogView(model: model)
    case "worktrees": WorktreesView(model: model)
    case "compare": BranchComparisonView(model: model)
    case "remotes": RemotesView(model: model)
    case "stash": StashView(model: model)
    case "tags": TagsView(model: model)
    case "repository": RepositorySettingsView(model: model)
    case "conflicts": ConflictResolutionView(model: model)
    case "lfs": LFSView(model: model)
    case "submodules": SubmodulesView(model: model)
    case "hosting": HostingWorkspaceView(model: model)
    default:
      GeometryReader { area in
        HStack(spacing: 0) {
          ChangesPanel(model: model).frame(
            width: min(max(250, panels.layout.changesWidth), area.size.width * 0.48))
          ResizeHandle(
            vertical: true,
            onDrag: { delta in
              var layout = panels.layout
              layout.changesWidth = min(
                max(250, layout.changesWidth + delta), area.size.width * 0.48)
              model.editLayout(layout, persist: false)
            }, onEnd: { model.persistLayout() })
          DiffPanel(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
  }
  /// Bound every PendingAction's details, including large commit/discard lists.
  /// Keep actions outside the scroll region and allow async reviews to update in place.
  private var workflowReview: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(model.confirmation?.title ?? "").font(.headline)
      if model.confirmation?.canConfirm == false { ProgressView().controlSize(.small) }
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          Text(model.confirmation?.detail ?? "").font(.callout).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
          if let parents = model.confirmation?.mainlineParents, !parents.isEmpty {
            MergeRevertParentPicker(model: model, parents: parents)
          }
        }
      }.frame(maxHeight: 280)
      HStack {
        Spacer()
        Button(store.text("Cancel", "取消"), role: .cancel) { model.confirmation = nil }
          .keyboardShortcut(.cancelAction).accessibilityIdentifier("gitpier.workflow.review.cancel")
        if let reviewedAction = model.confirmation?.reviewedAction {
          Button(store.text("Reviewed, Commit Later", "已审查，稍后提交")) {
            model.confirmation = nil
            reviewedAction()
          }.accessibilityIdentifier("gitpier.workflow.review.reviewed")
        }
        Button(
          model.confirmation?.confirmTitle ?? store.text("Confirm", "确认"),
          role: model.confirmation?.destructive == false ? nil : .destructive
        ) {
          guard let pending = model.confirmation, pending.readyForConfirmation else { return }
          model.confirmation = nil
          pending.performConfirmedAction()
        }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
          .disabled(model.confirmation?.readyForConfirmation != true).accessibilityIdentifier("gitpier.workflow.review.confirm")
      }
    }.padding(24).frame(width: 560).frame(maxHeight: 420)
      .modifier(AppAppearance(store: store))
      .onExitCommand { model.confirmation = nil }
      .onChange(of: store.selectionIdentity) { _, _ in
        if model.confirmation?.mainlineParents != nil { model.confirmation = nil }
      }
      .onChange(of: model.pageIdentity) { _, _ in
        if model.confirmation?.mainlineParents != nil { model.confirmation = nil }
      }
  }
  var toolbar: some View {
    HStack(spacing: 14) {
      ContextWorkflowButton(model: model, workspace: store.workspace)
      Menu {
        ForEach(model.branches.filter { !$0.remote }) { branch in
          Button((branch.current ? "✓ " : "") + branch.name) {
            model.run(updatesCommitState: .checkout) { git in try await git.switchBranch(branch.name) }
          }
        }
        Divider()
        Button(store.text("Manage Branches…", "管理分支…")) { model.setPage("branches") }
      } label: {
        Label(
          model.status.branch.isEmpty ? store.text("Repository", "仓库") : model.status.branch,
          systemImage: "arrow.triangle.branch"
        ).font(uiFont(size: 12, weight: .medium))
      }.menuStyle(.borderlessButton).frame(maxWidth: 190).accessibilityIdentifier("gitpier.repository.branch")
      Divider().frame(height: 18)
      ForEach(
        [("commit", "Commit", "提交"), ("history", "History", "历史"), ("branches", "Branches", "分支")],
        id: \.0
      ) { page in
        Button {
          model.setPage(page.0)
        } label: {
          Text(store.text(page.1, page.2)).font(
            .system(size: 12, weight: model.page == page.0 ? .semibold : .regular)
          ).foregroundStyle(model.page == page.0 ? Color.accentColor : Color.secondary)
        }.buttonStyle(.workspace)
      }
      Menu {
        Button(store.text("Resolve Conflicts", "解决冲突")) { model.openConflicts() }
        Button(store.text("Pull / Merge Requests", "拉取 / 合并请求")) { model.setPage("hosting") }
        Button(store.text("Reflog", "引用日志")) { model.setPage("reflog") }
        Button(store.text("Worktrees", "工作树")) { model.setPage("worktrees") }
        Button("Git LFS") { model.setPage("lfs") }
        Button(store.text("Submodules", "子模块")) { model.setPage("submodules") }
        Button(store.text("Compare Branches", "比较分支")) { model.setPage("compare") }
        Button(store.text("Import Patch…", "导入补丁…")) {
          PatchFileDialogs.choose { url in
            Task {
              do {
                let data = try await PatchFileDialogs.read(url)
                guard store.current === model, !model.busy else { return }
                importedPatch = PatchImportRequest(name: url.lastPathComponent, data: data)
              } catch { model.error = localizedUI(error.localizedDescription) }
            }
          }
        }.disabled(model.busy || model.status.operation != nil)
        Divider()
        Button(store.text("Remotes", "远程")) { model.setPage("remotes") }
        Button(localizedUI("Stash")) { model.setPage("stash") }
        Button(store.text("Tags", "标签")) { model.setPage("tags") }
        Divider()
        Button(store.text("Repository Settings", "仓库设置")) { model.setPage("repository") }
      } label: {
        Image(systemName: "ellipsis")
      }.menuStyle(.borderlessButton).frame(width: 22)
      Spacer(minLength: 5)
      RepositoryNetworkToolbar(model: model, workspace: store.workspace)
      IconButton("arrow.clockwise", help: store.text("Refresh (⌘R)", "刷新 (⌘R)")) {
        Task { await model.refresh() }
      }
      IconButton("terminal", help: store.text("Terminal (⌥F12)", "终端 (⌥F12)")) {
        var layout = panels.layout
        layout.terminalVisible.toggle()
        model.editLayout(layout)
        if layout.terminalVisible && model.terminal.sessions.isEmpty {
          model.terminal.add(settings: store.settings)
        }
      }
    }.padding(.horizontal, 14).frame(height: 43).background(Theme.panel(scheme))
      .accessibilityElement(children: .contain).accessibilityIdentifier("gitpier.repository.toolbar")
  }
  var statusBar: some View {
    HStack(spacing: 10) {
      Circle().fill(model.available ? Color.mint : .orange).frame(width: 5, height: 5)
      Text(
        model.available
          ? store.text(
            "\(model.status.files.count) changes · \(model.stagedCount) staged",
            "\(model.status.files.count) 处变更 · \(model.stagedCount) 已暂存")
          : store.text("Repository unavailable", "仓库不可用"))
      Spacer(minLength: 4)
      OperationProgressView(progress: model.activity) { model.cancel() }.layoutPriority(1)
      if model.busy || model.refreshing {
        EmptyView()
      } else if model.hasExternalChanges {
        Button(store.text("External changes · ⌘R", "外部变更 · ⌘R")) { Task { await model.refresh() } }
          .foregroundStyle(.orange).buttonStyle(.workspace)
      } else {
        Text(store.text("Manual refresh · ⌘R", "手动刷新 · ⌘R"))
      }
      if !model.busy && !model.refreshing, let upstream = model.status.upstream {
        Text(upstream).lineLimit(1)
      }
      Text(localizedUI("↑\(model.status.ahead) ↓\(model.status.behind)"))
      Text(model.status.head.map { String($0.prefix(8)) } ?? "No commits").font(
        .system(size: 10, design: .monospaced))
    }.font(uiFont(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 26)
      .background(Theme.panel(scheme))
  }
  func command(_ operation: GitOperation) -> String {
    operation == .cherryPick ? "cherry-pick" : operation.rawValue
  }
}

struct ChangesPanel: View {
  @ObservedObject var model: RepositoryModel
  @ObservedObject var panels: WorkspacePanels
  init(model: RepositoryModel) {
    self.model = model
    panels = model.panels
  }
  @EnvironmentObject var store: AppStore
  @Environment(\.colorScheme) var scheme
  @State private var blame: BlameRequest?
  @FocusState private var searchFocused: Bool
  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        HStack {
          Text(store.text("Changes", "更改")).font(uiFont(size: 12, weight: .semibold))
          Spacer()
          IconButton(
            model.treeMode ? "list.bullet" : "folder", help: store.text("List / Tree", "列表 / 目录树")
          ) {
            model.treeMode.toggle()
            if model.treeMode {
              model.expandedDirectories = Set(model.filteredFiles.flatMap { parents($0.path) })
            }
          }
          Menu {
            ForEach(
              [
                ("all", "All Changes", "全部变更"), ("staged", "Staged", "已暂存"),
                ("unstaged", "Unstaged", "未暂存"), ("conflicts", "Conflicts", "冲突"),
              ], id: \.0
            ) { item in Button(store.text(item.1, item.2)) { model.filter = item.0 } }
          } label: {
            Image(systemName: "line.3.horizontal.decrease")
          }.menuStyle(.borderlessButton).frame(width: 22)
        }.padding(.horizontal, 12).frame(height: 35)
        Divider()
        HStack(spacing: 4) {
          IconButton(
            "arrow.triangle.2.circlepath", help: store.text("Refresh Changes (⌘R)", "刷新更改 (⌘R)")
          ) { Task { await model.refresh() } }.disabled(model.refreshing)
          IconButton(
            "arrow.uturn.backward",
            help: store.text("Discard selected unstaged changes…", "丢弃选中未暂存修改…")
          ) { model.discardSelection() }.disabled(
            selectedChanges.filter { $0.isUnstaged && !$0.isConflicted }.isEmpty || model.busy)
          IconButton("arrow.down.to.line", help: store.text("Stage selected files", "暂存选中文件")) {
            model.stageGroup(selectedChanges, unstage: false)
          }.disabled(selectedChanges.isEmpty || model.busy)
          IconButton("arrow.up.to.line", help: store.text("Unstage selected files", "取消暂存选中文件")) {
            model.stageGroup(selectedChanges, unstage: true)
          }.disabled(!selectedChanges.contains(where: \.isStaged) || model.busy)
          IconButton("eye", help: store.text("Open selected Diff tab", "打开选中文件 Diff 标签")) {
            if let file = model.selectedFile { model.select(file, permanent: true) }
          }.disabled(model.selectedFile == nil)
          Divider().frame(height: 16)
          IconButton("scope", help: store.text("Locate selected file", "定位选中文件")) {
            NotificationCenter.default.post(name: .gitpierRevealSelected, object: nil)
          }.disabled(model.selectedFile == nil)
          IconButton("chevron.down", help: store.text("Expand file groups", "展开文件分组")) {
            panels.trackedExpanded = true
            panels.untrackedExpanded = true
            model.expandedDirectories = Set(model.filteredFiles.flatMap { parents($0.path) })
          }
          IconButton("chevron.up", help: store.text("Collapse file groups", "收起文件分组")) {
            panels.trackedExpanded = false
            panels.untrackedExpanded = false
            model.expandedDirectories = []
          }
          Spacer(minLength: 0)
        }.padding(.horizontal, 8).frame(height: 30).background(Theme.panel(scheme))
        Divider()
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
          TextField(store.text("Search files…", "搜索文件…"), text: $model.query).textFieldStyle(.plain)
            .focused($searchFocused)
          if !model.query.isEmpty {
            IconButton("xmark", help: localizedUI("Clear")) { model.query = "" }
          }
        }.font(uiFont(size: 11)).padding(.horizontal, 12).frame(height: 33)
        Divider()
        NativeChangesList(model: model, panels: panels, rows: listRows,
          menu: fileMenu, move: moveFileSelection).frame(maxHeight: .infinity)
        ResizeHandle(
          vertical: false,
          onDrag: { delta in
            var layout = panels.layout
            layout.messageHeight = min(
              max(140, layout.messageHeight - delta), geometry.size.height * 0.65)
            model.editLayout(layout, persist: false)
          }, onEnd: { model.persistLayout() })
        messagePanel.frame(
          height: min(panels.layout.messageHeight, max(130, geometry.size.height - 240)))
      }
    }.sheet(item: $blame) { BlameView(model: model, request: $0).environmentObject(store) }
    .background(Theme.editor(scheme)).onReceive(
      NotificationCenter.default.publisher(for: .gitpierSearch)
    ) { event in if event.object == nil { searchFocused = true } }
  }
  var selectedChanges: [FileChange] {
    model.status.files.filter { model.selectedPaths.contains($0.path) }
  }
  var listRows: [ChangesListRow] {
    let tracked = model.filteredFiles.filter { !$0.isUntracked }
    let untracked = model.filteredFiles.filter(\.isUntracked)
    var rows: [ChangesListRow] = []
    for (trackedGroup, title, files, expanded) in [
      (true, store.text("Tracked Files", "已跟踪文件"), tracked, panels.trackedExpanded),
      (false, store.text("Untracked Files", "未跟踪文件"), untracked, panels.untrackedExpanded),
    ] {
      rows.append(.group(tracked: trackedGroup, title: title, files: files, expanded: expanded))
      if expanded {
        for entry in entries(files) {
          if let file = entry.file { rows.append(.file(file, depth: entry.depth)) }
          else { rows.append(.directory(path: entry.id, depth: entry.depth,
            expanded: model.expandedDirectories.contains(entry.id))) }
        }
      }
    }
    if model.status.files.isEmpty {
      rows.append(.empty(model.status.operation == nil
        ? store.text("Working tree is clean", "工作区干净")
        : store.text("No file changes · Git operation still in progress", "没有文件差异 · Git 操作尚未完成")))
    }
    return rows
  }
  func moveFileSelection(_ delta: Int, modifiers: NSEvent.ModifierFlags) -> String? {
    let files = model.filteredFiles
    guard !files.isEmpty else { return nil }
    let index = files.firstIndex { $0.path == model.selectedPath } ?? 0
    let next = min(files.count - 1, max(0, index + delta))
    model.select(
      files[next], extend: modifiers.contains(.shift), toggle: modifiers.contains(.command))
    NotificationCenter.default.post(name: .gitpierRevealSelected, object: model.record.id)
    return files[next].path
  }
  func fileMenu(_ file: FileChange) -> NSMenu {
    model.select(file)
    var items = [
      NativeMenuItems.action(store.text("View Diff", "查看 Diff")) {
        model.select(file, permanent: true)
      },
      NativeMenuItems.action(store.text("Stage", "暂存")) {
        model.stageGroup(selected(file), unstage: false)
      },
      NativeMenuItems.action(
        store.text("Unstage", "取消暂存"), enabled: selected(file).contains(where: \.isStaged)
      ) {
        model.stageGroup(selected(file), unstage: true)
      },
      NativeMenuItems.action(store.text("Discard Changes…", "丢弃修改…"), enabled: file.isUnstaged) {
        model.discard(file)
      },
      .separator(),
      NativeMenuItems.editor(model: model, path: file.path),
      NativeMenuItems.action(store.text("Reveal in Finder", "在 Finder 中显示")) {
        model.reveal(file.path)
      },
      NativeMenuItems.action(store.text("Copy Path", "复制路径")) { copyText(file.path) },
      NativeMenuItems.action(store.text("Blame", "逐行溯源")) {
        blame = BlameRequest(path: file.path)
      },
      NativeMenuItems.action(store.text("File History", "文件历史")) {
        model.setPage("history")
        model.historyPath = file.path
        Task { await model.loadHistory(reset: true, path: file.path) }
      },
      NativeMenuItems.action(
        store.text("Add to .gitignore", "添加至 .gitignore"), enabled: file.isUntracked
      ) {
        model.run { git in try await git.ignore(file.path) }
      },
    ]
    if file.isConflicted {
      items.insert(
        NativeMenuItems.action(store.text("Resolve Conflict…", "解决冲突…")) {
          model.openConflicts(file.path)
        }, at: 0)
    }
    if file.isUntracked {
      items.append(
        NativeMenuItems.action(
          store.text("Ignore Locally (.git/info/exclude)", "添加到本地忽略 (.git/info/exclude)"),
          enabled: !model.busy && model.available
        ) {
          model.run(label: store.text("Ignoring locally", "添加本地忽略")) { git in
            try await git.excludeLocally(file.path)
          }
        })
    }
    return NativeMenuItems.menu(items)
  }
  var messagePanel: some View {
    VStack(spacing: 0) {
      HStack(spacing: 7) {
        Text(store.text("Commit Message", "提交说明")).font(uiFont(size: 11, weight: .semibold))
        Spacer()
        Toggle(localizedUI("Amend"), isOn: $model.amend).toggleStyle(.checkbox).font(
          uiFont(size: 10)
        ).disabled(model.status.operation != nil).help(
          store.text("Amend rewrites the latest commit", "Amend 会重写最后一次提交"))
        Menu {
          ForEach(["feat", "fix", "docs", "refactor", "test", "chore"], id: \.self) { type in
            Button(type + ": …") { model.editDraft(type + ": " + model.record.draft) }
          }
          Divider()
          ForEach(Array(model.recentMessages.enumerated()), id: \.offset) { _, message in
            Button(String(message.prefix(80))) { model.editDraft(message) }
          }
          Button(store.text("Use last commit message", "使用最近提交说明")) {
            Task {
              if let message = try? await model.git().history(count: 1).first {
                model.editDraft(
                  message.subject + (message.body.isEmpty ? "" : "\n\n" + message.body))
              }
            }
          }
        } label: {
          Image(systemName: "clock.arrow.circlepath")
        }.menuStyle(.borderlessButton).frame(width: 18)
      }.padding(.horizontal, 12).frame(height: 31).background(Theme.panel(scheme))
      Divider()
      ZStack(alignment: .topLeading) {
        if model.record.draft.isEmpty {
          Text(store.text("Summary\n\nDescribe why this change is needed…", "提交标题\n\n描述本次变更的原因…"))
            .font(uiFont(size: 12)).foregroundStyle(.tertiary).padding(10).allowsHitTesting(false)
        }
        CommitEditor(
          text: Binding(get: { model.record.draft }, set: { model.editDraft($0) }), scheme: scheme
        ) { model.commit(push: false) }
      }.frame(maxHeight: .infinity)
      Divider()
      HStack {
        Text(
          store.text(
            "\(model.includedPaths.count) files selected", "已选择 \(model.includedPaths.count) 个文件")
        )
        .foregroundStyle(.secondary)
        Spacer()
        Text(store.text("\(model.stagedCount) in Index", "Index 中 \(model.stagedCount) 个文件"))
          .foregroundStyle(.secondary)
      }.font(uiFont(size: 10, design: .monospaced)).padding(.horizontal, 10).frame(height: 26)
      HStack(spacing: 7) {
        if model.status.operation == .merge {
          Button(store.text("Complete Merge…", "完成合并…")) { model.reviewMergeContinuation() }
            .buttonStyle(.borderedProminent).disabled(!model.canContinueMerge)
            .accessibilityIdentifier("gitpier.merge.complete")
          if model.conflictPush != nil {
            Button(store.text("Complete & Push…", "完成并推送…")) { model.reviewMergeContinuation(push: true) }
              .disabled(!model.canContinueMerge).accessibilityIdentifier("gitpier.merge.complete-push")
          }
        } else {
          Button(store.text("Commit", "提交")) { model.commit(push: false) }.buttonStyle(
            .borderedProminent).disabled(!model.canCommit)
          Button(store.text("Commit & Push…", "提交并推送…")) { model.commit(push: true) }
            .disabled(!model.canCommit)
        }
        Spacer()
      }.controlSize(.small).padding(10)
    }
  }
  func selected(_ file: FileChange) -> [FileChange] {
    model.selectedPaths.contains(file.path)
      ? model.status.files.filter { model.selectedPaths.contains($0.path) } : [file]
  }
  func changeColor(_ file: FileChange) -> Color {
    file.isConflicted
      ? .orange
      : file.kind == .deleted
        ? .red : file.isUntracked || file.kind == .added ? .mint : .accentColor
  }
  struct TreeEntry: Identifiable {
    let id: String
    let file: FileChange?
    let depth: Int
  }
  func parents(_ path: String) -> [String] {
    let parts = path.split(separator: "/").dropLast()
    return parts.indices.map { parts[...$0].joined(separator: "/") }
  }
  func entries(_ files: [FileChange]) -> [TreeEntry] {
    if !model.treeMode { return files.map { TreeEntry(id: $0.path, file: $0, depth: 0) } }
    var result: [TreeEntry] = []
    var seen: Set<String> = []
    for file in files {
      let dirs = parents(file.path)
      for (depth, dir) in dirs.enumerated()
      where !seen.contains(dir)
        && dirs.prefix(depth).allSatisfy({ model.expandedDirectories.contains($0) })
      {
        seen.insert(dir)
        result.append(TreeEntry(id: dir, file: nil, depth: depth))
      }
      if dirs.allSatisfy({ model.expandedDirectories.contains($0) }) {
        result.append(TreeEntry(id: file.path, file: file, depth: dirs.count))
      }
    }
    return result
  }
}

struct StagingCheckbox: NSViewRepresentable {
  var state: NSControl.StateValue
  var enabled: Bool
  var accessibilityLabel = "Include changes in commit"
  var action: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator(action) }
  func makeNSView(context: Context) -> NSButton {
    let button = NSButton(
      checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.click))
    button.allowsMixedState = true
    button.controlSize = .small
    button.setAccessibilityLabel(accessibilityLabel)
    return button
  }
  func updateNSView(_ button: NSButton, context: Context) {
    button.state = state
    button.isEnabled = enabled
    button.setAccessibilityLabel(accessibilityLabel)
    context.coordinator.action = action
  }
  final class Coordinator: NSObject {
    var action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func click() { action() }
  }
}

final class CommitTextView: NSTextView {
  var commit: (() -> Void)?
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 && event.modifierFlags.contains(.command) {
      commit?()
    } else {
      super.keyDown(with: event)
    }
  }
}
struct CommitEditor: NSViewRepresentable {
  @Binding var text: String
  let scheme: ColorScheme
  var commit: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = DiffScrollView()
    scroll.drawsBackground = false
    let view = CommitTextView()
    view.isRichText = false
    view.font = NSFont.systemFont(ofSize: 12)
    view.textContainerInset = NSSize(width: 8, height: 8)
    view.isAutomaticQuoteSubstitutionEnabled = false
    view.isAutomaticDashSubstitutionEnabled = false
    view.delegate = context.coordinator
    view.autoresizingMask = [.width]
    view.textContainer?.widthTracksTextView = true
    scroll.documentView = view
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    let timing = ContinuousClock.now
    defer { PerformanceAcceptance.component("commit-editor", start: timing) }
    context.coordinator.parent = self
    guard let view = scroll.documentView as? CommitTextView else { return }
    if view.string != text { view.string = text }
    let background = scheme == .dark ? NSColor(hex: 0x191B1F) : NSColor(hex: 0xFAFBFC)
    if view.backgroundColor != background { view.backgroundColor = background }
    if view.textColor != .labelColor { view.textColor = .labelColor }
    if view.insertionPointColor != .labelColor { view.insertionPointColor = .labelColor }
    view.commit = commit
  }
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: CommitEditor
    init(_ parent: CommitEditor) { self.parent = parent }
    func textDidChange(_ notification: Notification) {
      if let view = notification.object as? NSTextView { parent.text = view.string }
    }
  }
}

struct PushUpstreamSheet: View {
  @ObservedObject var model: RepositoryModel
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @State private var remote = ""
  @State private var branch = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(store.text("Push & Set Upstream", "推送并设置 Upstream")).font(.title2)
      Picker(localizedUI("Remote"), selection: $remote) {
        ForEach(model.remotes) { Text($0.name).tag($0.name) }
      }
      TextField(store.text("Remote branch", "远程分支"), text: $branch)
      Text(
        store.text(
          "Pushes the existing local commit and sets its upstream. It does not create another commit.",
          "推送已有本地提交并设置 Upstream，不会重复创建提交。 ")
      ).font(.callout).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button(store.text("Cancel", "取消")) { dismiss() }
        Button(store.text("Push", "推送")) {
          model.network("push", remote: remote, branch: branch)
          dismiss()
        }.buttonStyle(.borderedProminent).disabled(remote.isEmpty || branch.isEmpty || model.busy)
      }
    }.padding(24).frame(width: 480).onAppear {
      remote = model.remotes.first?.name ?? ""
      branch = model.status.branch
    }
  }
}

extension Notification.Name {
  static let gitpierFileHistory = Notification.Name("GitPier.fileHistory")
  static let gitpierSearch = Notification.Name("GitPier.search")
  static let gitpierRevealSelected = Notification.Name("GitPier.revealSelected")
}

struct ScrollMemory: NSViewRepresentable {
  var key: String
  var containsNestedScrollViews = true
  static var positions: [String: NSPoint] = [:]
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { context.coordinator.attach(view, key: key, containsNestedScrollViews: containsNestedScrollViews) }
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    if context.coordinator.key != key || context.coordinator.containsNestedScrollViews != containsNestedScrollViews {
      DispatchQueue.main.async { context.coordinator.attach(view, key: key, containsNestedScrollViews: containsNestedScrollViews) }
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  @MainActor final class Coordinator {
    nonisolated(unsafe) var observer: NSObjectProtocol?
    weak var scroll: NSScrollView?
    var key = ""
    var containsNestedScrollViews = true
    func attach(_ view: NSView, key: String, containsNestedScrollViews: Bool) {
      guard let scroll = view.enclosingScrollView else { return }
      let overlay = OverlayScrollbars.install(on: scroll)
      overlay.leafDocumentMarker = containsNestedScrollViews ? nil : view
      self.containsNestedScrollViews = containsNestedScrollViews
      if self.scroll === scroll && self.key == key { return }
      if let observer {
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
      }
      self.scroll = scroll
      self.key = key
      if let point = ScrollMemory.positions[key] {
        scroll.contentView.scroll(to: point)
        scroll.reflectScrolledClipView(scroll.contentView)
      }
      scroll.contentView.postsBoundsChangedNotifications = true
      observer = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, let scroll = self.scroll else { return }
          ScrollMemory.positions[self.key] = scroll.contentView.bounds.origin
        }
      }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
  }
}
