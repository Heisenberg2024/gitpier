import AppKit
import GitPierCore
import SwiftUI

enum ConflictSelection: Equatable { case edited, ours, theirs, delete }

@MainActor final class ConflictEditorModel: ObservableObject {
  unowned let repository: RepositoryModel
  @Published private(set) var path: String?
  @Published private(set) var snapshot: ConflictSnapshot?
  @Published var result = ""
  @Published private(set) var selection = ConflictSelection.edited
  @Published private(set) var loading = false
  @Published private(set) var stale = false
  @Published private(set) var error: String?
  @Published var blockIndex = 0
  @Published var focusRequest = 0
  @Published var showBase = false
  private struct Draft {
    let snapshot: ConflictSnapshot
    let text: String
    let selection: ConflictSelection
  }
  private var drafts: [String: Draft] = [:]
  private var generation = 0
  private var task: Task<Void, Never>?
  private var parsedText: String?
  private var parsedSize = 7
  private var parsedBlocks: [ConflictBlock] = []
  private var parsedMarkers = false
  init(repository: RepositoryModel) { self.repository = repository }
  private func updateParseCache() {
    let size = snapshot?.markerSize ?? 7
    guard parsedText != result || parsedSize != size else { return }
    parsedText = result
    parsedSize = size
    parsedBlocks = ConflictMarkers.blocks(result, size: size)
    parsedMarkers = ConflictMarkers.containsMarkers(result, size: size)
  }
  var blocks: [ConflictBlock] {
    updateParseCache()
    return parsedBlocks
  }
  var hasMarkers: Bool {
    updateParseCache()
    return parsedMarkers
  }
  var unsavedPaths: [String] {
    var changed = Set(
      drafts.compactMap { path, draft in
        draft.selection != .edited || draft.text != (draft.snapshot.resultText ?? "") ? path : nil
      })
    if let snapshot, selection != .edited || result != (snapshot.resultText ?? "") {
      changed.insert(snapshot.path)
    }
    return changed.sorted()
  }
  var canSave: Bool {
    guard let snapshot, !loading, !stale, snapshot.supportsVersions,
      snapshot.working.kind != .other
    else { return false }
    return selection != .edited
      || (snapshot.resultText != nil
        && result.utf8.count <= ConflictSnapshot.textLimit && !result.utf8.contains(0)
        && !hasMarkers)
  }
  private func remember() {
    if let snapshot {
      if selection != .edited || result != (snapshot.resultText ?? "") {
        drafts[snapshot.path] = Draft(snapshot: snapshot, text: result, selection: selection)
      } else {
        drafts.removeValue(forKey: snapshot.path)
      }
    }
  }
  func select(_ path: String?, force: Bool = false, refresh: Bool = false) {
    if !force, !refresh, self.path == path, snapshot != nil || loading { return }
    remember()
    task?.cancel()
    generation += 1
    let ticket = generation
    self.path = path
    error = nil
    stale = false
    if force, let path { drafts.removeValue(forKey: path) }
    guard let path else {
      snapshot = nil
      result = ""
      loading = false
      return
    }
    loading = true
    if self.snapshot?.path != path {
      snapshot = nil
      result = ""
    }
    task = Task { [weak self] in
      guard let self, ticket == generation, !Task.isCancelled else { return }
      do {
        let fresh = try await repository.git().conflictSnapshot(path)
        guard ticket == generation else { return }
        if let draft = drafts[path] {
          snapshot = draft.snapshot
          result = draft.text
          selection = draft.selection
          if fresh.indexEntries != draft.snapshot.indexEntries
            || fresh.working != draft.snapshot.working
            || fresh.head != draft.snapshot.head || fresh.branch != draft.snapshot.branch
            || fresh.operationIdentity != draft.snapshot.operationIdentity
            || fresh.markerSize != draft.snapshot.markerSize
          {
            stale = true
            error = repository.store.text(
              "The file or conflict changed externally. Your draft is kept. Reload and review before saving.",
              "文件或冲突已被外部修改，编辑草稿仍保留。请重新加载并审查后再保存。")
          }
        } else {
          snapshot = fresh
          result = fresh.resultText ?? ""
          selection = .edited
        }
        blockIndex = min(blockIndex, max(0, blocks.count - 1))
      } catch is CancellationError {} catch {
        if ticket == generation {
          self.error = error.localizedDescription
          stale = true
        }
      }
      if ticket == generation { loading = false }
    }
  }
  func repositoryDidRefresh() {
    let files = repository.status.files.filter(\.isConflicted)
    if let path, files.contains(where: { $0.path == path }) {
      if repository.page == "conflicts" { select(path, refresh: true) }
    } else {
      select(files.first?.path)
    }
  }
  func edit(_ text: String) {
    result = text
    selection = .edited
    remember()
  }
  func acceptBlock(_ choice: ConflictBlockChoice) {
    result = ConflictMarkers.resolving(
      result, block: blockIndex, choice: choice, size: snapshot?.markerSize ?? 7)
    selection = .edited
    blockIndex = min(blockIndex, max(0, blocks.count - 1))
    focusRequest += 1
    remember()
  }
  func choose(_ choice: ConflictSelection) {
    selection = choice
    switch choice {
    case .ours: result = snapshot?.ours?.text ?? ""
    case .theirs: result = snapshot?.theirs?.text ?? ""
    case .delete: result = ""
    case .edited: break
    }
    blockIndex = 0
    focusRequest += 1
    remember()
  }
  func reload() {
    guard let path else { return }
    repository.confirmation = PendingAction(
      title: repository.store.text("Reload conflict?", "重新加载冲突？"),
      detail: repository.store.text(
        "Discard this editor draft and reload the file from disk?", "丢弃此文件的编辑草稿，从磁盘重新加载？")
    ) { [weak self] in self?.select(path, force: true) }
  }
  func save() {
    guard canSave, let snapshot else { return }
    let resolution: ConflictResolution
    switch selection {
    case .edited: resolution = .text(result)
    case .ours: resolution = .ours
    case .theirs: resolution = .theirs
    case .delete: resolution = .delete
    }
    let deleting =
      selection == .delete || (selection == .ours && snapshot.ours == nil)
      || (selection == .theirs && snapshot.theirs == nil)
    repository.confirmation = PendingAction(
      title: repository.store.text(
        deleting ? "Delete and resolve?" : "Save and mark resolved?",
        deleting ? "删除文件并解决冲突？" : "保存并标记解决？"),
      detail: repository.store.text(
        "This writes the reviewed result and stages only this file. It does not create a commit.",
        "将写入审查后的结果，并仅暂存此文件，不会创建提交。") + "\n\n" + snapshot.path,
      confirmTitle: repository.store.text(
        deleting ? "Delete & Resolve" : "Save & Resolve", deleting ? "删除并解决" : "保存并解决"),
      destructive: deleting
    ) { [weak self] in
      guard let self else { return }
      repository.run(
        label: repository.store.text("Resolving conflict", "解决冲突"),
        completion: repository.store.text("File saved and marked resolved.", "文件已保存并标记解决。"), updatesCommitState: .index
      ) { [weak self] git in
        guard let self else { return }
        do {
          try await git.resolveConflict(snapshot, resolution: resolution)
          drafts.removeValue(forKey: snapshot.path)
          self.snapshot = nil
          error = nil
        } catch {
          if case GitPierError.conflictChanged = error {
            stale = true
            self.error = repository.store.text(
              "The file or conflict changed externally. Reload and review before saving; your draft is kept.",
              "文件或冲突已被外部修改，请重新加载并审查后再保存；编辑草稿仍保留。")
          } else {
            self.error = error.localizedDescription
          }
          throw error
        }
      }
    }
  }
  func shutdown() {
    generation += 1
    task?.cancel()
    drafts.removeAll()
    snapshot = nil
    result = ""
    path = nil
    loading = false
    parsedText = nil
    parsedBlocks.removeAll()
    parsedMarkers = false
  }
}

struct ConflictResolutionView: View {
  @ObservedObject var model: RepositoryModel
  @ObservedObject var editor: ConflictEditorModel
  @EnvironmentObject var store: AppStore
  @Environment(\.colorScheme) var scheme
  init(model: RepositoryModel) {
    self.model = model
    editor = model.conflictEditor
  }
  var files: [FileChange] { model.status.files.filter(\.isConflicted) }
  var body: some View {
    HSplitView {
      VStack(alignment: .leading, spacing: 0) {
        Label(
          store.text("Conflicts", "冲突") + " (\(files.count))",
          systemImage: "exclamationmark.triangle"
        )
        .font(.headline).padding(14)
        Divider()
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(files) { file in
              Button {
                editor.select(file.path)
              } label: {
                HStack {
                  Image(systemName: "doc.text").foregroundStyle(.orange)
                  Text(file.path).lineLimit(2).truncationMode(.middle)
                  Spacer(minLength: 0)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                  .background(
                    editor.path == file.path ? Color.accentColor.opacity(0.16) : Color.clear)
              }.buttonStyle(.plain).disabled(model.busy)
                .accessibilityIdentifier("gitpier.conflict.file." + file.path)
            }
          }
        }
      }.frame(minWidth: 160, idealWidth: 210, maxWidth: 280).background(Theme.panel(scheme))
      VStack(spacing: 0) {
        header
        Divider()
        if let error = editor.error {
          HStack {
            Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            Spacer()
            Button(store.text("Reload…", "重新加载…")) { editor.reload() }.disabled(model.busy)
          }.padding(12)
          Divider()
        }
        if editor.loading {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let snapshot = editor.snapshot {
          if snapshot.supportsVersions, snapshot.working.kind != .other {
            VSplitView {
              HSplitView {
                versionPane(
                  editor.showBase ? snapshot.base : snapshot.ours,
                  title: store.text(
                    editor.showBase ? "Base" : "Current (Ours)",
                    editor.showBase ? "共同祖先" : "当前版本（Ours）"))
                versionPane(snapshot.theirs, title: store.text("Incoming (Theirs)", "传入版本（Theirs）"))
              }.frame(minHeight: 100, idealHeight: 240)
              resultPane(snapshot).frame(minHeight: 160)
            }
            footer
          } else {
            VStack(spacing: 16) {
              EmptyState(
                symbol: "shippingbox",
                title: store.text("File-type or submodule conflict", "文件类型或子模块冲突"),
                detail: store.text(
                  "Use an external editor or the terminal to resolve this conflict. The built-in editor will preserve it.",
                  "请使用外部编辑器或终端解决此类冲突，内置编辑器会保留现有内容。"))
              Button(store.text("Open in Editor", "在编辑器中打开")) { model.openEditor(snapshot.path) }
            }
          }
        } else if files.isEmpty {
          VStack(spacing: 16) {
            EmptyState(
              symbol: "checkmark.circle", title: store.text("No unresolved files", "没有未解决的冲突文件"),
              detail: store.text(
                "Review the staged files, then continue the Git operation. Saving a result does not create a commit.",
                "请审查已暂存文件，再继续 Git 操作。保存冲突结果不会创建提交。"))
            if model.status.operation == .merge {
              Button(
                store.text(
                  model.conflictPush == nil ? "Review & Continue Merge" : "Review, Continue & Push",
                  model.conflictPush == nil ? "审查并继续合并" : "审查、继续并推送")
              ) {
                model.reviewMergeContinuation(push: model.conflictPush != nil)
              }.buttonStyle(.borderedProminent).disabled(model.busy)
                .accessibilityIdentifier("gitpier.conflict.continue")
            } else if model.status.operation == nil {
              Button(store.text("Review Commit", "审查提交")) { model.setPage("commit") }
                .buttonStyle(.borderedProminent)
            }
          }
        } else {
          EmptyState(
            symbol: "doc.text.magnifyingglass", title: store.text("Select a conflict", "选择冲突文件"),
            detail: "")
        }
      }.frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity).background(
        Theme.editor(scheme))
    }.task { editor.repositoryDidRefresh() }
      .accessibilityIdentifier("gitpier.conflict.page")
  }
  var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(editor.path ?? store.text("Resolve Conflicts", "解决冲突")).font(.headline).lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        if editor.snapshot?.base != nil {
          Toggle(store.text("Show Base", "显示共同祖先"), isOn: $editor.showBase).toggleStyle(.checkbox)
        }
        Button(store.text("Reload…", "重新加载…")) { editor.reload() }.disabled(
          editor.path == nil || model.busy)
      }
      if model.status.operation == .rebase {
        Text(
          store.text(
            "During rebase, Current is the branch being rebased onto; Incoming is the commit being replayed.",
            "变基时，当前版本是变基目标分支，传入版本是正在重放的提交。")
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }.padding(12)
  }
  func versionPane(_ version: ConflictVersion?, title: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title).font(.subheadline.weight(.semibold)).padding(10)
      Divider()
      if let text = version?.text {
        ConflictTextEditor(
          text: .constant(text), editable: false, settings: store.settings, scheme: scheme,
          label: title)
      } else {
        EmptyState(
          symbol: version == nil ? "doc.badge.minus" : "doc.richtext",
          title: store.text(
            version == nil ? "Deleted" : "Binary or large file", version == nil ? "已删除" : "二进制或大型文件"
          ),
          detail: version?.objectID.prefix(8).description ?? "")
      }
    }.frame(minWidth: 200, maxWidth: .infinity)
  }
  func resultPane(_ snapshot: ConflictSnapshot) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text(store.text("Result", "合并结果")).font(.subheadline.weight(.semibold))
        Spacer()
        Menu(store.text("Use Whole File", "采用整个文件")) {
          Button(
            store.text(
              snapshot.ours == nil ? "Current: Delete File" : "Use Current",
              snapshot.ours == nil ? "当前版本：删除文件" : "采用当前版本")
          ) { editor.choose(.ours) }
          Button(
            store.text(
              snapshot.theirs == nil ? "Incoming: Delete File" : "Use Incoming",
              snapshot.theirs == nil ? "传入版本：删除文件" : "采用传入版本")
          ) { editor.choose(.theirs) }
          Divider()
          Button(store.text("Delete File", "删除文件")) { editor.choose(.delete) }
        }.disabled(model.busy || editor.stale)
      }.padding(10)
      if snapshot.resultText != nil, editor.selection != .delete,
        !(editor.selection == .ours && snapshot.ours == nil),
        !(editor.selection == .theirs && snapshot.theirs == nil)
      {
        HStack(spacing: 8) {
          Button {
            editor.blockIndex = max(0, editor.blockIndex - 1)
            editor.focusRequest += 1
          } label: {
            Image(systemName: "chevron.up")
          }
          Button {
            editor.blockIndex = min(max(0, editor.blocks.count - 1), editor.blockIndex + 1)
            editor.focusRequest += 1
          } label: {
            Image(systemName: "chevron.down")
          }
          Text(
            editor.blocks.isEmpty
              ? store.text(
                editor.hasMarkers
                  ? "Incomplete markers" : "No conflict markers",
                editor.hasMarkers
                  ? "冲突标记不完整" : "没有冲突标记")
              : store.text(
                "Conflict \(editor.blockIndex + 1) of \(editor.blocks.count)",
                "冲突 \(editor.blockIndex + 1) / \(editor.blocks.count)"))
          Spacer()
          Button(store.text("Current", "当前")) { editor.acceptBlock(.ours) }.accessibilityIdentifier(
            "gitpier.conflict.accept-current")
          Button(store.text("Incoming", "传入")) { editor.acceptBlock(.theirs) }
            .accessibilityIdentifier("gitpier.conflict.accept-incoming")
          Button(store.text("Both", "双方")) { editor.acceptBlock(.both) }.accessibilityIdentifier(
            "gitpier.conflict.accept-both")
        }.font(.caption).controlSize(.small).padding(.horizontal, 10).padding(.bottom, 8)
          .disabled(editor.blocks.isEmpty || editor.stale || model.busy)
        Divider()
        ConflictTextEditor(
          text: Binding(get: { editor.result }, set: { editor.edit($0) }),
          editable: !editor.stale && !model.busy,
          settings: store.settings, scheme: scheme, label: store.text("Conflict result", "冲突结果"),
          focusRequest: editor.focusRequest,
          selection: editor.blocks.indices.contains(editor.blockIndex)
            ? editor.blocks[editor.blockIndex].range : nil
        )
        .accessibilityIdentifier("gitpier.conflict.result")
      } else {
        Divider()
        EmptyState(
          symbol: "doc.text", title: store.text("Selected result", "已选择的结果"),
          detail: store.text(
            editor.selection == .edited
              ? "Choose Current, Incoming or Delete from Use Whole File."
              : editor.selection == .ours
                ? (snapshot.ours == nil ? "Delete this file" : "Keep Current version")
                : editor.selection == .theirs
                  ? (snapshot.theirs == nil ? "Delete this file" : "Keep Incoming version")
                  : "Delete this file",
            editor.selection == .edited
              ? "请从“采用整个文件”中选择当前版本、传入版本或删除。"
              : editor.selection == .ours
                ? (snapshot.ours == nil ? "删除此文件" : "保留当前版本")
                : editor.selection == .theirs
                  ? (snapshot.theirs == nil ? "删除此文件" : "保留传入版本") : "删除此文件"))
      }
    }
  }
  var footer: some View {
    HStack {
      Text(
        store.text(
          "Draft only until saved. Save stages this file; it does not commit.",
          "保存前仅为草稿。保存会暂存此文件，不会创建提交。")
      )
      .font(.caption).foregroundStyle(.secondary)
      Spacer()
      Button(store.text("Save & Mark Resolved", "保存并标记解决")) { editor.save() }
        .buttonStyle(.borderedProminent).disabled(!editor.canSave || model.busy)
        .accessibilityIdentifier("gitpier.conflict.save")
    }.padding(12)
  }
}

struct ConflictTextEditor: NSViewRepresentable {
  @Binding var text: String
  let editable: Bool
  let settings: AppSettings
  let scheme: ColorScheme
  var label = "Conflict version"
  var focusRequest = 0
  var selection: NSRange?
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = DiffScrollView()
    let view = NSTextView()
    view.isRichText = false
    view.allowsUndo = true
    view.isAutomaticQuoteSubstitutionEnabled = false
    view.isAutomaticDashSubstitutionEnabled = false
    view.isAutomaticTextReplacementEnabled = false
    view.isAutomaticSpellingCorrectionEnabled = false
    view.isContinuousSpellCheckingEnabled = false
    view.textContainerInset = NSSize(width: 10, height: 10)
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]
    view.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.textContainer?.widthTracksTextView = true
    view.textContainer?.containerSize = view.maxSize
    view.delegate = context.coordinator
    scroll.documentView = view
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let view = scroll.documentView as? NSTextView else { return }
    if view.string != text {
      view.string = text
      view.undoManager?.removeAllActions()
    }
    view.isEditable = editable
    view.isSelectable = true
    let font =
      NSFont(name: settings.diffFont, size: settings.diffFontSize)
      ?? NSFont.monospacedSystemFont(ofSize: settings.diffFontSize, weight: .regular)
    if view.font != font { view.font = font }
    let background = scheme == .dark ? NSColor(hex: 0x191B1F) : NSColor(hex: 0xFAFBFC)
    if view.backgroundColor != background { view.backgroundColor = background }
    if view.textColor != .labelColor { view.textColor = .labelColor }
    if view.insertionPointColor != .labelColor { view.insertionPointColor = .labelColor }
    view.setAccessibilityLabel(localizedUI(label))
    if context.coordinator.focusRequest != focusRequest {
      context.coordinator.focusRequest = focusRequest
      if let selection, NSMaxRange(selection) <= view.string.utf16.count {
        view.setSelectedRange(selection)
        view.scrollRangeToVisible(selection)
      }
    }
  }
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: ConflictTextEditor
    var focusRequest = -1
    init(_ parent: ConflictTextEditor) { self.parent = parent }
    func textDidChange(_ notification: Notification) {
      if let view = notification.object as? NSTextView { parent.text = view.string }
    }
  }
}
