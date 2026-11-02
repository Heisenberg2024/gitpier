#if DEBUG
import AppKit
import Darwin
import GitPierCore
import SwiftUI

extension UIAcceptance {
  static func verifyOperationGuidance(store: AppStore, output: URL) throws {
    let previous = store.settings
    defer { store.updateSettings(previous) }
    var checks: [[String: Any]] = []
    for language in [AppLanguage.english, .simplifiedChinese] {
      var settings = store.settings; settings.language = language; store.updateSettings(settings)
      for kind in [WorkflowOperationKind.push, .commitAndPush, .mergeAndPush, .review, .git] {
        let record = WorkflowOperationRecord(kind: kind, repositoryID: nil, state: .resultUnknown)
        let title = operationStateTitle(record, store: store)
        let passed: Bool
        switch kind {
        case .review:
          passed = title.contains(store.text("Review history", "审查历史"))
        case .push, .commitAndPush, .mergeAndPush:
          passed = title.contains(store.text("remote", "远端"))
            && !title.contains(store.text("Review history", "审查历史"))
        default:
          passed = title == store.text("Result unknown", "结果未知")
        }
        checks.append(["language": language.rawValue, "kind": kind.rawValue, "title": title, "passed": passed])
      }
    }
    try JSONSerialization.data(withJSONObject: ["checks": checks], options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("operation-guidance.json"))
    guard checks.allSatisfy({ $0["passed"] as? Bool == true }) else {
      throw GitPierError.invalidInput("Unknown-result recovery guidance pointed at the wrong destination")
    }
  }

  static func verifyStabilitySoak(root: URL, output: URL, store: AppStore,
    window: NSWindow, original: RepositoryModel) async throws {
    let otherRoot = root.deletingLastPathComponent().appendingPathComponent("ordered-one")
    let otherGit = GitService(root: otherRoot)
    try await otherGit.perform(["symbolic-ref", "HEAD", "refs/heads/soak-other"])
    await store.addRepository(otherRoot)
    guard let other = store.current else { throw GitPierError.invalidInput("Missing soak repository") }
    await other.activate()
    store.workspace.shutdown()
    var samples: [[String: Any]] = []
    let start = ContinuousClock.now
    for cycle in 0..<20 {
      let model = cycle.isMultiple(of: 2) ? original : other
      store.select(model.record.id)
      await model.activate()
      await model.refresh()
      guard store.current === model, model.available,
        model.status.branch == (model === original ? "main" : "soak-other") else {
        throw GitPierError.invalidInput("Repository switching published another repository's state")
      }
      if let file = model.status.files.first {
        model.select(file)
        try await waitFor { !model.diffLoading }
      }
      store.showOperationsCenter = true
      try await waitFor { window.attachedSheet != nil }
      store.showOperationsCenter = false
      try await waitFor { window.attachedSheet == nil }
      if cycle.isMultiple(of: 5) || cycle == 19 {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        samples.append(["cycle": cycle + 1, "processHighWaterRSSMiB": Double(usage.ru_maxrss) / 1024 / 1024])
      }
    }
    let report: [String: Any] = ["cycles": 20, "repositorySwitches": 20,
      "refreshes": 20, "operationsCenterOpenClosePairs": 20,
      "elapsedMS": PerformanceAcceptance.ms(start), "memory": samples,
      "scope": "short native smoke; cumulative high-water RSS, not live memory or long-soak acceptance"]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("stability-soak.json"))
  }

  /// Faults are injected only after real native Git has run in a disposable
  /// repository. Remote acceptance and local completion are checked separately.
  static func verifyCommitStability(root: URL, output: URL, scenario: String) async throws {
    guard ["index", "command", "receipt", "accepted", "branch", "ref-veto", "interruption"].contains(scenario) else {
      throw GitPierError.invalidInput("Unknown stability scenario")
    }
    let fixture = root.deletingLastPathComponent().appendingPathComponent("stability-" + scenario)
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    let git = GitService(root: fixture)
    for args in [["init", "-b", "main"], ["config", "user.name", "Stability Fixture"],
      ["config", "user.email", "stability@example.invalid"], ["config", "commit.gpgsign", "false"]] {
      try await git.perform(args)
    }
    let file = fixture.appendingPathComponent("tracked.txt")
    try Data("seed\n".utf8).write(to: file)
    try await git.perform(["add", "--", "tracked.txt"])
    try await git.perform(["commit", "-m", "seed"])
    let remote = fixture.deletingLastPathComponent().appendingPathComponent("stability-" + scenario + ".git")
    try await git.perform(["init", "--bare", remote.path])
    try await git.perform(["remote", "add", "origin", remote.path])
    try await git.perform(["push", "--set-upstream", "origin", "main"])
    let before = try await git.resolveCommit("HEAD")
    if scenario == "branch" {
      try await git.perform(["branch", "other"])
      let hook = fixture.appendingPathComponent(".git/hooks/pre-commit")
      try "#!/bin/sh\n/usr/bin/git symbolic-ref HEAD refs/heads/other\n".write(
        to: hook, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    }
    if scenario == "ref-veto" {
      let hook = fixture.appendingPathComponent(".git/hooks/reference-transaction")
      try "#!/bin/sh\nif [ \"$1\" = prepared ]; then echo 'Synthetic native ref policy veto' >&2; exit 1; fi\n"
        .write(to: hook, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    }
    if scenario == "interruption" {
      let hook = fixture.appendingPathComponent(".git/hooks/reference-transaction")
      try """
        #!/bin/sh
        [ "$1" = committed ] || exit 0
        changed=0
        while read old new ref; do
          if [ "$ref" = refs/heads/main ] && [ "$old" != "$new" ]; then changed=1; fi
        done
        [ "$changed" = 1 ] || exit 0
        /usr/bin/git rev-parse HEAD > .git/stability-hook-head
        printf 'Synthetic interrupted Hook stdout\\n'
        printf 'Synthetic interrupted Hook stderr\\n' >&2
        : > .git/stability-hook-blocked
        exec /bin/sleep 30
        """.write(to: hook, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    }
    let wrapper = fixture.appendingPathComponent(".git/stability-git")
    let script = """
      #!/bin/sh
      case " $* " in
        *" commit "*)
          printf 'attempt\\n' >> .git/stability-attempts
          /usr/bin/git "$@"
          result=$?
          if [ "$result" = 0 ]; then
            /usr/bin/git rev-parse HEAD > .git/stability-created
            printf 'commit\\n' >> .git/stability-commits
            : > .git/stability-completed
            if [ -e .git/stability-inject ]; then
              :
              \(scenario == "receipt" ? "rm -f -- \"$GITPIER_COMMIT_RECEIPT\"" : "")
              \(scenario == "command" ? "echo 'Synthetic completed-commit transport failure' >&2; exit 83" : "")
            fi
          fi
          exit "$result"
          ;;
        *" write-tree "*)
          if [ -e .git/stability-inject ] && [ -e .git/stability-completed ] && [ '\(scenario)' = index ]; then
            echo 'Synthetic post-commit Index observation failure' >&2; exit 82
          fi
          ;;
        *" push "*)
          /usr/bin/git "$@"
          result=$?
          if [ "$result" = 0 ] && [ -e .git/stability-inject ] && [ '\(scenario)' = accepted ]; then
            echo 'Synthetic client error after remote accepted the Push' >&2; exit 84
          fi
          exit "$result"
          ;;
      esac
      exec /usr/bin/git "$@"
      """
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    try Data().write(to: fixture.appendingPathComponent(".git/stability-inject"))
    let persistence = ConfigurationStore(url: fixture.deletingLastPathComponent().appendingPathComponent("stability-" + scenario + ".json"))
    var configuration = WorkspaceConfiguration()
    configuration.settings.gitPath = wrapper.path
    configuration.settings.automaticRefresh = false
    configuration.settings.completionNotifications = false
    try persistence.save(configuration)
    let store = AppStore(persistence: persistence)
    defer { store.shutdown() }
    await store.addRepository(fixture)
    guard let model = store.current else { throw GitPierError.invalidInput("Missing stability fixture") }
    await model.activate()
    store.workspace.shutdown()
    try Data("selected change\n".utf8).write(to: file)
    await model.refresh()
    model.toggleIncluded(model.status.files)
    model.editDraft("stability: retain completed local commit")
    guard model.canCommit else { throw GitPierError.invalidInput("Stability fixture cannot commit") }
    model.commit(push: true)
    model.setPage("history")
    store.showDashboard = true
    if scenario == "interruption" {
      try await waitFor { FileManager.default.fileExists(atPath: fixture.appendingPathComponent(".git/stability-hook-blocked").path) }
      model.shutdown()
    }
    try await waitFor { !model.busy && !model.refreshing }
    let created = try await git.resolveCommit("HEAD")
    let remoteHead = try await git.read(["--git-dir=" + remote.path, "rev-parse", "main"]).text.trimmingCharacters(in: .newlines)
    let operation = store.operations.records.first { $0.kind == .commitAndPush }
    if scenario == "ref-veto" {
      let passed = created == before && remoteHead == before && model.lastCommit == nil
        && operation?.localCommit == nil && operation?.state == .failed
        && operation?.detail?.contains("Synthetic native ref policy veto") == true
        && !model.record.draft.isEmpty && model.requiresIndexReview && model.available
      try JSONSerialization.data(withJSONObject: ["scenario": scenario, "passed": passed,
        "localUnchanged": created == before, "remoteUnchanged": remoteHead == before,
        "draftPreserved": !model.record.draft.isEmpty, "requiresReview": model.requiresIndexReview],
        options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("stability-ref-veto.json"))
      guard passed else { throw GitPierError.invalidInput("A native ref policy was bypassed or its diagnosis lost") }
      return
    }
    if scenario == "branch" {
      let main = try await git.read(["rev-parse", "refs/heads/main"]).text.trimmingCharacters(in: .newlines)
      let other = try await git.read(["rev-parse", "refs/heads/other"]).text.trimmingCharacters(in: .newlines)
      let state = try await git.status()
      let passed = main == before && other == before && remoteHead == before
        && state.branch == "other" && model.lastCommit == nil && operation?.localCommit == nil
        && model.record.draft == "stability: retain completed local commit" && model.requiresIndexReview
        && model.available && operation?.state == .failed && operation?.detail?.contains("branch changed") == true
      let report: [String: Any] = ["scenario": scenario, "passed": passed,
        "bothBranchesUnchanged": main == before && other == before, "remoteUnchanged": remoteHead == before,
        "externalSwitchPreserved": state.branch == "other", "draftPreserved": !model.record.draft.isEmpty,
        "requiresReview": model.requiresIndexReview, "operationState": operation?.state.rawValue ?? "missing"]
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("stability-branch.json"))
      guard passed else { throw GitPierError.invalidInput("A same-object branch switch bypassed commit review") }
      return
    }
    let known = scenario != "receipt" && scenario != "interruption"
    let expectedState: WorkflowOperationState = scenario == "accepted" ? .resultUnknown : .needsAttention
    let passed = created != before && model.record.draft.isEmpty
      && (known ? model.lastCommit == created && operation?.localCommit == created : model.lastCommit == nil && operation?.localCommit == nil)
      && remoteHead == (scenario == "accepted" ? created : before)
      && operation?.state == expectedState
      && operation?.detail?.contains(scenario == "receipt" ? "receipt" : "Synthetic") == true
      && (scenario == "receipt" ? model.output?.contains("History") == true : true)
    let report: [String: Any] = ["scenario": scenario, "passed": passed,
      "localHeadAdvanced": created != before, "remoteAccepted": remoteHead == created,
      "localHashRetained": model.lastCommit == created, "draftCleared": model.record.draft.isEmpty,
      "state": operation?.state.rawValue ?? "missing", "output": model.output ?? "",
      "pageChangedDuringOperation": model.page == "history", "dashboardSelected": store.showDashboard]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("stability-" + scenario + ".json"))
    guard passed else { throw GitPierError.invalidInput("Commit stability acceptance failed; see stability-" + scenario + ".json") }
    if scenario == "interruption" {
      let attempts = fixture.appendingPathComponent(".git/stability-attempts")
      let originalAttempts = try Data(contentsOf: attempts)
      guard !model.canCommit, model.recentMessages.contains("stability: retain completed local commit"),
        operation?.detail?.contains("Synthetic interrupted Hook stdout") == true,
        operation?.detail?.contains("Synthetic interrupted Hook stderr") == true,
        operation?.detail?.contains(CancellationError().localizedDescription) == true else {
        throw GitPierError.invalidInput("Interrupted completion lost its message/diagnosis or enabled repeat Commit")
      }
      model.commit(push: true)
      let after = try await git.resolveCommit("HEAD")
      let afterAttempts = try Data(contentsOf: attempts)
      guard after == created, afterAttempts == originalAttempts,
        originalAttempts.split(separator: 10).count == 1 else {
        throw GitPierError.invalidInput("An interrupted commit was repeated")
      }
      return
    }
    try FileManager.default.removeItem(at: fixture.appendingPathComponent(".git/stability-inject"))
    await model.refresh()
    if known {
      model.network("push")
      try await waitFor { !model.busy }
      let after = try await git.resolveCommit("HEAD")
      let pushed = try await git.read(["--git-dir=" + remote.path, "rev-parse", "main"]).text.trimmingCharacters(in: .newlines)
      let commits = try String(contentsOf: fixture.appendingPathComponent(".git/stability-commits"), encoding: .utf8)
      guard after == created, pushed == created, commits.split(separator: "\n").count == 1,
        store.operations.records.first(where: { $0.id == operation?.id })?.detail == operation?.detail else {
        throw GitPierError.invalidInput("Explicit Push retry changed the commit or erased the original diagnosis")
      }
    }
  }
}
#endif
