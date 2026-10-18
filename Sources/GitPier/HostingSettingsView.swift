import AppKit
import GitPierCore
import SwiftUI

struct HostingConnectionRequest: Identifiable {
  let id = UUID()
  let provider: HostingProvider
  var account: HostingAccount? = nil
  var storageMode: HostingStorageMode? = nil
}
struct HostingSettingsView: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject var hosting: HostingModel
  @State private var connecting: HostingConnectionRequest?
  @State private var disconnecting: HostingAccount?
  @State private var changingStorage: HostingAccount?
  @State private var cleaningStorage: HostingAccount?
  @State private var cleaningDisconnected: HostingDisconnectedAccount?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 6) {
          Text(store.text("Code Hosting", "代码托管")).font(.title2.weight(.semibold))
          Text(store.text("Connect accounts for pull requests, reviews and CI. Git authentication keeps using your existing credentials.", "连接账号以查看 PR/MR、审查和 CI。Git 认证继续使用现有凭证。"))
            .font(.callout).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 8) {
          Text(store.text("Credential Storage", "凭证存储")).font(.headline)
          Picker(store.text("Default Credential Storage", "默认凭证存储方式"), selection: Binding(get: { hosting.metadata.defaultStorageMode }, set: { hosting.setDefaultStorage($0) })) {
            ForEach(HostingStorageMode.allCases, id: \.self) { mode in Text(hosting.storageTitle(mode)).tag(mode) }
          }.accessibilityIdentifier("hosting-default-storage")
          Text(store.text("Applies to future connections only. Existing accounts keep their storage method.", "仅影响未来新连接的账号，已有账号继续使用各自的存储方式。"))
            .font(.caption).foregroundStyle(.secondary)
          Text(hosting.storageExplanation(hosting.metadata.defaultStorageMode)).font(.caption).foregroundStyle(.secondary)
        }
        HStack(spacing: 12) {
          ForEach(HostingProvider.allCases, id: \.self) { provider in
            Button { hosting.error = nil; connecting = HostingConnectionRequest(provider: provider) } label: {
              VStack(alignment: .leading, spacing: 9) {
                HStack {
                  if let logo = AppResources.hostingLogo(provider, dark: colorScheme == .dark) {
                    Image(nsImage: logo).resizable().renderingMode(.original).scaledToFit().frame(width: 36, height: 36)
                  }
                  Spacer()
                  Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.tertiary)
                }.accessibilityHidden(true)
                Text(provider.title).font(.headline)
                Text(store.text("Connect Account…", "连接账号…")).font(.caption).foregroundStyle(.secondary)
              }.padding(16).frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("hosting-connect-" + provider.rawValue)
          }
        }
        if let error = hosting.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
        if hosting.metadata.accounts.isEmpty {
          ContentUnavailableView(store.text("No Connected Accounts", "尚未连接账号"), systemImage: "person.crop.circle.badge.plus",
            description: Text(store.text("OAuth is recommended. Personal Access Tokens are available as a fallback.", "建议使用 OAuth，也可使用个人访问令牌（PAT）。")))
            .frame(maxWidth: .infinity, minHeight: 180)
        } else {
          ForEach(hosting.metadata.accounts) { account in
            VStack(alignment: .leading, spacing: 10) {
              HStack(alignment: .top, spacing: 12) {
                AsyncImage(url: account.user.avatarURL) { image in image.resizable().scaledToFill() }
                  placeholder: { Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary) }
                  .frame(width: 36, height: 36).clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                  Text(account.user.login).font(.headline)
                  Text(account.instance.provider.title + " · " + account.instance.baseURL.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Text(account.kind == .oauth ? "OAuth" : "PAT").font(.caption).foregroundStyle(.secondary)
                Text(hosting.stateTitle(hosting.states[account.id] ?? .credentialsLocked)).font(.caption)
              }
              Text(store.text("Granted scopes: ", "已授予权限：") + (account.scopes.isEmpty ? store.text("Managed by platform / PAT", "由平台 / PAT 管理") : account.scopes.joined(separator: ", ")))
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
              if let url = try? account.instance.endpoint(account.instance.provider == .github ? "settings/applications" : account.instance.provider == .gitlab ? "-/user_settings/applications" : "user/settings/applications") {
                Link(store.text("Platform Authorization Settings…", "平台授权设置…"), destination: url).font(.caption)
              }
              HStack {
                Label(hosting.storageTitle(account.storageMode), systemImage: account.storageMode == .localVault ? "lock.doc" : "key")
                  .font(.caption).accessibilityIdentifier("hosting-storage-" + account.id.uuidString)
                Spacer()
                Button(store.text("Change Storage Method…", "更换存储方式…")) { changingStorage = account }
                  .disabled(hosting.busy.contains(account.id) || hosting.authorizing)
              }
              if let warning = hosting.credentialWarnings[account.id] { Text(warning).font(.caption).foregroundStyle(.orange) }
              if !account.pendingCleanup.isEmpty || account.pendingMigration != nil {
                HStack {
                  Text(store.text("A previous storage copy or interrupted migration is retained. The displayed storage method remains authoritative.", "保留了旧存储副本或中断的迁移；当前显示的存储方式仍有效。"))
                    .font(.caption).foregroundStyle(.secondary)
                  Button(store.text("Clean Up…", "清理…")) { cleaningStorage = account }.disabled(hosting.busy.contains(account.id) || hosting.authorizing)
                }
              }
              HStack {
                if let date = account.lastVerified {
                  Text(store.text("Last verified: ", "最近验证：") + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if hosting.busy.contains(account.id) { ProgressView().controlSize(.small) }
                Button(store.text("Verify Connection", "验证连接")) { hosting.verify(account) }
                  .disabled(hosting.busy.contains(account.id) || hosting.authorizing)
                Button(store.text("Reauthorize…", "重新授权…")) { hosting.error = nil; connecting = HostingConnectionRequest(provider: account.instance.provider, account: account) }
                  .disabled(hosting.busy.contains(account.id) || hosting.authorizing)
                Button(store.text("Disconnect…", "断开连接…")) { disconnecting = account }
              }
            }.padding(14).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
          }
        }
        if !hosting.metadata.disconnectedAccounts.isEmpty {
          Text(store.text("Disconnected Accounts — Cleanup Pending", "已断开账号 · 待清理凭证")).font(.headline)
          ForEach(hosting.metadata.disconnectedAccounts) { record in
            VStack(alignment: .leading, spacing: 8) {
              Text(record.account.instance.provider.title + " · @" + record.account.user.login).font(.headline)
              Text(record.account.instance.baseURL.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
              Text(record.remainingStorage.isEmpty
                ? store.text("Credential copies removed; retry saving cleanup progress.", "凭证副本已移除，请重试保存清理进度。")
                : store.text("Disconnected. Remaining credential copies: ", "已断开。仍待清理的凭证副本：") + record.remainingStorage.map(hosting.storageTitle).joined(separator: ", "))
                .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
              Text(store.text("These copies cannot reconnect this account automatically. macOS authorization may be required to delete a Keychain copy. Retry only when you are ready to authorize cleanup.", "这些副本不会自动恢复账号连接。删除 Keychain 副本可能要求 macOS 授权，请在准备好授权清理时主动重试。"))
                .font(.caption).foregroundStyle(.secondary)
              HStack {
                Spacer()
                if hosting.busy.contains(record.id) { ProgressView().controlSize(.small) }
                Button(store.text("Retry Cleanup…", "重试清理…")) { cleaningDisconnected = record }
                  .disabled(hosting.busy.contains(record.id)).accessibilityIdentifier("hosting-retry-disconnected-cleanup")
              }
            }.padding(14).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
          }
        }
        Text(store.text("Local Vault restores credentials on demand without OAuth Keychain access. Keychain accounts use Verify Connection after restart; macOS may request authorization. Disconnect stops the session and removes bindings immediately. Credential copies that cannot be deleted remain listed for cleanup. The platform grant is not revoked.", "本地库按需自动恢复凭证，不访问 OAuth 钥匙串。Keychain 账号重启后请点击“验证连接”，macOS 可能要求授权。断开会立即停止会话并移除关联，无法删除的凭证副本将保留在待清理列表中；不会撤销平台授权。"))
          .font(.caption).foregroundStyle(.secondary)
      }.padding(20).frame(maxWidth: 960)
        .frame(maxWidth: .infinity)
    }
    .sheet(item: $connecting) { request in HostingConnectSheet(hosting: hosting, request: request).environmentObject(store) }
    .sheet(item: $changingStorage) { account in HostingStorageSheet(hosting: hosting, account: account).environmentObject(store) }
    .alert(store.text("Clean Up Disconnected Credentials?", "清理已断开账号的凭证？"), isPresented: Binding(get: { cleaningDisconnected != nil }, set: { if !$0 { cleaningDisconnected = nil } })) {
      Button(store.text("Cancel", "取消"), role: .cancel) { cleaningDisconnected = nil }
      Button(store.text("Clean Up", "清理")) {
        if let record = cleaningDisconnected { Task { await hosting.cleanupDisconnected(record.id) } }
        cleaningDisconnected = nil
      }
    } message: { Text(store.text("Delete only the remaining copies listed for this disconnected account. Keychain cleanup may request macOS authorization. Canceling authorization keeps the account disconnected and the copies listed.", "仅删除此已断开账号列表中的剩余副本。清理 Keychain 可能要求 macOS 授权；取消授权后，账号仍断开且保留待清理列表。")) }
    .alert(store.text("Clean Up Previous Credentials?", "清理旧凭证？"), isPresented: Binding(get: { cleaningStorage != nil }, set: { if !$0 { cleaningStorage = nil } })) {
      Button(store.text("Cancel", "取消"), role: .cancel) { cleaningStorage = nil }
      Button(store.text("Clean Up", "清理")) {
        if let account = cleaningStorage {
          Task {
            do {
              for mode in Set(account.pendingCleanup + [account.pendingMigration].compactMap { $0 }) where mode != account.storageMode {
                guard let current = hosting.account(account.id) else { break }
                try await hosting.cleanupCredential(current, mode: mode)
              }
            } catch { hosting.error = hosting.message(error) }
          }
        }
        cleaningStorage = nil
      }
    } message: { Text(store.text("Remove only this account's previous storage copies. Keychain cleanup may request macOS authorization and can be postponed. The active credentials remain available. File deletion is not guaranteed physical erasure on SSDs.", "仅移除此账号的旧存储副本。清理钥匙串可能要求 macOS 授权，可暂缓处理；当前凭证继续可用。SSD 普通文件删除不保证物理擦除。")) }
    .alert(store.text("Disconnect Account?", "断开账号连接？"), isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } })) {
      Button(store.text("Cancel", "取消"), role: .cancel) { disconnecting = nil }
      Button(store.text("Disconnect", "断开连接")) {
        if let account = disconnecting { Task { do { try await hosting.disconnect(account, discardReviewWork: true) } catch { hosting.error = hosting.message(error) } } }
        disconnecting = nil
      }
    } message: { Text(disconnectionMessage) }
  }
  private var disconnectionMessage: String {
    let base = store.text("Stop this account's session and API requests, then remove its hosting credential copies and bindings. Copies whose deletion is denied remain listed for explicit cleanup. The platform OAuth grant and Git credentials remain available.", "先停止此账号的会话和 API 请求，再删除托管凭证副本及关联。删除被拒绝的副本保留在列表中，供主动清理。平台 OAuth 授权与 Git 凭证继续保留。")
    guard let account = disconnecting else { return base }
    let pending = store.reviewSessions.unfinished(accountID: account.id)
    let details = pending.map(\.displayName).joined(separator: "\n")
    return base + "\n\n" + store.text("Continuing discards this account's review drafts in every window and cancels waiting requests. A request already sent may still succeed. Unresolved operation metadata remains in the journal for manual checking.", "继续将丢弃所有窗口中此账号的审查草稿，并取消等待中的请求。已经发送的请求仍可能成功；待核实操作元数据将保留在日志中。") + (details.isEmpty ? "" : "\n\n" + details)
  }
}

struct HostingConnectSheet: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var hosting: HostingModel
  let request: HostingConnectionRequest
  @State private var instanceURL = ""
  @State private var clientID = ""
  @State private var pat = ""
  @State private var usePAT = false
  @State private var selfHosted = false
  @State private var loopback = false
  @State private var port = "43827"
  @State private var storageMode: HostingStorageMode = .localVault
  @State private var level: HostingAuthorizationLevel = .read
  @State private var patBusy = false
  @State private var patTask: Task<Void, Never>?
  @State private var savedConfiguration = ""
  var provider: HostingProvider { request.provider }
  var resolvedInstanceURL: String {
    if let account = request.account { return account.instance.baseURL.absoluteString }
    return selfHosted || provider == .gitea ? instanceURL : provider == .github ? "https://github.com" : "https://gitlab.com"
  }
  var redirect: HostingRedirect { provider == .gitea ? .loopback(port: 0) : loopback ? .loopback(port: UInt16(port) ?? 0) : .application }
  var configuration: OAuthConfiguration? {
    guard let instance = try? HostingInstance(provider: provider, url: resolvedInstanceURL) else { return nil }
    let publicPlatform = provider == .github || provider == .gitlab && instance.baseURL.absoluteString == "https://gitlab.com"
    let id = publicPlatform ? (provider == .github ? hosting.publicConfiguration.githubClientID : hosting.publicConfiguration.gitlabClientID) : clientID
    return OAuthConfiguration(instance: instance, clientID: id, redirect: redirect)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(store.text("Connect ", "连接 ") + provider.title).font(.title2.weight(.semibold))
        Spacer()
        Button(store.text("Cancel", "取消")) { hosting.cancelAuthorization(); patTask?.cancel(); pat = ""; dismiss() }.keyboardShortcut(.cancelAction)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if let device = hosting.device {
            Text(store.text("Authorize GitPier in your browser.", "请在浏览器中授权 GitPier。"))
            Text(device.userCode).font(.system(size: 30, weight: .semibold, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity).padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            HStack {
              Button(store.text("Copy Code", "复制验证码")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(device.userCode, forType: .string) }
              Button(store.text("Open GitHub", "打开 GitHub")) { hosting.openAuthorizationPage(device.verificationURL) }
            }
            Label(store.text("Waiting for GitHub authorization…", "正在等待 GitHub 授权…"), systemImage: "clock")
            Text(store.text("Expires: ", "有效期至：") + device.expiresAt.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
          } else {
            Picker(store.text("Authentication", "认证方式"), selection: $usePAT) {
              Text(store.text("OAuth (Recommended)", "OAuth（推荐）")).tag(false)
              Text("Personal Access Token").tag(true)
            }.pickerStyle(.segmented)
            if provider == .gitlab && request.account == nil { Toggle(store.text("Self-hosted GitLab", "自建 GitLab"), isOn: $selfHosted) }
            if selfHosted || provider == .gitea || request.account != nil {
              TextField(store.text("Instance URL", "实例地址"), text: $instanceURL).disabled(request.account != nil || hosting.authorizing)
            }
            if usePAT {
              SecureField(store.text("Personal Access Token", "个人访问令牌"), text: $pat)
              Text(store.text("Create a PAT on this instance. Start with read access; creation requires repository write/API access. GitPier validates the user identity before saving it.", "请在此实例创建 PAT。优先使用只读权限；创建请求需要仓库写入 / API 权限。保存前会验证用户身份。"))
                .font(.callout).foregroundStyle(.secondary)
              if provider == .gitea {
                Text(store.text("Gitea issue comments need write:issue; reviews need write:repository. GitPier cannot expand an existing PAT. Create an appropriately scoped PAT on the instance and replace it explicitly.", "Gitea 普通评论需要 write:issue，审查需要 write:repository。GitPier 无法扩大已有 PAT 权限，请在实例创建具有所需权限的 PAT 后主动替换。"))
                  .font(.caption).foregroundStyle(.secondary)
              }
            } else {
              if selfHosted || provider == .gitea {
                Picker(store.text("Saved Instance", "已保存实例"), selection: $savedConfiguration) {
                  Text(store.text("New Configuration", "新配置")).tag("")
                  ForEach(hosting.metadata.configurations.filter { $0.instance.provider == provider }) { config in
                    Text(config.instance.baseURL.absoluteString).tag(config.id)
                  }
                }
                TextField("Client ID", text: $clientID)
                if provider == .gitlab {
                  Toggle(store.text("Use registered fixed-port loopback callback", "使用已注册的固定端口回环回调"), isOn: $loopback)
                  if loopback { TextField(store.text("Registered port", "已注册端口"), text: $port) }
                }
                Text(store.text("Register a Public / Non-Confidential application with this instance. Never enter a Client Secret. Gitea OAuth requires v1.23+ granular scopes; older versions can use PAT.", "请在此实例注册 Public / Non-Confidential 应用，不需要输入 Client Secret。Gitea OAuth 要求 v1.23+ 细粒度权限，旧版本可使用 PAT。"))
                  .font(.callout).foregroundStyle(.secondary)
                Button(store.text("Save Public Configuration", "保存公开配置")) {
                  if let configuration {
                    do { try hosting.saveConfiguration(configuration); savedConfiguration = configuration.id; hosting.error = nil }
                    catch { hosting.error = hosting.message(error) }
                  }
                }.disabled(configuration.flatMap { try? $0.validate() } == nil || hosting.authorizing)
              }
              if provider != .github {
                LabeledContent(store.text("Redirect URI", "回调地址")) {
                  Text(redirect.registrationURL(for: provider)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                  Button(store.text("Copy", "复制")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(redirect.registrationURL(for: provider), forType: .string) }
                }
              }
              Picker(store.text("Access Level", "授权级别"), selection: $level) {
                Text(store.text("Basic / Read Collaboration", "基础信息 / 只读协作")).tag(HostingAuthorizationLevel.read)
                Text(store.text("Public Repository Collaboration", "公共仓库协作")).tag(HostingAuthorizationLevel.publicWrite)
                Text(store.text("Private Repository Collaboration", "私有仓库协作")).tag(HostingAuthorizationLevel.privateWrite)
                if provider == .gitea {
                  Text(store.text("Reviews + Issue Comments (Expanded Scope)", "审查与 Issue 评论（扩大权限）")).tag(HostingAuthorizationLevel.reviewCollaboration)
                }
              }
              Text(level.scopes(for: provider).joined(separator: " ")).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
              Text(scopeExplanation).font(.callout).foregroundStyle(level == .read ? Color.secondary : .orange)
              if provider == .gitea, level == .reviewCollaboration {
                Label(store.text("This adds write:issue, which grants issue read/write access beyond comments. An existing OAuth grant may reject expanded scopes. GitPier will not revoke the grant, retry silently or remove your connected account. Manage the grant on the instance yourself, or explicitly replace it with a PAT.", "此选项新增 write:issue，授予超出评论范围的 Issue 读写权限。已有 OAuth Grant 可能拒绝扩大 Scope。GitPier 不会撤销 Grant、静默重试或删除已连接账号。请自行在实例管理 Grant，或主动改用 PAT。"), systemImage: "info.circle")
                  .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("hosting.gitea.expanded-scope-explanation")
              }
              if configuration?.clientID.isEmpty == true { Text(hosting.message(HostingError.missingClientID)).font(.callout).foregroundStyle(.orange) }
            }
            if request.account == nil {
              DisclosureGroup(store.text("Storage Options", "存储选项")) {
                Picker(store.text("Credential Storage", "凭证存储"), selection: $storageMode) {
                  ForEach(HostingStorageMode.allCases, id: \.self) { mode in Text(hosting.storageTitle(mode)).tag(mode) }
                }.accessibilityIdentifier("hosting-connect-storage")
                Text(hosting.storageExplanation(storageMode)).font(.caption).foregroundStyle(.secondary)
              }.disabled(hosting.authorizing)
            } else {
              Text(store.text("Credential Storage: ", "凭证存储：") + hosting.storageTitle(storageMode)).font(.caption).foregroundStyle(.secondary)
            }
            if hosting.authorizing { ProgressView(store.text("Waiting for browser authorization…", "正在等待浏览器授权…")) }
          }
          if let error = hosting.error { Text(error).foregroundStyle(.orange).font(.callout).textSelection(.enabled) }
        }.textFieldStyle(.roundedBorder).disabled(patBusy)
          // AppKit's focus ring extends beyond the field bounds; keep it inside the scroll viewport.
          .padding(6)
      }
      HStack {
        Spacer()
        if patBusy { ProgressView().controlSize(.small) }
        Button(usePAT ? store.text("Connect with PAT", "使用 PAT 连接") : store.text("Authorize with ", "授权连接 ") + provider.title) {
          hosting.error = nil
          if usePAT {
            let secret = pat; pat = ""; patBusy = true
            patTask = Task {
              defer { patBusy = false }
              do {
                let instance = try HostingInstance(provider: provider, url: resolvedInstanceURL)
                try await hosting.connectPAT(instance: instance, secret: secret, expected: request.account, storageMode: storageMode)
                try Task.checkCancellation(); dismiss()
              } catch is CancellationError {} catch { hosting.error = hosting.message(error) }
            }
          } else if let configuration { hosting.connect(configuration: configuration, level: level, reauthorizing: request.account, storageMode: storageMode) }
        }.buttonStyle(.borderedProminent).disabled(hosting.authorizing || patBusy || (usePAT ? pat.isEmpty : configuration.flatMap { try? $0.validate() } == nil))
      }
    }.padding(22).frame(width: 590, height: 560)
    .onAppear {
      storageMode = request.storageMode ?? request.account?.storageMode ?? hosting.metadata.defaultStorageMode
      instanceURL = request.account?.instance.baseURL.absoluteString ?? (provider == .gitea ? "https://" : "https://gitlab.com")
      clientID = request.account?.oauth?.clientID ?? ""
      selfHosted = provider == .gitlab && request.account?.instance.baseURL.host != nil && request.account?.instance.baseURL.host != "gitlab.com"
      usePAT = request.account?.kind == .pat
      if case .loopback(let value) = request.account?.oauth?.redirect { loopback = true; port = String(value) }
    }
    .onChange(of: hosting.authorizing) { old, new in if old && !new && hosting.error == nil { dismiss() } }
    .onChange(of: savedConfiguration) { _, id in
      guard let config = hosting.metadata.configurations.first(where: { $0.id == id }) else { return }
      instanceURL = config.instance.baseURL.absoluteString; clientID = config.clientID
      if case .loopback(let value) = config.redirect { loopback = true; if value > 0 { port = String(value) } } else { loopback = false }
    }
    .onDisappear { hosting.cancelAuthorization(); patTask?.cancel(); pat = "" }
  }
  var scopeExplanation: String {
    if provider == .github {
      return level == .read ? store.text("Reads public profile and public repository data. Private collaboration requires a new authorization with repo. Previously granted scopes may also be returned by GitHub.", "读取公共资料和公开仓库数据。私有仓库协作需要重新授予 repo；GitHub 可能同时返回此前已授权的权限。")
        : level == .privateWrite ? store.text("repo grants broad read and write access to private repositories. It is not read-only.", "repo 会授予私有仓库广泛的读写权限，并非只读。")
        : store.text("public_repo grants read and write access to public repositories.", "public_repo 会授予公共仓库读写权限。")
    }
    if provider == .gitlab { return level == .read ? store.text("read_user + read_api allow read-only account and API access.", "read_user + read_api 允许只读账号和 API 访问。") : store.text("api grants broad API read and write access, including merge requests, discussions and approvals. It is not limited to comments.", "api 会授予广泛的 API 读写权限，包括合并请求、讨论与审批，并非仅允许评论。") }
    if level == .reviewCollaboration { return store.text("Explicitly request read:user + write:repository + write:issue for repository reviews and issue conversations. Existing access levels keep their original scopes.", "主动申请 read:user + write:repository + write:issue，用于仓库审查与 Issue 会话。既有授权级别的 Scope 保持不变。") }
    return level == .read ? store.text("Read account and repository data on this instance.", "读取此实例的账号和仓库数据。") : store.text("write:repository grants repository read and write access on this instance.", "write:repository 会授予此实例的仓库读写权限。")
  }
}
