import AppKit
import GitPierCore
import SwiftUI

struct BlameView: View {
  @ObservedObject var model: RepositoryModel
  let request: BlameRequest
  @EnvironmentObject var store: AppStore
  @Environment(\.colorScheme) private var scheme
  @Environment(\.dismiss) private var dismiss
  @StateObject private var query = WorkflowRequest()
  @StateObject private var detailQuery = WorkflowRequest()
  @State private var page: BlamePage?
  @State private var start = 1
  @State private var commit: CommitRecord?
  @State private var commitPath: String?
  @State private var revision: String?
  private var font: NSFont { NSFont(name: store.settings.diffFont, size: store.settings.diffFontSize) ?? .monospacedSystemFont(ofSize: store.settings.diffFontSize, weight: .regular) }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(store.text("Blame", "逐行溯源")).font(.headline)
          Text(request.path).font(uiFont(size: 11)).lineLimit(2).textSelection(.enabled)
          Text(request.revision.map { String($0.prefix(12)) } ?? store.text("Working file (includes uncommitted changes)", "工作文件（包含未提交修改）")).font(uiFont(size: 10)).foregroundStyle(.secondary)
        }
        Spacer()
        Button(store.text("Refresh", "刷新")) { revision = request.revision; load() }
        Button(store.text("Done", "完成")) { dismiss() }.keyboardShortcut(.cancelAction)
      }.padding(12)
      Divider()
      WorkflowProblem(request: query)
      WorkflowProblem(request: detailQuery)
      ScrollView([.horizontal, .vertical]) {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(page?.lines ?? []) { line in
            HStack(alignment: .top, spacing: 12) {
              Button { showCommit(line) } label: {
                Text(line.uncommitted ? store.text("Uncommitted", "未提交") : String(line.hash.prefix(8))).font(.system(size: 11, design: .monospaced)).frame(width: 95, alignment: .leading)
              }.buttonStyle(.plain).disabled(line.uncommitted).accessibilityIdentifier("blame-commit-\(line.line)")
                .contextMenu { if !line.uncommitted { Button(store.text("Copy Hash", "复制 Hash")) { copyText(line.hash) } } }
              Text(line.uncommitted ? store.text("Working file", "工作文件") : line.author).font(uiFont(size: 11)).frame(width: 110, alignment: .leading).lineLimit(1).help(line.uncommitted ? store.text("Working file", "工作文件") : line.author)
              Text(line.uncommitted ? "—" : line.date.formatted(date: .numeric, time: .omitted)).font(uiFont(size: 10)).foregroundStyle(.secondary).frame(width: 88, alignment: .leading)
              Text("\(line.line)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
              Text(AttributedString(SyntaxHighlighter.highlight(line.text, path: request.path, font: font, dark: scheme == .dark)))
                .textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
            }.padding(.horizontal, 12).padding(.vertical, 3)
              .background(line.uncommitted ? Color.orange.opacity(0.08) : Color.clear)
          }
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      HStack {
        Button(store.text("Previous", "上一页")) { start = max(1, start - 400); load() }.disabled(start <= 1 || query.loading)
        if let page { Text("\(start)–\(page.lines.last?.line ?? 0) / \(page.totalLines)").font(uiFont(size: 11)) }
        Button(store.text("Next", "下一页")) { start += 400; load() }.disabled(query.loading || (page?.totalLines ?? 0) < start + 400)
        Spacer()
        Text(store.text("400 lines per page · UTF-8 files up to 4 MiB · follows Git rename attribution", "每页 400 行 · UTF-8 文件上限 4 MiB · 使用 Git 重命名追踪")).font(uiFont(size: 10)).foregroundStyle(.secondary).lineLimit(2)
      }.padding(12)
    }.frame(minWidth: 780, idealWidth: 1080, minHeight: 440, idealHeight: 680)
      .onAppear { revision = request.revision; load() }
      .onDisappear { query.cancel(); detailQuery.cancel() }
      .sheet(item: $commit) { WorkflowCommitSheet(model: model, commit: $0, path: commitPath).environmentObject(store) }
  }
  private func load() {
    page = nil
    let requestedStart = start, path = request.path, requestedRevision = revision
    query.start { ticket in
      let result = try await model.git().blame(path: path, revision: requestedRevision, start: requestedStart)
      guard query.current(ticket), start == requestedStart else { return }
      guard !result.lines.contains(where: { $0.text.utf16.count > 20000 }) else {
        throw GitPierError.invalidInput(store.text("Blame display refuses lines over 20,000 characters. Open this file in an external editor.", "逐行溯源不显示超过 20,000 字符的单行，请在外部编辑器中打开此文件。"))
      }
      page = result
      // Pin historical queries across pages so a moving branch cannot mix revisions.
      if request.revision != nil { revision = result.revision }
    }
  }
  private func showCommit(_ line: BlameLine) {
    guard !line.uncommitted else { return }
    detailQuery.start { ticket in
      let record = try await model.git().commitDetail(line.hash)
      guard detailQuery.current(ticket) else { return }
      commitPath = line.originalPath; commit = record
    }
  }
}
