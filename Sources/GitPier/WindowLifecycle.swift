import AppKit
import SwiftUI

struct WindowLifecycle: NSViewRepresentable {
  @EnvironmentObject var store: AppStore
  func makeNSView(context: Context) -> WindowHookView { WindowHookView(store: store) }
  func updateNSView(_ view: WindowHookView, context: Context) {}
}

@MainActor final class WindowHookView: NSView {
  unowned let store: AppStore
  var proxy: WindowDelegateProxy?
  init(store: AppStore) {
    self.store = store
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window, proxy == nil else { return }
    store.managedWindows.insert(ObjectIdentifier(window))
    let proxy = WindowDelegateProxy(original: window.delegate, store: store)
    self.proxy = proxy
    window.delegate = proxy
    // Fulfil a CLI request that arrived before this cold-start window existed.
    store.presentNavigationWindow(window)
    if !CommandLine.arguments.contains("--ui-acceptance") {
      window.setFrameAutosaveName("GitPier.Workspace")
    }
  }
}

@MainActor final class WindowDelegateProxy: NSObject, NSWindowDelegate {
  nonisolated(unsafe) weak var original: (any NSWindowDelegate)?
  unowned let store: AppStore
  private var agentsStoppedForClose = false
  init(original: (any NSWindowDelegate)?, store: AppStore) {
    self.original = original
    self.store = store
    super.init()
  }
  override nonisolated func responds(to selector: Selector!) -> Bool {
    super.responds(to: selector) || (original?.responds(to: selector) ?? false)
  }
  override nonisolated func forwardingTarget(for selector: Selector!) -> Any? { original }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if store.managedWindows.count <= 1 {
      if !store.hasBlockingGitOperations, store.workspace.automaticallyFetching {
        Task { await store.workspace.stopAutomaticChecks(); sender.performClose(nil) }
        return false
      }
      if store.hasBlockingGitOperations {
        let alert = NSAlert()
        alert.messageText = store.text("A Git operation is running", "Git 操作正在运行")
        alert.informativeText = store.text(
          "Wait for Git operations to finish before closing the workspace.", "请等待 Git 操作完成后再关闭工作空间。")
        alert.runModal()
        return false
      }
      if !agentsStoppedForClose {
        if !store.reviewSessions.confirmClose(store: store, quitting: false) { return false }
        if !store.taskWorkspaces.confirmQuit() { return false }
        if !store.unsavedConflictDrafts.isEmpty {
          if !store.confirmDiscardConflictDrafts(quitting: false) { return false }
        } else if store.models.values.contains(where: { $0.terminal.sessions.contains { !$0.exited && $0.agentConfiguration == nil } }
        ) {
          let alert = NSAlert()
          alert.messageText = store.text("Close the workspace?", "关闭工作空间？")
          alert.informativeText = store.text(
            "The last window is closing. Running terminal sessions and attached jobs will stop. Drafts are saved.",
            "这是最后一个窗口，将停止终端会话和关联作业，提交草稿已保存。 ")
          alert.addButton(withTitle: store.text("Close", "关闭"))
          alert.addButton(withTitle: store.text("Cancel", "取消"))
          if alert.runModal() != .alertFirstButtonReturn { return false }
        }
      }
      if !store.taskWorkspaces.active.isEmpty {
        Task {
          if await store.taskWorkspaces.stopAllAndWait(), !store.hasBlockingGitOperations {
            agentsStoppedForClose = true; sender.performClose(nil); agentsStoppedForClose = false
          }
        }
        return false
      }
    }
    return original?.windowShouldClose?(sender) ?? true
  }
  func windowWillClose(_ notification: Notification) {
    if let window = notification.object as? NSWindow {
      store.managedWindows.remove(ObjectIdentifier(window))
    }
    if store.managedWindows.isEmpty { store.shutdown() }
    original?.windowWillClose?(notification)
  }
}
