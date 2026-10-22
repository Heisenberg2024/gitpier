import AppKit
import GitPierCore
import SwiftUI
import UniformTypeIdentifiers

struct PatchImportRequest: Identifiable {
  let id = UUID()
  let name: String
  let data: Data
}
enum PatchExportSource: Sendable {
  case file(FileChange, DiffComparison)
  case selected(DiffDocument, Set<Int>, String)
  case commit(CommitRecord)
  case range
  var emailAvailable: Bool {
    switch self { case .commit, .range: true; default: false }
  }
}
struct PatchExportRequest: Identifiable {
  let id = UUID()
  let source: PatchExportSource
}

@MainActor enum PatchFileDialogs {
  static var type: UTType { UTType(filenameExtension: "patch") ?? .plainText }
  static func choose(_ result: @escaping @MainActor (URL) -> Void) {
    DispatchQueue.main.async {
      let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
      panel.allowedContentTypes = [.plainText, .data]
      panel.begin { response in if response == .OK, let url = panel.url { result(url) } }
    }
  }
  static func save(_ data: Data, name: String, completion: @escaping @MainActor (Bool, Error?) -> Void) {
    let panel = NSSavePanel(); panel.allowedContentTypes = [type]; panel.nameFieldStringValue = name
    panel.begin { response in
      guard response == .OK, let url = panel.url else { completion(false, nil); return }
      Task {
        do {
          try await Task.detached { try data.write(to: url, options: .atomic) }.value
          completion(true, nil)
        } catch { completion(false, error) }
      }
    }
  }
  static func read(_ url: URL) async throws -> Data {
    try await Task.detached {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw GitPierError.invalidInput("Choose a regular local patch file.")
      }
      let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
      let data = try handle.read(upToCount: PatchParser.limit + 1) ?? Data()
      guard data.count <= PatchParser.limit else { throw GitPierError.outputLimit }
      return data
    }.value
  }
}

struct PatchImportView: View {
  @ObservedObject var model: RepositoryModel
  let input: PatchImportRequest
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @Environment(\.colorScheme) var scheme
  @StateObject private var request = WorkflowRequest()
  @State private var target = PatchTarget.workingTree
  @State private var review: PatchImportReview?
  @State private var selected: String?
  @State private var confirming = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(store.text("Import Patch", "导入补丁")).font(.title2.weight(.semibold))
        Spacer(); Text(input.name).lineLimit(1).foregroundStyle(.secondary)
      }
      HStack {
        Picker(store.text("Apply to", "应用到"), selection: $target) {
          Text(store.text("Working Tree", "工作区")).tag(PatchTarget.workingTree)
          Text("Index").tag(PatchTarget.index)
        }.pickerStyle(.segmented).frame(width: 340)
        Spacer(); Button(store.text("Refresh Review", "刷新审查")) { load() }.disabled(request.loading || model.busy)
      }
      Text(store.text(target == .workingTree ? "Changes will remain unstaged. Existing Index content is preserved." : "Only the Index changes; working files remain untouched. Review existing partial staging.",
                      target == .workingTree ? "修改保持未暂存，保留已有 Index 内容。" : "只修改 Index，工作文件保持不变。请审查已有部分暂存。"))
        .font(.caption).foregroundStyle(.secondary)
      WorkflowProblem(request: request)
      if let review {
        Text(review.operation.branch + " · " + String((review.operation.head ?? "").prefix(12))
          + " · " + store.text("\(review.files.count) files", "\(review.files.count) 个文件")).font(.caption)
        if !review.summary.isEmpty { Text(review.summary).font(.caption).textSelection(.enabled).lineLimit(4) }
        HStack(spacing: 0) {
          List(review.files, selection: $selected) { file in
            VStack(alignment: .leading, spacing: 4) {
              Text(file.path).lineLimit(2)
              Text(file.binary ? store.text("Binary patch", "二进制补丁") : "+\(file.additions ?? 0) −\(file.deletions ?? 0)")
                .font(.caption).foregroundStyle(.secondary)
            }.tag(file.path)
          }.listStyle(.inset).frame(width: 225)
          Divider()
          if let file = review.files.first(where: { $0.path == selected }) {
            if file.binary {
              EmptyState(symbol: "doc.richtext", title: store.text("Binary patch", "二进制补丁"),
                         detail: store.text("Git verified this literal binary patch. Applying it changes the displayed file.", "Git 已校验此字面量二进制补丁，应用会修改显示的文件。"))
            } else if file.document.pairs.count > 20_000 || file.document.raw.utf8.count > 2 * 1024 * 1024 {
              EmptyState(symbol: "doc.text", title: store.text("Large Diff", "大型 Diff"),
                         detail: store.text("The complete patch is checked by Git; preview is limited to keep the interface responsive. Review large patches in the terminal before applying.", "完整补丁由 Git 校验，预览有大小限制。应用前请在终端审查大型补丁。"))
            } else if file.document.hunks.isEmpty {
              Text(file.document.raw).font(uiFont(size: 11, design: .monospaced)).textSelection(.enabled).padding(15)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
              DiffTable(document: file.document, path: file.path, key: "patch-" + review.operation.branch + file.path,
                        settings: store.settings, dark: scheme == .dark, selectedHunk: 0,
                        afterOnly: !file.document.hasOldContent,
                        beforeTitle: store.text("Before", "修改前"), afterTitle: store.text("Patch Result", "补丁结果"))
            }
          } else { Spacer() }
        }.frame(maxHeight: .infinity)
      } else { Spacer() }
      HStack {
        Text(store.text("No commit is created. Email patches require git am in the terminal.", "不会创建提交。邮件补丁请在终端使用 git am。")).font(.caption).foregroundStyle(.secondary)
        Spacer(); Button(store.text("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(store.text("Apply Reviewed Patch…", "应用已审查补丁…")) { confirming = true }
          .disabled(review == nil || request.loading || model.busy).accessibilityIdentifier("patch.apply")
      }
    }.padding(20).frame(minWidth: 760, idealWidth: 1000, minHeight: 460, idealHeight: 650)
      .onAppear { load() }.onDisappear { request.cancel() }
      .onChange(of: target) { _, _ in load() }
      .onChange(of: store.current?.record.id) { _, id in if id != model.record.id { dismiss() } }
      .alert(store.text("Apply patch to \(target == .index ? "Index" : "Working Tree")?", "将补丁应用到\(target == .index ? " Index" : "工作区")？"), isPresented: $confirming) {
        Button(store.text("Apply Patch", "应用补丁")) { execute() }
        Button(store.text("Cancel", "取消"), role: .cancel) {}.keyboardShortcut(.defaultAction)
      } message: {
        Text(store.text("Only the displayed files and target will change. Any external state change requires another review.", "仅修改显示的文件和目标，外部状态改变后必须重新审查。")
          + "\n\n" + (review?.files.map(\.path).joined(separator: "\n") ?? ""))
      }
  }
  func load() {
    review = nil; selected = nil
    let target = target
    request.start { ticket in
      let value = try await model.git().reviewPatchImport(input.data, target: target)
      guard request.current(ticket), store.current === model else { return }
      review = value; selected = value.files.first?.path
    }
  }
  func execute() {
    guard let review, store.current === model, !model.busy else { return }
    dismiss()
    model.run(label: store.text("Applying patch", "应用补丁"), completion: store.text("Patch applied. Review the resulting changes before committing.", "补丁已应用，请在提交前审查结果。"), updatesCommitState: review.target == .index ? .index : nil) { git in
      model.output = try await git.applyImportedPatch(review)
    }
  }
}

struct PatchExportView: View {
  @ObservedObject var model: RepositoryModel
  let source: PatchExportSource
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @StateObject private var request = WorkflowRequest()
  @State private var format = PatchExportFormat.diff
  @State private var from = "HEAD~1"
  @State private var to = "HEAD"
  @State private var data: Data?
  @State private var saved = false
  @State private var cancelled = false
  @State private var problem: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(store.text("Export Patch", "导出补丁")).font(.title2.weight(.semibold))
      Picker(store.text("Format", "格式"), selection: $format) {
        Text(store.text("Git Diff Patch", "Git Diff 补丁")).tag(PatchExportFormat.diff)
        if source.emailAvailable { Text(store.text("Commit Email Patch (format-patch)", "提交邮件补丁（format-patch）")).tag(PatchExportFormat.commitEmail) }
      }
      if case .range = source {
        HStack {
          TextField(store.text("From commit", "起始提交"), text: $from)
          Text("→")
          TextField(store.text("To commit", "结束提交"), text: $to)
          Button(store.text("Prepare", "准备")) { load() }
        }.textFieldStyle(.roundedBorder)
      }
      Text(store.text(format == .diff ? "A Diff describes file changes. Commit export compares the first parent, including merge commits." : "Email patches preserve commit messages/authors and require git am; GitPier does not import or commit them automatically.",
                      format == .diff ? "Diff 描述文件修改；提交导出与第一父提交比较，包括合并提交。" : "邮件补丁保留提交消息与作者，需使用 git am；GitPier 不会自动导入或提交。"))
        .font(.caption).foregroundStyle(.secondary)
      WorkflowProblem(request: request)
      if let data {
        Text(store.text("\(data.count) bytes ready", "已准备 \(data.count) 字节")).font(.caption)
        ScrollView {
          Text(String(decoding: data.prefix(64 * 1024), as: UTF8.self)).font(uiFont(size: 11, design: .monospaced))
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: .infinity)
        if data.count > 64 * 1024 { Text(store.text("Preview shows the first 64 KiB; the saved file includes the complete patch.", "预览仅显示前 64 KiB，保存文件包含完整补丁。")).font(.caption).foregroundStyle(.secondary) }
      } else { Spacer() }
      if let problem { Text(problem).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
      if saved { Text(store.text("Patch saved; repository state is unchanged.", "补丁已保存，仓库状态未改变。")).font(.caption) }
      if cancelled { Text(store.text("Export cancelled.", "导出已取消。")).font(.caption) }
      HStack {
        Button(store.text("Done", "完成")) { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer(); Button(store.text("Save Patch…", "保存补丁…")) {
          guard let data else { return }
          PatchFileDialogs.save(data, name: "GitPier-\(format == .commitEmail ? "commits" : "changes").patch") { completed, error in
            problem = error?.localizedDescription; saved = completed; cancelled = !completed && error == nil
          }
        }.disabled(data?.isEmpty != false || request.loading)
      }
    }.padding(20).frame(minWidth: 680, idealWidth: 860, minHeight: 420, idealHeight: 600)
      .onAppear { load() }.onDisappear { request.cancel() }
      .onChange(of: format) { _, _ in load() }
      .onChange(of: from) { _, _ in request.cancel(); data = nil }
      .onChange(of: to) { _, _ in request.cancel(); data = nil }
      .onChange(of: store.current?.record.id) { _, id in if id != model.record.id { dismiss() } }
  }
  func load() {
    data = nil; problem = nil; saved = false; cancelled = false
    let from = from, to = to, format = format
    request.start { ticket in
      let git = await model.git()
      let value: Data
      switch source {
      case let .file(file, comparison): value = try await git.exportFilePatch(file, comparison: comparison)
      case let .selected(document, ids, _): value = try await Task.detached { try SelectivePatch.build(document, selected: ids) }.value
      case let .commit(commit): value = try await git.exportCommitPatch(commit.hash, format: format)
      case .range: value = try await git.exportRangePatch(from: from, to: to, format: format)
      }
      guard request.current(ticket), store.current === model else { return }; data = value
    }
  }
}
