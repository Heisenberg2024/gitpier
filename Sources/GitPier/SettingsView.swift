import AppKit
import GitPierCore
import SwiftUI

import enum SwiftTerm.CursorStyle

@MainActor enum InstalledFonts {
  static let names = NSFontManager.shared.availableFonts.sorted {
    $0.localizedStandardCompare($1) == .orderedAscending
  }
}

struct SettingsView: View {
  @EnvironmentObject var store: AppStore
  @State private var gitVersion = ""
  @State private var selectedTab: Int
  init(initialTab: Int = 0) { _selectedTab = State(initialValue: initialTab) }
  var body: some View {
    TabView(selection: $selectedTab) {
      Form {
        Section(store.text("General", "常规")) {
          Picker(store.text("Language", "语言"), selection: setting(\.language)) {
            Text(localizedUI("English")).tag(AppLanguage.english)
            Text(localizedUI("简体中文")).tag(AppLanguage.simplifiedChinese)
          }
          Picker(store.text("Launch Page", "启动页面"), selection: setting(\.launchPage)) {
            Text(store.text("Dashboard", "仓库总览")).tag("dashboard")
            Text(store.text("Last Repository", "最近仓库")).tag("last")
          }
          Toggle(
            store.text("Watch external changes (show refresh reminder)", "监听外部变更（显示刷新提示）"),
            isOn: setting(\.automaticRefresh))
          Toggle(
            store.text("Completion notifications", "完成通知"),
            isOn: Binding(
              get: { store.settings.completionNotifications },
              set: { store.configureNotifications($0) }))
          Stepper(
            store.text(
              "Recent repositories: \(store.settings.recentLimit)",
              "最近仓库：\(store.settings.recentLimit)"), value: setting(\.recentLimit), in: 5...50)
          ExternalEditorPicker()
        }
      }.formStyle(.grouped).tabItem { Label(store.text("General", "常规"), systemImage: "gearshape") }
        .tag(0)
      Form {
        Picker(store.text("Appearance", "外观"), selection: setting(\.appearance)) {
          Text(store.text("Follow System", "跟随系统")).tag(AppearanceMode.system)
          Text(store.text("Dark", "深色")).tag(AppearanceMode.dark)
          Text(store.text("Light", "浅色")).tag(AppearanceMode.light)
        }
        Toggle(store.text("Compact file rows", "紧凑文件列表"), isOn: setting(\.compactUI))
        diffTypography
        Toggle(store.text("Colored file icons", "彩色文件图标"), isOn: setting(\.coloredFileIcons))
        ColorPicker(
          store.text("Diff additions", "Diff 新增颜色"), selection: colorSetting(\.diffAddedHex),
          supportsOpacity: false)
        ColorPicker(
          store.text("Diff deletions", "Diff 删除颜色"), selection: colorSetting(\.diffRemovedHex),
          supportsOpacity: false)
        Text(
          store.text(
            "Panel sizes are saved independently for each repository. Drag the dividers in the workspace.",
            "面板尺寸按仓库独立保存，可在工作台拖动分隔线调整。")
        ).font(.callout).foregroundStyle(.secondary)
        Button(store.text("Reset Current Repository Layout", "重置当前仓库布局")) {
          store.current?.editLayout(PanelLayout())
        }.disabled(store.current == nil)
      }.formStyle(.grouped).tabItem {
        Label(store.text("Appearance", "外观"), systemImage: "circle.lefthalf.filled")
      }.tag(1)
      Form {
        TextField(store.text("Git Executable", "Git 可执行文件"), text: setting(\.gitPath))
        HStack {
          Text(gitVersion).font(uiFont(size: 11, design: .monospaced))
          Spacer()
          Button(store.text("Check Version", "检查版本")) {
            Task {
              do {
                gitVersion = try await ProcessRunner().run(
                  executable: store.settings.gitPath, arguments: ["--version"], directory: nil
                ).text.trimmingCharacters(in: .whitespacesAndNewlines)
              } catch { gitVersion = error.localizedDescription }
            }
          }
        }
        Picker(store.text("Pull Strategy", "Pull 策略"), selection: setting(\.pullStrategy)) {
          Text(store.text("Respect Git Configuration", "遵循 Git 配置")).tag("configured")
          Text(localizedUI("Merge")).tag("merge")
          Text(localizedUI("Rebase")).tag("rebase")
        }
        Text(
          store.text(
            "Author identity, hooks, signing and LFS are inherited from your Git configuration. Edit repository-specific identity in Repository Settings. Global Git and SSH files are never changed automatically.",
            "作者身份、Hooks、签名和 LFS 遵循现有 Git 配置。仓库设置可以修改仓库级身份；不会自动修改全局 Git 或 SSH 配置。")
        ).font(.callout).foregroundStyle(.secondary)
        AutomaticRemoteCheckSettings(workspace: store.workspace)
        Button(store.text("Open Repository Settings", "打开仓库设置")) {
          store.current?.setPage("repository")
        }.disabled(store.current == nil)
      }.formStyle(.grouped).tabItem {
        Label(localizedUI("Git"), systemImage: "arrow.triangle.branch")
      }.tag(2)
      Form {
        TextField(store.text("Default Shell", "默认 Shell"), text: setting(\.shellPath))
        Toggle(
          store.text("Launch interactive login shell", "启动交互式登录 Shell"), isOn: setting(\.loginShell)
        )
        TextField(
          store.text("Font (installed PostScript name)", "字体（已安装字体的 PostScript 名称）"),
          text: setting(\.terminalFont))
        Menu(store.text("Installed monospace / Nerd Fonts", "已安装等宽 / Nerd 字体")) {
          ForEach(
            NSFontManager.shared.availableFonts.filter {
              $0.localizedCaseInsensitiveContains("nerd") || $0.hasPrefix("Menlo")
                || $0.hasPrefix("Monaco")
            }.sorted(), id: \.self
          ) { name in
            Button(name) {
              var settings = store.settings
              settings.terminalFont = name
              store.updateSettings(settings)
            }
          }
        }
        HStack {
          Text(store.text("Line Height", "行高"))
          Slider(value: setting(\.terminalLineSpacing), in: 0.8...1.8, step: 0.05)
          Text(String(format: "%.2f", store.settings.terminalLineSpacing))
        }
        Picker(store.text("Cursor", "光标"), selection: setting(\.terminalCursor)) {
          ForEach(CursorStyle.allCases, id: \.tagName) { Text($0.displayName).tag($0.tagName) }
        }
        Picker(store.text("Terminal Theme", "终端主题"), selection: setting(\.terminalTheme)) {
          Text(store.text("Follow App", "跟随应用")).tag("follow")
          Text(store.text("Dark", "深色")).tag("dark")
          Text(store.text("Light", "浅色")).tag("light")
        }
        Picker(store.text("Starting Directory", "起始目录"), selection: setting(\.terminalDirectory)) {
          Text(store.text("Repository Root", "仓库根目录")).tag("repository")
          Text(store.text("Home Directory", "用户目录")).tag("home")
          Text(store.text("Custom", "自定义")).tag("custom")
        }
        if store.settings.terminalDirectory == "custom" {
          TextField(
            store.text("Custom Directory", "自定义目录"), text: setting(\.terminalCustomDirectory))
        }
        HStack {
          Text(store.text("Font Size", "字号"))
          Slider(value: setting(\.terminalFontSize), in: 10...24, step: 1)
          Text(localizedUI("\(Int(store.settings.terminalFontSize)) pt")).frame(width: 44)
        }
        Stepper(
          store.text(
            "Scrollback: \(store.settings.scrollback) rows", "滚动历史：\(store.settings.scrollback) 行"),
          value: setting(\.scrollback), in: 1000...100000, step: 1000)
        Text(
          store.text(
            "Shell and scrollback changes apply to new sessions. Existing shells keep running. Terminal history is kept in memory; no terminal output is written to disk.",
            "Shell 和历史上限修改适用于新会话，现有 Shell 继续运行。终端内容只保存在内存中。")
        ).font(.callout).foregroundStyle(.secondary)
        Text(localizedUI("⌘C Copy   ⌘V Paste   ⌃C Interrupt   ⌃D EOF   ⌃Z Suspend")).font(
          .system(size: 11, design: .monospaced))
        CLISettingsSections()
      }.formStyle(.grouped).tabItem { Label(store.text("Terminal", "终端"), systemImage: "terminal") }
        .tag(3)
      Form {
        Toggle(store.text("Unified Diff", "统一 Diff"), isOn: setting(\.unifiedDiff))
        Toggle(store.text("Wrap Lines", "自动换行"), isOn: setting(\.wrapDiff))
        Toggle(store.text("Line Numbers", "行号"), isOn: setting(\.showLineNumbers))
        Toggle(store.text("Show Whitespace", "显示空白"), isOn: setting(\.showWhitespace))
        Toggle(
          store.text("Ignore Whitespace Differences", "忽略空白差异"), isOn: setting(\.ignoreWhitespace))
        diffTypography
        Stepper(
          store.text("Tab Width: \(store.settings.tabSize)", "Tab 宽度：\(store.settings.tabSize)"),
          value: setting(\.tabSize), in: 1...8)
        Text(
          store.text(
            "Whitespace filtering disables hunk mutations to preserve exact patch context.",
            "忽略空白差异时禁用差异块修改，以保持 Patch 上下文准确。")
        ).font(.caption).foregroundStyle(.secondary)
      }.formStyle(.grouped).tabItem {
        Label(localizedUI("Diff"), systemImage: "arrow.left.arrow.right")
      }.tag(4)
      OrganizationsView().tabItem {
        Label(store.text("Organizations", "组织"), systemImage: "folder")
      }.tag(5)
      CredentialsView().tabItem { Label(store.text("Credentials", "凭证"), systemImage: "key") }.tag(
        6)
      HostingSettingsView(hosting: store.hosting).tabItem {
        Label(store.text("Code Hosting", "代码托管"), systemImage: "person.crop.circle.badge.checkmark")
      }.tag(8)
      // Keep About last when adding tabs; its stable selection ID remains 7.
      AboutSettingsView().tabItem {
        Label(store.text("About", "关于"), systemImage: "info.circle")
      }.tag(7)
    }.padding(10)
  }
  func setting<T>(_ path: WritableKeyPath<AppSettings, T>) -> Binding<T> {
    Binding(
      get: { store.settings[keyPath: path] },
      set: { value in
        var settings = store.settings
        settings[keyPath: path] = value
        store.updateSettings(settings)
      })
  }
  var diffTypography: some View {
    Group {
      LabeledContent(store.text("Diff Code Font", "Diff 代码字体")) {
        InstalledFontPicker(font: setting(\.diffFont))
      }
      HStack {
        Text(store.text("Diff Code Size", "Diff 代码字号"))
        Slider(value: setting(\.diffFontSize), in: 10...24, step: 1)
        Text("\(Int(store.settings.diffFontSize)) pt").frame(width: 44)
      }
      Text(store.text("Only affects code in Diff views.", "仅影响 Diff 对比页的代码，其他界面使用系统字体。"))
        .font(.caption).foregroundStyle(.secondary)
    }
  }
  func colorSetting(_ path: WritableKeyPath<AppSettings, String>) -> Binding<Color> {
    Binding(
      get: {
        Color(nsColor: NSColor(hex: UInt32(store.settings[keyPath: path], radix: 16) ?? 0x55B982))
      },
      set: { value in
        guard let color = NSColor(value).usingColorSpace(.sRGB) else { return }
        let hex = String(
          format: "%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255),
          Int(color.blueComponent * 255))
        var settings = store.settings
        settings[keyPath: path] = hex
        store.updateSettings(settings)
      })
  }
}

struct AboutSettingsView: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.colorScheme) var scheme
  @Environment(\.openWindow) var openWindow
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 14) {
        if let image = AppResources.applicationIcon {
          Image(nsImage: image).resizable().frame(width: 56, height: 56)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text("GitPier").font(.system(size: 24, weight: .semibold))
          Text(localizedUI("Native Git Client for macOS")).font(.headline)
          Text(localizedUI("All Your Repositories. One Workspace."))
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 4) {
          Text(store.text("Version", "版本")).font(.caption).foregroundStyle(.secondary)
          Text("\(AppResources.version) (\(AppResources.build))").textSelection(.enabled)
        }
      }
      UpdateSettingsView(manager: store.updates)
        .padding(16).background(Theme.panel(scheme), in: RoundedRectangle(cornerRadius: 12))
      VStack(alignment: .leading, spacing: 6) {
        LabeledContent(store.text("License", "许可证")) { Text("MIT License") }
        Text(
          store.text(
            "Licensed under the MIT License. Copyright © 2026 Heisenberg2024.",
            "版权所有 © 2026 Heisenberg2024。使用与分发遵循 MIT License。")
        )
        .font(.caption).foregroundStyle(.secondary).frame(
          maxWidth: .infinity, alignment: .leading)
        Text(
          store.text(
            "Repository contents stay on this Mac. GitPier has no analytics or repository-upload service.",
            "仓库内容保留在本机。GitPier 不提供分析或仓库上传服务。")
        )
        .font(.caption).foregroundStyle(.secondary).frame(
          maxWidth: .infinity, alignment: .leading)
      }
      Divider()
      HStack(spacing: 18) {
        Button(store.text("GitPier Help", "GitPier 帮助")) { openWindow(id: "help") }
        Link(
          store.text("Source Code", "源代码"),
          destination: URL(string: "https://github.com/Heisenberg2024/gitpier")!)
        Spacer()
        Link("GitHub Releases", destination: URL(string: "https://github.com/Heisenberg2024/gitpier/releases/latest")!)
          .help(store.text("Manual DMG Upgrade", "手动 DMG 升级"))
      }
      Spacer(minLength: 0)
    }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(Theme.editor(scheme))
  }
}

struct RepositorySettingsView: View {
  @ObservedObject var model: RepositoryModel
  @EnvironmentObject var store: AppStore
  @State private var userName = ""
  @State private var userEmail = ""
  @State private var signing = false
  @State private var signingKey = ""
  @State private var signingFormat = "openpgp"
  @State private var hooksPath = ""
  @State private var credentialsMode = "system"
  var body: some View {
    Form {
      Section(store.text("Repository", "仓库")) {
        TextField(store.text("Display Name", "显示名称"), text: record(\.name))
        Picker(
          store.text("Organization / Project Collection", "组织 / 项目合集"),
          selection: Binding(
            get: { model.record.group },
            set: { value in
              do {
                try store.moveRepositories(
                  [model.record.id], to: store.organizations.first { $0.name == value }?.id)
              } catch { store.error = error.localizedDescription }
            })
        ) {
          Text(store.text("Ungrouped", "未分组")).tag("")
          ForEach(store.organizations) { Text($0.name).tag($0.name) }
        }
        Button(store.text("Manage Organizations / Groups…", "管理组织 / 分组…")) {
          store.showOrganizations = true
        }
        Toggle(store.text("Favorite", "收藏"), isOn: record(\.favorite))
        Text(model.record.path).font(uiFont(size: 11, design: .monospaced)).textSelection(.enabled)
        Text(model.status.upstream ?? store.text("No upstream", "无 Upstream")).foregroundStyle(
          .secondary)
      }
      Section(store.text("Remote Authentication", "远程认证")) {
        Picker(store.text("Credentials", "凭证"), selection: $credentialsMode) {
          Text(store.text("System Git / SSH", "系统 Git / SSH")).tag("system")
          Text(store.text("Global Default", "全局默认")).tag("default")
          ForEach(store.configuration.credentials) { Text($0.name).tag($0.id.uuidString) }
        }.onChange(of: credentialsMode) { _, value in
          model.record.useDefaultCredential = value == "default"
          model.record.credentialID = UUID(uuidString: value)
          store.update(model.record)
          Task { await model.configure() }
        }
        Text(
          store.text(
            "Credentials authenticate remotes; they do not set commit authorship.",
            "凭证用于远程认证，不会改变提交作者身份。")
        ).font(.caption).foregroundStyle(.secondary)
      }
      Section(store.text("Repository Git Identity", "仓库 Git 身份")) {
        TextField(localizedUI("User Name"), text: $userName)
        TextField(localizedUI("User Email"), text: $userEmail)
        Button(store.text("Save Repository Identity", "保存仓库身份")) {
          let name = userName
          let email = userEmail
          model.run { git in
            try await git.perform(["config", "--local", "user.name", name])
            try await git.perform(["config", "--local", "user.email", email])
          }
        }.disabled(userName.isEmpty || userEmail.isEmpty || model.busy)
      }
      Section(store.text("Hooks & Signing", "Hooks 与签名")) {
        Toggle(store.text("Sign commits", "提交签名"), isOn: $signing)
        Picker(localizedUI("Signing Format"), selection: $signingFormat) {
          Text(localizedUI("OpenPGP")).tag("openpgp")
          Text(localizedUI("SSH")).tag("ssh")
        }
        TextField(localizedUI("Signing Key"), text: $signingKey)
        TextField(localizedUI("Hooks Path"), text: $hooksPath)
        Button(store.text("Save Repository Signing & Hooks", "保存仓库签名与 Hooks")) {
          let enabled = signing
          let key = signingKey
          let format = signingFormat
          let hooks = hooksPath
          model.run { git in
            try await git.perform([
              "config", "--local", "commit.gpgsign", enabled ? "true" : "false",
            ])
            try await git.perform(["config", "--local", "gpg.format", format])
            if !key.isEmpty {
              try await git.perform(["config", "--local", "user.signingkey", key])
            }
            if !hooks.isEmpty {
              try await git.perform(["config", "--local", "core.hooksPath", hooks])
            }
          }
        }.disabled(model.busy)
        Text(
          store.text(
            "These buttons explicitly write local repository configuration. Existing global settings are preserved. Install Git LFS separately when needed; GitPier uses its existing filters and hooks.",
            "这些按钮明确写入仓库本地配置，保留全局设置。需要 LFS 时请另行安装，GitPier 使用现有过滤器及 Hooks。")
        ).font(.caption).foregroundStyle(.secondary)
      }
    }.formStyle(.grouped).onAppear {
      userName = model.identity["user.name"] ?? ""
      userEmail = model.identity["user.email"] ?? ""
      signing = model.identity["commit.gpgsign"] == "true"
      signingKey = model.identity["user.signingkey"] ?? ""
      signingFormat = model.identity["gpg.format"].flatMap { $0.isEmpty ? nil : $0 } ?? "openpgp"
      hooksPath = model.identity["core.hooksPath"] ?? ""
      credentialsMode =
        model.record.credentialID?.uuidString
        ?? (model.record.useDefaultCredential ? "default" : "system")
    }
  }
  func record<T>(_ path: WritableKeyPath<RepositoryRecord, T>) -> Binding<T> {
    Binding(
      get: { model.record[keyPath: path] },
      set: { value in
        model.record[keyPath: path] = value
        store.update(model.record)
      })
  }
}

struct CredentialsView: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @State private var selectedID: UUID?
  @State private var editing = false
  @State private var profile = CredentialProfile(name: "", host: "")
  @State private var token = ""
  @State private var deleting: UUID?
  @State private var connectionURL = ""
  @State private var testing = false
  @State private var testResult = ""
  var selected: CredentialProfile? { store.configuration.credentials.first { $0.id == selectedID } }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(store.text("Credentials", "凭证")).font(.title3.weight(.semibold))
        Spacer()
        Button(store.text("Add Account…", "添加账号…")) {
          profile = CredentialProfile(name: "", host: "")
          token = ""
          editing = true
        }
        Button(store.text("Close", "关闭")) { dismiss() }
      }.padding(16)
      Divider()
      HSplitView {
        List(store.configuration.credentials, selection: $selectedID) { credential in
          VStack(alignment: .leading, spacing: 5) {
            HStack {
              Image(systemName: credential.kind == .ssh ? "terminal" : "key").foregroundStyle(
                .secondary)
              Text(credential.name).font(uiFont(size: 12, weight: .medium))
              if store.settings.defaultCredentialID == credential.id {
                Image(systemName: "star.fill").font(uiFont(size: 9)).foregroundStyle(.yellow)
              }
            }
            Text(credential.host + " · " + credential.username).font(uiFont(size: 10))
              .foregroundStyle(.secondary)
          }.padding(.vertical, 6).tag(credential.id)
        }.frame(minWidth: 220, maxWidth: 270).listStyle(.sidebar)
        if let selected {
          VStack(alignment: .leading, spacing: 16) {
            Text(selected.name).font(.title3.weight(.semibold))
            Text(selected.host).foregroundStyle(.secondary)
            Text(selected.kind == .ssh ? selected.identityPath : selected.username).font(
              .system(size: 11, design: .monospaced)
            ).textSelection(.enabled)
            Text(
              store.text(
                "Tokens are stored in macOS Keychain. This view never reads or displays stored tokens.",
                "Token 保存在 macOS Keychain，此页面不会读取或显示已保存 Token。")
            ).font(.callout).foregroundStyle(.secondary)
            HStack {
              Button(store.text("Edit…", "编辑…")) {
                profile = selected
                token = ""
                editing = true
              }
              Button(store.text("Set Global Default", "设为全局默认")) {
                var settings = store.settings
                settings.defaultCredentialID = selected.id
                store.updateSettings(settings)
              }
              Button(store.text("Delete…", "删除…"), role: .destructive) { deleting = selected.id }
            }.controlSize(.small)
            Divider()
            TextField(
              store.text("Repository URL to test (read-only)", "用于测试的仓库 URL（只读）"),
              text: $connectionURL
            ).textFieldStyle(.roundedBorder)
            HStack {
              Button(store.text("Test Connection", "测试连接")) { test(selected) }.disabled(
                testing || connectionURL.isEmpty)
              if testing { ProgressView().controlSize(.small) }
            }
            ScrollView {
              Text(testResult).font(uiFont(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
          }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
          EmptyState(
            symbol: "key", title: store.text("Choose an account", "选择一个账号"),
            detail: store.text(
              "Bind each repository to its own account, even on the same host.",
              "即使使用同一 Host，也可为每个仓库绑定独立账号。"))
        }
      }
    }
    .sheet(isPresented: $editing) {
      VStack(alignment: .leading, spacing: 14) {
        Text(store.text("Account Credentials", "账号凭证")).font(.title2)
        TextField(store.text("Name", "名称"), text: $profile.name)
        TextField(store.text("Host (e.g. github.com)", "Host（如 github.com）"), text: $profile.host)
        Picker(store.text("Protocol", "协议"), selection: $profile.kind) {
          Text(localizedUI("HTTPS Token")).tag(CredentialProfile.Kind.https)
          Text(localizedUI("SSH Identity")).tag(CredentialProfile.Kind.ssh)
        }
        TextField(store.text("Username", "用户名"), text: $profile.username)
        if profile.kind == .https {
          SecureField(store.text("Token (empty keeps existing)", "Token（留空保留原值）"), text: $token)
        } else {
          HStack {
            TextField(store.text("Private key path", "私钥路径"), text: $profile.identityPath)
            Button(store.text("Choose…", "选择…")) {
              let panel = NSOpenPanel()
              panel.canChooseDirectories = false
              if panel.runModal() == .OK { profile.identityPath = panel.url?.path ?? "" }
            }
          }
        }
        Text(
          store.text(
            "SSH uses your existing SSH config and agent. TLS and host-key verification remain enabled.",
            "SSH 使用现有 SSH 配置和 Agent，保留 TLS 和 Host Key 校验。")
        ).font(.caption).foregroundStyle(.secondary)
        HStack {
          Spacer()
          Button(store.text("Cancel", "取消")) {
            token = ""
            editing = false
          }
          Button(store.text("Save", "保存")) {
            do {
              _ = try AuthenticationContext.make(
                profile: profile, executable: Bundle.main.executablePath ?? "",
                configurationPath: store.persistence.url.path)
              if profile.kind == .https && token.isEmpty
                && !store.configuration.credentials.contains(where: { $0.id == profile.id })
              {
                throw GitPierError.invalidInput("A token is required for a new HTTPS account.")
              }
              try store.saveCredential(profile, token: token)
              selectedID = profile.id
              token = ""
              editing = false
            } catch { store.error = error.localizedDescription }
          }.buttonStyle(.borderedProminent).disabled(profile.name.isEmpty || profile.host.isEmpty)
        }
      }.textFieldStyle(.roundedBorder).padding(24).frame(width: 550)
    }
    .alert(
      store.text("Delete Credentials?", "删除凭证？"),
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    ) {
      Button(store.text("Delete", "删除"), role: .destructive) {
        do {
          if let deleting { try store.deleteCredential(deleting) }
          deleting = nil
          selectedID = nil
        } catch { store.error = error.localizedDescription }
      }
      Button(store.text("Cancel", "取消"), role: .cancel) { deleting = nil }
    } message: {
      Text(
        store.text(
          "Removes the Keychain token and repository bindings. SSH key files are preserved.",
          "删除 Keychain Token 与仓库绑定，保留 SSH 私钥文件。"))
    }
  }
  func test(_ profile: CredentialProfile) {
    testing = true
    testResult = ""
    Task {
      defer { testing = false }
      do {
        try InputValidation.remoteURL(connectionURL)
        let auth = try AuthenticationContext.make(
          profile: profile, executable: Bundle.main.executablePath ?? CommandLine.arguments[0],
          configurationPath: store.persistence.url.path)
        let result = try await ProcessRunner().run(
          executable: store.settings.gitPath,
          arguments: auth.arguments + ["ls-remote", "--", connectionURL], directory: nil,
          environment: auth.environment, limit: 4 * 1024 * 1024)
        if result.code == 0 {
          testResult = store.text(
            "Connection succeeded. Remote references are readable.", "连接成功，可读取远程引用。")
        } else {
          testResult = GitService.redact(result.errorText)
        }
      } catch { testResult = error.localizedDescription }
    }
  }
}
