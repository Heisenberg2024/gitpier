import AppKit
import GitPierCore
import SwiftUI

struct DiffPanel: View {
  @ObservedObject var model: RepositoryModel
  @EnvironmentObject var store: AppStore
  @Environment(\.colorScheme) var scheme
  @State private var showSlowLoad = false
  @State private var blame: BlameRequest?
  @State private var patchExport: PatchExportRequest?
  @State private var lineSelectionKey = ""
  @State private var selectedLineIDs: Set<Int> = []
  @State private var lineSupportRevision: UUID?
  @State private var lineSupport = false
  var currentLineKey: String {
    model.record.id.uuidString + (model.selectedPath ?? "") + model.comparison.rawValue
      + model.diff.revision.uuidString + (model.snapshot?.identity ?? "") + String(store.settings.ignoreWhitespace)
  }
  var activeLines: Set<Int> { lineSelectionKey == currentLineKey ? selectedLineIDs : [] }
  var lineActionsAvailable: Bool {
    !model.busy && !model.refreshing && !model.diffLoading && !store.settings.ignoreWhitespace && model.selectedFile?.kind == .modified
      && model.selectedFile?.submodule == "N..." && model.snapshot != nil
      && lineSupportRevision == model.diff.revision && lineSupport
  }
  var body: some View {
    VStack(spacing: 0) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 0) {
          ForEach(model.tabs) { tab in
            HStack(spacing: 8) {
              Image(systemName: "arrow.left.arrow.right").font(uiFont(size: 10)).foregroundStyle(
                .secondary)
              Text(URL(fileURLWithPath: tab.path).lastPathComponent).font(
                .system(size: 11, weight: .medium)
              ).italic(tab.preview)
              if tab.pinned {
                Image(systemName: "pin.fill").font(uiFont(size: 8)).foregroundStyle(.secondary)
              }
              Button {
                model.closeTab(tab.path)
              } label: {
                Image(systemName: "xmark").font(uiFont(size: 9))
              }.buttonStyle(.workspace).foregroundStyle(.secondary)
            }.padding(.horizontal, 13).frame(height: 34)
              .background(
                model.selectedPath == tab.path
                  ? Color.accentColor.opacity(0.14) : Theme.panel(scheme)
              )
              .overlay(alignment: .bottom) {
                if model.selectedPath == tab.path {
                  Rectangle().fill(Color.accentColor).frame(height: 2)
                }
              }
              .onTapGesture {
                model.activateTab(tab.path)
              }
              .contextMenu {
                Button(
                  store.text(tab.pinned ? "Unpin Tab" : "Pin Tab", tab.pinned ? "取消固定标签" : "固定标签")
                ) {
                  if let i = model.tabs.firstIndex(where: { $0.id == tab.id }) {
                    model.tabs[i].pinned.toggle()
                    model.tabs[i].preview = false
                  }
                }
                Button(store.text("Close Tab", "关闭标签")) { model.closeTab(tab.path) }
                Button(store.text("Close Other Tabs", "关闭其他标签")) {
                  model.tabs.removeAll { !$0.pinned && $0.path != tab.path }
                }
              }
          }
        }
      }.frame(height: 34).background(Theme.panel(scheme))
      Divider()
      HStack(spacing: 8) {
        IconButton("arrow.up", help: store.text("Previous difference", "上一处差异")) {
          model.selectedHunk = max(0, model.selectedHunk - 1)
        }.disabled(model.diff.hunks.isEmpty)
        IconButton("arrow.down", help: store.text("Next difference", "下一处差异")) {
          model.selectedHunk = min(max(0, model.diff.hunks.count - 1), model.selectedHunk + 1)
        }.disabled(model.diff.hunks.isEmpty)
        Divider().frame(height: 17)
        Picker(localizedUI("Compare"), selection: $model.comparison) {
          Text(store.text("Unstaged", "未暂存")).tag(DiffComparison.unstaged)
          Text(store.text("Staged", "已暂存")).tag(DiffComparison.staged)
        }.pickerStyle(.segmented).frame(width: 160).onChange(of: model.comparison) {
          model.loadDiff()
        }
        Spacer(minLength: 0)
        Text(store.text("\(model.diff.hunks.count) differences", "\(model.diff.hunks.count) 处差异"))
          .font(uiFont(size: 10)).foregroundStyle(.secondary)
        Menu {
          Toggle(store.text("Unified Diff", "统一 Diff"), isOn: setting(\.unifiedDiff))
          Toggle(store.text("Wrap Lines", "自动换行"), isOn: setting(\.wrapDiff))
          Toggle(store.text("Line Numbers", "行号"), isOn: setting(\.showLineNumbers))
          Toggle(store.text("Show Whitespace", "显示空白"), isOn: setting(\.showWhitespace))
          Toggle(store.text("Ignore Whitespace", "忽略空白差异"), isOn: setting(\.ignoreWhitespace))
          Divider()
          EditorLaunchMenu(model: model, path: model.selectedPath)
        } label: {
          Image(systemName: "gearshape")
        }.menuStyle(.borderlessButton).frame(width: 22)
      }.padding(.horizontal, 10).frame(height: 35).background(Theme.panel(scheme))
      Divider()
      if let path = model.selectedPath {
        HStack {
          Image(systemName: "doc.text").foregroundStyle(.secondary)
          Text(path).lineLimit(1).truncationMode(.middle)
          Button(store.text("Blame", "逐行溯源")) { blame = BlameRequest(path: path) }
          Menu {
            if let file = model.selectedFile {
              Button(store.text("Export File Patch…", "导出文件补丁…")) { patchExport = PatchExportRequest(source: .file(file, model.comparison)) }
            }
            if lineActionsAvailable, !model.diff.hunks.isEmpty {
              let hunk = model.diff.hunks[min(model.selectedHunk, model.diff.hunks.count - 1)]
              Button(store.text("Export Hunk Patch…", "导出差异块补丁…")) {
                let ids = Set(hunk.lines.filter { $0.kind == .addition || $0.kind == .deletion }.map(\.id))
                patchExport = PatchExportRequest(source: .selected(model.diff, ids, path))
              }
              Button(store.text("Export Selected Lines…", "导出选中行补丁…")) {
                patchExport = PatchExportRequest(source: .selected(model.diff, activeLines, path))
              }.disabled(activeLines.isEmpty)
            }
          } label: { Image(systemName: "square.and.arrow.up") }.menuStyle(.borderlessButton).frame(width: 22)
            .help(store.text("Export Patch", "导出补丁"))
          Spacer()
          if model.selectedFile?.submodule.hasPrefix("S") == true { Badge(text: "Submodule") }
        }.font(uiFont(size: 10)).padding(.horizontal, 12).frame(height: 27)
        Divider()
        if model.selectedFile?.isConflicted == true {
          VStack(spacing: 16) {
            EmptyState(
              symbol: "exclamationmark.triangle",
              title: store.text("Unresolved conflict", "尚未解决的冲突"),
              detail: store.text(
                "Compare Current and Incoming, edit the result, then save and mark the file resolved.",
                "对照当前版本和传入版本，编辑结果，再保存并标记此文件已解决。"))
            Button(store.text("Resolve Conflict…", "解决冲突…")) { model.openConflicts(path) }
              .buttonStyle(.borderedProminent)
          }
        } else if let error = model.diffError {
          EmptyState(
            symbol: "doc.text.magnifyingglass",
            title: store.text("Unable to load Diff", "无法加载 Diff"), detail: error)
        } else if model.diff.binary {
          BinaryDiffView(model: model)
        } else if model.diff.pairs.count > 20000 || model.diff.raw.utf8.count > 2 * 1024 * 1024 {
          EmptyState(
            symbol: "doc.text", title: store.text("Large Diff", "大型 Diff"),
            detail: store.text(
              "This diff exceeds 20,000 rows. Open it in your editor to keep the workspace responsive.",
              "此 Diff 超过 20,000 行，请在编辑器中查看。"))
        } else {
          ZStack {
            let selectionKey = currentLineKey
            DiffTable(
              document: model.diff, path: path,
              key: model.record.id.uuidString + path + model.comparison.rawValue,
              settings: store.settings, dark: scheme == .dark, selectedHunk: model.selectedHunk,
              indexSide: model.comparison == .staged ? 1 : 0,
              afterOnly: model.comparison == .unstaged && !model.diff.hunks.isEmpty
                && !model.diff.hasOldContent,
              beforeTitle: model.comparison == .staged ? "HEAD" : "Index",
              afterTitle: model.comparison == .staged ? "Index" : store.text("Working Tree", "工作区"),
              selectionKey: selectionKey, allowsLineSelection: lineActionsAvailable,
              selectedLineIDs: activeLines,
              onLineSelection: lineActionsAvailable ? { ids in
                guard selectionKey == currentLineKey, lineActionsAvailable else { return }
                lineSelectionKey = selectionKey; selectedLineIDs = ids
              } : nil,
              lineActionTitle: store.text(model.comparison == .staged ? "Unstage Selected Lines" : "Stage Selected Lines",
                                         model.comparison == .staged ? "取消暂存选中行" : "暂存选中行"),
              onLineAction: lineActionsAvailable ? { ids in
                guard selectionKey == currentLineKey else { return }; applyLines(ids)
              } : nil
            )
            .equatable()
            if !model.diffLoading && model.diff.hunks.isEmpty {
              EmptyState(
                symbol: "checkmark", title: store.text("No text changes", "没有文本变更"),
                detail: model.diff.raw.isEmpty
                  ? store.text(
                    "Switch comparison to inspect the other side of the Index.",
                    "切换对比方式以查看 Index 另一侧的修改。") : model.diff.raw)
            }
            if model.diffLoading && showSlowLoad {
              VStack {
                HStack {
                  Spacer()
                  ProgressView().controlSize(.small).padding(12)
                }
                Spacer()
              }
            }
          }
          Divider()
          HStack(spacing: 8) {
            Text(store.text("Select changed lines in the gutter · ⇧ range · ⌘ toggle", "在行号区选择修改行 · ⇧ 连选 · ⌘ 多选"))
              .foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if !activeLines.isEmpty {
              Text(store.text("\(activeLines.count) selected", "已选 \(activeLines.count) 行"))
              Button(store.text("Clear", "清除")) { selectedLineIDs = [] }
            }
            Button(store.text(model.comparison == .staged ? "Unstage Selected Lines" : "Stage Selected Lines",
                              model.comparison == .staged ? "取消暂存选中行" : "暂存选中行")) { applyLines(activeLines) }
              .disabled(!lineActionsAvailable || activeLines.isEmpty)
              .accessibilityIdentifier("diff.selected-lines")
          }.font(uiFont(size: 10)).controlSize(.small).padding(.horizontal, 10).frame(height: 32)
            .help(store.text("Code text still supports normal copying. Unsupported file types use file or hunk actions; no whole-file fallback runs.",
                             "代码文本仍可正常复制。不支持的文件类型请使用文件级或差异块操作，不会自动改为整文件暂存。"))
          Divider()
          hunkToolbar
        }
      } else {
        EmptyState(
          symbol: "arrow.left.arrow.right", title: store.text("Review your changes", "审查你的修改"),
          detail: store.text(
            "Select a file to preview its diff. Double-click to keep it open in a tab.",
            "单击文件预览 Diff，双击保留为标签。"))
      }
    }.sheet(item: $blame) { BlameView(model: model, request: $0).environmentObject(store) }
    .sheet(item: $patchExport) { PatchExportView(model: model, source: $0.source).environmentObject(store) }
    .background(Theme.editor(scheme))
      .onChange(of: model.selectedPath) { _, _ in clearLineSelection() }
      .onChange(of: model.comparison) { _, _ in clearLineSelection() }
      .onChange(of: model.refreshing) { _, refreshing in if refreshing { clearLineSelection() } }
      .onChange(of: model.diff.revision) { _, _ in clearLineSelection() }
      .task(id: model.diff.revision) {
        let document = model.diff
        let supported = await Task.detached(priority: .userInitiated) { SelectivePatch.supported(document) }.value
        guard !Task.isCancelled, model.diff.revision == document.revision else { return }
        lineSupport = supported; lineSupportRevision = document.revision
      }
      .task(id: model.diffLoading) {
        showSlowLoad = false
        guard model.diffLoading else { return }
        do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
        if model.diffLoading { showSlowLoad = true }
      }
  }
  func clearLineSelection() { lineSelectionKey = ""; selectedLineIDs = [] }
  func applyLines(_ ids: Set<Int>) {
    guard lineActionsAvailable, let file = model.selectedFile, let index = model.snapshot else { return }
    model.applySelectedLines(ids, document: model.diff, file: file, comparison: model.comparison, index: index)
  }
  var hunkToolbar: some View {
    HStack(spacing: 10) {
      if !model.diff.hunks.isEmpty {
        let hunk = model.diff.hunks[min(model.selectedHunk, model.diff.hunks.count - 1)]
        Menu {
          ForEach(model.diff.hunks) { item in
            Button("\(item.id + 1)  " + item.header) { model.selectedHunk = item.id }
          }
        } label: {
          Text(
            store.text(
              "Hunk \(hunk.id + 1) of \(model.diff.hunks.count)",
              "差异块 \(hunk.id + 1) / \(model.diff.hunks.count)"))
        }.menuStyle(.borderlessButton).frame(maxWidth: 155)
        Text(localizedUI("+\(hunk.additions)")).foregroundStyle(.mint)
        Text(localizedUI("−\(hunk.deletions)")).foregroundStyle(.red)
        Spacer()
        Button(store.text("Copy Hunk", "复制差异块")) {
          copyText(String(decoding: hunk.patch, as: UTF8.self))
        }
        if model.comparison == .unstaged {
          Button(store.text("Discard Hunk…", "丢弃差异块…")) { model.applyHunk(hunk, discard: true) }
            .disabled(disableHunks)
        }
        Button(
          store.text(
            model.comparison == .staged ? "Unstage Hunk" : "Stage Hunk",
            model.comparison == .staged ? "取消暂存差异块" : "暂存差异块")
        ) { model.applyHunk(hunk) }.disabled(disableHunks)
      }
    }.font(uiFont(size: 10)).controlSize(.small).padding(.horizontal, 10).frame(height: 36)
      .background(Theme.panel(scheme))
      .help(
        disableHunks
          ? store.text(
            "Hunk actions require an exact text patch without renames, mode changes or whitespace filtering. Use file-level staging for this change.",
            "重命名、模式修改或忽略空白时请使用文件级暂存。") : "")
  }
  var disableHunks: Bool {
    model.busy || store.settings.ignoreWhitespace || model.diff.complexMetadata
      || model.selectedFile?.isConflicted == true || model.selectedFile?.isUntracked == true
  }
  func setting(_ key: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
    Binding(
      get: { store.settings[keyPath: key] },
      set: { value in
        var settings = store.settings
        settings[keyPath: key] = value
        store.updateSettings(settings)
      })
  }
}

struct BinaryDiffView: View {
  @ObservedObject var model: RepositoryModel
  @EnvironmentObject var store: AppStore
  @State private var before: Data?
  @State private var after: Data?
  @State private var problem: String?
  var body: some View {
    VStack(spacing: 18) {
      Label(store.text("Binary file", "二进制文件"), systemImage: "doc.richtext").font(.title3)
      HStack(alignment: .top, spacing: 20) {
        preview(before, title: model.comparison == .staged ? "HEAD" : "Index")
        preview(
          after, title: model.comparison == .staged ? "Index" : store.text("Working Tree", "工作区"))
      }
      if let problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
      Text(
        store.text(
          "Binary contents cannot be staged by hunk. Use the file checkbox to stage the exact file.",
          "二进制文件不能按差异块暂存，请使用文件复选框。")
      ).font(.callout).foregroundStyle(.secondary)
      EditorLaunchMenu(model: model, path: model.selectedPath)
    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
      .task(id: (model.selectedPath ?? "") + model.comparison.rawValue) {
        before = nil
        after = nil
        problem = nil
        guard let file = model.selectedFile else { return }
        do {
          let old = try await model.git().fileContents(
            file, comparison: model.comparison, after: false)
          let new = try await model.git().fileContents(
            file, comparison: model.comparison, after: true)
          try Task.checkCancellation()
          before = old
          after = new
        } catch is CancellationError {} catch { problem = error.localizedDescription }
      }
  }
  @ViewBuilder func preview(_ data: Data?, title: String) -> some View {
    VStack(spacing: 10) {
      Text(title).font(uiFont(size: 11, weight: .semibold)).foregroundStyle(.secondary)
      if let data, let image = NSImage(data: data) {
        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 340)
      } else if let data {
        Image(systemName: "doc.richtext").font(uiFont(size: 32)).foregroundStyle(.secondary)
        Text("\(data.count) bytes").font(uiFont(size: 11, design: .monospaced))
        if LFSPointer.parse(data) != nil, let text = String(data: data, encoding: .utf8)
        {
          Text(store.text("Git LFS pointer", "Git LFS 指针")).font(.caption)
          Text(text).font(uiFont(size: 10, design: .monospaced)).textSelection(.enabled)
        }
      } else {
        Text(store.text("File absent", "文件不存在")).font(.caption).foregroundStyle(.secondary)
      }
    }.padding(18).frame(maxWidth: .infinity, minHeight: 150).background(Color.primary.opacity(0.03))
  }
}

struct DiffTable: NSViewRepresentable, Equatable {
  let document: DiffDocument
  let path: String
  let key: String
  let settings: AppSettings
  let dark: Bool
  let selectedHunk: Int
  var indexSide: Int? = nil
  var afterOnly = false
  var beforeTitle = "Before"
  var afterTitle = "After"
  var selectionKey = ""
  var allowsLineSelection = false
  var selectedLineIDs: Set<Int> = []
  var onLineSelection: ((Set<Int>) -> Void)? = nil
  var lineActionTitle = "Stage Selected Lines"
  var onLineAction: ((Set<Int>) -> Void)? = nil
  // Remote review is a separate interaction; it never enables selective staging.
  var reviewKey = ""
  var onReviewLine: ((DiffLine, HostingReviewSide) -> Void)? = nil
  var reviewActionTitle = "Add Review Comment"
  var reviewLineCounts: [Int: Int] = [:]
  var reviewCountTitle = "Review comments"
  nonisolated static func == (lhs: DiffTable, rhs: DiffTable) -> Bool {
    lhs.document.revision == rhs.document.revision && lhs.path == rhs.path && lhs.key == rhs.key
      && lhs.styleIdentity == rhs.styleIdentity && lhs.dark == rhs.dark
      && lhs.selectedHunk == rhs.selectedHunk && lhs.beforeTitle == rhs.beforeTitle
      && lhs.afterTitle == rhs.afterTitle && lhs.afterOnly == rhs.afterOnly
      && lhs.indexSide == rhs.indexSide
      && lhs.selectedLineIDs == rhs.selectedLineIDs
      && lhs.selectionKey == rhs.selectionKey && lhs.allowsLineSelection == rhs.allowsLineSelection
      && lhs.lineActionTitle == rhs.lineActionTitle
      && lhs.reviewKey == rhs.reviewKey
      && lhs.reviewActionTitle == rhs.reviewActionTitle
      && lhs.reviewLineCounts == rhs.reviewLineCounts && lhs.reviewCountTitle == rhs.reviewCountTitle
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> DiffSplitContainer {
    let host = DiffSplitContainer()
    let coordinator = context.coordinator
    coordinator.host = host
    for side in 0...1 {
      let scroll = host.scrolls[side]
      let table = host.tables[side]
      table.delegate = coordinator
      table.dataSource = coordinator
      table.selectLine = { [weak coordinator] row, modifiers in coordinator?.selectChangedLine(row, side: side, modifiers: modifiers) }
      table.clearLines = { [weak coordinator] in coordinator?.clearChangedLines() }
      table.lineAction = { [weak coordinator] in coordinator?.invokeLineAction() }
      table.actionMenu = { [weak coordinator] row in coordinator?.lineMenu(row, side: side) }
      scroll.contentView.postsBoundsChangedNotifications = true
      let observer = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
      ) { [weak coordinator] _ in
        MainActor.assumeIsolated { coordinator?.didScroll(side: side) }
      }
      coordinator.observers.append(observer)
    }
    host.resized = { [weak coordinator] in coordinator?.resize() }
    return host
  }
  func updateNSView(_ host: DiffSplitContainer, context: Context) {
    let timing = ContinuousClock.now
    defer { PerformanceAcceptance.component("diff-update", start: timing) }
    host.renderedPath = path
    let c = context.coordinator
    let changed =
      c.document.revision != document.revision || c.key != key || c.dark != dark
      || c.style != styleIdentity || host.afterOnly != afterOnly
    let previousKey = c.key
    let previousRevision = c.document.revision
    let previousSelectionKey = c.selectionKey
    let previousLines = c.selectedLineIDs
    let previousReviewCounts = c.reviewLineCounts
    c.document = document
    c.path = path
    c.key = key
    c.dark = dark
    c.settings = settings
    c.style = styleIdentity
    c.selectionKey = selectionKey
    c.selectedLineIDs = selectedLineIDs
    c.onLineSelection = onLineSelection; c.onLineAction = onLineAction; c.lineActionTitle = lineActionTitle
    c.onReviewLine = onReviewLine; c.reviewActionTitle = reviewActionTitle
    c.reviewLineCounts = reviewLineCounts; c.reviewCountTitle = reviewCountTitle
    if previousKey != key || previousRevision != document.revision || previousSelectionKey != selectionKey { c.anchors = [nil, nil] }
    host.unified = settings.unifiedDiff
    host.afterOnly = afterOnly
    if changed {
      c.rows =
        settings.unifiedDiff
        ? document.hunks.flatMap { hunk in
          [
            DiffLine(
              id: -hunk.id - 1, kind: .header, text: hunk.header, oldNumber: nil, newNumber: nil)
          ] + hunk.lines
        } : []
      c.resolvedFont =
        NSFont(name: settings.diffFont, size: settings.diffFontSize)
        ?? NSFont.monospacedSystemFont(ofSize: settings.diffFontSize, weight: .regular)
      c.longestLines = (0...1).map { side in
        let strings =
          settings.unifiedDiff
          ? c.rows.map(\.text)
          : document.pairs.map { side == 0 ? $0.old?.text ?? "" : $0.new?.text ?? "" }
        return strings.map {
          $0.replacingOccurrences(
            of: "\t", with: String(repeating: " ", count: max(1, settings.tabSize))
          ).count
        }.max() ?? 0
      }
      c.lastWidths = [-1, -1]
    }
    for (side, table) in host.tables.enumerated() {
      table.gutterWidth = settings.showLineNumbers ? 46 : 18
      table.selectLine = allowsLineSelection ? { [weak c] row, modifiers in c?.selectChangedLine(row, side: side, modifiers: modifiers) } : nil
      table.lineAction = onLineAction == nil ? nil : { [weak c] in c?.invokeLineAction() }
      table.clearLines = allowsLineSelection ? { [weak c] in c?.clearChangedLines() } : nil
      table.reviewLine = onReviewLine == nil ? nil : { [weak c] row in c?.reviewLine(row, side: side) }
      table.canReviewLine = onReviewLine == nil ? nil : { [weak c] row in c?.reviewableLine(row, side: side) != nil }
      table.reviewActionTitle = reviewActionTitle
      host.scrolls[side].verticalThumbOnLeft = !settings.unifiedDiff && side == indexSide
      table.backgroundColor = NSColor(hex: dark ? 0x191B1F : 0xFAFBFC)
      table.tableColumns[0].title =
        settings.unifiedDiff ? localizedUI("Changes") : side == 0 ? beforeTitle : afterTitle
      table.tableColumns[0].headerCell.font = NSFont.systemFont(ofSize: 10, weight: .medium)
    }
    if !changed && (previousLines != selectedLineIDs || previousReviewCounts != reviewLineCounts) { c.refreshLineHighlights() }
    if changed {
      c.synchronizing = true
      host.needsLayout = true
      host.layoutSubtreeIfNeeded()
      for table in host.tables { table.reloadData() }
      host.reloadCount += 1
      c.resize()
      for side in 0...1 {
        let positionKey = key + "-side\(side)"
        if previousKey != key, let point = ScrollMemory.positions[positionKey] {
          host.scrolls[side].contentView.scroll(to: point)
          host.scrolls[side].reflectScrolledClipView(host.scrolls[side].contentView)
        }
      }
      c.synchronizing = false
    }
    if let last = c.lastHunk, last != selectedHunk, selectedHunk < document.hunks.count {
      let row =
        settings.unifiedDiff
        ? document.hunks.prefix(selectedHunk).reduce(0) { $0 + $1.lines.count + 1 }
        : document.hunks[selectedHunk].rowOffset
      for table in host.tables { table.scrollRowToVisible(row) }
    }
    c.lastHunk = selectedHunk
  }
  nonisolated private var styleIdentity: String {
    "\(settings.diffFont):\(settings.diffFontSize):\(settings.unifiedDiff):\(settings.wrapDiff):\(settings.showLineNumbers):\(settings.showWhitespace):\(settings.tabSize):\(settings.diffAddedHex):\(settings.diffRemovedHex)"
  }
  @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var host: DiffSplitContainer?
    var document = DiffDocument.empty
    var settings = AppSettings()
    var rows: [DiffLine] = []
    var path = "", key = "", style = ""
    var dark = true, synchronizing = false
    var lastHunk: Int?
    nonisolated(unsafe) var observers: [NSObjectProtocol] = []
    var resolvedFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    var font: NSFont { resolvedFont }
    var longestLines = [0, 0]
    var lastWidths: [CGFloat] = [-1, -1]
    var pendingHeightUpdate: Task<Void, Never>?
    var selectedLineIDs: Set<Int> = []
    var onLineSelection: ((Set<Int>) -> Void)?
    var onLineAction: ((Set<Int>) -> Void)?
    var lineActionTitle = "Stage Selected Lines"
    var onReviewLine: ((DiffLine, HostingReviewSide) -> Void)?
    var reviewActionTitle = "Add Review Comment"
    var reviewLineCounts: [Int: Int] = [:]
    var reviewCountTitle = "Review comments"
    var selectionKey = ""
    var anchors: [Int?] = [nil, nil]
    func changedLine(_ row: Int, side: Int) -> DiffLine? {
      guard row >= 0, row < rowCount else { return nil }
      let line = settings.unifiedDiff ? rows[row] : side == 0 ? document.pairs[row].old : document.pairs[row].new
      return line?.kind == .addition || line?.kind == .deletion ? line : nil
    }
    func selectChangedLine(_ row: Int, side: Int, modifiers: NSEvent.ModifierFlags) {
      guard onLineSelection != nil else { return }
      if modifiers.contains(.shift), let anchor = anchors[side] {
        let ids = Set((min(anchor, row)...max(anchor, row)).compactMap { changedLine($0, side: side)?.id })
        selectedLineIDs.formUnion(ids)
      } else if let line = changedLine(row, side: side) {
        if modifiers.contains(.command) {
          if !selectedLineIDs.insert(line.id).inserted { selectedLineIDs.remove(line.id) }
        } else { selectedLineIDs = [line.id] }
        anchors[side] = row
      } else if !modifiers.contains(.command) { selectedLineIDs = []; anchors[side] = row }
      onLineSelection?(selectedLineIDs); refreshLineHighlights()
    }
    func clearChangedLines() { selectedLineIDs = []; anchors = [nil, nil]; onLineSelection?([]); refreshLineHighlights() }
    @objc func invokeLineAction() { if !selectedLineIDs.isEmpty { onLineAction?(selectedLineIDs) } }
    func lineMenu(_ row: Int, side: Int) -> NSMenu? {
      if onReviewLine != nil, reviewableLine(row, side: side) != nil {
        return NativeMenuItems.menu([NativeMenuItems.action(reviewActionTitle) { [weak self] in self?.reviewLine(row, side: side) }])
      }
      guard onLineSelection != nil, onLineAction != nil else { return nil }
      if let line = changedLine(row, side: side), !selectedLineIDs.contains(line.id) {
        selectChangedLine(row, side: side, modifiers: [])
      }
      let menu = NSMenu(); menu.autoenablesItems = false
      let item = NSMenuItem(title: lineActionTitle, action: #selector(invokeLineAction), keyEquivalent: "")
      item.target = self; item.isEnabled = !selectedLineIDs.isEmpty; menu.addItem(item)
      return menu
    }
    func reviewableLine(_ row: Int, side: Int) -> (DiffLine, HostingReviewSide)? {
      guard onReviewLine != nil, row >= 0, row < rowCount, !document.binary,
        !document.complexMetadata else { return nil }
      let line = settings.unifiedDiff ? rows[row] : side == 0 ? document.pairs[row].old : document.pairs[row].new
      guard let line, line.kind == .addition || line.kind == .deletion || line.kind == .context else { return nil }
      let reviewSide: HostingReviewSide = settings.unifiedDiff ? (line.kind == .deletion ? .old : .new) : side == 0 ? .old : .new
      guard (reviewSide == .old ? line.oldNumber : line.newNumber) != nil else { return nil }
      return (line, reviewSide)
    }
    func reviewLine(_ row: Int, side: Int) {
      guard let (line, reviewSide) = reviewableLine(row, side: side) else { return }
      onReviewLine?(line, reviewSide)
    }
    func refreshLineHighlights() {
      guard let host else { return }
      for table in host.tables {
        let range = table.rows(in: table.visibleRect)
        if range.location != NSNotFound, range.length > 0 {
          table.reloadData(forRowIndexes: IndexSet(integersIn: range.location..<NSMaxRange(range)), columnIndexes: IndexSet(integer: 0))
        }
      }
    }
    var rowCount: Int { settings.unifiedDiff ? rows.count : document.pairs.count }
    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }
    func resize() {
      let timing = ContinuousClock.now
      defer { PerformanceAcceptance.component("diff-resize", start: timing) }
      guard let host else { return }
      var wrappedWidthChanged = false
      for side in 0...1 {
        let scroll = host.scrolls[side]
        guard !scroll.isHidden else { continue }
        let table = host.tables[side]
        let available = max(80, scroll.contentSize.width)
        guard abs(lastWidths[side] - available) > 0.5 else { continue }
        lastWidths[side] = available
        let width =
          settings.wrapDiff
          ? available
          : max(
            available, min(6000, CGFloat(longestLines[side]) * settings.diffFontSize * 0.65 + 70))
        if abs(table.tableColumns[0].width - width) > 0.5 { table.tableColumns[0].width = width }
        if abs(table.frame.width - width) > 0.5 { table.frame.size.width = width }
        if settings.wrapDiff && table.numberOfRows > 0 {
          wrappedWidthChanged = true
          let visible = table.rows(in: scroll.documentVisibleRect)
          if visible.location != NSNotFound, visible.length > 0 {
            table.noteHeightOfRows(
              withIndexesChanged: IndexSet(integersIn: visible.location..<NSMaxRange(visible)))
          }
        }
      }
      if wrappedWidthChanged {
        pendingHeightUpdate?.cancel()
        pendingHeightUpdate = Task { [weak self] in
          do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
          guard let self, let host = self.host, self.settings.wrapDiff else { return }
          for table in host.tables where table.numberOfRows > 0 {
            host.heightInvalidationCount += 1
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
          }
        }
      }
    }
    func didScroll(side: Int) {
      guard let host, !synchronizing else { return }
      let source = host.scrolls[side]
      let other = host.scrolls[1 - side]
      ScrollMemory.positions[key + "-side\(side)"] = source.contentView.bounds.origin
      guard !settings.unifiedDiff, !host.afterOnly,
        abs(source.contentView.bounds.origin.y - other.contentView.bounds.origin.y) > 0.5
      else { return }
      synchronizing = true
      var point = other.contentView.bounds.origin
      point.y = source.contentView.bounds.origin.y
      other.contentView.scroll(to: point)
      other.reflectScrolledClipView(other.contentView)
      ScrollMemory.positions[key + "-side\(1-side)"] = other.contentView.bounds.origin
      synchronizing = false
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
      let minimum = ceil(settings.diffFontSize * 1.65)
      guard settings.wrapDiff, row < rowCount, let host else { return minimum }
      let side = host.afterOnly && !settings.unifiedDiff ? 1 : 0
      let width = max(
        40, host.scrolls[side].contentSize.width - (settings.showLineNumbers ? 64 : 20))
      let strings =
        settings.unifiedDiff
        ? [rows[row].text]
        : [document.pairs[row].old?.text ?? "", document.pairs[row].new?.text ?? ""]
      return max(
        minimum,
        strings.map {
          ($0 as NSString).boundingRect(
            with: NSSize(width: width, height: 10000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]
          ).height + 6
        }.max() ?? minimum)
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
      -> NSView?
    {
      guard row < rowCount else { return nil }
      let side = tableView === host?.tables[1] ? 1 : 0
      let line =
        settings.unifiedDiff
        ? rows[row] : side == 0 ? document.pairs[row].old : document.pairs[row].new
      let id = NSUserInterfaceItemIdentifier("code")
      let cell = (tableView.makeView(withIdentifier: id, owner: self) as? DiffCell) ?? DiffCell()
      cell.identifier = id
      var text = (line?.text ?? "").replacingOccurrences(
        of: "\t", with: String(repeating: " ", count: max(1, min(settings.tabSize, 16))))
      if text.hasSuffix("\r") { text.removeLast() }
      if settings.showWhitespace { text = text.replacingOccurrences(of: " ", with: "·") }
      let attributed = SyntaxHighlighter.highlight(
        text, path: path, font: font, dark: dark, plain: line?.kind == .header)
      cell.code.font = font
      cell.code.textStorage?.setAttributedString(attributed)
      cell.code.textContainer?.lineBreakMode = settings.wrapDiff ? .byWordWrapping : .byClipping
      cell.code.textContainer?.maximumNumberOfLines = settings.wrapDiff ? 0 : 1
      cell.number.font = NSFont.monospacedSystemFont(
        ofSize: settings.diffFontSize - 1, weight: .regular)
      cell.number.textColor = NSColor(hex: dark ? 0x626875 : 0x9BA1AE)
      let number =
        settings.unifiedDiff
        ? line?.newNumber ?? line?.oldNumber : side == 0 ? line?.oldNumber : line?.newNumber
      cell.number.stringValue = settings.showLineNumbers ? number.map(String.init) ?? "" : ""
      let comments = line.map { reviewLineCounts[$0.id] ?? 0 } ?? 0
      cell.reviewMarker.stringValue = comments > 9 ? "9+" : String(comments)
      cell.reviewMarker.isHidden = comments == 0
      cell.reviewMarker.toolTip = "\(comments) " + reviewCountTitle
      cell.reviewMarker.setAccessibilityLabel("\(comments) " + reviewCountTitle)
      cell.gutter.constant = settings.showLineNumbers || onReviewLine != nil ? 46 : 4
      var background = NSColor(hex: dark ? 0x191B1F : 0xFAFBFC)
      if line?.kind == .addition {
        background =
          background.blended(
            withFraction: dark ? 0.24 : 0.14,
            of: NSColor(hex: UInt32(settings.diffAddedHex, radix: 16) ?? 0x55B982)) ?? background
      }
      if line?.kind == .deletion {
        background =
          background.blended(
            withFraction: dark ? 0.24 : 0.14,
            of: NSColor(hex: UInt32(settings.diffRemovedHex, radix: 16) ?? 0xCF6679)) ?? background
      }
      if line?.kind == .header { background = NSColor(hex: dark ? 0x252B36 : 0xEDF1F8) }
      if line == nil { background = NSColor(hex: dark ? 0x202228 : 0xF0F1F4) }
      if let line, selectedLineIDs.contains(line.id) {
        background = background.blended(withFraction: 0.35, of: .controlAccentColor) ?? background
      }
      cell.layer?.backgroundColor = background.cgColor
      return cell
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
  }
}

@MainActor final class DiffSplitContainer: NSView {
  var renderedPath = ""
  let scrolls = [DiffScrollView(), DiffScrollView()]
  let tables = [LineSelectableDiffTable(), LineSelectableDiffTable()]
  var unified = false { didSet { if oldValue != unified { needsLayout = true } } }
  var afterOnly = false { didSet { if oldValue != afterOnly { needsLayout = true } } }
  var resized: (() -> Void)?
  private(set) var layoutSize = CGSize.zero
  var reloadCount = 0
  var heightInvalidationCount = 0
  override init(frame: NSRect) {
    super.init(frame: frame)
    for side in 0...1 {
      let scroll = scrolls[side]
      let table = tables[side]
      table.headerView = NSTableHeaderView()
      table.intercellSpacing = .zero
      table.selectionHighlightStyle = .none
      table.columnAutoresizingStyle = .noColumnAutoresizing
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("side"))
      column.minWidth = 40
      table.addTableColumn(column)
      scroll.documentView = table
      addSubview(scroll)
    }
  }
  convenience init() { self.init(frame: .zero) }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layout() {
    let timing = ContinuousClock.now
    defer { PerformanceAcceptance.component("diff-layout", start: timing) }
    super.layout()
    if unified {
      scrolls[0].frame = bounds
      scrolls[0].isHidden = false
      scrolls[1].isHidden = true
    } else if afterOnly {
      scrolls[0].isHidden = true
      scrolls[1].isHidden = false
      scrolls[1].frame = bounds
    } else {
      let width = floor(bounds.width / 2)
      scrolls[0].frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
      scrolls[0].isHidden = false
      scrolls[1].frame = NSRect(
        x: width + 1, y: 0, width: max(0, bounds.width - width - 1), height: bounds.height)
      scrolls[1].isHidden = false
    }
    if layoutSize != bounds.size {
      layoutSize = bounds.size
      resized?()
    }
  }
}

final class DiffCell: NSTableCellView {
  let number = NSTextField(labelWithString: "")
  let reviewMarker = NSTextField(labelWithString: "")
  let code = NSTextView()
  var gutter: NSLayoutConstraint!
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    number.alignment = .right
    number.translatesAutoresizingMaskIntoConstraints = false
    reviewMarker.translatesAutoresizingMaskIntoConstraints = false
    reviewMarker.font = .systemFont(ofSize: 9, weight: .semibold)
    reviewMarker.textColor = .controlAccentColor; reviewMarker.alignment = .center; reviewMarker.isHidden = true
    code.isEditable = false
    code.isSelectable = true
    code.isRichText = true
    code.drawsBackground = false
    code.textContainerInset = .zero
    code.textContainer?.lineFragmentPadding = 0
    code.textContainer?.widthTracksTextView = true
    code.isHorizontallyResizable = false
    code.isVerticallyResizable = false
    code.isAutomaticQuoteSubstitutionEnabled = false
    code.isAutomaticDashSubstitutionEnabled = false
    code.setAccessibilityLabel("Diff code line")
    code.translatesAutoresizingMaskIntoConstraints = false
    code.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    addSubview(number)
    addSubview(reviewMarker)
    addSubview(code)
    gutter = number.widthAnchor.constraint(equalToConstant: 46)
    NSLayoutConstraint.activate([
      number.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
      reviewMarker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
      reviewMarker.widthAnchor.constraint(equalToConstant: 17), reviewMarker.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      number.topAnchor.constraint(equalTo: topAnchor, constant: 3), gutter,
      code.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 10),
      code.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
      code.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      code.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
    ])
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

enum SyntaxHighlighter {
  static let supported: Set<String> = [
    "ts", "tsx", "js", "jsx", "json", "yml", "yaml", "swift", "py", "go", "java", "kt", "kts",
    "html", "css", "scss", "sh", "bash", "zsh", "fish", "sql", "md", "markdown",
  ]
  static let patterns: [(NSRegularExpression, UInt32, UInt32)] = [
    (
      #"\b(?:import|from|export|default|const|let|var|func|function|class|struct|enum|protocol|public|private|static|return|if|else|switch|case|for|while|break|continue|try|catch|throw|async|await|def|lambda|package|interface|type|new|extends|implements|SELECT|FROM|WHERE|JOIN|INSERT|UPDATE|DELETE|CREATE|TABLE)\b"#,
      0xD79875, 0xA33B14
    ),
    (
      #"\b(?:true|false|null|nil|None|True|False|self|this)\b|\b\d+(?:\.\d+)?\b"#, 0xB79BDB,
      0x7749A4
    ),
    (#"\b[A-Za-z_$][\w$]*(?=\s*\()"#, 0x74ACF8, 0x176AC4),
    (#"\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`"#, 0x91BC84, 0x377538),
    (#"//.*$|#.*$|/\*.*?\*/|<!--.*?-->"#, 0x747B88, 0x7D8492),
  ].compactMap { (pattern, dark, light) in
    (try? NSRegularExpression(pattern: pattern)).map { ($0, dark, light) }
  }
  static func highlight(_ text: String, path: String, font: NSFont, dark: Bool, plain: Bool = false)
    -> NSAttributedString
  {
    let result = NSMutableAttributedString(
      string: text,
      attributes: [.font: font, .foregroundColor: NSColor(hex: dark ? 0xD3D8E1 : 0x333A46)])
    guard !plain, supported.contains((path as NSString).pathExtension.lowercased()),
      text.utf16.count < 10000
    else { return result }
    let range = NSRange(location: 0, length: text.utf16.count)
    for (regex, darkColor, lightColor) in patterns {
      for match in regex.matches(in: text, range: range) {
        result.addAttribute(
          .foregroundColor, value: NSColor(hex: dark ? darkColor : lightColor), range: match.range)
      }
    }
    return result
  }
}
