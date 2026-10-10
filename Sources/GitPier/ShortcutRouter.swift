import AppKit
import SwiftTerm

@MainActor enum ShortcutRouter {
  static func terminalFocused(_ responder: NSResponder?) -> Bool {
    var current = responder
    while let value = current {
      if value is TerminalView { return true }
      current = value.nextResponder
    }
    return false
  }
  @discardableResult static func closeTab(store: AppStore, responder: NSResponder?) -> Bool {
    guard !store.showDashboard, let model = store.current else { return false }
    if terminalFocused(responder), let id = model.terminal.selectedID {
      model.confirmation = PendingAction(
        title: store.text("Close terminal?", "关闭终端？"),
        detail: store.text("The attached shell and jobs will stop.", "关联 Shell 和作业将停止。")
      ) { model.terminal.close(id) }
      return true
    }
    guard model.record.page == "commit" else { return false }
    if let path = model.selectedPath { model.closeTab(path) }
    return true  // Cmd+W in the commit workbench never closes the workspace, even with no tabs.
  }
}
