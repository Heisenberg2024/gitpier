#if DEBUG
import AppKit
import GitPierCore
import SwiftUI

extension UIAcceptance {
  static func verifyWorkflow210(store: AppStore, model: RepositoryModel, root: URL, window: NSWindow, output: URL) async throws {
    var settings = store.settings
    settings.automaticFetch = false; settings.automaticRefresh = false; settings.completionNotifications = false
    store.updateSettings(settings); store.workspace.shutdown()
    let wrapper = root.deletingLastPathComponent().appendingPathComponent("workflow210-git")
    let faults = root.appendingPathComponent(".git/workflow210-fault")
    let queries = root.appendingPathComponent(".git/workflow210-queries")
    let observationFault = root.appendingPathComponent(".git/workflow210-observation-fault")
    let committed = root.appendingPathComponent(".git/workflow210-committed")
    let commits = root.appendingPathComponent(".git/workflow210-commits")
    let script = """
      #!/bin/sh
      case " $* " in
        *" ls-remote "*) case " $* " in *" --get-url "*) ;; *) printf 'query\\n' >> '\(queries.path)';; esac;;
        *" push "*) if [ -f '\(faults.path)' ]; then /usr/bin/git "$@" || exit $?; exit 84; fi;;
        *" commit "*)
          printf 'commit\\n' >> '\(commits.path)'
          /usr/bin/git "$@"; result=$?
          if [ "$result" -eq 0 ] && [ -f '\(observationFault.path)' ]; then touch '\(committed.path)'; fi
          exit "$result";;
        *" write-tree "*) if [ -f '\(committed.path)' ]; then echo 'Synthetic post-commit observation failure' >&2; exit 81; fi;;
      esac
      exec /usr/bin/git "$@"
      """
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    settings.gitPath = wrapper.path; store.updateSettings(settings)
    await model.refresh()
    window.center(); window.makeKeyAndOrderFront(nil); NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    var checks: [String] = [], captures: [String] = []
    func require(_ value: Bool, _ label: String) throws {
      guard value else { throw GitPierError.invalidInput("Workflow 2.1: " + label) }
      checks.append(label)
    }
    func queryCount() -> Int { (try? Data(contentsOf: queries).split(separator: 10).count) ?? 0 }
    for language in AppLanguage.allCases {
      settings = store.settings; settings.language = language; store.updateSettings(settings); store.notice = nil
      let file = root.appendingPathComponent("workflow210.txt")
      try Data((language.rawValue + "\n").utf8).write(to: file)
      try Data().write(to: faults)
      await model.refresh()
      model.toggleIncluded(model.status.files.filter { !model.includedPaths.contains($0.path) })
      model.editDraft("fixture: retain " + language.rawValue)
      try require(model.canCommit, "real Commit is available")
      model.commit(push: true)
      if let review = model.confirmation {
        try require(review.readyForConfirmation, "current Index review is ready")
        model.confirmation = nil; review.performConfirmedAction()
      }
      model.setPage("history"); store.showDashboard = true
      try await waitFor { !model.busy && !model.refreshing }
      guard let record = store.operations.records.first(where: { $0.kind == .commitAndPush && $0.state == .resultUnknown }),
        let checkpoint = record.pushCheckpoint else { throw GitPierError.invalidInput("Unknown Push lost its checkpoint") }
      try require(record.localCommit == model.lastCommit, "local Hash survives accepted Push/client error and navigation")
      model.error = nil
      try await waitFor { window.attachedSheet == nil }
      if language == .english {
        try FileManager.default.removeItem(at: faults)
        try Data().write(to: observationFault)
        try Data("a newer local commit\n".utf8).write(to: root.appendingPathComponent("workflow210-newer.txt"))
        await model.refresh()
        model.toggleIncluded(model.status.files.filter { !model.includedPaths.contains($0.path) })
        model.editDraft("fixture: newer commit needs its own Push recovery")
        model.commit(push: true)
        if let review = model.confirmation {
          try require(review.readyForConfirmation, "newer Commit review is ready")
          model.confirmation = nil; review.performConfirmedAction()
        }
        try await waitFor { !model.busy && !model.refreshing }
        let newer = store.operations.records.first { $0.kind == .commitAndPush }
        try require(newer?.state == .needsAttention && newer?.localCommit != checkpoint.localHead && newer?.pushCheckpoint == nil,
          "newer local commit survives a post-commit observation fault without attempting Push")
        try FileManager.default.removeItem(at: observationFault)
        try FileManager.default.removeItem(at: committed)
        await model.refresh()
        store.showDashboard = false; model.setPage("commit")
        model.error = nil
        model.retryPush()
        try await waitFor { model.confirmation != nil || model.busy || model.error != nil }
        guard let review = model.confirmation, let saved = newer?.localCommit else {
          throw GitPierError.invalidInput("Newer saved commit must receive its own Push review")
        }
        let fixtureGit = GitService(root: root)
        let remote = try await fixtureGit.read(["ls-remote", "--", "origin", "refs/heads/main"]).text
        try require(!model.busy && review.readyForConfirmation && review.detail.contains(saved)
          && review.detail.contains("origin / main") && !review.detail.contains(checkpoint.localHead)
          && remote.hasPrefix(checkpoint.localHead + "\t"),
          "current retry reviews only the newer saved commit and waits for confirmation")
        model.confirmation = nil; review.performConfirmedAction()
        try await waitFor { !model.busy && !model.refreshing }
        let retried = try await fixtureGit.read(["ls-remote", "--", "origin", "refs/heads/main"]).text
        try require(retried.hasPrefix(saved + "\t") && model.outputResult == .succeeded
          && store.operations.records.first(where: { $0.id == record.id })?.state == .resultUnknown,
          "newer retry succeeds while the older unknown result remains independently retained")
        try require((try Data(contentsOf: commits)).split(separator: 10).count == 2,
          "retry of the newer local result creates no duplicate Commit")
        let remotePath = root.deletingLastPathComponent().appendingPathComponent("remote.git")
        try await fixtureGit.perform(["--git-dir=" + remotePath.path, "update-ref", "refs/heads/main", checkpoint.localHead])
        try Data().write(to: faults)
      }
      model.run(label: "Fixture later successful observation") { git in _ = try await git.read(["rev-parse", "HEAD"]) }
      try await waitFor { !model.busy && !model.refreshing }
      try require(store.operations.records.first(where: { $0.id == record.id })?.pushCheckpoint == checkpoint, "later success preserves original unknown target")
      store.showDashboard = false; model.setPage("commit"); try await settle()
      try require(ContextWorkflowAdvice.evaluate(model.workflowInput()).kind == .unverifiedResult, "context prioritizes the retained unknown result")
      let beforeQueries = queryCount()
      guard let host = window.contentView, let entry = assistantFind(host, id: "gitpier.workflow.open") else { throw GitPierError.invalidInput("Missing native context entry") }
      try assistantPress(entry)
      try await waitFor { NSApp.windows.contains { $0.isVisible && $0.contentView.map { assistantFind($0, id: "gitpier.workflow.inspectOperations") != nil } == true } }
      guard let popover = NSApp.windows.first(where: { $0.isVisible && $0.contentView.map { assistantFind($0, id: "gitpier.workflow.inspectOperations") != nil } == true }),
        let popoverContent = popover.contentView, let inspect = assistantFind(popoverContent, id: "gitpier.workflow.inspectOperations") else { throw GitPierError.invalidInput("Missing context recovery action") }
      let contextCapture = "context-unknown-" + language.rawValue
      try await captureHostingWindow(popover, to: output.appendingPathComponent(contextCapture + ".png")); captures.append(contextCapture)
      try assistantPress(inspect)
      try await waitFor { window.attachedSheet != nil }
      for appearance in [AppearanceMode.light, .dark] {
        settings = store.settings; settings.appearance = appearance; store.updateSettings(settings); store.notice = nil
        for width in [960, 1280] {
          window.setContentSize(NSSize(width: width, height: width == 960 ? 640 : 820)); window.center()
          try await settle()
          guard let sheet = window.attachedSheet, let content = sheet.contentView else { throw GitPierError.invalidInput("Missing native Operations Center") }
          if assistantFind(content, id: "gitpier.operation.verify." + record.id.uuidString) == nil {
            let elements = assistantElements(content).map { assistantString($0, "accessibilityIdentifier") + " | " + assistantString($0, "accessibilityLabel") }
            try elements.joined(separator: "\n").write(to: output.appendingPathComponent("missing-verification-elements.txt"), atomically: true, encoding: .utf8)
            try await captureHostingWindow(sheet, to: output.appendingPathComponent("missing-verification.png"))
          }
          try require(assistantFind(content, id: "gitpier.operation.verify." + record.id.uuidString) != nil, "accessible Verify Remote " + language.rawValue)
          try require(assistantFind(content, id: "gitpier.operation.copy." + record.id.uuidString) != nil, "accessible full Hash copy " + language.rawValue)
          try require(assistantFind(content, id: "gitpier.operation.retry." + record.id.uuidString) != nil, "accessible reviewed Push-only retry " + language.rawValue)
          try require(accessibleButton(content, title: store.text("Close", "关闭"), enabled: true) != nil, "Close remains reachable at " + String(width))
          let name = "operations-unknown-" + language.rawValue + "-" + appearance.rawValue + "-" + String(width)
          try await captureHostingWindow(sheet, to: output.appendingPathComponent(name + ".png")); captures.append(name)
        }
      }
      try require(queryCount() == beforeQueries, "rendering, navigation and presentation perform no remote verification")
      guard let operationsSheet = window.attachedSheet, let operationsContent = operationsSheet.contentView,
        let retry = assistantFind(operationsContent, id: "gitpier.operation.retry." + record.id.uuidString) else { throw GitPierError.invalidInput("Missing native saved Push review") }
      try assistantPress(retry)
      try await waitFor { model.confirmation != nil && window.attachedSheet != nil && window.attachedSheet !== operationsSheet }
      guard let retrySheet = window.attachedSheet else { throw GitPierError.invalidInput("Missing native Push confirmation") }
      let retryCapture = "retry-review-" + language.rawValue
      try await captureHostingWindow(retrySheet, to: output.appendingPathComponent(retryCapture + ".png")); captures.append(retryCapture)
      try require(queryCount() == beforeQueries, "opening saved Push review never sends or verifies Push")
      try sendWorkspaceKey(53, window: retrySheet)
      try await waitFor { model.confirmation == nil && window.attachedSheet == nil }
      try require(store.operations.records.first(where: { $0.id == record.id })?.state == .resultUnknown,
        "Escape cancels Push review and retains the original unknown result")
      store.showOperationsCenter = true
      try await waitFor { window.attachedSheet != nil }
      try await settle()
      guard let sheet = window.attachedSheet, let content = sheet.contentView,
        let verify = assistantFind(content, id: "gitpier.operation.verify." + record.id.uuidString) else { throw GitPierError.invalidInput("Missing Verify Remote action") }
      let fixtureGit = GitService(root: root)
      let remotePath = root.deletingLastPathComponent().appendingPathComponent("remote.git")
      let previous = try await fixtureGit.read(["rev-parse", checkpoint.localHead + "^"]).text.trimmingCharacters(in: .newlines)
      try await fixtureGit.perform(["--git-dir=" + remotePath.path, "update-ref", "refs/heads/main", previous])
      try assistantPress(verify)
      try await waitFor { queryCount() == beforeQueries + 1 && !store.operations.verifyingPush.contains(record.id) }
      try require(store.operations.records.first(where: { $0.id == record.id })?.state == .resultUnknown,
        "different remote tip preserves unknown result without another Push")
      let unconfirmed = "operations-unconfirmed-" + language.rawValue
      try await captureHostingWindow(sheet, to: output.appendingPathComponent(unconfirmed + ".png")); captures.append(unconfirmed)
      try await fixtureGit.perform(["--git-dir=" + remotePath.path, "update-ref", "refs/heads/main", checkpoint.localHead])
      guard let nextVerify = assistantFind(content, id: "gitpier.operation.verify." + record.id.uuidString) else { throw GitPierError.invalidInput("Unconfirmed result lost Verify Remote") }
      try assistantPress(nextVerify)
      try await waitFor { store.operations.records.first(where: { $0.id == record.id })?.verifiedAt != nil }
      let resolved = store.operations.records.first { $0.id == record.id }
      try require(resolved?.state == .succeeded && resolved?.detail == record.detail, "exact remote observation resolves only original record and retains diagnosis")
      try require(queryCount() == beforeQueries + 2, "each explicit action performs exactly one remote query")
      try require(!model.workflowInput().unresolvedResult, "context updates after authoritative verification")
      let name = "operations-confirmed-" + language.rawValue
      try await captureHostingWindow(sheet, to: output.appendingPathComponent(name + ".png")); captures.append(name)
      try sendWorkspaceKey(53, window: sheet)
      try await waitFor { window.attachedSheet == nil }
      try require(store.operations.records.contains { $0.id == record.id && $0.localCommit == checkpoint.localHead }, "Esc closes Sheet without clearing saved result")
      try FileManager.default.removeItem(at: faults)
    }
    let report: [String: Any] = ["checks": checks, "captures": captures,
      "scope": "Real temporary Git, local bare remote, actual native windows and accessibility button actions; English/Chinese, light/dark, 960/1280 widths; native Escape.",
      "limits": "No real hosting credentials, spoken VoiceOver, global accessibility setting changes, installation or production update. Clipboard is not modified by acceptance."]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("workflow210-results.json"))
  }
}
#endif
