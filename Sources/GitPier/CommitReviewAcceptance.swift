import AppKit
import GitPierCore
import SwiftUI

@MainActor extension UIAcceptance {
  static func verifyCommitReviews(root: URL, output: URL) async throws {
    guard root.deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui.") else {
      throw GitPierError.invalidInput("Commit review acceptance requires a disposable repository")
    }
    var checks: [String] = []
    func require(_ value: Bool, _ name: String) throws {
      guard value else { throw GitPierError.invalidInput("Commit review: " + name) }
      checks.append(name)
      try checks.joined(separator: "\n").write(to: output.appendingPathComponent("commit-review-results.txt"), atomically: true, encoding: .utf8)
    }
    let store = AppStore(persistence: ConfigurationStore(url: root.deletingLastPathComponent().appendingPathComponent("commit-review.json")))
    defer { store.shutdown() }
    await store.addRepository(root); await store.current?.activate(refresh: true)
    guard let model = store.current else { throw GitPierError.invalidInput("Missing commit review fixture") }
    let git = await model.git()
    let initial = try await git.snapshot()
    let indexURL = root.appendingPathComponent(".git/index")
    let draft = "test: snapshot-scoped commit review"
    model.editDraft(draft)
    func selectAll() { model.toggleIncluded(model.status.files.filter { !model.includedPaths.contains($0.path) }) }
    selectAll()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640), styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: RootView().environmentObject(store).modifier(AppAppearance(store: store)))
    window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    defer { window.close() }
    func settleOperation() async throws {
      try await waitFor { !model.busy && !model.refreshing }
      try await settle()
    }
    func press(_ name: String) async throws {
      try await waitFor { window.attachedSheet != nil }
      try await settle()
      guard let content = window.attachedSheet?.contentView,
        let button = assistantFind(content, id: "gitpier.workflow.review." + name) else {
        throw GitPierError.invalidInput("Missing commit review control: " + name)
      }
      let frame = (button.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
      try require(window.attachedSheet!.frame.height <= 440 && window.attachedSheet!.frame.width <= 620, "Three-action review remains bounded")
      try require(!frame.isEmpty && window.attachedSheet!.frame.contains(frame), name + " control is visible inside the bounded sheet")
      try assistantPress(button)
      try await waitFor { window.attachedSheet == nil }
    }
    func openReview() throws -> String {
      model.commit(push: false)
      try require(model.confirmation != nil && !model.busy, "Changed snapshot opens review before writing")
      return model.confirmation!.detail
    }
    func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
    func stage(_ path: String) async throws {
      // Simulate another client: a direct Git command does not join the application's write queue.
      _ = try await git.read(["--literal-pathspecs", "add", "--", path])
    }
    try require(!model.requiresIndexReview, "Initial snapshot needs no historical review")
    try await git.switchBranch("feature/terminal"); await model.refresh()
    try require(model.requiresIndexReview, "A branch change with the same HEAD requires review")
    try await git.switchBranch("main"); await model.refresh()
    try require(!model.requiresIndexReview, "Returning to the reviewed identity clears the historical change")

    try write("working-only.txt", "Working tree edits do not change Index identity\n")
    await model.refresh(); selectAll()
    try require(!model.requiresIndexReview && model.snapshot?.identity == initial.identity, "Working tree edits alone never require Index review")
    let readme = model.status.files.filter { $0.path == "README.md" }
    model.run(updatesCommitState: .index) { git in
      try await git.stage(readme)
      await model.refresh()
    }
    try await settleOperation()
    try require(!model.requiresIndexReview, "A read during owned staging cannot leave a historical warning after success")
    model.stageGroup(model.status.files.filter { $0.path == "README.md" }, unstage: true)
    try await settleOperation()
    var duringWriteRead: Task<Void, Never>?
    model.run(updatesCommitState: .index) { git in
      await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
        duringWriteRead = Task { started.resume(); await model.refresh() }
      }
      try await git.stage(readme)
    }
    try await settleOperation(); await duringWriteRead?.value
    let afterOverlappingRead = try await git.snapshot()
    try require(model.snapshot == afterOverlappingRead && !model.requiresIndexReview,
      "A read overlapping owned staging cannot leave an older snapshot or historical warning after completion")
    try require(!model.requiresIndexReview, "GitPier staging establishes its own snapshot")
    model.stageGroup(model.status.files.filter { $0.path == "README.md" }, unstage: true)
    try await settleOperation()
    try require(!model.requiresIndexReview, "GitPier unstaging does not create an external change notice")

    try await stage("README.md")
    let staged = try await git.snapshot()
    try require(CommitStateUpdate.index.accepts(initial, staged) && !CommitStateUpdate.history.accepts(initial, staged),
      "Only an Index operation can own a new staged tree; history operations keep staged leftovers pending")
    let stagedBytes = try Data(contentsOf: indexURL)
    model.run { _ in }
    try await settleOperation()
    try require(model.requiresIndexReview, "An operation cannot consume an external change that existed before it but was not yet refreshed")
    let detail = try openReview()
    try require(detail.contains("Index:") && detail.contains(String(initial.tree.prefix(8))) && detail.contains(String(staged.tree.prefix(8))), "Index notice includes the actual old and new tree IDs")
    try require(detail.contains("Staged files (1)") && detail.contains("Selected files ("), "Staged files and selected working files are distinguished")
    try await press("cancel")
    await model.refresh()
    try require(model.requiresIndexReview, "Cancel does not silently acknowledge unseen changes")
    _ = try openReview(); try await press("reviewed")
    try require(!model.requiresIndexReview && model.record.draft == draft, "Review-only acknowledgment clears this snapshot and preserves the draft")
    let afterReview = try await git.snapshot()
    try require(afterReview == staged && (try Data(contentsOf: indexURL)) == stagedBytes, "Review-only acknowledgment never changes HEAD or exact Index bytes")
    await model.refresh()
    try require(!model.requiresIndexReview, "Refreshing an acknowledged snapshot does not repeat its notice")

    try write("README.md", "Another version at the same staged path\n")
    try await stage("README.md"); await model.refresh()
    let changed = try await git.snapshot()
    var pendingReview = CommitSnapshotReview()
    pendingReview.observe(staged, ownedChangeFrom: nil)
    pendingReview.observe(initial, ownedChangeFrom: nil)
    pendingReview.observe(changed, ownedChangeFrom: initial.identity)
    try require(pendingReview.requiresReview, "An owned change cannot acknowledge an earlier unreviewed external transition")
    let samePathDetail = try openReview()
    try require(samePathDetail.contains(String(staged.tree.prefix(8))) && samePathDetail.contains(String(changed.tree.prefix(8))), "Changed staged content is detected even when the path count is unchanged")
    try await stage("settings.json"); await model.refresh()
    try await press("reviewed")
    try require(model.requiresIndexReview, "Acknowledging an older open sheet cannot clear a newer Index change")
    var settings = store.settings; settings.language = .simplifiedChinese; store.updateSettings(settings)
    let chinese = try openReview()
    try require(chinese.contains("当前暂存文件（2）") && chinese.contains("本次选择文件（") && chinese.contains("Index:"), "Chinese review describes current staging and selection")
    try await press("reviewed")
    settings.language = .english; store.updateSettings(settings)
    let beforeHead = try await git.snapshot()
    let externalCommit = try await git.commit(message: "test: external HEAD transition", expected: beforeHead)
    await model.refresh(); selectAll()
    let headDetail = try openReview()
    try require(headDetail.contains("HEAD:") && headDetail.contains(String(beforeHead.head!.prefix(8))) && headDetail.contains(String(externalCommit.hash.prefix(8))) && !headDetail.contains("Index:"), "HEAD-only transition is explained without claiming an Index tree change")
    try await press("reviewed")
    let onMain = try await git.snapshot()
    try await git.createBranch("review/other"); try await git.switchBranch("review/other"); await model.refresh()
    let onOther = try await git.snapshot()
    try require(!CommitStateUpdate.index.accepts(beforeHead, onMain), "An Index-only operation cannot own a HEAD transition")
    try require(!CommitStateUpdate.history.accepts(onMain, onOther) && CommitStateUpdate.checkout.accepts(onMain, onOther),
      "Only an explicit checkout can own a branch transition")
    try require(!CommitStateUpdate.commit(head: onOther.head!, branch: onMain.branch, acceptsIndex: true).accepts(onMain, onOther),
      "A commit receipt rejects a different branch even when HEAD matches")
    try require(!CommitStateUpdate.commit(head: onOther.head!, branch: onOther.branch, acceptsIndex: false).accepts(onMain, onOther),
      "A commit receipt never owns Index changes reported by Hooks")
    let branchDetail = try openReview()
    try require(branchDetail.contains("Branch: main → review/other") && !branchDetail.contains("HEAD:") && !branchDetail.contains("Index:"), "Branch-only transition is explained independently")
    try await press("reviewed")

    // Staged-only selection prevents our own automatic staging from introducing a new identity.
    try await stage("working-only.txt"); await model.refresh()
    model.toggleIncluded(model.status.files.filter { model.includedPaths.contains($0.path) && $0.path != "working-only.txt" })
    let hook = root.appendingPathComponent(".git/hooks/pre-commit")
    try write(".git/hooks/pre-commit", "#!/bin/sh\necho 'Synthetic review hook rejection' >&2\nexit 1\n")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    let beforeHook = try await git.snapshot()
    let beforeHookBytes = try Data(contentsOf: indexURL)
    _ = try openReview(); try await press("confirm"); try await settleOperation()
    try require(model.error != nil && model.lastCommit == nil && !model.requiresIndexReview, "Failed hook preserves the explicit acknowledgment without requiring a successful commit")
    let afterHook = try await git.snapshot()
    try require(afterHook == beforeHook && (try Data(contentsOf: indexURL)) == beforeHookBytes && model.record.draft == draft, "Hook rejection preserves HEAD, exact Index bytes and draft")
    model.commit(push: false)
    try require(model.confirmation == nil && model.busy, "Retrying the same acknowledged snapshot does not reopen review")
    try await settleOperation()
    try FileManager.default.removeItem(at: hook)
    model.error = nil; try await settle()

    // Change Git behind the displayed model, without refreshing it. The real write gate must reject it.
    try write("race-selected.txt", "Must remain untracked on stale attempts\n")
    await model.refresh(); selectAll()
    for kind in ["Index", "HEAD", "Branch"] {
      if !model.requiresIndexReview {
        try write("README.md", "Trigger a new review before race \(kind)\n")
        try await stage("README.md"); await model.refresh()
      }
      _ = try openReview()
      switch kind {
      case "Index":
        try write("README.md", "External Index mutation during the sheet\n"); try await stage("README.md")
      case "HEAD":
        _ = try await git.commit(message: "test: external commit during review", expected: git.snapshot())
      default:
        try await git.createBranch("review/race"); try await git.switchBranch("review/race")
      }
      let external = try await git.snapshot()
      let externalBytes = try Data(contentsOf: indexURL)
      try await press("confirm"); try await settleOperation()
      let observed = try await git.snapshot()
      try require(model.error != nil && observed == external && (try Data(contentsOf: indexURL)) == externalBytes, "Actual \(kind) race is rejected without modifying the external state")
      try require(model.requiresIndexReview && model.record.draft == draft, "Failed \(kind) race refresh records a new review instead of losing it while busy")
      model.error = nil; try await settle()
      let refreshedDetail = try openReview()
      try require(refreshedDetail.contains(kind + ":"), "Next review identifies the actual \(kind) race")
      try await press("cancel")
      let raceFile = try await git.status().files.first { $0.path == "race-selected.txt" }
      try require(raceFile?.isUntracked == true, "Stale \(kind) attempt never stages the selected working file")
    }
    // Push only to a missing local fixture path, so no network/provider credentials are involved.
    _ = try await git.read(["branch", "--set-upstream-to=origin/main"])
    _ = try await git.read(["remote", "set-url", "origin", root.deletingLastPathComponent().appendingPathComponent("missing-remote.git").path])
    model.commit(push: true)
    try require(model.confirmation?.confirmTitle == "Commit & Push", "Commit-and-push review names the requested action")
    try await press("confirm"); try await settleOperation()
    try require(model.lastCommit != nil && model.record.draft.isEmpty && !model.requiresIndexReview && model.pushFailed, "Successful local commit stays acknowledged when its subsequent push fails")

    model.error = nil; model.editDraft("test: review concurrent external changes")
    try write("pending-selection.txt", "Keep a selected working file during network reviews\n")
    await model.refresh(); selectAll(); try await settle()
    for kind in [WorkflowOperationKind.fetch, .push, .git] {
      var gate: CheckedContinuation<Void, Never>?
      model.run(kind: kind) { _ in await withCheckedContinuation { gate = $0 } }
      try await waitFor { gate != nil }
      do {
        switch kind {
        case .fetch:
          try write("foreign-index.txt", "External Index mutation while fetching\n"); try await stage("foreign-index.txt")
        case .push:
          _ = try await git.commit(message: "test: external HEAD while pushing", expected: git.snapshot())
        default:
          try await git.createBranch("review/network"); try await git.switchBranch("review/network")
        }
      } catch { gate?.resume(); throw error }
      gate?.resume(); try await settleOperation(); selectAll()
      try require(model.requiresIndexReview, "A \(kind.rawValue) operation cannot acknowledge external local changes during its wait")
      _ = try openReview(); try await press("reviewed")
    }

    // A no-op Pull can still overlap an external Index write while upload-pack is waiting.
    _ = try await git.read(["remote", "set-url", "origin", root.deletingLastPathComponent().appendingPathComponent("remote.git").path])
    _ = try await git.network("push", remote: "origin", branch: model.status.branch)
    let pullReady = root.deletingLastPathComponent().appendingPathComponent("pull-ready")
    let pullRelease = root.deletingLastPathComponent().appendingPathComponent("pull-release")
    let pullTimeout = root.deletingLastPathComponent().appendingPathComponent("pull-timeout")
    let uploadPack = root.deletingLastPathComponent().appendingPathComponent("held-upload-pack")
    let pullScript = "#!/bin/sh\n: > " + InputValidation.shellQuote(pullReady.path)
      + "\ni=0\nwhile [ ! -f " + InputValidation.shellQuote(pullRelease.path)
      + " ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i+1)); done\n[ -f " + InputValidation.shellQuote(pullRelease.path)
      + " ] || { : > " + InputValidation.shellQuote(pullTimeout.path) + "; exit 1; }\nexec /usr/bin/git-upload-pack \"$@\"\n"
    try pullScript.write(to: uploadPack, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: uploadPack.path)
    defer { try? Data().write(to: pullRelease); try? FileManager.default.removeItem(at: uploadPack) }
    _ = try await git.read(["config", "--local", "remote.origin.uploadpack", uploadPack.path])
    model.network("pull", reviewedStrategy: "merge")
    try await waitFor { FileManager.default.fileExists(atPath: pullReady.path) }
    try write("during-pull.txt", "External staging during a no-op Pull\n"); try await stage("during-pull.txt")
    let duringPull = try await git.snapshot()
    try require(model.busy && !FileManager.default.fileExists(atPath: pullRelease.path)
      && !FileManager.default.fileExists(atPath: pullTimeout.path), "External staging completes while Pull is still waiting on its unreleased gate")
    try Data().write(to: pullRelease); try await settleOperation()
    try require(model.error == nil && model.requiresIndexReview && model.snapshot == duringPull,
      "A successful no-op Pull never acknowledges external staging made during its network wait")
    _ = try await git.read(["config", "--local", "--unset", "remote.origin.uploadpack"])
    selectAll(); _ = try openReview(); try await press("reviewed")

    // A real pre-push hook holds the network phase after the local commit is complete.
    let ready = root.deletingLastPathComponent().appendingPathComponent("push-ready")
    let release = root.deletingLastPathComponent().appendingPathComponent("push-release")
    let pushTimeout = root.deletingLastPathComponent().appendingPathComponent("push-timeout")
    let pushHook = root.appendingPathComponent(".git/hooks/pre-push")
    let script = "#!/bin/sh\n: > " + InputValidation.shellQuote(ready.path)
      + "\ni=0\nwhile [ ! -f " + InputValidation.shellQuote(release.path)
      + " ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i+1)); done\n[ -f " + InputValidation.shellQuote(release.path)
      + " ] || : > " + InputValidation.shellQuote(pushTimeout.path) + "\nexit 1\n"
    try script.write(to: pushHook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pushHook.path)
    defer { try? Data().write(to: release); try? FileManager.default.removeItem(at: pushHook) }
    model.error = nil; model.editDraft("test: local commit before a held push")
    await model.refresh(); selectAll()
    let previousCommit = model.lastCommit
    model.commit(push: true)
    try await waitFor { FileManager.default.fileExists(atPath: ready.path) }
    try require(model.lastCommit != nil && model.lastCommit != previousCommit && model.record.draft.isEmpty, "The local commit completes before entering the held push")
    try write("during-push.txt", "External staging after local commit\n"); try await stage("during-push.txt")
    let duringPush = try await git.snapshot()
    try require(model.busy && !FileManager.default.fileExists(atPath: release.path)
      && !FileManager.default.fileExists(atPath: pushTimeout.path), "External staging completes while Push is still waiting on its unreleased hook")
    try Data().write(to: release); try await settleOperation()
    try require(model.requiresIndexReview && model.pushFailed && model.snapshot == duringPush, "Commit-and-push preserves a new external Index change made after the local commit")
    model.error = nil; model.editDraft("test: review staging made during push"); try await settle()
    let afterPushDetail = try openReview()
    try require(afterPushDetail.contains("Index:") && !afterPushDetail.contains("HEAD:"), "The post-push review identifies the foreign Index rather than re-warning about our own commit")
    try await press("cancel")
    _ = try openReview(); try await press("reviewed")
    let postHook = root.appendingPathComponent(".git/hooks/post-commit")
    try "#!/bin/sh\nprintf 'Hook staged a foreign file\\n' > foreign-post.txt\ngit add -- foreign-post.txt\n".write(to: postHook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: postHook.path)
    defer { try? FileManager.default.removeItem(at: postHook) }
    model.editDraft("test: preserve staging performed by post-commit hook")
    model.commit(push: false); try await settleOperation()
    try require(model.record.draft.isEmpty && model.requiresIndexReview && model.snapshot?.paths.contains("foreign-post.txt") == true,
      "Known Index changes made during commit stay staged and require review instead of being acknowledged as owned")
  }
}
