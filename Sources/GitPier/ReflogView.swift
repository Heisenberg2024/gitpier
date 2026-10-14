import GitPierCore
import SwiftUI

struct ReflogView: View {
  @ObservedObject var model: RepositoryModel
  @EnvironmentObject var store: AppStore
  @StateObject private var request = WorkflowRequest()
  @StateObject private var detailRequest = WorkflowRequest()
  @State private var reference = "HEAD"
  @State private var search = ""
  @State private var operation = ""
  @State private var entries: [ReflogEntry] = []
  @State private var selected: ReflogEntry?
  @State private var commit: CommitRecord?
  @State private var branchName = ""
  @State private var recovering = false
  @State private var offset = 0
  @State private var hasMore = false
  private var queryID: String { reference + "\0" + search + "\0" + operation }
  var body: some View {
    GeometryReader { area in
      VStack(spacing: 0) {
        ScrollView(.horizontal) {
          HStack(spacing: 10) {
            Text(store.text("Reflog", "引用日志")).font(.headline)
            Picker(store.text("Reference", "引用"), selection: $reference) {
              Text("HEAD").tag("HEAD")
              ForEach(model.branches.filter { !$0.remote }) { Text($0.name).tag($0.reference) }
            }.frame(width: 180)
            Picker(store.text("Operation", "操作"), selection: $operation) {
              Text(store.text("All operations", "全部操作")).tag("")
              ForEach(["commit", "reset", "checkout", "merge", "rebase", "cherry-pick", "revert", "branch"], id: \.self) { Text($0).tag($0) }
            }.frame(width: 160)
            TextField(store.text("Search descriptions", "搜索操作说明"), text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
            Button(store.text("Refresh", "刷新")) { load(reset: true) }
          }.padding(12)
        }
        Text(store.text("Recover by creating a branch. Expired reflogs and garbage-collected objects may be unrecoverable.", "优先创建分支恢复。过期的引用日志或已被垃圾回收的对象可能无法恢复。"))
          .font(uiFont(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 8)
        Divider()
        WorkflowProblem(request: request)
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(entries) { entry in
              Button { selected = entry; commit = nil; loadDetail(entry) } label: {
                HStack(spacing: 10) {
                  Text(entry.operation).font(uiFont(size: 10, weight: .medium)).frame(width: 85, alignment: .leading).lineLimit(1)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(entry.message).lineLimit(1)
                    Text(entry.selector).font(uiFont(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                  }.frame(maxWidth: .infinity, alignment: .leading)
                  Text(entry.date.formatted(date: .numeric, time: .shortened)).foregroundStyle(.secondary).lineLimit(1)
                  Text(String(entry.hash.prefix(8))).font(.system(size: 11, design: .monospaced))
                }.font(uiFont(size: 11)).padding(10).contentShape(Rectangle())
                  .background(selected?.id == entry.id ? Color.accentColor.opacity(0.12) : .clear)
              }.buttonStyle(.plain).accessibilityIdentifier("reflog-" + entry.hash)
            }
            if hasMore { Button(store.text("Load more records", "加载更多记录")) { load(reset: false) }.disabled(request.loading).padding(12) }
            if entries.isEmpty && !request.loading && request.problem == nil { Text(store.text("No matching reflog records", "没有匹配的引用日志")).foregroundStyle(.secondary).padding(20) }
          }
        }
        if let selected {
          Divider()
          ScrollView(.horizontal) {
            HStack {
              Button(store.text("Create Recovery Branch…", "创建恢复分支…")) { branchName = ""; recovering = true }
                .disabled(commit == nil || model.busy)
              Menu(store.text("Reset to Commit…", "重置到此提交…")) {
                Button(store.text("Soft (keep Index and files)…", "Soft（保留暂存与文件）…")) {
                  model.perform(["reset", "--soft", selected.hash], confirmation: store.text("Rewrite local HEAD to the selected commit, keeping Index and files? Prefer a recovery branch. Target: ", "将本地 HEAD 改写至所选提交，保留 Index 与文件？建议优先使用恢复分支。目标：") + selected.hash)
                }
                Button(store.text("Mixed (clear staging)…", "Mixed（清除暂存选择）…")) {
                  model.perform(["reset", "--mixed", selected.hash], confirmation: store.text("Rewrite HEAD and replace the Index. Existing staging choices will be lost. Working files remain. Target: ", "改写 HEAD 并替换 Index，将丢失现有暂存选择，工作文件保留。目标：") + selected.hash)
                }
              }.disabled(commit == nil || model.busy)
              Button(store.text("Copy Hash", "复制 Hash")) { copyText(selected.hash) }
            }.padding(10)
          }
          WorkflowProblem(request: detailRequest)
          if let commit {
            CommitDetailView(model: model, commit: commit, onClose: { self.selected = nil; self.commit = nil; detailRequest.cancel() })
              .id(commit.hash).frame(height: max(160, min(area.size.height * 0.48, model.panels.layout.historyDetailHeight)))
          }
        }
      }
    }.task(id: queryID) { load(reset: true) }
      .onChange(of: model.busy) { if !model.busy { load(reset: true) } }
      .onDisappear { request.cancel(); detailRequest.cancel() }
      .alert(store.text("Create Recovery Branch", "创建恢复分支"), isPresented: $recovering) {
        TextField(store.text("Branch name", "分支名称"), text: $branchName)
        Button(store.text("Create", "创建")) {
          if let selected { let name = branchName; model.run { git in try await git.recoverReflogCommit(selected.hash, branch: name) } }
        }
        Button(store.text("Cancel", "取消"), role: .cancel) {}
      } message: { Text(store.text("Creates a branch at the selected available commit. HEAD, working files and Index remain in place.", "在所选有效提交处创建分支，保留当前 HEAD、工作文件及 Index。")) }
  }
  private func load(reset: Bool) {
    let ref = reference, text = search, type = operation, skip = reset ? 0 : offset
    if reset { entries = []; selected = nil; commit = nil; offset = 0; hasMore = false; detailRequest.cancel() }
    request.start { ticket in
      if reset { try await Task.sleep(for: .milliseconds(180)) }
      let result = try await model.git().reflog(reference: ref, skip: skip, search: text, operation: type)
      guard request.current(ticket), ref == reference, text == search, type == operation else { return }
      entries = reset ? result : entries + result
      offset = skip + result.count; hasMore = result.count == 100
    }
  }
  private func loadDetail(_ entry: ReflogEntry) {
    detailRequest.start { ticket in
      let result = try await model.git().commitDetail(entry.hash)
      guard detailRequest.current(ticket), selected?.id == entry.id else { return }
      commit = result
    }
  }
}
