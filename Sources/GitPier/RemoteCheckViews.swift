import GitPierCore
import SwiftUI

@MainActor struct RemoteCheckText {
  let workspace: WorkspaceModel
  let id: UUID
  var store: AppStore { workspace.store }
  var value: RemoteCheckRecord { workspace.remoteCheck(id) }
  var stale: Bool { value.isStale(interval: workspace.remoteInterval(id)) }
  var title: String {
    if let snapshot = workspace.entries[id]?.snapshot, snapshot.upstream == nil { return store.text("No upstream", "无上游") }
    switch value.phase {
    case .notChecked: return store.text("Remote unverified", "远端未确认")
    case .queued: return store.text("Check queued", "等待检查")
    case .checking: return store.text("Checking remote", "正在检查远端")
    case .upToDate: return stale ? store.text("Check overdue", "检查已过期") : store.text("Remote checked", "远端已检查")
    case .referencesUpdated: return stale ? store.text("Check overdue", "检查已过期") : store.text("References updated", "引用已更新")
    case .failed: return store.text("Check failed", "检查失败")
    case .authenticationRequired: return store.text("Authentication required", "需要认证")
    case .skipped: return store.text("Check deferred", "检查已延后")
    }
  }
  var warning: Bool { value.phase == .failed || value.phase == .authenticationRequired }
  var help: String {
    let target = workspace.entries[id]?.snapshot?.remoteTarget
    var lines = [store.text("Remote", "远程") + ": " + (target?.remote.name ?? "—"), title]
    lines.append(store.text("Last successful Fetch", "上次成功获取") + ": " + date(value.lastSuccess))
    lines.append(store.text("Last attempt", "上次尝试") + ": " + date(value.lastAttempt))
    lines.append(store.text("Next eligible check", "下次允许检查") + ": " + (value.phase == .authenticationRequired ? store.text("Manual Fetch required", "需要手动获取") : date(value.nextEligible)))
    lines.append(store.text("Local snapshot", "本地状态") + ": " + date(workspace.entries[id]?.snapshot?.collectedAt))
    if stale { lines.append(store.text("Ahead/Behind uses local tracking references; remote data may be outdated.", "领先/落后根据本地跟踪引用计算，远端数据可能过期。")) }
    if let error = value.diagnostic { lines.append(error) }
    return lines.joined(separator: "\n")
  }
  private func date(_ date: Date?) -> String {
    guard let date else { return store.text("Never", "从未") }
    return date.formatted(.dateTime.locale(Locale(identifier: store.settings.language == .english ? "en" : "zh_CN")).year().month().day().hour().minute().second())
  }
}

struct RepositorySyncStatus: View {
  @EnvironmentObject var store: AppStore
  let entry: WorkspaceEntry
  @ObservedObject var workspace: WorkspaceModel
  var body: some View {
    let check = RemoteCheckText(workspace: workspace, id: entry.record.id)
    VStack(alignment: .leading, spacing: 4) {
      if let value = entry.usable {
        if value.upstream == nil { Text(store.text("No upstream", "无上游")) }
        else if !value.upstreamComparable { Text(store.text("Upstream unavailable", "上游引用不可用")) }
        else if value.ahead == 0 && value.behind == 0 {
          // A successful custom/manual fetch need not cover every upstream ref. Keep this
          // branch comparison literal; the separate line reports remote-check freshness.
          Text(store.text("Tracking refs match", "跟踪引用一致"))
        } else {
          HStack(spacing: 6) {
            if value.ahead > 0 { Text("↑\(value.ahead)").foregroundStyle(Color.accentColor) }
            if value.behind > 0 { Text("↓\(value.behind)").foregroundStyle(.orange) }
          }.monospacedDigit()
        }
        if value.upstream != nil {
          if value.ahead > 0 && value.behind > 0 { Text(store.text("Diverged", "已分叉")).foregroundStyle(.orange) }
          else {
            HStack(spacing: 4) {
              if check.value.phase == .checking { ProgressView().controlSize(.mini) }
              if check.warning { Image(systemName: "exclamationmark.triangle") }
              Text(check.title).lineLimit(1)
            }.font(uiFont(size: 10)).foregroundStyle(check.warning ? .orange : .secondary)
          }
        }
      } else { Text("—") }
    }.font(uiFont(size: 12)).foregroundStyle(.secondary).help(check.help)
  }
}

struct RepositoryNetworkToolbar: View {
  @EnvironmentObject var store: AppStore
  @ObservedObject var model: RepositoryModel
  @ObservedObject var workspace: WorkspaceModel
  var body: some View {
    let check = RemoteCheckText(workspace: workspace, id: model.record.id)
    HStack(spacing: 12) {
      Button { model.network("fetch") } label: {
        HStack(spacing: 4) {
          if model.networkFetching || check.value.phase == .checking || check.value.phase == .queued { ProgressView().controlSize(.mini) }
          else { Image(systemName: check.warning ? "exclamationmark.triangle" : check.stale ? "clock.arrow.circlepath" : "arrow.down.to.line") }
          Text(store.text("Fetch", "获取"))
        }
      }.accessibilityLabel(store.text("Fetch", "获取")).accessibilityValue(model.networkFetching ? store.text("Fetching", "正在获取") : check.title).help(check.help)
      Button { model.network("pull") } label: {
        Label(store.text("Pull", "拉取") + (model.status.behind > 0 ? " ↓\(model.status.behind)" : ""),
          systemImage: diverged ? "arrow.triangle.branch" : "arrow.down")
          .foregroundStyle(model.status.behind > 0 ? Color.orange : .primary)
      }.help(trackingHelp + "\n" + check.help)
      Button {
        if model.status.upstream == nil { model.needsUpstream = true }
        else { model.network("push") }
      } label: {
        Label(store.text("Push", "推送") + (model.status.ahead > 0 ? " ↑\(model.status.ahead)" : ""),
          systemImage: diverged ? "arrow.triangle.branch" : "arrow.up")
          .foregroundStyle(diverged ? Color.orange : model.status.ahead > 0 ? Color.accentColor : .primary)
      }.disabled(model.status.operation != nil || model.status.files.contains(where: \.isConflicted))
        .help(trackingHelp + "\n" + check.help)
    }.font(uiFont(size: 11)).buttonStyle(.plain).disabled(model.busy || !model.available)
  }
  private var diverged: Bool { model.status.ahead > 0 && model.status.behind > 0 }
  private var trackingHelp: String {
    if model.status.upstream == nil { return store.text("No upstream. Configure a remote branch before synchronizing.", "无上游，请配置远程分支后同步。") }
    if !model.status.upstreamComparable { return store.text("Upstream tracking reference unavailable. Fetch manually to check configuration.", "上游跟踪引用不可用，请手动获取并检查配置。") }
    if diverged { return store.text("Branch diverged. Remote commits must be integrated before a normal Push.", "分支已分叉，普通推送前需要整合远程提交。") }
    return store.text("\(model.status.ahead) ahead · \(model.status.behind) behind upstream", "相对上游领先 \(model.status.ahead) · 落后 \(model.status.behind)")
  }
}

struct AutomaticRemoteCheckSettings: View {
  @EnvironmentObject var store: AppStore
  @ObservedObject var workspace: WorkspaceModel
  var body: some View {
    Section(store.text("Automatic Remote Checks", "自动远程检查")) {
      Toggle(store.text("Automatic Fetch", "自动获取"), isOn: setting(\.automaticFetch))
      Text(store.text("Enabling connects to configured remote servers while GitPier is active. Fetch updates tracking references only; it never merges, pushes or changes working files.", "启用后，GitPier 活动期间会自动连接已配置的远程服务器。仅更新远程跟踪引用，不自动合并、推送或修改工作文件。"))
        .font(.callout).foregroundStyle(.secondary)
      Picker(store.text("Current Repository Interval", "当前仓库检查间隔"), selection: setting(\.remoteCheckIntervalMinutes)) {
        ForEach(RemoteCheckPolicy.intervals, id: \.self) { minutes in Text(store.text("\(minutes) minutes", "\(minutes) 分钟")).tag(minutes) }
      }
      Picker(store.text("Fetch Scope", "获取范围"), selection: setting(\.remoteCheckScope)) {
        Text(store.text("Current repository only", "仅当前仓库")).tag("current")
        Text(store.text("Current + workspace (others: 45 min)", "当前及工作空间（其他：45 分钟）")).tag("workspace")
      }
      if let current = store.current {
        Toggle(store.text("Include current repository", "包含当前仓库"), isOn: Binding(get: {
          !store.settings.remoteCheckExcludedRepositories.contains(current.record.id)
        }, set: { included in
          var settings = store.settings
          if included { settings.remoteCheckExcludedRepositories.remove(current.record.id) }
          else { settings.remoteCheckExcludedRepositories.insert(current.record.id) }
          store.updateSettings(settings)
        }))
        LabeledContent(store.text("Last Remote Check", "最近远程检查"), value: workspace.remoteCheck(current.record.id).lastSuccess?.formatted(date: .abbreviated, time: .shortened) ?? store.text("Never", "从未"))
          .help(RemoteCheckText(workspace: workspace, id: current.record.id).help)
        Button(store.text("Fetch Manually", "手动获取")) { current.network("fetch") }.disabled(current.busy)
      }
      if let error = workspace.remoteMetadataError { Text(error).foregroundStyle(.orange) }
    }
  }
  private func setting<T>(_ key: WritableKeyPath<AppSettings, T>) -> Binding<T> {
    Binding(get: { store.settings[keyPath: key] }, set: { value in
      var settings = store.settings; settings[keyPath: key] = value; store.updateSettings(settings)
    })
  }
}
