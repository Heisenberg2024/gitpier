import GitPierCore
import SwiftUI

/// SwiftUI cancels both tasks on selection changes and view removal. Results additionally
/// check their selected path, so a late Git read cannot replace a newer preview.
struct StashPreviewView: View {
  @ObservedObject var model: RepositoryModel
  let stash: GitStash
  @EnvironmentObject var store: AppStore
  @Environment(\.colorScheme) private var scheme
  @State private var files: [StashFile] = []
  @State private var selected: String?
  @State private var diff = DiffDocument.empty
  @State private var oversized = false
  @State private var filesLoading = true
  @State private var loading = false
  @State private var problem: String?

  var body: some View {
    HStack(spacing: 0) {
      List(files, selection: $selected) { file in
        Label(file.change.path, systemImage: "doc.text")
          .font(uiFont(size: 11)).lineLimit(1).tag(file.id)
      }.listStyle(.inset).frame(minWidth: 180, idealWidth: 240, maxWidth: 300)
      Divider()
      VStack(spacing: 0) {
        HStack {
          Text(selected ?? stash.message).lineLimit(1)
          Spacer()
          Button(store.text("Copy Patch", "复制 Patch")) { copyText(diff.raw) }
            .disabled(loading || filesLoading || selected == nil)
        }.font(uiFont(size: 11)).padding(10)
        Divider()
        if let problem {
          EmptyState(
            symbol: "exclamationmark.triangle",
            title: store.text("Unable to load stash", "无法加载 Stash"), detail: problem)
        } else if loading || filesLoading {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if selected == nil {
          EmptyState(symbol: "tray", title: store.text("No changed files", "没有变更文件"), detail: "")
        } else if diff.binary {
          EmptyState(
            symbol: "doc.richtext", title: store.text("Binary changes", "二进制变更"), detail: "")
        } else if oversized || diff.pairs.count > 20000 || diff.raw.utf8.count > 2 * 1024 * 1024 {
          EmptyState(
            symbol: "doc.text", title: store.text("Large Diff", "大型 Diff"),
            detail: store.text("This diff exceeds the display limit.", "此 Diff 超过显示上限。"))
        } else if diff.hunks.isEmpty {
          EmptyState(
            symbol: "doc.text", title: store.text("No text changes", "没有文本变更"), detail: diff.raw)
        } else {
          DiffTable(
            document: diff, path: selected ?? "",
            key: model.record.id.uuidString + stash.hash + (selected ?? ""),
            settings: store.settings, dark: scheme == .dark, selectedHunk: 0,
            indexSide: 0, afterOnly: !diff.hasOldContent,
            beforeTitle: store.text("Stash base", "Stash 基准"),
            afterTitle: store.text("Saved changes", "保存的修改")
          )
          .equatable()
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }.task(id: stash.hash) {
      filesLoading = true
      files = []
      selected = nil
      problem = nil
      do {
        let result = try await model.git().stashFiles(stash)
        try Task.checkCancellation()
        files = result
        selected = result.first?.id
        filesLoading = false
      } catch {
        guard !Task.isCancelled else { return }
        filesLoading = false
        problem = GitService.redact(error.localizedDescription)
      }
    }.task(id: selected) {
      diff = .empty
      oversized = false
      loading = false
      guard let path = selected, let file = files.first(where: { $0.id == path }) else { return }
      problem = nil
      loading = true
      do {
        let bytes = try await model.git().stashPatch(stash, file: file)
        let large =
          bytes.count > 2 * 1024 * 1024 || bytes.reduce(into: 0) { if $1 == 10 { $0 += 1 } } > 40000
        let result = await Task.detached(priority: .userInitiated) {
          large ? DiffDocument.empty : DiffParser.parse(bytes)
        }.value
        try Task.checkCancellation()
        guard selected == path else { return }
        diff = result
        oversized = large
        loading = false
      } catch {
        guard !Task.isCancelled, selected == path else { return }
        loading = false
        problem = GitService.redact(error.localizedDescription)
      }
    }
  }
}
