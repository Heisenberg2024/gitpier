import AppKit
import SwiftTerm

@MainActor enum ShortcutRouter {
  static func handleKeyDown(_ event: NSEvent, store: AppStore, window: NSWindow?) -> Bool {
    guard let window, store.managedWindows.contains(ObjectIdentifier(window)),
      window.attachedSheet == nil, store.current?.confirmation == nil
    else { return false }
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "p",
       !terminalFocused(window.firstResponder) {
      store.showQuickOpen = true
      return true
    }
    if event.keyCode == 53, modifiers.isEmpty {
      return closeHistory(store: store, responder: window.firstResponder)
    }
    guard modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "w" else {
      return false
    }
    return closeTab(store: store, responder: window.firstResponder)
  }
  @discardableResult static func closeHistory(store: AppStore, responder: NSResponder?) -> Bool {
    guard !store.showDashboard, let model = store.current, model.page == "history",
      model.selectedHistoryCommit != nil, !terminalFocused(responder)
    else { return false }
    model.selectedHistoryCommit = nil
    return true
  }
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
    guard model.page == "commit" else { return false }
    if let path = model.selectedPath { model.closeTab(path) }
    return true  // Cmd+W in the commit workbench never closes the workspace, even with no tabs.
  }
}
