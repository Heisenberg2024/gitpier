import GitPierCore
import SwiftUI

struct RepositoryAuthenticationSection: View {
  @ObservedObject var model: RepositoryModel
  @ObservedObject var workspace: WorkspaceModel
  @EnvironmentObject var store: AppStore
  @State private var selectedRemote: String?
  @State private var connection: ConnectionResult?
  @State private var request: UUID?
  @State private var testTask: Task<Void, Never>?

  private enum ConnectionResult { case readable, failed(String) }
  private var remote: GitRemote? {
    model.remotes.first { $0.name == selectedRemote }
      ?? model.remotes.first { $0.name == workspace.entries[model.record.id]?.snapshot?.remoteTarget?.remote.name }
      ?? model.remotes.first
  }
  private var mode: Binding<String> {
    Binding(get: { model.record.credentialID?.uuidString ?? (model.record.useDefaultCredential ? "default" : "system") },
      set: { value in
        guard !model.busy else { return }
        model.record.useDefaultCredential = value == "default"
        model.record.credentialID = UUID(uuidString: value)
        store.update(model.record)
        Task { await model.configure() }
      })
  }
  var body: some View {
    let binding = model.credentialBinding
    Section(store.text("Remote Authentication", "远程认证")) {
      Picker(store.text("Authentication source", "认证来源"), selection: mode) {
        Text(store.text("System Git / SSH", "系统 Git / SSH")).tag("system")
        Text(store.text("GitPier Default", "GitPier 默认凭证")).tag("default")
        ForEach(store.configuration.credentials) { profile in
          Text(store.text("GitPier: \(profile.name)", "GitPier：\(profile.name)")).tag(profile.id.uuidString)
        }
        if binding.missingProfile, binding.source == .repository, let id = binding.profileID {
          Text(store.text("Unavailable GitPier Credential", "GitPier 凭证不可用")).tag(id.uuidString)
        }
      }.disabled(model.busy || request != nil)
        .accessibilityIdentifier("gitpier.repository.authentication.source")
      Text(sourceDetail(binding)).font(.callout)
        .foregroundStyle(binding.missingProfile ? Color.orange : .secondary)
      if let remote {
        if model.remotes.count > 1 {
          Picker(store.text("Remote", "远程"), selection: Binding(get: { remote.name }, set: { selectedRemote = $0 })) {
            ForEach(model.remotes) { Text($0.name).tag($0.name) }
          }.disabled(request != nil)
        }
        LabeledContent(store.text("Fetch destination", "获取目标"), value: destination(remote.fetchURL))
        if remote.pushURL != remote.fetchURL {
          LabeledContent(store.text("Push destination", "推送目标"), value: destination(remote.pushURL))
        }
        if workspace.entries[model.record.id]?.snapshot?.remoteTarget?.remote.name == remote.name {
          let check = RemoteCheckText(workspace: workspace, id: model.record.id)
          LabeledContent(store.text("Last remote check", "上次远程检查"), value: check.title).help(check.help)
        }
        HStack {
          Button(store.text("Test Fetch Connection", "测试获取连接")) { test(remote, binding: binding) }
            .disabled(model.busy || request != nil || binding.missingProfile)
            .accessibilityIdentifier("gitpier.repository.authentication.test")
          if request != nil { ProgressView().controlSize(.small).accessibilityLabel(store.text("Testing connection", "正在测试连接")) }
          Button(store.text("Manage GitPier Credentials…", "管理 GitPier 凭证…")) { store.showCredentials = true }
        }
        if let connection {
          switch connection {
          case .readable:
            Label(store.text("Remote references are readable. Public access may not require credentials.",
              "可以读取远端引用。公开仓库可能无需凭证。"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
          case .failed(let detail):
            Label(store.text("Connection failed", "连接失败"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            OperationDiagnosticView(detail: detail)
          }
        }
      } else {
        Text(store.text("No remote is configured for this repository.", "此仓库尚未配置远程。")).foregroundStyle(.secondary)
      }
      Text(store.text("Git transport authentication is separate from commit authorship and Code Hosting API accounts.",
        "Git 远程认证独立于提交作者身份和代码托管 API 账号。")).font(.caption).foregroundStyle(.secondary)
    }
    .onChange(of: binding) { _, _ in reset() }
    .onChange(of: remote) { _, _ in reset() }
    .onChange(of: store.settings.gitPath) { _, _ in reset() }
    .onDisappear { reset() }
  }

  private func sourceDetail(_ binding: GitCredentialBinding) -> String {
    if binding.missingProfile {
      return store.text("The selected profile is missing. Choose another profile or System Git / SSH before using this remote.",
        "所选凭证已不存在。使用远程前，请更换凭证或选择系统 Git / SSH。")
    }
    if let profile = binding.profile {
      let kind = profile.kind == .https ? store.text("HTTPS token", "HTTPS Token") : store.text("SSH identity", "SSH 身份")
      return store.text("Configured: \(profile.name) · \(kind). Test the connection to check remote access.",
        "已配置：\(profile.name) · \(kind)。可测试连接来核查远端访问。")
    }
    if binding.source == .workspaceDefault {
      return store.text("No GitPier default is set. Git uses your system helpers and SSH configuration.",
        "未设置 GitPier 默认凭证。Git 会使用系统凭证助手和 SSH 配置。")
    }
    return store.text("Uses your Git helpers and SSH configuration. No GitPier credential is required.",
      "使用现有 Git 凭证助手和 SSH 配置，无需另建 GitPier 凭证。")
  }

  private func destination(_ url: String) -> String {
    let transport = BackgroundAuthentication.transport(for: url)
    if let parsed = URLComponents(string: url), let host = parsed.host, !host.isEmpty {
      return "\(transport) · \(host)" + (parsed.port.map { ":\($0)" } ?? "")
    }
    if transport == "SSH", let endpoint = url.split(separator: "@", maxSplits: 1).last {
      if endpoint.hasPrefix("["), let end = endpoint.firstIndex(of: "]") { return "SSH · " + endpoint[...end] }
      if let host = endpoint.split(separator: ":", maxSplits: 1).first { return "SSH · " + host }
    }
    return transport == "Local" || transport == "FILE" ? store.text("Local repository", "本地仓库") : transport
  }

  private func reset() {
    testTask?.cancel(); testTask = nil; request = nil; connection = nil
  }

  private func test(_ remote: GitRemote, binding: GitCredentialBinding) {
    guard request == nil, !model.busy else { return }
    let id = UUID(), record = model.record
    request = id; connection = nil
    testTask = Task { @MainActor in
      let result: ConnectionResult
      do {
        guard await model.configure(reportErrors: false) else { throw AuthenticationFailure(.configurationInvalid) }
        let git = await model.git()
        let targets = try await git.reviewWorkspaceFetch(record)
        guard let target = targets.first(where: { $0.remote == remote }), model.credentialBinding == binding,
          model.record.path == record.path, !model.busy, !Task.isCancelled else { throw AuthenticationFailure(.configurationInvalid) }
        try await git.testFetchConnection(target)
        result = .readable
      } catch { result = .failed(GitService.redact(localizedUI(error.localizedDescription))) }
      guard request == id, !Task.isCancelled else { return }
      request = nil; testTask = nil
      guard model.credentialBinding == binding, model.record.path == record.path, self.remote == remote else { return }
      connection = result
    }
  }
}
