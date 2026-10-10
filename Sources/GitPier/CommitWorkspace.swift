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
  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      if let operation = model.status.operation {
        HStack(spacing: 10) {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
          Text(operation.rawValue.capitalized + store.text(" in progress", " 进行中"))
          Spacer()
          Button(store.text("Continue", "继续")) {
            model.perform([command(operation), "--continue"])
          }
          Button(store.text("Abort…", "中止…")) {
            model.perform(
              [command(operation), "--abort"],
              confirmation: store.text(
                "Abort the operation and restore its starting state?", "中止操作并恢复起始状态？"))
          }
        }.font(uiFont(size: 12)).padding(10).background(Color.orange.opacity(0.09))
        Divider()
      }
      if let output = model.output {
        HStack(alignment: .center, spacing: 10) {
          Image(systemName: "checkmark.circle").font(.system(size: 14)).foregroundStyle(.mint)
            .frame(width: 20, height: 20)
          Text(output.trimmingCharacters(in: .whitespacesAndNewlines)).font(uiFont(size: 11))
            .lineLimit(3).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          Spacer()
          if model.pushFailed { Button(store.text("Retry Push", "重试推送")) { model.network("push") } }
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
    .alert(
      model.confirmation?.title ?? "",
      isPresented: Binding(
        get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } })
    ) {
      Button(store.text("Confirm", "确认"), role: .destructive) {
        let action = model.confirmation?.action
        model.confirmation = nil
        action?()
      }
      Button(store.text("Cancel", "取消"), role: .cancel) { model.confirmation = nil }
    } message: {
      Text(model.confirmation?.detail ?? "")
    }
    .task { await model.activate() }
    .background {
      if PerformanceAcceptance.enabled {
        PerformancePageProbe(page: model.record.page, repositoryID: model.record.id)
      }
    }
  }
  @ViewBuilder func pageContent(height: Double) -> some View {
    switch model.record.page {
    case "history": HistoryView(model: model)
    case "branches": BranchesView(model: model)
    case "remotes": RemotesView(model: model)
    case "stash": StashView(model: model)
    case "tags": TagsView(model: model)
    case "repository": RepositorySettingsView(model: model)
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
  var toolbar: some View {
    HStack(spacing: 14) {
      Menu {
        ForEach(model.branches.filter { !$0.remote }) { branch in
          Button((branch.current ? "✓ " : "") + branch.name) {
            model.run { git in try await git.switchBranch(branch.name) }
          }
        }
        Divider()
        Button(store.text("Manage Branches…", "管理分支…")) { model.setPage("branches") }
      } label: {
        Label(
          model.status.branch.isEmpty ? store.text("Repository", "仓库") : model.status.branch,
          systemImage: "arrow.triangle.branch"
        ).font(uiFont(size: 12, weight: .medium))
      }.menuStyle(.borderlessButton).frame(maxWidth: 190)
      Divider().frame(height: 18)
      ForEach(
        [("commit", "Commit", "提交"), ("history", "History", "历史"), ("branches", "Branches", "分支")],
        id: \.0
      ) { page in
        Button {
          model.setPage(page.0)
        } label: {
          Text(store.text(page.1, page.2)).font(
            .system(size: 12, weight: model.record.page == page.0 ? .semibold : .regular)
          ).foregroundStyle(model.record.page == page.0 ? Color.accentColor : Color.secondary)
        }.buttonStyle(.workspace)
      }
      Menu {
        Button(store.text("Remotes", "远程")) { model.setPage("remotes") }
        Button(localizedUI("Stash")) { model.setPage("stash") }
        Button(store.text("Tags", "标签")) { model.setPage("tags") }
        Divider()
        Button(store.text("Repository Settings", "仓库设置")) { model.setPage("repository") }
      } label: {
        Image(systemName: "ellipsis")
      }.menuStyle(.borderlessButton).frame(width: 22)
      Spacer(minLength: 5)
      HStack(spacing: 14) {
        Button {
          model.network("fetch")
        } label: {
          Label(store.text("Fetch", "获取"), systemImage: "arrow.down.to.line")
        }
        Button {
          model.network("pull")
        } label: {
          Label(store.text("Pull", "拉取"), systemImage: "arrow.down")
        }
        Button {
          if model.status.upstream == nil {
            model.needsUpstream = true
          } else {
            model.network("push")
          }
        } label: {
          Label(store.text("Push", "推送"), systemImage: "arrow.up")
        }
      }.font(uiFont(size: 11)).buttonStyle(.plain).disabled(model.busy || !model.available)
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
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              let tracked = model.filteredFiles.filter { !$0.isUntracked }
              let untracked = model.filteredFiles.filter(\.isUntracked)
              fileGroup(
                title: store.text("Tracked Files", "已跟踪文件"), files: tracked,
                expanded: $panels.trackedExpanded)
              if panels.trackedExpanded {
                ForEach(entries(tracked)) { entry in
                  if let file = entry.file {
                    fileRow(file, depth: entry.depth)
                  } else {
                    directoryRow(entry)
                  }
                }
              }
              fileGroup(
                title: store.text("Untracked Files", "未跟踪文件"), files: untracked,
                expanded: $panels.untrackedExpanded)
              if panels.untrackedExpanded {
                ForEach(entries(untracked)) { entry in
                  if let file = entry.file {
                    fileRow(file, depth: entry.depth)
                  } else {
                    directoryRow(entry)
                  }
                }
              }
              if model.status.files.isEmpty {
                Text(store.text("Working tree is clean", "工作区干净")).font(uiFont(size: 11))
                  .foregroundStyle(.secondary).padding(18)
              }
            }.padding(.vertical, 6).background(
              ScrollMemory(key: "files-" + model.record.id.uuidString))
          }.onReceive(NotificationCenter.default.publisher(for: .gitpierRevealSelected)) { event in
            guard event.object == nil || event.object as? UUID == model.record.id else { return }
            if let path = model.selectedPath {
              panels.trackedExpanded = true
              panels.untrackedExpanded = true
              model.expandedDirectories.formUnion(parents(path))
              proxy.scrollTo(path, anchor: .center)
            }
          }.onMoveCommand { direction in
            let files = model.filteredFiles
            guard !files.isEmpty else { return }
            let index = files.firstIndex { $0.path == model.selectedPath } ?? 0
            let next =
              direction == .down
              ? min(files.count - 1, index + 1) : direction == .up ? max(0, index - 1) : index
            model.select(files[next])
            proxy.scrollTo(files[next].path)
          }.focusable().focusEffectDisabled()
        }.frame(maxHeight: .infinity)
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
    }.background(Theme.editor(scheme)).onReceive(
      NotificationCenter.default.publisher(for: .gitpierSearch)
    ) { event in if event.object == nil { searchFocused = true } }
  }
  var selectedChanges: [FileChange] {
    model.status.files.filter { model.selectedPaths.contains($0.path) }
  }
  @ViewBuilder func fileGroup(title: String, files: [FileChange], expanded: Binding<Bool>)
    -> some View
  {
    let all = !files.isEmpty && files.allSatisfy { model.includedPaths.contains($0.path) }
    let mixed = files.contains { model.includedPaths.contains($0.path) } && !all
    HStack(spacing: 7) {
      Button {
        expanded.wrappedValue.toggle()
      } label: {
        Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right").font(
          .system(size: 9)
        ).frame(width: 12)
      }.buttonStyle(.workspace)
      StagingCheckbox(
        state: all ? .on : mixed ? .mixed : .off, enabled: !model.busy && !files.isEmpty
      ) { model.toggleIncluded(files) }.frame(width: 14, height: 16)
      Text(title).font(uiFont(size: 11, weight: .semibold))
      Text(localizedUI("\(files.count)")).font(uiFont(size: 11)).foregroundStyle(.secondary)
      Spacer()
    }.padding(.horizontal, 10).frame(height: 28)
  }
  func directoryRow(_ entry: TreeEntry) -> some View {
    Button {
      if model.expandedDirectories.contains(entry.id) {
        model.expandedDirectories.remove(entry.id)
      } else {
        model.expandedDirectories.insert(entry.id)
      }
    } label: {
      HStack(spacing: 6) {
        Image(
          systemName: model.expandedDirectories.contains(entry.id)
            ? "chevron.down" : "chevron.right"
        ).font(uiFont(size: 8))
        Image(systemName: "folder").foregroundStyle(.secondary)
        Text(URL(fileURLWithPath: entry.id).lastPathComponent).font(uiFont(size: 11))
        Spacer()
      }.padding(.leading, 35 + CGFloat(entry.depth) * 13).frame(height: 23)
    }.buttonStyle(.workspace)
  }
  func fileRow(_ file: FileChange, depth: Int) -> some View {
    HStack(spacing: 7) {
      StagingCheckbox(
        state: model.includedPaths.contains(file.path) ? .on : .off,
        enabled: !model.busy && model.available && !file.isConflicted
      ) { model.toggleIncluded([file]) }.frame(width: 14, height: 16)
        .help(
          file.isPartial
            ? store.text(
              "Commit the staged portion. Use Stage to include the remaining edits.",
              "提交已暂存部分；使用“暂存”操作可包含其余修改。")
            : store.text("Include in commit; does not stage this file.", "选入提交，不会立即暂存文件。"))
      HStack(spacing: 7) {
        Image(
          systemName: file.isConflicted
            ? "exclamationmark.triangle.fill"
            : file.submodule.hasPrefix("S")
              ? "shippingbox" : file.kind == .deleted ? "doc.badge.minus" : "doc.text"
        ).font(uiFont(size: 11)).foregroundStyle(
          store.settings.coloredFileIcons ? changeColor(file) : .secondary)
        Text(URL(fileURLWithPath: file.path).lastPathComponent).font(uiFont(size: 11))
          .foregroundStyle(changeColor(file)).lineLimit(1).layoutPriority(1)
        if !model.treeMode {
          Text(
            URL(fileURLWithPath: file.path).deletingLastPathComponent().path == "/"
              ? "" : (file.path as NSString).deletingLastPathComponent
          ).font(uiFont(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
        }
        Spacer(minLength: 0)
        if file.isPartial {
          Text(localizedUI("±")).font(uiFont(size: 10, weight: .semibold)).foregroundStyle(.orange)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay {
          ImmediateFileClick(
            path: file.path, selected: model.selectedPaths.contains(file.path),
            action: { count, modifiers in
              if count > 1 {
                if model.selectedPath != file.path { model.select(file) }
                model.promoteTab(file.path)
              } else {
                model.select(
                  file, extend: modifiers.contains(.shift), toggle: modifiers.contains(.command))
              }
            }, move: { delta, modifiers in moveFileSelection(delta, modifiers: modifiers) })
        }
    }.padding(.leading, 32 + CGFloat(depth) * 13).padding(.trailing, 10).frame(
      height: store.settings.compactUI ? 24 : 30
    )
    .background(
      model.selectedPaths.contains(file.path) ? Color.accentColor.opacity(0.18) : Color.clear
    ).background {
      ImmediateFileContext { model.select(file) }
    }.contentShape(Rectangle())
    .contextMenu { fileMenu(file) }.help(
      file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
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
  @ViewBuilder func fileMenu(_ file: FileChange) -> some View {
    Button(store.text("View Diff", "查看 Diff")) { model.select(file, permanent: true) }
    Button(store.text("Stage", "暂存")) { model.stageGroup(selected(file), unstage: false) }
    Button(store.text("Unstage", "取消暂存")) { model.stageGroup(selected(file), unstage: true) }
      .disabled(!selected(file).contains(where: \.isStaged))
    Button(store.text("Discard Changes…", "丢弃修改…"), role: .destructive) { model.discard(file) }
      .disabled(!file.isUnstaged)
    Divider()
    Button(store.text("Open in Editor", "在编辑器中打开")) { model.openEditor(file.path) }
    Button(store.text("Reveal in Finder", "在 Finder 中显示")) { model.reveal(file.path) }
    Button(store.text("Copy Path", "复制路径")) { copyText(file.path) }
    Button(store.text("File History", "文件历史")) {
      model.setPage("history")
      model.historyPath = file.path
      Task { await model.loadHistory(reset: true, path: file.path) }
    }
    Button(store.text("Add to .gitignore", "添加至 .gitignore")) {
      model.run { git in try await git.ignore(file.path) }
    }.disabled(!file.isUntracked)
    if file.isUntracked {
      Button(store.text("Ignore Locally (.git/info/exclude)", "添加到本地忽略 (.git/info/exclude)")) {
        model.run(label: store.text("Ignoring locally", "添加本地忽略")) { git in
          try await git.excludeLocally(file.path)
        }
      }.disabled(model.busy || !model.available)
    }
  }
  var messagePanel: some View {
    VStack(spacing: 0) {
      HStack(spacing: 7) {
        Text(store.text("Commit Message", "提交说明")).font(uiFont(size: 11, weight: .semibold))
        Spacer()
        Toggle(localizedUI("Amend"), isOn: $model.amend).toggleStyle(.checkbox).font(
          uiFont(size: 10)
        ).help(
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
        Button(store.text("Commit", "提交")) { model.commit(push: false) }.buttonStyle(
          .borderedProminent)
        Button(store.text("Commit & Push…", "提交并推送…")) { model.commit(push: true) }
        Spacer()
      }.controlSize(.small).disabled(!model.canCommit).padding(10)
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
  var action: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator(action) }
  func makeNSView(context: Context) -> NSButton {
    let button = NSButton(
      checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.click))
    button.allowsMixedState = true
    button.controlSize = .small
    button.setAccessibilityLabel("Include changes in commit")
    return button
  }
  func updateNSView(_ button: NSButton, context: Context) {
    button.state = state
    button.isEnabled = enabled
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
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
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
  static var positions: [String: NSPoint] = [:]
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { context.coordinator.attach(view, key: key) }
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    if context.coordinator.key != key {
      DispatchQueue.main.async { context.coordinator.attach(view, key: key) }
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  @MainActor final class Coordinator {
    nonisolated(unsafe) var observer: NSObjectProtocol?
    weak var scroll: NSScrollView?
    var key = ""
    func attach(_ view: NSView, key: String) {
      guard let scroll = view.enclosingScrollView else { return }
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
