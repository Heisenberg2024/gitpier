import AppKit
import GitPierCore
import SwiftTerm
import SwiftUI

#if DEBUG
  if CommandLine.arguments.contains("--product-screenshots") {
    ProductScreenshots.run()
  }
#endif

if CommandLine.arguments.contains("--ssh-profile") {
  SSHLauncher.run()
} else if CommandLine.arguments.contains("--background-keychain-helper") {
  if CommandLine.arguments.last == "get" {
    let request = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    if let response = KeychainStore.internetResponse(request: request) { FileHandle.standardOutput.write(Data(response.utf8)) }
  }
  exit(0)
} else if CommandLine.arguments.contains("--credential-helper") {
  let args = CommandLine.arguments
  if let index = args.firstIndex(of: "--credential-helper"), args.count > index + 2,
    let id = UUID(uuidString: args[index + 1]), args.last == "get"
  {
    let request = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    let url = ProcessInfo.processInfo.environment["GITPIER_CONFIGURATION"].map {
      URL(fileURLWithPath: $0)
    }
    if let configuration = try? ConfigurationStore(url: url).load(),
      let profile = configuration.credentials.first(where: { $0.id == id }),
      let secret = try? KeychainStore().read(id: id, allowInteraction: ProcessInfo.processInfo.environment["GITPIER_BACKGROUND"] != "1"),
      let response = AuthenticationContext.helperResponse(
        request: request, profile: profile, secret: secret)
    {
      FileHandle.standardOutput.write(Data(response.utf8))
    }
  }
  exit(0)
} else if ProcessInfo.processInfo.environment["GITPIER_ASKPASS"] == "1"
  && CommandLine.arguments.count == 2 && !CommandLine.arguments[1].hasPrefix("--")
{
  // Credential helpers run before App construction. Prompts are interactive, never logged or persisted.
  NSApplication.shared.setActivationPolicy(.accessory)
  NSApplication.shared.activate(ignoringOtherApps: true)
  let alert = NSAlert()
  alert.messageText = "GitPier Authentication"
  alert.informativeText = GitService.redact(
    CommandLine.arguments.dropFirst().joined(separator: " "))
  let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
  alert.accessoryView = input
  alert.addButton(withTitle: "Continue")
  alert.addButton(withTitle: "Cancel")
  alert.window.initialFirstResponder = input
  if alert.runModal() == .alertFirstButtonReturn {
    FileHandle.standardOutput.write(Data((input.stringValue + "\n").utf8))
    exit(0)
  }
  exit(1)
} else if CommandLine.arguments.contains("--performance-acceptance") {
  PerformanceAcceptance.run()
} else if CommandLine.arguments.contains("--ui-acceptance") {
  UIAcceptance.run()
} else {
  GitPierApp.main()
}

struct GitPierApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject var store = AppStore.shared
  @Environment(\.openWindow) var openWindow
  var body: some Scene {
    WindowGroup("GitPier", id: "workspace") {
      RootView().environmentObject(store).modifier(AppAppearance(store: store))
        .environment(
          \.locale, Locale(identifier: store.settings.language == .english ? "en_US" : "zh_Hans")
        )
        .frame(minWidth: 960, minHeight: 640)
    }.defaultSize(width: 1440, height: 920).windowToolbarStyle(.unifiedCompact)
      .commands {
        CommandGroup(replacing: .appInfo) {
          Button(store.text("About GitPier", "关于 GitPier")) {
            var options: [NSApplication.AboutPanelOptionKey: Any] = [.applicationName: "GitPier"]
            if let icon = AppResources.applicationIcon { options[.applicationIcon] = icon }
            NSApp.orderFrontStandardAboutPanel(options: options)
          }
        }
        CommandGroup(after: .appInfo) {
          UpdateCheckMenu(manager: store.updates).environmentObject(store)
        }
        CommandGroup(replacing: .newItem) {
          Button(store.text("Open Repository…", "打开仓库…")) { store.openRepository() }
            .keyboardShortcut("o")
          Button(store.text("Clone Repository…", "克隆仓库…")) { store.showClone = true }
          Button(store.text("Quick Open (⌘⇧P)…", "快速打开 (⌘⇧P)…")) { if !terminalFocused() { store.showQuickOpen = true } }
          Button(store.text("Workspace Search…", "工作空间搜索…")) { store.showWorkspaceSearch = true }
          Button(store.text("New Workspace Window", "新建工作空间窗口")) { openWindow(id: "workspace") }
            .keyboardShortcut("n", modifiers: [.command, .shift])
          Button(store.text("Search", "搜索")) {
            NotificationCenter.default.post(
              name: .gitpierSearch, object: terminalFocused() ? "terminal" : nil)
          }.keyboardShortcut("f")
        }
        CommandMenu(store.text("Repository", "仓库")) {
          Button(store.text("Refresh", "刷新")) { Task { await store.refreshVisibleRepositories() } }
            .keyboardShortcut("r")
          Divider()
          Button(localizedUI("Commit")) { store.current?.setPage("commit") }.keyboardShortcut("1")
          Button(store.text("History", "历史")) { store.current?.setPage("history") }
            .keyboardShortcut("2")
          Button(store.text("Branches", "分支")) { store.current?.setPage("branches") }
            .keyboardShortcut("3")
          Divider()
          Button(store.text("Reflog", "引用日志")) { store.current?.setPage("reflog") }.disabled(store.current == nil)
          Button(store.text("Worktrees", "工作树")) { store.current?.setPage("worktrees") }.disabled(store.current == nil)
          Button(store.text("Compare Branches", "比较分支")) { store.current?.setPage("compare") }.disabled(store.current == nil)
          Divider()
          Button(store.text("Toggle Terminal", "显示 / 隐藏终端")) { toggleTerminal() }.keyboardShortcut(
            KeyEquivalent("\u{F70F}"), modifiers: .option)
          Button(store.text("New Terminal Tab", "新建终端标签")) {
            if let model = store.current, terminalFocused() {
              model.terminal.add(settings: store.settings)
            }
          }.keyboardShortcut("t")
          Button(store.text("Close Active Tab", "关闭当前标签")) {
            ShortcutRouter.closeTab(store: store, responder: NSApp.keyWindow?.firstResponder)
          }
        }
        CommandGroup(after: .appSettings) {
          Button(store.text("Credentials…", "凭证…")) { store.showCredentials = true }
        }
        CommandGroup(replacing: .help) {
          Button(store.text("GitPier Help", "GitPier 帮助")) { openWindow(id: "help") }
            .keyboardShortcut("/", modifiers: [.command, .shift])
          Link(
            store.text("Report an Issue…", "报告问题…"),
            destination: URL(string: "https://github.com/Heisenberg2024/gitpier/issues")!)
        }
      }
    Window(store.text("GitPier Help", "GitPier 帮助"), id: "help") {
      HelpView().environmentObject(store).modifier(AppAppearance(store: store))
        .frame(minWidth: 640, minHeight: 500)
    }.defaultSize(width: 780, height: 640)
    Settings {
      SettingsView().environmentObject(store).modifier(AppAppearance(store: store)).frame(
        width: 760, height: 580)
    }
  }
  func toggleTerminal() {
    guard let model = store.current else { return }
    var layout = model.panels.layout
    layout.terminalVisible.toggle()
    model.editLayout(layout)
    if layout.terminalVisible && model.terminal.sessions.isEmpty {
      model.terminal.add(settings: store.settings)
    }
  }
  func terminalFocused() -> Bool { ShortcutRouter.terminalFocused(NSApp.keyWindow?.firstResponder) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  nonisolated(unsafe) private var keyMonitor: Any?
  func applicationDidFinishLaunching(_ notification: Notification) {
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let consumed = MainActor.assumeIsolated {
        ShortcutRouter.handleKeyDown(event, store: AppStore.shared, window: NSApp.keyWindow)
      }
      return consumed ? nil : event
    }
    NSApp.setActivationPolicy(.regular)
    if let icon = AppResources.applicationIcon { NSApp.applicationIconImage = icon }
    NSApp.activate(ignoringOtherApps: true)
    AppStore.shared.updates.start()
    if let index = CommandLine.arguments.firstIndex(of: "--repository"),
      CommandLine.arguments.count > index + 1
    {
      Task {
        await AppStore.shared.addRepository(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
      }
    }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let store = AppStore.shared
    if store.hasBlockingGitOperations {
      let alert = NSAlert()
      alert.messageText = store.text("A Git operation is running", "Git 操作正在运行")
      alert.informativeText = store.text(
        "Wait for Git operations to finish before quitting or installing an update.", "请等待 Git 操作完成后再退出或安装更新。")
      alert.runModal()
      store.updates.terminationWasCancelled()
      return .terminateCancel
    }
    if !store.unsavedConflictDrafts.isEmpty {
      if !store.confirmDiscardConflictDrafts(quitting: true) {
        store.updates.terminationWasCancelled()
        return .terminateCancel
      }
    } else if store.models.values.contains(where: { $0.terminal.sessions.contains { !$0.exited } })
    {
      let alert = NSAlert()
      alert.messageText = store.text("Quit GitPier?", "退出 GitPier？")
      alert.informativeText = store.text(
        "Open terminal sessions and their attached jobs will be stopped. Commit drafts are saved.",
        "将停止终端会话及其作业，提交草稿已保存。")
      alert.addButton(withTitle: store.text("Quit", "退出"))
      alert.addButton(withTitle: store.text("Cancel", "取消"))
      if alert.runModal() != .alertFirstButtonReturn {
        store.updates.terminationWasCancelled()
        return .terminateCancel
      }
    }
    if store.workspace.automaticallyFetching {
      Task {
        await store.workspace.stopAutomaticChecks()
        guard !store.hasBlockingGitOperations else {
          store.updates.terminationWasCancelled()
          sender.reply(toApplicationShouldTerminate: false)
          return
        }
        store.shutdown()
        sender.reply(toApplicationShouldTerminate: true)
      }
      return .terminateLater
    }
    store.shutdown()
    return .terminateNow
  }
}
