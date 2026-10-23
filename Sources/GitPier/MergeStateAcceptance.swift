import AppKit
import GitPierCore
import SwiftUI

@MainActor extension UIAcceptance {
  static func verifyMergeState(root: URL, output: URL) async throws {
    guard root.deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui.") else {
      throw GitPierError.invalidInput("Pending merge acceptance requires disposable repositories")
    }
    let fixture = root.deletingLastPathComponent().appendingPathComponent("merge-state")
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    let raw = GitService(root: fixture)
    func command(_ args: [String]) async throws { _ = try await raw.perform(args) }
    func write(_ path: String, _ text: String) throws {
      try Data(text.utf8).write(to: fixture.appendingPathComponent(path))
    }
    try await command(["init", "-b", "main"])
    try await command(["config", "user.name", "Merge State Acceptance"])
    try await command(["config", "user.email", "merge@example.invalid"])
    try await command(["config", "commit.gpgsign", "false"])
    try await command(["config", "core.hooksPath", fixture.appendingPathComponent(".git/hooks").path])
    try write("state.txt", "base\n"); try write("partial.txt", "base\n")
    try await command(["add", "--", "state.txt", "partial.txt"])
    try await command(["commit", "-m", "base"])
    try write("state.txt", "fixed\n"); try await command(["add", "--", "state.txt"])
    try await command(["commit", "-m", "fix"])
    let incoming = try await raw.status().head!
    try await command(["branch", "incoming"])
    try await command(["update-ref", "refs/remotes/origin/main", incoming])
    try write("state.txt", "fixed; guide added\n"); try write("GUIDE.md", "guide\n")
    try await command(["add", "--", "state.txt", "GUIDE.md"])
    try await command(["commit", "--amend", "-m", "fix and guide"])
    let local = try await raw.status().head!
    let tree = try await raw.snapshot().tree
    let merge = try await raw.read(["merge", "--no-commit", "incoming"], allowFailure: true)
    guard merge.code == 1 else { throw GitPierError.invalidInput("Expected a real merge conflict") }

    let store = AppStore(persistence: ConfigurationStore(url: root.deletingLastPathComponent().appendingPathComponent("merge-state.json")))
    defer { store.shutdown() }
    await store.addRepository(fixture); await store.current?.activate(refresh: true)
    guard let model = store.current else { throw GitPierError.invalidInput("Missing pending merge model") }
    model.editDraft("")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: RootView().environmentObject(store).modifier(AppAppearance(store: store)))
    host.sizingOptions = []
    window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    defer { window.close() }
    var checks: [String] = []
    func require(_ value: Bool, _ name: String) throws {
      guard value else { throw GitPierError.invalidInput("Pending merge: " + name) }
      checks.append(name)
      try checks.joined(separator: "\n").write(to: output.appendingPathComponent("merge-state-results.txt"), atomically: true, encoding: .utf8)
    }
    func control(_ id: String, in view: NSView? = nil) throws -> NSObject {
      guard let result = assistantFind(view ?? host, id: id) else {
        throw GitPierError.invalidInput("Missing pending merge control: " + id)
      }
      return result
    }
    func idle() async throws {
      try await waitFor { !model.busy && !model.refreshing }; try await settle()
    }
    func review() async throws {
      try assistantPress(control("gitpier.merge.complete"))
      try await waitFor { !model.busy && model.confirmation != nil && window.attachedSheet != nil }
      try await settle()
    }
    func sheet(_ action: String) async throws {
      guard let content = window.attachedSheet?.contentView else { throw GitPierError.invalidInput("Missing merge review sheet") }
      try assistantPress(control("gitpier.workflow.review." + action, in: content))
      try await waitFor { window.attachedSheet == nil }; try await idle()
    }
    func screenshot(_ name: String, window target: NSWindow) async throws {
      try await waitFor { target.isVisible && target.windowNumber > 0 }
      let result = try await ProcessRunner().run(executable: "/usr/sbin/screencapture",
        arguments: ["-x", "-o", "-l", String(target.windowNumber), output.appendingPathComponent(name + ".png").path], directory: fixture)
      guard result.code == 0 else {
        throw GitPierError.invalidInput("Native capture \(name), window \(target.windowNumber), visible \(target.isVisible), frame \(target.frame), exit \(result.code): " + result.errorText)
      }
      try require(true, "Native window capture: " + name)
    }
    try await idle()
    try require(model.status.operation == .merge && model.status.files.contains(where: \.isConflicted), "Unresolved merge is identified from live Git state")
    try require(!model.canContinueMerge && assistantFind(host, id: "gitpier.merge.resolve") != nil,
      "Unresolved conflicts expose resolution and prevent completion")
    model.reviewMergeContinuation()
    try require(!model.busy && model.confirmation == nil, "Unresolved files cannot start merge completion")
    let conflict = try await raw.conflictSnapshot("state.txt")
    try await raw.resolveConflict(conflict, resolution: .ours)
    await model.refresh(); try await idle()
    try require(model.status.operation == .merge && model.status.files.isEmpty && model.snapshot?.paths.isEmpty == true,
      "Resolving to the amended HEAD leaves an empty file list and a pending merge")
    try require(!model.canCommit && model.record.draft.isEmpty, "Ordinary commits stay blocked during a pending merge")
    try require(assistantFind(host, id: "gitpier.merge.state") != nil, "Commit page keeps the pending merge visible with no file changes")
    try require((try control("gitpier.merge.complete")).value(forKey: "accessibilityEnabled") as? Bool == true,
      "Empty diff merge completion is enabled without a commit draft or selected files")
    for language in [AppLanguage.english, .simplifiedChinese] {
      for appearance in [AppearanceMode.light, .dark] {
        var settings = store.settings; settings.language = language; settings.appearance = appearance
        store.updateSettings(settings); try await settle()
        try await review()
        let detail = model.confirmation!.detail
        try require(detail.contains(local) && detail.contains(incoming) && detail.contains("Merge branch 'incoming'"), "Merge review includes both full parent IDs and the merge message")
        try await screenshot("merge-state-review-\(language.rawValue)-\(appearance.rawValue)", window: window.attachedSheet!)
        try await sheet("cancel")
        try require(model.status.head == local && model.status.operation == .merge, "Cancelling review preserves the pending merge")
        model.setPage("history"); try await settle()
        try require(assistantFind(host, id: "gitpier.merge.state") != nil, "Pending merge remains visible on the history page")
        model.setPage("commit"); try await settle()
        window.setContentSize(NSSize(width: 960, height: 640)); try await settle()
        let frame = (try control("gitpier.merge.complete")).value(forKey: "accessibilityFrame") as? NSValue
        try require(frame.map { window.frame.contains($0.rectValue) } == true, "Complete Merge remains visible at the minimum window size")
        try await screenshot("merge-state-\(language.rawValue)-\(appearance.rawValue)", window: window)
      }
    }
    // Change the real Index after review, without entering the app's FIFO.
    try await review()
    try write("partial.txt", "external staged\n"); _ = try await raw.read(["add", "--", "partial.txt"])
    try write("partial.txt", "external unstaged\n")
    try await sheet("confirm")
    let staged = try await raw.read(["show", ":partial.txt"]).text
    try require(model.error != nil && model.status.head == local && model.status.operation == .merge
      && staged == "external staged\n" && model.status.files.first(where: { $0.path == "partial.txt" })?.isPartial == true,
      "A stale merge review refuses completion and preserves external partial staging")
    model.error = nil; try await waitFor { window.attachedSheet == nil }
    try write("partial.txt", "base\n"); _ = try await raw.read(["add", "--", "partial.txt"])
    await model.refresh(); try await idle()
    let hook = fixture.appendingPathComponent(".git/hooks/pre-commit")
    try Data("#!/bin/sh\necho 'merge acceptance hook rejection' >&2\nexit 1\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    try await review(); try await sheet("confirm")
    try require(model.status.operation == .merge && model.status.head == local && model.error?.contains("merge acceptance hook rejection") == true,
      "Hook rejection preserves merge state and reports the original failure")
    model.error = nil
    try await waitFor { window.attachedSheet == nil }
    try FileManager.default.removeItem(at: hook)
    try await review(); try await sheet("confirm")
    let merged = try await raw.commitDetail("HEAD")
    let completedTree = try await raw.snapshot().tree
    try require(model.error == nil && model.status.operation == nil && model.status.files.isEmpty,
      "Retry completes the merge and refreshes the clean repository")
    try require(merged.parents == [local, incoming] && completedTree == tree,
      "Empty diff completion creates the two ordered parents without changing the file tree")
    try require(assistantFind(host, id: "gitpier.merge.state") == nil && !model.canCommit,
      "A normal clean repository has no pending merge controls and cannot make an empty commit")

    // Recreate the same state in a linked worktree, then complete its reviewed Index.
    let linked = root.deletingLastPathComponent().appendingPathComponent("merge-state-linked")
    try await command(["worktree", "add", "-b", "linked-case", linked.path, local])
    let linkedGit = GitService(root: linked)
    _ = try await linkedGit.read(["merge", "--no-commit", "incoming"], allowFailure: true)
    try await linkedGit.resolveConflict(linkedGit.conflictSnapshot("state.txt"), resolution: .ours)
    await store.addRepository(linked); await store.current?.activate(refresh: true)
    guard let linkedModel = store.current else { throw GitPierError.invalidInput("Missing linked merge model") }
    try await settle()
    try require(linkedModel.status.operation == .merge && linkedModel.status.files.isEmpty && assistantFind(host, id: "gitpier.merge.state") != nil,
      "A linked worktree finds its own pending merge with an empty file list")
    try Data("staged only\n".utf8).write(to: linked.appendingPathComponent("partial.txt"))
    _ = try await linkedGit.read(["add", "--", "partial.txt"])
    try Data("unstaged remainder\n".utf8).write(to: linked.appendingPathComponent("partial.txt"))
    try Data("keep untracked\n".utf8).write(to: linked.appendingPathComponent("untracked.txt"))
    await linkedModel.refresh(); try await settle()
    try require(linkedModel.canContinueMerge && linkedModel.status.files.first(where: { $0.path == "partial.txt" })?.isPartial == true,
      "A staged merge with an unstaged remainder still offers completion")
    linkedModel.reviewMergeContinuation()
    try await waitFor { linkedModel.confirmation != nil && !linkedModel.busy && window.attachedSheet != nil }
    try await settle()
    try require(linkedModel.confirmation!.detail.contains("partial.txt") && !linkedModel.confirmation!.detail.contains("untracked.txt"),
      "Merge review identifies the authoritative staged files and excludes untracked content")
    try await sheet("confirm")
    try await waitFor { !linkedModel.busy && !linkedModel.refreshing }; try await settle()
    let linkedCommit = try await linkedGit.commitDetail("HEAD")
    let linkedContents = try await linkedGit.read(["show", "HEAD:partial.txt"]).text
    let remainder = try String(contentsOf: linked.appendingPathComponent("partial.txt"), encoding: .utf8)
    try require(linkedModel.status.operation == nil && linkedCommit.parents == [local, incoming] && linkedContents == "staged only\n"
      && remainder == "unstaged remainder\n" && linkedModel.status.untracked.map(\.path) == ["untracked.txt"],
      "Linked merge completion commits only the reviewed Index and preserves unstaged and untracked files")
    // Another linked branch verifies a merge completed by an external Git client.
    let external = root.deletingLastPathComponent().appendingPathComponent("merge-state-external")
    try await command(["worktree", "add", "-b", "external-case", external.path, local])
    let externalGit = GitService(root: external)
    _ = try await externalGit.read(["merge", "--no-commit", "incoming"], allowFailure: true)
    try await externalGit.resolveConflict(externalGit.conflictSnapshot("state.txt"), resolution: .ours)
    await store.addRepository(external); await store.current?.activate(refresh: true)
    guard let externalModel = store.current else { throw GitPierError.invalidInput("Missing external merge model") }
    try await settle()
    try assistantPress(control("gitpier.merge.abort"))
    try await waitFor { externalModel.confirmation != nil && window.attachedSheet != nil }; try await settle()
    try require(externalModel.confirmation!.detail.contains("两条分支仍可能分叉"), "Merge abort explains the remaining divergence")
    try await sheet("cancel")
    try require(externalModel.status.operation == .merge, "Cancelling merge abort preserves the operation")
    try assistantPress(control("gitpier.merge.abort"))
    try await waitFor { externalModel.confirmation != nil && window.attachedSheet != nil }; try await settle()
    try await sheet("confirm"); try await waitFor { !externalModel.busy && !externalModel.refreshing }
    try require(externalModel.status.operation == nil && externalModel.status.head == local
      && assistantFind(host, id: "gitpier.merge.state") == nil, "Confirmed merge abort refreshes back to the pre-merge HEAD")
    _ = try await externalGit.read(["merge", "--no-commit", "incoming"], allowFailure: true)
    try await externalGit.resolveConflict(externalGit.conflictSnapshot("state.txt"), resolution: .ours)
    await externalModel.refresh(); try await settle()
    try require(externalModel.status.operation == .merge && assistantFind(host, id: "gitpier.merge.state") != nil,
      "An externally started and resolved merge reappears after refresh")
    _ = try await externalGit.read(["commit", "-m", "external merge completion"])
    await externalModel.refresh(); try await settle()
    try require(externalModel.status.operation == nil && assistantFind(host, id: "gitpier.merge.state") == nil,
      "External completion removes the merge controls after refresh without a restart")
    _ = try await externalGit.read(["cherry-pick", incoming], allowFailure: true)
    await externalModel.refresh(); try await settle()
    try require(externalModel.status.operation == .cherryPick && !externalModel.canContinueMerge
      && assistantFind(host, id: "gitpier.merge.state") == nil, "Cherry-pick conflicts never use merge completion")
    try await externalGit.resolveConflict(externalGit.conflictSnapshot("state.txt"), resolution: .ours)
    await externalModel.refresh(); try await settle()
    try require(externalModel.status.operation == .cherryPick && externalModel.status.files.isEmpty
      && !externalModel.canCommit && !externalModel.canContinueMerge, "An empty paused cherry-pick retains its own recovery flow")
    _ = try await externalGit.perform(["cherry-pick", "--abort"])
    _ = try await externalGit.read(["switch", "-c", "rebase-case", local])
    _ = try await externalGit.read(["rebase", "incoming"], allowFailure: true)
    await externalModel.refresh(); try await settle()
    try require(externalModel.status.operation == .rebase && !externalModel.canContinueMerge
      && assistantFind(host, id: "gitpier.merge.state") == nil, "Paused rebase retains its own recovery flow")
    _ = try await externalGit.perform(["rebase", "--abort"])
  }
}
