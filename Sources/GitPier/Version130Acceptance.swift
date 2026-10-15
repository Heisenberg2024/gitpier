import AppKit
import GitPierCore
import SwiftUI

extension UIAcceptance {
  static func verifyVersion130(store: AppStore, output: URL) async throws {
    if ProcessInfo.processInfo.environment["GITPIER_UI_ACCEPTANCE_INTERACTIVE_V130"] == "1" {
      NSApp.setActivationPolicy(.regular)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-v130-ui-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let git = GitService(root: root)
    try await git.perform(["init", "-b", "main"])
    try await git.perform(["config", "user.name", "GitPier Rebase Acceptance"])
    try await git.perform(["config", "user.email", "acceptance@example.invalid"])
    try await git.perform(["config", "commit.gpgsign", "false"])
    try await git.perform(["config", "core.attributesFile", "/dev/null"])
    let source = root.appendingPathComponent("workflow.swift")
    try "let value = 0\n".write(to: source, atomically: true, encoding: .utf8)
    try await git.stage(try await git.status().files)
    _ = try await git.commit(message: "seed", expected: git.snapshot())
    let base = try await git.resolveCommit("HEAD")
    for n in 1...3 {
      try "let value = \(n)\n".write(to: source, atomically: true, encoding: .utf8)
      try await git.stage(try await git.status().files)
      _ = try await git.commit(message: "change \(n)", expected: git.snapshot())
    }
    await store.addRepository(root)
    guard let model = store.current else { throw GitPierError.invalidInput("Missing rebase acceptance model") }
    await model.refresh()
    let original = store.settings
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                          styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    window.setContentSize(NSSize(width: 860, height: 620))
    host.frame = NSRect(x: 0, y: 0, width: 860, height: 620)
    host.autoresizingMask = [.width, .height]
    // SwiftUI's complete accessibility tree is available only in a real visible native window.
    window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    defer { host.rootView = AnyView(EmptyView()); window.close(); model.shutdown(); store.updateSettings(original); store.remove(model.record.id) }
    let before = try await git.reviewOperation()
    for language in AppLanguage.allCases {
      for appearance in [AppearanceMode.light, .dark] {
        var settings = original; settings.language = language; settings.appearance = appearance
        store.updateSettings(settings)
        host.rootView = AnyView(InteractiveRebaseView(model: model, initialUpstream: base)
          .environmentObject(store).modifier(AppAppearance(store: store)))
        try await settle()
        try capture(host, to: output.appendingPathComponent("v130-rebase-loading.png"))
        try accessibilityLabels(host).write(to: output.appendingPathComponent("v130-rebase-accessibility.txt"), atomically: true, encoding: .utf8)
        try await waitFor {
          accessibleButton(host, title: store.text("Review & Rewrite History…", "审查并改写历史…"), enabled: true) != nil
        }
        try capture(host, to: output.appendingPathComponent("v130-rebase-" + language.rawValue + "-" + appearance.rawValue + ".png"))
        host.rootView = AnyView(EmptyView()); try await settle()
      }
    }
    guard try await git.reviewOperation() == before else { throw GitPierError.invalidInput("Read-only rebase review changed Git state") }
    let candidate = try await git.interactiveRebaseCandidate(upstream: base)
    var plan = InteractiveRebasePlan(candidate: candidate)
    plan.steps[0].action = .reword; plan.steps[0].message = "reviewed change 1"
    model.run(label: "Rebase acceptance") { git in model.output = try await git.startInteractiveRebase(plan) }
    try await waitFor { !model.busy }
    guard model.status.operation == nil, model.status.files.isEmpty, model.error == nil else {
      throw GitPierError.invalidInput(model.error ?? "Rebase model did not refresh")
    }
    let rewritten = try await git.history()
    guard rewritten[2].subject == "reviewed change 1" else { throw GitPierError.invalidInput("Rebase message was not applied") }
    let next = try await git.interactiveRebaseCandidate(upstream: base)
    let conflictPlan = InteractiveRebasePlan(candidate: next, steps: [
      RebaseStep(commit: next.commits[2]), RebaseStep(commit: next.commits[0], action: .drop),
      RebaseStep(commit: next.commits[1], action: .drop)])
    model.run { git in model.output = try await git.startInteractiveRebase(conflictPlan) }
    try await waitFor { !model.busy }
    guard model.status.operation == .rebase, model.page == "conflicts" else {
      throw GitPierError.invalidInput("Rebase conflict did not reach the conflict workspace")
    }
    host.rootView = AnyView(RebaseRecoveryView(model: model).environmentObject(store).modifier(AppAppearance(store: store)))
    try await settle()
    try await waitFor {
      accessibleButton(host, title: store.text("Skip Commit…", "跳过提交…"), enabled: true) != nil
    }
    try capture(host, to: output.appendingPathComponent("v130-rebase-recovery.png"))
    host.rootView = AnyView(EmptyView()); try await settle()
    let paused = try await git.rebaseState()
    guard let paused else { throw GitPierError.invalidInput("Missing native rebase state") }
    model.run { git in model.output = try await git.controlRebase(.abort, expected: paused) }
    try await waitFor { !model.busy }
    guard model.status.operation == nil, model.status.head == next.review.head else {
      throw GitPierError.invalidInput("Rebase Abort did not refresh the restored HEAD")
    }
    try await verifySelectedLines(store: store, model: model, git: git, source: source,
                                  host: host, window: window, output: output)
    // The dedicated Rebase inspection retains the already verified clean linear fixture.
    if ProcessInfo.processInfo.environment["GITPIER_UI_ACCEPTANCE_INTERACTIVE_PAGE"] != "rebase" {
      try await verifyAdvanced130(store: store, model: model, git: git, root: root,
                                  source: source, host: host, window: window, output: output)
    }
    if ProcessInfo.processInfo.environment["GITPIER_UI_ACCEPTANCE_INTERACTIVE_V130"] == "1" {
      var settings = original
      settings.language = ProcessInfo.processInfo.environment["GITPIER_UI_ACCEPTANCE_LANGUAGE"] == "zh-Hans" ? .simplifiedChinese : .english
      settings.appearance = ProcessInfo.processInfo.environment["GITPIER_UI_ACCEPTANCE_APPEARANCE"] == "light" ? .light : .dark
      let requested = ProcessInfo.processInfo.environment["GITPIER_UI_ACCEPTANCE_INTERACTIVE_PAGE"] ?? "history"
      if requested == "advanced" { settings.gitPath = root.appendingPathComponent(".git/git-lfs-interface-fixture").path }
      store.updateSettings(settings)
      if requested == "advanced" {
        await model.configure()
        let original = try Data(contentsOf: source)
        try Data("let value = 4\n".utf8).write(to: source)
        let file = try await git.status().files.first { $0.path == "workflow.swift" }!
        let patch = try await git.exportFilePatch(file, comparison: .unstaged)
        try original.write(to: source)
        host.rootView = AnyView(Advanced130ReviewPanel(model: model, patch: patch).environmentObject(store).modifier(AppAppearance(store: store)))
      } else if requested == "about" {
        host.rootView = AnyView(SettingsView(initialTab: 7).environmentObject(store).modifier(AppAppearance(store: store)))
      } else if requested == "rebase" {
        host.rootView = AnyView(InteractiveRebaseView(model: model, initialUpstream: base).environmentObject(store).modifier(AppAppearance(store: store)))
      } else {
      model.setPage(requested == "lines" ? "commit" : ["history", "lfs", "submodules"].contains(requested) ? requested : "history")
      host.rootView = AnyView(RootView().environmentObject(store).modifier(AppAppearance(store: store)))
      }
      window.title = "GitPier v1.3 Acceptance — Temporary Repository"
      window.setContentSize(requested == "about" ? NSSize(width: 760, height: 580) : NSSize(width: 960, height: 640))
      window.center(); window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      try root.path.write(to: output.appendingPathComponent("gui-ready.txt"), atomically: true, encoding: .utf8)
      let finish = output.appendingPathComponent("finish-gui")
      while !FileManager.default.fileExists(atPath: finish.path) { try await Task.sleep(for: .milliseconds(250)) }
      try FileManager.default.removeItem(at: finish)
    }
    try "Rebase review controls rendered in both languages and appearances. Cancelled/read-only review preserved HEAD and Index. Model execution refreshed history; conflicts opened the existing workspace; native Abort restored HEAD. Hosted captures are supplementary; actual drag/confirmation and visible appearance require isolated GUI interaction.\n"
      .write(to: output.appendingPathComponent("version130-results.txt"), atomically: true, encoding: .utf8)
  }
  static func verifySelectedLines(store: AppStore, model: RepositoryModel, git: GitService, source: URL,
                                  host: NSHostingView<AnyView>, window: NSWindow, output: URL) async throws {
    let original = try String(contentsOf: source, encoding: .utf8)
    let working = "let value = 4\nlet added = true\n"
    try working.write(to: source, atomically: true, encoding: .utf8)
    await model.refresh()
    guard let file = model.status.files.first(where: { $0.path == "workflow.swift" }) else {
      throw GitPierError.invalidInput("Missing selected-lines fixture change")
    }
    model.comparison = .unstaged; model.select(file, permanent: true)
    host.rootView = AnyView(DiffPanel(model: model).environmentObject(store).modifier(AppAppearance(store: store)))
    try await waitFor { !model.diffLoading && !model.diff.hunks.isEmpty }
    try await settle()
    func selectPairAndApply(_ title: String) async throws {
      guard let container = descendants(host).compactMap({ $0 as? DiffSplitContainer }).first,
        let coordinator = container.tables[0].dataSource as? DiffTable.Coordinator,
        let row = coordinator.document.pairs.firstIndex(where: { $0.old?.kind == .deletion && $0.new?.kind == .addition }) else {
        throw GitPierError.invalidInput("Missing shared native Diff replacement pair")
      }
      for side in 0...1 {
        let table = container.tables[side]
        let point = table.convert(NSPoint(x: 12, y: table.rect(ofRow: row).midY), to: nil)
        guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point,
          modifierFlags: side == 0 ? [] : .command, timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
          throw GitPierError.invalidInput("Cannot create native gutter acceptance event")
        }
        table.mouseDown(with: event)
      }
      try await settle()
      guard coordinator.selectedLineIDs.count == 2, coordinator.onLineAction != nil else {
        throw GitPierError.invalidInput("Native gutter clicks did not select exactly the replacement pair")
      }
      guard let button = accessibleButton(host, title: title, enabled: true) else {
        throw GitPierError.invalidInput("Selected-lines toolbar action did not become enabled")
      }
      let selector = NSSelectorFromString("accessibilityPerformPress")
      typealias Press = @convention(c) (AnyObject, Selector) -> Bool
      let press = unsafeBitCast(button.method(for: selector), to: Press.self)
      guard press(button, selector) else { throw GitPierError.invalidInput("Selected-lines toolbar press failed") }
      try await waitFor { !model.busy && !model.diffLoading }
      guard model.error == nil else { throw GitPierError.invalidInput(model.error!) }
    }
    try await selectPairAndApply(store.text("Stage Selected Lines", "暂存选中行"))
    let staged = try await git.read(["show", ":workflow.swift"]).text
    guard staged == "let value = 4\n", try String(contentsOf: source, encoding: .utf8) == working else {
      throw GitPierError.invalidInput("Selected staging expanded its pair or changed the working file")
    }
    try capture(host, to: output.appendingPathComponent("v130-selected-lines-staged.png"))
    model.comparison = .staged; model.loadDiff()
    try await waitFor { !model.diffLoading && !model.diff.hunks.isEmpty }; try await settle()
    try await selectPairAndApply(store.text("Unstage Selected Lines", "取消暂存选中行"))
    let unstaged = try await git.read(["show", ":workflow.swift"]).text
    guard unstaged == original, try String(contentsOf: source, encoding: .utf8) == working else {
      throw GitPierError.invalidInput("Selected unstaging lost existing work or expanded the patch")
    }
    host.rootView = AnyView(EmptyView()); try await settle()
    if ProcessInfo.processInfo.environment["GITPIER_UI_ACCEPTANCE_INTERACTIVE_PAGE"] != "lines" {
      try original.write(to: source, atomically: true, encoding: .utf8); await model.refresh()
    } else { model.comparison = .unstaged; model.loadDiff() }
    try "Native old/new gutter clicks with Command selected exactly one replacement pair. Toolbar Stage/Unstage became enabled and changed only that pair; the extra working line remained. Diff selection invalidated after state/comparison refresh.\n"
      .write(to: output.appendingPathComponent("selected-lines-results.txt"), atomically: true, encoding: .utf8)
  }
  static func accessibleButton(_ host: NSView, title: String, enabled: Bool? = nil) -> NSObject? {
    var visited = Set<ObjectIdentifier>()
    func value(_ object: NSObject, _ name: String) -> Any? {
      let selector = NSSelectorFromString(name)
      return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
    }
    func find(_ item: Any, depth: Int = 0) -> NSObject? {
      guard depth < 80, let item = item as? NSObject,
        visited.insert(ObjectIdentifier(item)).inserted else { return nil }
      if ["AXButton", "AXCheckBox"].contains(value(item, "accessibilityRole") as? String ?? ""),
        value(item, "accessibilityLabel") as? String == title {
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        if let enabled, item.responds(to: selector) {
          typealias Enabled = @convention(c) (AnyObject, Selector) -> Bool
          let getter = unsafeBitCast(item.method(for: selector), to: Enabled.self)
          if getter(item, selector) != enabled { return nil }
        }
        return item
      }
      for child in value(item, "accessibilityChildren") as? [Any] ?? [] {
        if let result = find(child, depth: depth + 1) { return result }
      }
      if let view = item as? NSView {
        for child in view.subviews { if let result = find(child, depth: depth + 1) { return result } }
      }
      return nil
    }
    return find(host)
  }
  static func accessibilityLabels(_ host: NSView) -> String {
    var visited = Set<ObjectIdentifier>(); var lines: [String] = []
    func walk(_ object: Any, depth: Int = 0) {
      guard depth < 80, let object = object as? NSObject,
        visited.insert(ObjectIdentifier(object)).inserted else { return }
      func value(_ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
      }
      if let label = value("accessibilityLabel") as? String { lines.append((value("accessibilityRole") as? String ?? "") + " " + label) }
      for child in value("accessibilityChildren") as? [Any] ?? [] { walk(child, depth: depth + 1) }
      if let view = object as? NSView { for child in view.subviews { walk(child, depth: depth + 1) } }
    }
    walk(host); return lines.joined(separator: "\n")
  }
}
