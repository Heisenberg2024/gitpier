import GitPierCore
import SwiftUI

struct BranchComparisonView: View {
  @ObservedObject var model: RepositoryModel
  @EnvironmentObject var store: AppStore
  @Environment(\.colorScheme) private var scheme
  @StateObject private var request = WorkflowRequest()
  @StateObject private var patchRequest = WorkflowRequest()
  @StateObject private var commitRequest = WorkflowRequest()
  @StateObject private var moreRequest = WorkflowRequest()
  @State private var left = ""
  @State private var right = ""
  @State private var reviewedTitles: [String: String] = [:]
  @State private var reviewedTargets: [String: BranchComparisonTarget] = [:]
  @State private var reviewedRequestID: UUID?
  @State private var mode = BranchComparisonMode.tips
  @State private var result: BranchComparisonResult?
  @State private var leftCommits: [CommitRecord] = []
  @State private var rightCommits: [CommitRecord] = []
  @State private var selected: String?
  @State private var document = DiffDocument.empty
  @State private var large = false
  @State private var commit: CommitRecord?
  private var queryID: String { left + "\0" + right + "\0" + mode.rawValue + "\0" + (reviewedRequestID?.uuidString ?? "") }
  var body: some View {
    comparisonContent.onAppear(perform: prepareAppearance)
      .onChange(of: model.workflowComparison?.id) { _, _ in consumeWorkflowRequest() }
      .task(id: queryID) { load() }
      .task(id: patchID) { loadPatch() }
      .onDisappear { cancelRequests() }
      .sheet(item: $commit) { WorkflowCommitSheet(model: model, commit: $0).environmentObject(store) }
  }
  private var patchID: String { (result?.diffBase ?? "") + "\0" + (result?.rightHash ?? "") + "\0" + (selected ?? "") }
  private func cancelRequests() { request.cancel(); patchRequest.cancel(); commitRequest.cancel(); moreRequest.cancel() }
  private var comparisonContent: some View {
    GeometryReader { area in
      VStack(spacing: 0) {
        HostingLocalComparisonExplanation().padding(.horizontal, 12).padding(.top, 10)
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            Text(store.text("Compare Branches", "比较分支")).font(.headline)
            branchPicker(store.text("Left", "左侧"), selection: $left)
            Button { swap(&left, &right) } label: { Image(systemName: "arrow.left.arrow.right") }
            branchPicker(store.text("Right", "右侧"), selection: $right)
            Picker(store.text("Comparison", "比较方式"), selection: $mode) {
              Text(store.text("Tips (A → B)", "分支末端（A → B）")).tag(BranchComparisonMode.tips)
              Text(store.text("Merge base (A…B)", "共同祖先（A…B）")).tag(BranchComparisonMode.mergeBase)
            }.frame(width: 215)
            Button(store.text("Refresh", "刷新")) { load() }
          }.padding(12)
        }
        Text(mode == .tips ? store.text("Direct comparison: left tip → right tip. Counts show commits unique to each branch.", "直接比较：左侧末端 → 右侧末端。数量表示各分支独有提交。") : store.text("Three-point comparison: merge base → right tip. Counts still describe both branch tips.", "三点比较：共同祖先 → 右侧末端。提交数量仍描述两个分支末端。"))
          .font(uiFont(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 8)
        if let result {
          VStack(alignment: .leading, spacing: 4) {
            Text(store.text("Left ahead / behind: ", "左侧领先 / 落后：") + "\(result.leftOnlyCount) / \(result.rightOnlyCount)   ·   " + String(result.leftHash.prefix(8)) + " → " + String(result.rightHash.prefix(8)))
              .accessibilityIdentifier("gitpier.comparison.counts")
            Text(store.text("Merge base: ", "共同祖先：") + (result.mergeBases.isEmpty ? store.text("None (unrelated histories)", "无（不相关历史）") : result.mergeBases.joined(separator: ", "))).textSelection(.enabled).lineLimit(2)
          }.font(uiFont(size: 11)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 10)
        }
        Divider()
        WorkflowProblem(request: request)
        WorkflowProblem(request: commitRequest)
        WorkflowProblem(request: moreRequest)
        if let result {
          HStack(alignment: .top, spacing: 0) {
            exclusiveList(leftCommits, total: result.leftOnlyCount, isLeft: true)
            Divider()
            exclusiveList(rightCommits, total: result.rightOnlyCount, isLeft: false)
          }.frame(height: min(170, area.size.height * 0.25))
          Divider()
          HStack(spacing: 0) {
            List(result.files, selection: $selected) { file in
              Label(file.path, systemImage: "doc.text").font(uiFont(size: 11)).lineLimit(1).tag(file.path)
            }.listStyle(.plain).frame(width: min(260, area.size.width * 0.3))
            Divider()
            VStack(spacing: 0) {
              WorkflowProblem(request: patchRequest)
              if large { Text(store.text("Diff exceeds the display limit (2 MiB / 20,000 rows).", "Diff 超过显示上限（2 MiB / 20,000 行）。")).padding() }
              else if selected == nil { EmptyState(symbol: "doc.text", title: store.text("No changed files", "没有变更文件"), detail: "") }
              else if document.binary { EmptyState(symbol: "doc.richtext", title: store.text("Binary changes", "二进制变更"), detail: "") }
              else if !patchRequest.loading && patchRequest.problem == nil {
                DiffTable(document: document, path: selected ?? "", key: model.record.id.uuidString + result.diffBase + result.rightHash + (selected ?? ""), settings: store.settings, dark: scheme == .dark, selectedHunk: 0, indexSide: 0, afterOnly: !document.hasOldContent,
                  beforeTitle: String(result.diffBase.prefix(8)), afterTitle: String(result.rightHash.prefix(8))).equatable()
              }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        } else if !request.loading && request.problem == nil {
          EmptyState(symbol: "arrow.left.arrow.right", title: store.text("Select two branches", "选择两个分支"), detail: "")
        }
      }
    }
  }
  private func prepareAppearance() {
    consumeWorkflowRequest()
    if left.isEmpty { left = model.branches.first { $0.current && !$0.remote }?.reference ?? model.branches.first?.reference ?? "" }
    if right.isEmpty { right = model.comparisonRight ?? model.branches.first { $0.reference != left && !$0.name.hasSuffix("/HEAD") }?.reference ?? left }
    model.comparisonRight = nil
  }
  private func consumeWorkflowRequest() {
    guard let value = model.workflowComparison else { return }
    model.workflowComparison = nil
    reviewedTitles = [value.left: value.leftTitle]
    reviewedTitles[value.right] = value.rightTitle
    reviewedTargets = value.targets
    reviewedRequestID = value.id
    left = value.left; right = value.right; mode = value.mode
  }
  private func branchPicker(_ title: String, selection: Binding<String>) -> some View {
    Picker(title, selection: selection) {
      Text(store.text("Select", "选择")).tag("")
      ForEach(reviewedTitles.keys.sorted(), id: \.self) { hash in
        Text((reviewedTitles[hash] ?? "") + (hash.hasPrefix("upstream:") ? store.text(" · tracking snapshot", " · 跟踪快照") : " · " + String(hash.prefix(8)))).tag(hash)
      }
      ForEach(model.branches.filter { !$0.name.hasSuffix("/HEAD") }) { Text(($0.remote ? store.text("Remote: ", "远程：") : store.text("Local: ", "本地：")) + $0.name).tag($0.reference) }
    }.frame(width: 220)
  }
  private func exclusiveList(_ commits: [CommitRecord], total: Int, isLeft: Bool) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(isLeft ? store.text("Only on left (\(total))", "仅左侧（\(total)）") : store.text("Only on right (\(total))", "仅右侧（\(total)）")).font(uiFont(size: 11, weight: .semibold)).padding(8)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 5) {
          ForEach(commits) { record in
            Button { commit = record } label: { Text(String(record.hash.prefix(8)) + "  " + record.subject).font(uiFont(size: 11)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
          }
          if commits.count < total { Button(store.text("Load more commits", "加载更多提交")) { loadMore(isLeft) }.disabled(moreRequest.loading) }
        }.padding(.horizontal, 8).padding(.bottom, 8)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func load() {
    request.cancel(); patchRequest.cancel(); moreRequest.cancel(); document = .empty; selected = nil; result = nil; leftCommits = []; rightCommits = []
    guard !left.isEmpty, !right.isEmpty else { return }
    let a = left, b = right, requestedMode = mode
    let generation = reviewedRequestID
    let leftTarget = reviewedTargets[a] ?? .branch(a), rightTarget = reviewedTargets[b] ?? .branch(b)
    request.start { ticket in
      let comparison = try await model.git().compareBranchTargets(left: leftTarget, right: rightTarget, mode: requestedMode)
      guard request.current(ticket), reviewedRequestID == generation, left == a, right == b, mode == requestedMode else { return }
      result = comparison; leftCommits = comparison.leftOnly; rightCommits = comparison.rightOnly; selected = comparison.files.first?.path
    }
  }
  private func loadPatch() {
    document = .empty; large = false
    guard let result, let path = selected else { patchRequest.cancel(); return }
    patchRequest.start { ticket in
      let data = try await model.git().commitPatch(result.rightHash, path: path, parent: result.diffBase, localOnly: true)
      let oversized = data.count > 2 * 1024 * 1024 || data.reduce(into: 0) { if $1 == 10 { $0 += 1 } } > 40000
      let parsed = await Task.detached { oversized ? DiffDocument.empty : DiffParser.parse(data) }.value
      guard patchRequest.current(ticket), selected == path, self.result?.diffBase == result.diffBase, self.result?.rightHash == result.rightHash else { return }
      large = oversized || parsed.pairs.count > 20000; document = parsed
    }
  }
  private func loadMore(_ isLeft: Bool) {
    guard let result else { return }
    let skip = isLeft ? leftCommits.count : rightCommits.count
    moreRequest.start { ticket in
      let records = try await model.git().comparisonCommits(base: isLeft ? result.rightHash : result.leftHash, tip: isLeft ? result.leftHash : result.rightHash, skip: skip, localOnly: true)
      guard moreRequest.current(ticket), self.result?.leftHash == result.leftHash, self.result?.rightHash == result.rightHash else { return }
      if isLeft { leftCommits += records } else { rightCommits += records }
    }
  }
}
