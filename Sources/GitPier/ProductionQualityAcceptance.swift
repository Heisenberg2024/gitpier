#if DEBUG
import AppKit
import GitPierCore
import SwiftUI

extension UIAcceptance {
  static func verifyErrorDismissalQuality(root: URL, output: URL) async throws {
    let bin = root.appendingPathComponent(".git/quality-error-bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let wrapper = bin.appendingPathComponent("git")
    let script = """
      #!/bin/sh
      case " $* " in
        *" status "*)
          if [ -e .git/quality-error-refresh ]; then
            : > .git/quality-error-waiting
            attempts=0
            while [ ! -e .git/quality-error-release ] && [ "$attempts" -lt 1000 ]; do
              /bin/sleep 0.02
              attempts=$((attempts + 1))
            done
            [ -e .git/quality-error-release ] || exit 84
          fi
          ;;
      esac
      exec /usr/bin/git "$@"
      """
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    let persistence = ConfigurationStore(url: root.deletingLastPathComponent().appendingPathComponent("quality-error-workspace.json"))
    var configuration = WorkspaceConfiguration()
    configuration.settings.gitPath = wrapper.path
    configuration.settings.automaticRefresh = false
    configuration.settings.completionNotifications = false
    try persistence.save(configuration)
    let store = AppStore(persistence: persistence)
    defer { store.shutdown() }
    await store.addRepository(root)
    guard let model = store.current else { throw GitPierError.invalidInput("Missing error dismissal fixture") }
    await model.activate()
    store.workspace.shutdown()
    let host = NSHostingView(rootView: RootView().environmentObject(store).modifier(AppAppearance(store: store)))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    NSApp.setActivationPolicy(.regular); window.center(); window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    defer { window.close() }
    try await settle()
    let cause = "Synthetic operation failure: retain this original cause"
    model.run(label: "Error dismissal quality", kind: .git) { _ in
      try Data().write(to: root.appendingPathComponent(".git/quality-error-refresh"))
      throw GitPierError.invalidInput(cause)
    }
    try await waitFor {
      FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/quality-error-waiting").path)
        && model.error?.contains(cause) == true && window.attachedSheet != nil
    }
    try await settle()
    guard let content = window.attachedSheet?.contentView else { throw GitPierError.invalidInput("Missing actual error Sheet") }
    try await waitFor { accessibleButton(content, title: localizedUI("Close"), enabled: true) != nil }
    try accessibilityLabels(content).write(to: output.appendingPathComponent("error-sheet-accessibility.txt"), atomically: true, encoding: .utf8)
    try pressNativeButton(content, title: localizedUI("Close"))
    try await waitFor { model.error == nil && window.attachedSheet == nil }
    try Data().write(to: root.appendingPathComponent(".git/quality-error-release"))
    try await waitFor { !model.busy && !model.refreshing }
    try await settle()
    let recorded = store.operations.records.first { $0.repositoryID == model.record.id && $0.state == .failed }
    let reopened = model.error != nil || window.attachedSheet != nil
    let retained = recorded?.detail?.contains(cause) == true
    let report: [String: Any] = ["errorSheetReopened": reopened, "historicalCauseRetained": retained,
      "operationState": recorded?.state.rawValue ?? "missing", "closedThroughActualNativeButton": true,
      "scope": "real RootView error Sheet, controlled final Git status gate, disposable repository"]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("error-dismissal.json"))
    guard !reopened && retained else {
      throw GitPierError.invalidInput("A dismissed error Sheet reopened or lost its historical cause; see error-dismissal.json")
    }
  }

  static func verifyDiffQuality(root: URL, output: URL, burst: Bool) async throws {
    guard !burst || ProcessTrace.enabled else { throw GitPierError.invalidInput("Diff burst acceptance requires process tracing") }
    let fixture = root.deletingLastPathComponent().appendingPathComponent(burst ? "quality-diff-burst" : "quality-diff-stale")
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    let git = GitService(root: fixture)
    try await git.perform(["init", "-b", "main"])
    try await git.perform(["config", "user.name", "Quality Fixture"])
    try await git.perform(["config", "user.email", "quality@example.invalid"])
    try await git.perform(["config", "commit.gpgsign", "false"])
    let count = burst ? 32 : 1
    for index in 0..<count { try Data("seed\n".utf8).write(to: fixture.appendingPathComponent("file-\(index).txt")) }
    try await git.perform(["add", "--", "."])
    try await git.perform(["commit", "-m", "seed"])
    for index in 0..<count { try Data("first change\n".utf8).write(to: fixture.appendingPathComponent("file-\(index).txt")) }
    let bin = fixture.appendingPathComponent(".git/quality-diff-bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let wrapper = bin.appendingPathComponent("git")
    let intercept = burst ? "/bin/sleep 0.3" : """
      if [ ! -e .git/quality-diff-read ]; then
        /usr/bin/git "$@" > .git/quality-old-patch || exit $?
        : > .git/quality-diff-read
        attempts=0
        while [ ! -e .git/quality-diff-release ] && [ "$attempts" -lt 300 ]; do
          /bin/sleep 0.02
          attempts=$((attempts + 1))
        done
        /bin/cat .git/quality-old-patch
        exit 0
      fi
      """
    let script = """
      #!/bin/sh
      case " $* " in
        *" --cached "*) ;;
        *" diff "*)
          \(intercept)
          ;;
      esac
      exec /usr/bin/git "$@"
      """
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    let persistence = ConfigurationStore(url: fixture.deletingLastPathComponent().appendingPathComponent(burst ? "quality-diff-burst.json" : "quality-diff-stale.json"))
    var configuration = WorkspaceConfiguration()
    configuration.settings.gitPath = wrapper.path
    configuration.settings.automaticRefresh = false
    try persistence.save(configuration)
    let store = AppStore(persistence: persistence)
    defer { store.shutdown() }
    await store.addRepository(fixture)
    guard let model = store.current else { throw GitPierError.invalidInput("Diff fixture did not open") }
    await model.activate()
    store.workspace.shutdown()
    let files = model.status.files
    if burst {
      GitProcessActivity.reset()
      for file in files {
        let previous = model.diffReadCount
        model.select(file)
        try await waitFor { model.diffReadCount > previous || !model.diffLoading }
      }
      try await waitFor { !model.diffLoading }
      let activity = GitProcessActivity.snapshot()
      let passed = activity.launches >= count / 2 && activity.peak <= 3
        && model.selectedPath == files.last?.path && model.diff.raw.contains("+first change")
      let report: [String: Any] = ["passed": passed, "files": count, "peakGitProcesses": activity.peak,
        "gitLaunches": activity.launches, "diffReads": model.diffReadCount, "scope": "repository model and actual Git processes; visual controls covered separately"]
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("diff-burst.json"))
      guard passed else { throw GitPierError.invalidInput("Rapid Diff selection exceeded the existing workspace process budget") }
    } else {
      try await waitFor { FileManager.default.fileExists(atPath: fixture.appendingPathComponent(".git/quality-diff-read").path) }
      guard let file = files.first else { throw GitPierError.invalidInput("Missing Diff fixture file") }
      model.select(file)
      await Task.yield()
      try Data("second external change\n".utf8).write(to: fixture.appendingPathComponent(file.path))
      try Data().write(to: fixture.appendingPathComponent(".git/quality-diff-release"))
      try await waitFor { !model.diffLoading }
      let passed = model.diffError != nil || model.diff.raw.contains("+second external change")
      let report: [String: Any] = ["passed": passed, "showedOldDiff": model.diff.raw.contains("+first change"),
        "reportedChange": model.diffError != nil, "scope": "repository model publication after a controlled real Git read"]
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("diff-stale.json"))
      guard passed else { throw GitPierError.invalidInput("A file changed during its Diff read but stale contents were published") }
    }
  }

  static func verifyPostCommitQuality(root: URL, output: URL, cancel: Bool) async throws {
    let fixture = root.deletingLastPathComponent().appendingPathComponent(cancel ? "quality-cancel" : "quality-failure")
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    let git = GitService(root: fixture)
    try await git.perform(["init", "-b", "main"])
    try await git.perform(["config", "user.name", "Quality Fixture"])
    try await git.perform(["config", "user.email", "quality@example.invalid"])
    try await git.perform(["config", "commit.gpgsign", "false"])
    let file = fixture.appendingPathComponent("tracked.txt")
    try Data("seed\n".utf8).write(to: file)
    try await git.perform(["add", "--", "tracked.txt"])
    try await git.perform(["commit", "-m", "seed"])
    let remote = fixture.deletingLastPathComponent().appendingPathComponent(cancel ? "quality-cancel.git" : "quality-failure.git")
    try await git.perform(["init", "--bare", remote.path])
    try await git.perform(["remote", "add", "origin", remote.path])
    try await git.perform(["push", "--set-upstream", "origin", "main"])
    let before = try await git.resolveCommit("HEAD")
    let wrapper = fixture.appendingPathComponent(".git/quality-git")
    let wait = cancel ? """
      if [ ! -e .git/quality-first-status ]; then
        : > .git/quality-first-status
        echo 'Synthetic post-commit observation failure' >&2
        exit 81
      fi
      : > .git/quality-waiting
      trap 'rm -f .git/quality-post-commit; exit 130' TERM
      /bin/sleep 30
      """ : "echo 'Synthetic post-commit observation failure' >&2\nexit 81"
    let script = """
      #!/bin/sh
      case " $* " in
        *" commit "*)
          /usr/bin/git "$@"
          result=$?
          if [ "$result" = 0 ]; then : > .git/quality-post-commit; fi
          exit "$result"
          ;;
        *" status "*)
          if [ -e .git/quality-post-commit ]; then
            \(wait)
          fi
          ;;
      esac
      exec /usr/bin/git "$@"
      """
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    let persistence = ConfigurationStore(url: fixture.deletingLastPathComponent().appendingPathComponent(cancel ? "quality-cancel.json" : "quality-failure.json"))
    var configuration = WorkspaceConfiguration()
    configuration.settings.gitPath = wrapper.path
    configuration.settings.automaticRefresh = false
    configuration.settings.completionNotifications = false
    try persistence.save(configuration)
    let store = AppStore(persistence: persistence)
    defer { store.shutdown() }
    await store.addRepository(fixture)
    guard let model = store.current else { throw GitPierError.invalidInput("Quality fixture did not open") }
    await model.activate()
    try Data("selected local change\n".utf8).write(to: file)
    await model.refresh()
    model.toggleIncluded(model.status.files)
    model.editDraft("quality: preserve successful local commit")
    model.commit(push: true)
    if cancel {
      try await waitFor { FileManager.default.fileExists(atPath: fixture.appendingPathComponent(".git/quality-waiting").path) && !model.committing }
      model.cancel()
    }
    try await waitFor { !model.busy }
    let committed = try await git.resolveCommit("HEAD")
    let remoteHead = try await git.read(["--git-dir=" + remote.path, "rev-parse", "main"]).text.trimmingCharacters(in: .newlines)
    let localText = model.output ?? ""
    let operation = store.operations.records.first { $0.kind == .commitAndPush }
    let passed = committed != before && remoteHead == before && model.lastCommit == committed
      && localText.contains("Local commit succeeded") && localText.contains(String(committed.prefix(8)))
      && localText.contains(cancel ? "cancelled" : "failed")
      && model.pushFailed && (cancel || model.error?.contains("Local commit succeeded") == true)
      && operation?.localCommit == committed && operation?.detail?.contains("Local commit succeeded") == true
    let report: [String: Any] = ["scenario": cancel ? "post-commit-status-cancelled" : "post-commit-status-failed",
      "passed": passed, "headAdvanced": committed != before, "remoteUnchanged": remoteHead == before,
      "reportedLocalCommit": model.lastCommit == committed, "output": localText,
      "operationStates": store.operations.records.map { $0.state.rawValue }]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(cancel ? "post-commit-cancel.json" : "post-commit-failure.json"))
    guard passed else { throw GitPierError.invalidInput("Local success was lost after post-commit status collection; see quality report") }
    let marker = fixture.appendingPathComponent(".git/quality-post-commit")
    if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
    await model.refresh()
    model.network("push")
    try await waitFor { !model.busy }
    let afterRetry = try await git.resolveCommit("HEAD")
    let pushed = try await git.read(["--git-dir=" + remote.path, "rev-parse", "main"]).text.trimmingCharacters(in: .newlines)
    guard afterRetry == committed, pushed == committed else { throw GitPierError.invalidInput("Push retry changed the local commit or did not reach the local bare remote") }
    guard store.operations.records.first(where: { $0.id == operation?.id })?.detail == operation?.detail else {
      throw GitPierError.invalidInput("A later successful Push erased the earlier operation's diagnostic")
    }
  }
}
#endif
