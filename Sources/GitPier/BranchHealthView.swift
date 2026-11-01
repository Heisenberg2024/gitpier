import GitPierCore
import SwiftUI

@MainActor final class BranchHealthReader: ObservableObject {
  @Published private(set) var snapshot: BranchHealthSnapshot?
  @Published private(set) var byReference: [String: BranchHealth] = [:]
  let request = WorkflowRequest()
  private var key: String?
  @Published private(set) var analyzedTarget: String?
  func cancelAnalysis() { request.cancel(); key = nil; analyzedTarget = nil }
  func invalidate() { cancelAnalysis(); snapshot = nil; byReference = [:] }
  func load(_ model: RepositoryModel, target: String, force: Bool = false) {
    let store = model.store, selection = model.store.selectionIdentity, page = model.pageIdentity
    let path = model.record.path, executable = store.settings.gitPath
    let observedStatus = model.status, observedBranches = model.branches, refresh = model.refreshCount
    let branchKeys = observedBranches.map { branch in
      [branch.reference, branch.hash, branch.upstream, branch.tracking].joined(separator: ":")
    }
    let keyParts: [String] = [selection.uuidString, page.uuidString, path, executable, target,
      observedStatus.branch, observedStatus.head ?? "", String(refresh),
      observedStatus.operation?.rawValue ?? "", branchKeys.joined(separator: "\0")]
    let nextKey = keyParts.joined(separator: "\0")
    if !force, key == nextKey, request.loading || snapshot != nil { return }
    key = nextKey
    snapshot = nil; byReference = [:]; analyzedTarget = nil
    request.start { ticket in
      let value = try await model.git().branchHealth(mergedInto: target.isEmpty ? nil : target, record: model.record)
      guard self.request.current(ticket), store.current === model, store.selectionIdentity == selection,
        model.pageIdentity == page, model.record.path == path, store.settings.gitPath == executable,
        model.refreshCount == refresh, !model.hasExternalChanges else { return }
      guard Set(value.branches.map(\.reference)).count == value.branches.count else {
        throw GitPierError.invalidInput("Branch reference names are ambiguous. Inspect the refs in the repository terminal.")
      }
      let locals = observedBranches.filter { !$0.remote }
      guard Set(locals.map(\.reference)).count == locals.count else { throw GitPierError.indexChanged }
      let localByReference = Dictionary(uniqueKeysWithValues: locals.map { ($0.reference, $0) })
      guard model.status == observedStatus, model.branches == observedBranches,
        value.head == observedStatus.head, (value.currentBranch ?? "(detached)") == observedStatus.branch,
        value.operation == observedStatus.operation, value.branches.count == locals.count,
        value.branches.allSatisfy({ health in
          guard let branch = localByReference[health.reference] else { return false }
          return branch.hash == health.hash && branch.current == health.current
            && branch.upstream == health.upstreamShort && branch.tracking == health.tracking
        }) else {
        throw GitPierError.invalidInput("The branch list changed. Refresh the repository before analyzing branch health.")
      }
      self.byReference = Dictionary(uniqueKeysWithValues: value.branches.map { ($0.reference, $0) })
      self.snapshot = value
      self.analyzedTarget = value.targetReference
    }
  }
}

struct BranchHealthPanel: View {
  @ObservedObject var model: RepositoryModel
  @ObservedObject var health: BranchHealthReader
  @ObservedObject var request: WorkflowRequest
  @Binding var target: String
  @EnvironmentObject var store: AppStore
  init(model: RepositoryModel, health: BranchHealthReader, target: Binding<String>) {
    self.model = model; self.health = health; request = health.request; _target = target
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      header
      WorkflowProblem(request: request)
      if !target.isEmpty && !localTargets.contains(target) {
        Text(store.text("The merge target no longer exists. Choose an existing local branch and analyze again.",
          "合并目标已不存在，请选择已有本地分支并重新分析。")).font(.caption).foregroundStyle(.orange)
      }
      provenance
      Text(store.text("No server contact. Sync compares local tracking references. Select a target and Analyze to check ancestry; inactivity does not establish that deletion is safe.",
        "未联系服务器。同步状态比较本地跟踪引用。选择目标并分析可检查祖先关系；长期未活动不代表可以安全删除。"))
        .font(.caption).foregroundStyle(.secondary)
    }.padding(.horizontal, 18).padding(.vertical, 10)
  }
  private var header: some View {
    HStack {
      Text(store.text("Branch Health", "分支健康")).font(.callout.weight(.semibold))
      if request.loading { ProgressView().controlSize(.small) }
      if let snapshot = health.snapshot {
        if snapshot.detached { Text(store.text("Detached HEAD", "分离 HEAD")).foregroundStyle(.orange) }
        if let operation = snapshot.operation { Text(operation == .cherryPick ? "Cherry-pick" : operation.rawValue.capitalized).foregroundStyle(.orange) }
      }
      Spacer()
      Picker(store.text("Merge target", "合并目标"), selection: $target) {
        Text(store.text("Choose a local branch…", "请选择本地分支…")).tag("")
        if !target.isEmpty && !localTargets.contains(target) {
          Text(store.text("Missing: ", "引用缺失：") + target).tag(target)
        }
        ForEach(localTargets, id: \.self) { reference in
          Text(String(reference.dropFirst("refs/heads/".count))).tag(reference)
        }
      }.frame(maxWidth: 310).accessibilityIdentifier("health.target")
        .onChange(of: target) { _, _ in health.cancelAnalysis() }
      Button(store.text("Analyze", "分析")) { health.load(model, target: target, force: true) }.disabled(model.busy || request.loading || target.isEmpty || !localTargets.contains(target))
        .accessibilityIdentifier("health.analyze")
    }
  }
  @ViewBuilder private var provenance: some View {
    if let value = health.snapshot {
      Text(provenanceText(value))
        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      if let reference = health.analyzedTarget, let hash = value.targetHash {
        Text(store.text("Merged status compares to ", "已合并状态比较目标：") + reference + " · " + hash)
          .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
      }
      if value.shallow {
        Text(store.text("Shallow history: unproven ancestry is Unknown.", "浅克隆历史：无法证明的祖先关系显示未知。")).font(.caption).foregroundStyle(.orange)
      }
    }
  }
  private func provenanceText(_ value: BranchHealthSnapshot) -> String {
    let fetched = fetchDate(value).map(formattedDate) ?? store.text("Unknown", "未知")
    let parts: [String] = [store.text("Local references · observed ", "本地引用 · 观察时间 "), formattedDate(value.collectedAt),
      " · ", store.text("Last app Fetch for current remote", "当前远程上次应用获取"), " ", value.fetchRemoteName ?? "", ": ", fetched]
    return parts.joined()
  }
  private var localTargets: [String] { model.branches.filter { !$0.remote }.map(\.reference) }
  private func formattedDate(_ date: Date) -> String {
    date.formatted(.dateTime.locale(Locale(identifier: store.settings.language == .english ? "en" : "zh_CN"))
      .year().month().day().hour().minute().second())
  }
  private func fetchDate(_ value: BranchHealthSnapshot) -> Date? {
    guard let targetID = value.fetchTargetID,
      let workspace = store.workspace.entries[model.record.id]?.usable,
      workspace.branch == (value.currentBranch ?? "(detached)"),
      workspace.remoteTarget?.id == targetID else { return nil }
    return store.workspace.remoteCheck(model.record.id).lastSuccess
  }
}

/// Shared sync visuals for branch rows, Dashboard and Context Workflow.
/// Colors describe local tracking relationships, never workflow risk or Fetch freshness.
@MainActor struct BranchSyncPresentation {
  let state: BranchSyncState
  let store: AppStore
  var title: String {
    switch state {
    case .synced: return store.text("Synced", "已同步")
    case .ahead: return store.text("Ahead", "领先")
    case .behind: return store.text("Behind", "落后")
    case .diverged: return store.text("Diverged", "已分叉")
    case .noUpstream: return store.text("No upstream", "未设置上游")
    case .unknown: return store.text("Unknown", "状态未知")
    }
  }
  var symbol: String {
    switch state {
    case .synced: return "checkmark.circle"
    case .ahead: return "arrow.up.circle"
    case .behind: return "arrow.down.circle"
    case .diverged: return "arrow.triangle.branch"
    case .noUpstream: return "link.badge.plus"
    case .unknown: return "questionmark.circle"
    }
  }
  var counts: String? {
    switch state {
    case .ahead(let count): return "↑\(count)"
    case .behind(let count): return "↓\(count)"
    case .diverged(let ahead, let behind): return "↑\(ahead) ↓\(behind)"
    default: return nil
    }
  }
  var accessibleText: String {
    switch state {
    case .ahead(let count): return store.text("Ahead by \(count) commits", "领先 \(count) 个提交")
    case .behind(let count): return store.text("Behind by \(count) commits", "落后 \(count) 个提交")
    case .diverged(let ahead, let behind): return store.text("Diverged, \(ahead) ahead and \(behind) behind", "已分叉，领先 \(ahead)、落后 \(behind) 个提交")
    default: return title
    }
  }
  var color: Color {
    switch state {
    case .synced: return .green
    case .ahead: return .primary
    case .behind: return .blue
    case .diverged: return .orange
    case .noUpstream, .unknown: return .secondary
    }
  }
  // Toolbar arrows describe actions; tint only when the corresponding commits exist.
  var incomingColor: Color {
    switch state { case .behind, .diverged: return color; default: return .primary }
  }
  var outgoingColor: Color {
    switch state { case .ahead, .diverged: return color; default: return .primary }
  }
}

struct BranchSyncBadge: View {
  let state: BranchSyncState
  var stacked = false
  @EnvironmentObject var store: AppStore
  private var display: BranchSyncPresentation { BranchSyncPresentation(state: state, store: store) }
  var body: some View {
    Group {
      if stacked {
        VStack(alignment: .leading, spacing: 3) {
          statusLabel
          if let counts = display.counts { Text(counts).padding(.leading, 16) }
        }
      } else {
        HStack(spacing: 5) { statusLabel; if let counts = display.counts { Text(counts) } }
      }
    }.font(.caption).monospacedDigit().fixedSize(horizontal: !stacked, vertical: true)
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .ignore).accessibilityLabel(display.accessibleText)
      .accessibilityIdentifier("health.sync." + display.symbol)
      .help(display.accessibleText + " · " + store.text("Local tracking references; not live server state", "本地跟踪引用，不代表服务器实时状态"))
  }
  private var statusLabel: some View {
    Label { Text(display.title) } icon: {
      Image(systemName: display.symbol).symbolRenderingMode(.monochrome)
        .foregroundStyle(display.color).accessibilityHidden(true)
    }
  }
}

/// Commit containment is independent of the upstream comparison above.
@MainActor struct BranchMergePresentation {
  let merged: Bool?
  let targetReference: String?
  let store: AppStore
  var title: String {
    guard let targetReference else { return store.text("Merge not analyzed", "合并关系未分析") }
    let name = String(targetReference.dropFirst("refs/heads/".count))
    guard let merged else { return store.text("Merge unknown → ", "合并关系未知 → ") + name }
    return (merged ? store.text("Merged into ", "已合并至 ") : store.text("Not merged into ", "未合并至 ")) + name
  }
  var symbol: String {
    guard targetReference != nil else { return "circle.dashed" }
    switch merged {
    case .some(true): return "arrow.triangle.merge"
    case .some(false): return "arrow.triangle.branch"
    case .none: return "questionmark.circle"
    }
  }
  var color: Color { targetReference != nil && merged == true ? .green : .secondary }
}

struct BranchHealthBadge: View {
  let value: BranchHealth
  let collectedAt: Date
  var targetReference: String?
  @EnvironmentObject var store: AppStore
  private var merge: BranchMergePresentation {
    BranchMergePresentation(merged: value.mergedIntoTarget, targetReference: targetReference, store: store)
  }
  var body: some View {
    VStack(alignment: .trailing, spacing: 4) {
      BranchSyncBadge(state: value.syncState)
      Label { Text(merge.title) } icon: {
        Image(systemName: merge.symbol).symbolRenderingMode(.monochrome)
          .foregroundStyle(merge.color).accessibilityHidden(true)
      }.lineLimit(1).truncationMode(.middle).frame(maxWidth: 250, alignment: .trailing)
        .help(merge.title).accessibilityElement(children: .ignore).accessibilityLabel(merge.title)
        .accessibilityIdentifier("health.merge." + merge.symbol)
      HStack(spacing: 8) {
        if value.inactive(asOf: collectedAt) { Text(store.text("Inactive 90d", "90 天未活动")) }
        if !value.worktreePaths.isEmpty { Label("\(value.worktreePaths.count)", systemImage: "folder.badge.gearshape").help(value.worktreePaths.joined(separator: "\n")) }
        if let date = value.lastCommit {
          Text(date, style: .date).environment(\.locale, Locale(identifier: store.settings.language == .english ? "en" : "zh_CN"))
        }
      }
    }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: true, vertical: false)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("health.branch." + value.name)
  }
}
