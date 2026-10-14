import GitPierCore
import SwiftUI

struct LFSView: View {
  @ObservedObject var model: RepositoryModel
  @EnvironmentObject var store: AppStore
  @Environment(\.colorScheme) var scheme
  @StateObject private var request = WorkflowRequest()
  @State private var state: LFSState?
  @State private var pattern = ""
  @State private var remote = ""
  @State private var selected: String?
  @State private var ruleReview: LFSRuleReview?
  @State private var networkReview: LFSNetworkReview?
  @State private var confirmingNetwork = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
          Text("Git LFS").font(.title3.weight(.semibold))
          if let state { Text(state.installed ? state.version : store.text("Not Installed", "未安装")).font(.caption).foregroundStyle(.secondary) }
          Button(store.text("Refresh", "刷新")) { load() }.disabled(request.loading || model.busy)
          Picker(store.text("Remote", "远程"), selection: $remote) {
            Text(store.text("Choose remote", "选择远程")).tag("")
            ForEach(model.remotes) { Text($0.name).tag($0.name) }
          }.frame(width: 150)
          Button(store.text("LFS Fetch…", "LFS 获取…")) { reviewNetwork(.fetch) }
            .disabled(state?.installed != true || remote.isEmpty || model.busy)
          Button(store.text("LFS Pull…", "LFS 拉取…")) { reviewNetwork(.pull) }
            .disabled(state?.installed != true || state?.configured != true || remote.isEmpty || model.busy)
        }
      }
      WorkflowProblem(request: request)
      if let state {
        if !state.installed {
          Text(store.text("Install Git LFS separately using its official instructions, then refresh. GitPier does not download it, install filters/hooks or change global Git settings.",
                          "请按 Git LFS 官方说明自行安装，然后刷新。GitPier 不会下载工具、安装过滤器 / Hooks 或修改全局 Git 配置。"))
            .font(.callout).foregroundStyle(.orange)
        } else if !state.configured {
          Text(store.text("Git LFS filters are not configured for this Git environment. Configure them separately before Pull; Fetch and rule review remain available.",
                          "当前 Git 环境未配置 LFS 过滤器，请自行配置后再拉取；获取与规则审查仍可使用。"))
            .font(.caption).foregroundStyle(.orange)
        }
        if let diagnostic = state.diagnostic, state.installed { Text(localizedUI(diagnostic)).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        Text(store.text(state.inUse ? "This repository uses Git LFS." : "No current LFS usage was found.", state.inUse ? "此仓库使用 Git LFS。" : "未发现当前 LFS 使用记录。"))
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          TextField(store.text("Root tracking pattern, e.g. *.psd", "根目录跟踪规则，例如 *.psd"), text: $pattern).textFieldStyle(.roundedBorder)
          Button(store.text("Track…", "跟踪…")) { reviewRule(pattern, track: true) }
            .disabled(state.installed == false || pattern.isEmpty || model.busy)
          Button(store.text("Open .gitattributes", "打开 .gitattributes")) { model.openEditor(".gitattributes") }
        }
        Text(store.text("Rule edits change only the root .gitattributes. Existing files are not automatically converted or staged; nested rules and other attributes are preserved.",
                        "规则编辑只修改根目录 .gitattributes，不自动转换或暂存已有文件，保留嵌套规则和其他属性。"))
          .font(.caption).foregroundStyle(.secondary)
        HStack(alignment: .top, spacing: 0) {
          VStack(alignment: .leading, spacing: 8) {
            Text(store.text("Root LFS Rules", "根目录 LFS 规则")).font(.headline)
            List(state.rules) { rule in
              VStack(alignment: .leading, spacing: 4) {
                Text(rule.pattern).lineLimit(2)
                Text(rule.attributes.joined(separator: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
              }.contextMenu {
                Button(store.text("Untrack Pattern…", "取消跟踪规则…")) { reviewRule(rule.pattern, track: false) }
                  .disabled(!state.installed || model.busy)
                Button(store.text("Copy Pattern", "复制规则")) { copyText(rule.pattern) }
              }
            }.listStyle(.inset).frame(maxHeight: 140)
            Text(store.text("All reported rules", "全部已报告规则")).font(.caption.weight(.semibold))
            ScrollView {
              Text(state.trackingSummary.isEmpty ? "—" : state.trackingSummary).font(uiFont(size: 10, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
          }.padding(.trailing, 12).frame(width: 260)
          Divider()
          VStack(alignment: .leading, spacing: 8) {
            Text(store.text("LFS Files", "LFS 文件")).font(.headline)
            List(state.files, selection: $selected) { file in
              HStack {
                VStack(alignment: .leading, spacing: 4) {
                  Text(file.path).lineLimit(2)
                  Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Badge(text: file.workingPointer != nil ? store.text("Pointer", "指针") : file.materialized ? store.text("Content", "内容") : store.text("Missing", "缺失"))
              }.tag(file.path)
            }.listStyle(.inset)
            if let file = state.files.first(where: { $0.path == selected }) {
              Text("sha256:" + file.oid).font(uiFont(size: 10, design: .monospaced)).textSelection(.enabled)
              HStack {
                Text(store.text(file.downloaded ? "Object available locally" : "Object not downloaded", file.downloaded ? "对象已在本地" : "对象尚未下载")).font(.caption).foregroundStyle(.secondary)
                Spacer(); Button(store.text("Copy OID", "复制对象 ID")) { copyText(file.oid) }
              }
            }
          }.padding(.leading, 12).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxHeight: .infinity)
      } else { Spacer() }
    }.padding(18)
      .onAppear { load() }.onDisappear { request.cancel() }
      .onChange(of: model.busy) { _, busy in if !busy { load() } }
      .sheet(isPresented: Binding(get: { ruleReview != nil }, set: { if !$0 { ruleReview = nil } })) {
        if let review = ruleReview { LFSRuleReviewView(model: model, review: review).environmentObject(store) }
      }
      .alert(store.text(networkReview?.action == .pull ? "Download & Materialize LFS Files?" : "Fetch LFS Objects?",
                         networkReview?.action == .pull ? "下载并物化 LFS 文件？" : "获取 LFS 对象？"), isPresented: $confirmingNetwork) {
        Button(store.text("Proceed", "继续")) { executeNetwork() }
        Button(store.text("Cancel", "取消"), role: .cancel) { networkReview = nil }.keyboardShortcut(.defaultAction)
      } message: {
        Text((networkReview?.remoteURL ?? "") + "\nHEAD " + String((networkReview?.operation.head ?? "").prefix(12))
          + "\n\n" + store.text(networkReview?.action == .pull ? "Pull may download many large files and replace LFS pointer files in this working tree. It does not stage or commit changes. Only this repository is affected." : "Fetch downloads objects for the reviewed commit, leaving working files unchanged. Existing Git/SSH/HTTPS credentials and verification are used.",
                               networkReview?.action == .pull ? "拉取可能下载大量大型文件，并在当前工作区替换 LFS 指针文件；不会暂存或提交，只操作此仓库。" : "获取已审查提交的对象，保持工作文件不变，使用现有 Git/SSH/HTTPS 凭据和验证机制。")
        )
      }
  }
  func load() {
    state = nil
    if remote.isEmpty { remote = model.remotes.first(where: { $0.name == "origin" })?.name ?? model.remotes.first?.name ?? "" }
    request.start { ticket in
      let value = try await model.git().lfsState()
      guard request.current(ticket), store.current === model else { return }
      state = value
      if selected == nil || !value.files.contains(where: { $0.path == selected }) { selected = value.files.first?.path }
    }
  }
  func reviewRule(_ pattern: String, track: Bool) {
    request.start { ticket in
      let review = try await model.git().reviewLFSRule(pattern, track: track)
      guard request.current(ticket), store.current === model, !model.busy else { return }; ruleReview = review
    }
  }
  func reviewNetwork(_ action: LFSNetworkAction) {
    let remote = remote
    request.start { ticket in
      let review = try await model.git().reviewLFSNetwork(action, remote: remote)
      guard request.current(ticket), store.current === model, !model.busy else { return }
      networkReview = review; confirmingNetwork = true
    }
  }
  func executeNetwork() {
    guard let review = networkReview, store.current === model, !model.busy else { return }
    networkReview = nil
    model.run(label: store.text(review.action == .pull ? "LFS Pull" : "LFS Fetch", review.action == .pull ? "LFS 拉取" : "LFS 获取")) { git in
      model.output = try await git.performLFSNetwork(review, progress: model.activity.receiver())
    }
  }
}

struct LFSRuleReviewView: View {
  @ObservedObject var model: RepositoryModel
  let review: LFSRuleReview
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @Environment(\.colorScheme) var scheme
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(store.text(review.track ? "Track LFS Pattern" : "Untrack LFS Pattern", review.track ? "跟踪 LFS 规则" : "取消跟踪 LFS 规则")).font(.title2.weight(.semibold))
      Text(review.pattern).font(.headline).textSelection(.enabled)
      Text(store.text("Review the exact .gitattributes change. The Index, other attributes, hooks and existing file contents are preserved. No conversion or commit runs.",
                      "审查准确的 .gitattributes 修改。保留 Index、其他属性、Hooks 和已有文件内容，不执行转换或提交。"))
        .font(.caption).foregroundStyle(.secondary)
      DiffTable(document: review.document, path: ".gitattributes", key: "lfs-rule-" + review.document.revision.uuidString,
                settings: store.settings, dark: scheme == .dark, selectedHunk: 0,
                afterOnly: review.before.isEmpty, beforeTitle: store.text("Before", "修改前"), afterTitle: store.text("After", "修改后"))
      HStack {
        Button(store.text("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer(); Button(store.text("Apply Rule Change", "应用规则修改")) {
          guard store.current === model, !model.busy else { return }; dismiss()
          model.run(label: store.text("Updating LFS Rules", "更新 LFS 规则")) { git in try await git.applyLFSRule(review) }
        }.disabled(model.busy)
      }
    }.padding(20).frame(minWidth: 720, idealWidth: 920, minHeight: 420, idealHeight: 580)
  }
}
