import AppKit
import Foundation
import GitPierCore

@MainActor extension AppStore {
  func enqueueNavigation(_ request: NavigationRequest) {
    guard !recentNavigationIDs.contains(request.id), !pendingNavigation.contains(where: { $0.id == request.id }) else { return }
    guard pendingNavigation.count < 100 else { return }
    pendingNavigation.append(request)
    guard !routingNavigation else { return }
    routingNavigation = true
    Task {
      defer { routingNavigation = false }
      while !pendingNavigation.isEmpty {
        let request = pendingNavigation.removeFirst()
        recentNavigationIDs.append(request.id)
        recentNavigationIDs = Array(recentNavigationIDs.suffix(100))
        await routeNavigation(request)
      }
    }
  }
  func routeNavigation(_ request: NavigationRequest) async {
    do {
      try request.validateAccess()
      let git = await GitServiceRegistry.shared.service(for: request.directory, gitPath: settings.gitPath)
      let root = try await git.validate()
      let common = try await git.commonDirectory()
      // No credential configuration, network check, automatic Fetch, write or confirmation bypass.
      if let existing = repositories.first(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == root }), let model = models[existing.id] {
        selectedID = existing.id; showDashboard = false
        model.record.lastOpened = Date(); update(model.record)
        model.setPage(request.page.rawValue)
        presentNavigationWindow()
        await model.activate(refresh: true)
      } else {
        // URL schemes cannot authenticate a CLI caller. Both CLI and ordinary
        // external URLs require consent before registering an unknown repository.
        let rootIdentity = try TaskDirectoryIdentity.read(root.path)
        let commonIdentity = try TaskDirectoryIdentity.read(common.path)
        presentNavigationWindow()
        guard makeExternalNavigationAlert(root: root).runModal() == .alertFirstButtonReturn else { return }
        try request.validateAccess()
        guard try await git.validate() == root, try await git.commonDirectory() == common,
          try TaskDirectoryIdentity.read(root.path) == rootIdentity,
          try TaskDirectoryIdentity.read(common.path) == commonIdentity else { throw TaskWorkspaceError.changed }
        // Another window may have registered it while native confirmation was open.
        if repositories.contains(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == root }) {
          await routeNavigation(request); return
        }
        var record = RepositoryRecord(path: root.path)
        record.lastOpened = Date()
        configuration.repositories.append(record)
        let model = RepositoryModel(record: record, store: self)
        models[record.id] = model; selectedID = record.id; showDashboard = false
        model.setPage(request.page.rawValue); save()
        presentNavigationWindow()
        await model.activate(refresh: true)
      }
      Workflow170NavigationProbe.record(request, store: self)
    } catch {
      self.error = text("The external navigation request could not open an accessible local Git repository. No Git operation was started.", "外部导航请求无法打开可访问的本地 Git 仓库，未启动 Git 操作。")
    }
  }
  func makeExternalNavigationAlert(root: URL) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = text("Add repository from external navigation?", "添加外部导航请求的仓库？")
    alert.informativeText = text("An external application requested this local repository. The URL does not prove which application sent it. Add this repository to GitPier?", "外部应用请求打开此本地仓库。URL 无法证明发送方身份。是否将此仓库加入 GitPier？") + "\n\n" + root.path
    alert.addButton(withTitle: text("Add Repository", "添加仓库")); alert.addButton(withTitle: text("Cancel", "取消"))
    alert.buttons[0].keyEquivalent = ""; alert.buttons[1].keyEquivalent = "\r"
    alert.window.appearance = settings.appearance == .system ? nil : NSAppearance(named: settings.appearance == .dark ? .darkAqua : .aqua)
    return alert
  }
  func presentNavigationWindow() {
    navigationPresentationPending = true
    // A cold-start URL can arrive before SwiftUI attaches the workspace window.
    guard let window = NSApp.keyWindow.flatMap({ managedWindows.contains(ObjectIdentifier($0)) ? $0 : nil })
      ?? NSApp.orderedWindows.first(where: { managedWindows.contains(ObjectIdentifier($0)) })
      ?? NSApp.windows.first(where: { managedWindows.contains(ObjectIdentifier($0)) }) else { return }
    presentNavigationWindow(window)
  }
  func presentNavigationWindow(_ window: NSWindow) {
    guard navigationPresentationPending, managedWindows.contains(ObjectIdentifier(window)) else { return }
    navigationPresentationPending = false
    if window.isMiniaturized { window.deminiaturize(nil) }
    NSApp.unhide(nil)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}

/// Fixture-only evidence, gated by both disposable runtime identity and bundled workspace path.
@MainActor enum Workflow170NavigationProbe {
  static func record(_ request: NavigationRequest, store: AppStore) {
    guard Bundle.main.object(forInfoDictionaryKey: "GitPierWorkflowTesting") as? Bool == true,
      (Bundle.main.bundleIdentifier ?? "").hasPrefix("com.heisenberg2024.gitpier.workspace-test.workflow170"),
      (store.persistence.url.path.contains("/.cache/v170/") || store.persistence.url.path.hasPrefix("/private/tmp/GitPier-workflow170-")) else { return }
    let result: [String: Any] = ["request": request.id.uuidString, "page": store.current?.page ?? "",
      "root": store.current?.record.path ?? "", "repositories": store.repositories.count,
      "windows": store.managedWindows.count, "pid": ProcessInfo.processInfo.processIdentifier]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
      try? data.write(to: store.persistence.url.deletingLastPathComponent().appendingPathComponent("navigation-" + request.id.uuidString + ".json"), options: .atomic)
    }
  }
}
