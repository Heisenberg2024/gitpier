import AppKit
import GitPierCore
import SwiftUI

extension UIAcceptance {
  static func verifyVersion120(store: AppStore, output: URL) async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-v120-ui-" + UUID().uuidString)
    let root = parent.appendingPathComponent("main")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let git = GitService(root: root)
    try await git.perform(["init", "-b", "main"])
    try await git.perform(["config", "user.name", "GitPier Workflow Acceptance"])
    try await git.perform(["config", "user.email", "workflow@example.invalid"])
    try await git.perform(["config", "commit.gpgsign", "false"])
    let source = root.appendingPathComponent("workflow.swift")
    try "import Foundation\nlet message = \"seed\"\n".write(to: source, atomically: true, encoding: .utf8)
    try await git.stage(try await git.status().files)
    _ = try await git.commit(message: "seed workflow", expected: git.snapshot())
    try await git.createBranch("topic")
    try "import Foundation\nlet message = \"main-only\"\n".write(to: source, atomically: true, encoding: .utf8)
    try await git.stage(try await git.status().files)
    _ = try await git.commit(message: "main unique commit", expected: git.snapshot())
    try await git.switchBranch("topic")
    try "import Foundation\nlet message = \"topic-only\"\n".write(to: source, atomically: true, encoding: .utf8)
    try await git.stage(try await git.status().files)
    _ = try await git.commit(message: "topic unique commit", expected: git.snapshot())
    try await git.switchBranch("main")
    let owned = try await git.createWorktree(destination: parent.appendingPathComponent("linked"), branch: "ui-linked", newBranch: true)
    store.rememberWorktree(owned)
    await store.addRepository(root)
    guard let model = store.current else { throw GitPierError.invalidInput("Missing workflow model") }
    await model.refresh()
    let before = try await git.reviewOperation()
    let mainDraft = "main isolated draft"
    model.editDraft(mainDraft)
    await store.addRepository(URL(fileURLWithPath: owned.path))
    guard let linkedModel = store.current else { throw GitPierError.invalidInput("Missing linked model") }
    linkedModel.editDraft("linked isolated draft")
    var linkedLayout = linkedModel.panels.layout; linkedLayout.terminalHeight = 405
    linkedModel.editLayout(linkedLayout)
    guard model.record.draft == mainDraft, linkedModel.record.id != model.record.id,
      model.terminal !== linkedModel.terminal,
      model.panels !== linkedModel.panels,
      model.panels.layout.terminalHeight != linkedModel.panels.layout.terminalHeight else {
      throw GitPierError.invalidInput("Worktree model state leaked across working trees")
    }
    store.select(model.record.id)
    await model.activate()
    let original = store.settings
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    window.setFrameOrigin(NSPoint(x: -2000, y: -2000)); window.orderFront(nil)
    defer { host.rootView = AnyView(EmptyView()); window.close(); store.updateSettings(original); linkedModel.shutdown(); model.shutdown() }

    // Cancellation is deliberately ignored by the old worker; only a ticket can reject it.
    let requests = WorkflowRequest()
    var published = ""
    requests.start { ticket in
      await Task.detached { try? await Task.sleep(for: .milliseconds(180)) }.value
      if requests.current(ticket) { published = "stale" }
    }
    requests.start { ticket in if requests.current(ticket) { published = "latest" } }
    try await settle()
    guard published == "latest" else { throw GitPierError.invalidInput("A stale workflow result overwrote the current selection") }
    requests.cancel()

    // Repair resets the cached Git actor, watcher and terminal root without changing record ID.
    // Only this worktree's drafts constrain repair; another tree's draft is retained.
    let linkedID = linkedModel.record.id
    linkedModel.editDraft("")
    let relocated = parent.appendingPathComponent("relocated-linked")
    try FileManager.default.moveItem(at: URL(fileURLWithPath: owned.path), to: relocated)
    let repaired = try await git.repairWorktree(at: relocated)
    await store.reconcileMovedWorktree(repaired)
    guard linkedModel.record.id == linkedID, linkedModel.record.path == relocated.path,
      await linkedModel.git().root.path == relocated.path, linkedModel.available,
      model.record.draft == mainDraft else { throw GitPierError.invalidInput("Moved worktree retained a stale service or leaked repository state") }
    let externalPath = parent.appendingPathComponent("external-tool")
    try await git.perform(["worktree", "add", "-b", "external-tool", externalPath.path])
    await store.addRepository(externalPath)
    guard let externalModel = store.current else { throw GitPierError.invalidInput("Missing external worktree model") }
    let externalID = externalModel.record.id
    let externalMoved = parent.appendingPathComponent("external-moved")
    try FileManager.default.moveItem(at: externalPath, to: externalMoved)
    let externalReview = try await git.reviewWorktreeRepair(at: externalMoved)
    let externalRepair = try await git.repairWorktree(externalReview)
    await store.reconcileMovedWorktree(externalRepair, previousPath: externalReview.previous.path)
    guard externalModel.record.id == externalID, externalModel.available,
      externalModel.record.path == externalMoved.path,
      !store.configuration.ownedWorktrees.contains(where: { $0.gitDirectory == externalRepair.gitDirectory }) else {
      throw GitPierError.invalidInput("External repair lost its record or granted unknown-directory deletion: id=\(externalModel.record.id == externalID), available=\(externalModel.available), path=\(externalModel.record.path), expected=\(externalMoved.path), owned=\(store.configuration.ownedWorktrees.contains { $0.gitDirectory == externalRepair.gitDirectory }), error=\(externalModel.error ?? "none")")
    }
    store.select(model.record.id)
    defer { store.remove(externalID) }
    for language in AppLanguage.allCases {
      for appearance in [AppearanceMode.light, .dark] {
        var settings = original; settings.language = language; settings.appearance = appearance
        store.updateSettings(settings)
        let suffix = language.rawValue + "-" + appearance.rawValue
        for (name, content) in [
          ("reflog", AnyView(ReflogView(model: model))),
          ("worktrees", AnyView(WorktreesView(model: model))),
          ("comparison", AnyView(BranchComparisonView(model: model))),
          ("blame", AnyView(BlameView(model: model, request: BlameRequest(path: "workflow.swift"))))
        ] {
          if name == "comparison" { model.comparisonRight = "refs/heads/topic" }
          host.rootView = AnyView(content.environmentObject(store).modifier(AppAppearance(store: store)))
          window.setContentSize(NSSize(width: 960, height: 640))
          host.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
          try await settle()
          if name == "comparison" {
            try await waitFor {
              descendants(host).compactMap { $0 as? NSTableView }.compactMap { $0.dataSource as? DiffTable.Coordinator }
                .contains { $0.document.raw.contains("topic-only") || $0.document.raw.contains("main-only") }
            }
          }
          try capture(host, to: output.appendingPathComponent("v120-" + name + "-" + suffix + ".png"))
          host.rootView = AnyView(EmptyView()); try await Task.sleep(for: .milliseconds(80))
        }
      }
    }
    var settings = original
    settings.language = ProcessInfo.processInfo.environment["GITPIER_UI_ACCEPTANCE_LANGUAGE"] == "zh-Hans" ? .simplifiedChinese : .english
    settings.appearance = ProcessInfo.processInfo.environment["GITPIER_UI_ACCEPTANCE_APPEARANCE"] == "light" ? .light : .dark
    store.updateSettings(settings)
    model.setPage("reflog")
    host.rootView = AnyView(ReflogView(model: model).environmentObject(store).modifier(AppAppearance(store: store)))
    try await settle()
    let entries = try await git.reflog()
    guard let entry = entries.first else { throw GitPierError.invalidInput("Missing reflog records") }
    _ = try await git.commitDetail(entry.hash)
    host.rootView = AnyView(EmptyView())
    let after = try await git.reviewOperation()
    guard before == after else { throw GitPierError.invalidInput("Read-only workflow UI modified HEAD or Index") }
    if ProcessInfo.processInfo.environment["GITPIER_UI_ACCEPTANCE_INTERACTIVE_WORKFLOWS"] == "1" {
      host.rootView = AnyView(RootView().environmentObject(store).modifier(AppAppearance(store: store)))
      window.title = "GitPier v1.2 Acceptance — Temporary Repositories"
      window.setContentSize(NSSize(width: 960, height: 640))
      host.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
      host.autoresizingMask = [.width, .height]
      window.center(); window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      try "Ready for native GUI interactions. Temporary fixture: " .appending(root.path).write(to: output.appendingPathComponent("gui-ready.txt"), atomically: true, encoding: .utf8)
      let marker = output.appendingPathComponent("finish-gui")
      while !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(for: .milliseconds(250)) }
      try FileManager.default.removeItem(at: marker)
    }
    try "Hosted Reflog, Worktree, comparison and Blame query/render checks in English/Chinese and light/dark at 960×640. Shared Diff rendered real branch changes. Cancelled stale query rejected; per-worktree drafts, layouts and terminal managers stayed independent. HEAD and Index preserved. Offscreen bitmap captures do not establish complete SwiftUI appearance; verify it in the isolated visible GUI.\n".write(to: output.appendingPathComponent("version120-results.txt"), atomically: true, encoding: .utf8)
    store.configuration.ownedWorktrees.removeAll { $0.gitDirectory == owned.gitDirectory }
    store.remove(linkedModel.record.id); store.remove(model.record.id)
  }
}
