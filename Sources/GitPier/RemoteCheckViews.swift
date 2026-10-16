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
    lines.append(store.text("Next eligible check", "下次允许检查") + ": " + (value.phase == .authenticationRequired ? store.text("Review authentication or retry in Git settings", "请在 Git 设置中检查认证或重试") : date(value.nextEligible)))
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
        AutomaticAuthenticationSettings(workspace: workspace, model: current)
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

struct AutomaticAuthenticationSettings: View {
  @EnvironmentObject var store: AppStore
  @ObservedObject var workspace: WorkspaceModel
  @ObservedObject var model: RepositoryModel
  @State private var confirmation = false
  @State private var authorizationTarget: String?
  @State private var authorizationRepository: UUID?
  @State private var authorizationRemote = ""
  @State private var authorizationIsSSH = false
  private var info: BackgroundAuthentication? { workspace.authenticationInfo(model.record.id) }
  private var state: BackgroundAuthenticationState? { info?.state }
  private var sshPreparation: Bool { state == .sshIdentityNotLoaded || state == .sshAgentUnavailable }
  private var busy: Bool { workspace.authenticationIsBusy(model.record.id) || model.busy }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let target = workspace.entries[model.record.id]?.snapshot?.remoteTarget {
        Text(target.remote.name + " · " + GitService.redact(target.remote.fetchURL))
          .font(.caption).textSelection(.enabled).lineLimit(2)
        if let info {
          Text(info.transport + " · " + source(info.source)).font(.callout)
          Text(status(info.state)).font(.callout).foregroundStyle(info.state == .ready ? Color.secondary : Color.orange)
          if info.state == .ready {
            Text(store.text("Credentials are available locally. Server access is verified only by Fetch.", "本地凭证已就绪；服务器权限仅能由获取结果确认。"))
              .font(.caption).foregroundStyle(.secondary)
          }
        } else {
          Text(store.text("Background authentication has not been checked.", "尚未检查后台认证能力。"))
            .font(.callout).foregroundStyle(.secondary)
        }
        HStack {
          Button(store.text("Retry Automatic Check", "重新检查自动认证")) { workspace.retryAuthentication(model.record.id) }
          if state == .requiresForegroundAuthorization || sshPreparation {
            Button(sshPreparation ? store.text("Prepare SSH Authentication…", "初始化 SSH 认证…") : store.text("Authorize Background Access…", "配置后台认证…")) {
              authorizationTarget = target.id; authorizationRepository = model.record.id
              authorizationRemote = info?.remote ?? target.remote.fetchURL; authorizationIsSSH = sshPreparation
              confirmation = true
            }
          }
          if busy { ProgressView().controlSize(.small) }
        }.disabled(busy)
      }
    }
    .alert(authorizationIsSSH ? store.text("Prepare SSH Authentication", "初始化 SSH 认证") : store.text("Authorize Background Access", "配置后台认证"), isPresented: $confirmation) {
      Button(store.text("Continue", "继续")) {
        guard authorizationRepository == model.record.id,
          workspace.entries[model.record.id]?.snapshot?.remoteTarget?.id == authorizationTarget else {
          store.notice = store.text("The remote changed. Review authentication again.", "远程已变化，请重新审查认证。")
          return
        }
        workspace.retryAuthentication(model.record.id, authorize: !authorizationIsSSH, prepareSSH: authorizationIsSSH)
      }
      Button(store.text("Cancel", "取消"), role: .cancel) {}
    } message: {
      Text(authorizationRemote + "\n\n" + (authorizationIsSSH
        ? store.text("SSH Agent will load this remote's configured identity. macOS may ask for its passphrase. GitPier does not save the passphrase or change SSH configuration. No Fetch is required to prepare it.", "SSH Agent 将加载此远程配置的身份，macOS 可能请求私钥口令。GitPier 不保存口令或修改 SSH 配置，初始化无需先执行获取。")
        : store.text("GitPier will request macOS access to the existing credential for this remote, then verify background access again. No new managed credential is saved and no access controls are changed by GitPier. For legacy items, macOS may offer Always Allow; choosing Allow once may still leave background access blocked.", "GitPier 将请求 macOS 授权访问此远程已有凭证，再验证后台访问能力。不会保存新的托管凭证，也不会自行修改访问控制。传统项目的系统授权窗可能提供“始终允许”；仅选择一次“允许”后后台访问仍可能受阻。")))
    }
  }
  private func source(_ value: String) -> String {
    value.components(separatedBy: " + ").map { source in
      switch source {
      case "managedKeychain": return store.text("GitPier Keychain", "GitPier 钥匙串")
      case "systemKeychain": return store.text("System Keychain", "系统钥匙串")
      case "store": return store.text("Git credential store", "Git 凭证文件")
      case "cache": return store.text("Git credential cache", "Git 凭证缓存")
      case "sshAgent": return store.text("SSH Agent / SSH Config", "SSH Agent / SSH 配置")
      case "sshIdentity": return store.text("SSH Identity / SSH Config", "SSH 身份 / SSH 配置")
      case "sshConfig": return store.text("SSH Config", "SSH 配置")
      case "unsupportedHelper": return store.text("Unsupported helper", "不支持的助手")
      default: return store.text("Source unavailable", "凭证来源尚不可用")
      }
    }.joined(separator: " + ")
  }
  private func status(_ value: BackgroundAuthenticationState) -> String {
    switch value {
    case .ready: return store.text("Ready for Automatic Fetch", "自动获取认证已就绪")
    case .requiresForegroundAuthorization: return store.text("Background access not authorized", "后台访问尚未获准")
    case .credentialMissing: return store.text("No matching saved credential. Configure an account or supported helper.", "未找到匹配凭证，请配置账号或受支持的凭证助手。")
    case .unsupportedHelper: return store.text("This credential helper has no supported silent interface. Use a GitPier account or a supported helper.", "此凭证助手没有受支持的静默接口，请使用 GitPier 账号或受支持的助手。")
    case .sshAgentUnavailable: return store.text("SSH Agent is unavailable. Prepare authentication to start a private agent if needed.", "SSH Agent 不可用，请初始化认证，必要时启动专属 Agent。")
    case .sshIdentityNotLoaded: return store.text("The configured SSH identity is not loaded", "配置的 SSH 身份尚未加载")
    case .accessDenied: return store.text("Authorization was denied or cancelled", "授权被拒绝或已取消")
    case .serverRejected: return store.text("The server rejected the saved credential or SSH identity", "服务器拒绝了已保存凭证或 SSH 身份")
    case .hostVerificationFailed: return store.text("SSH host verification failed. Review known hosts before retrying.", "SSH 主机验证失败，请检查已知主机后重试。")
    case .networkFailure: return store.text("Network check failed; existing backoff applies", "网络检查失败，将遵循现有退避策略")
    case .configurationInvalid:
      if info?.source == "sshConfig" {
        return store.text("SSH configuration contains external commands, a provider or a dynamic Include. Automatic authentication cannot guarantee silent operation; use manual SSH or a static configuration.", "SSH 配置包含外部命令、Provider 或动态 Include，无法保证静默认证；请使用手动 SSH 或静态配置。")
      }
      return store.text("Authentication configuration changed or is unsupported. Review the remote and SSH configuration.", "认证配置已变化或不受支持，请检查远程和 SSH 配置。")
    }
  }
}
