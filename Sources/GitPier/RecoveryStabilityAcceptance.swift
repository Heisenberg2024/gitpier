#if DEBUG
import Foundation
import GitPierCore

extension UIAcceptance {
  static func verifyRecoveryStability(root: URL, output: URL, scenario: String) async throws {
    guard ["merge-error", "merge-cancel", "merge-success", "retry-error", "retry-cancel", "retry-success", "merge-noop-error", "merge-noop-cancel", "merge-noop-refresh-error", "merge-noop-refresh-cancel"].contains(scenario) else {
      throw GitPierError.invalidInput("Unknown recovery stability scope")
    }
    var failures: [String] = []
    for language in [AppLanguage.english, .simplifiedChinese] {
      let retry = scenario.hasPrefix("retry-"), cancelled = scenario.hasSuffix("-cancel")
      let noOp = scenario.contains("-noop-")
      let inFlightRefresh = scenario.contains("-refresh-")
      let success = scenario.hasSuffix("-success")
      let name = "recovery-" + scenario + "-" + language.rawValue
      let fixture = root.deletingLastPathComponent().appendingPathComponent(name)
      try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
      let git = GitService(root: fixture)
      try await git.perform(["init", "-b", "main"])
      for pair in [["user.name", "Recovery Fixture"], ["user.email", "recovery@example.invalid"],
        ["commit.gpgsign", "false"], ["core.hooksPath", fixture.appendingPathComponent(".git/hooks").path]] {
        try await git.perform(["config"] + pair)
      }
      for file in ["first.txt", "second.txt"] { try Data("base\n".utf8).write(to: fixture.appendingPathComponent(file)) }
      try await git.perform(["add", "--", "first.txt", "second.txt"])
      try await git.perform(["commit", "-m", "recovery seed"])
      let baseHead = try await git.resolveCommit("HEAD")
      let remote = fixture.deletingLastPathComponent().appendingPathComponent(name + ".git")
      let peer = fixture.deletingLastPathComponent().appendingPathComponent(name + "-peer")
      try await git.perform(["init", "--bare", remote.path])
      try await git.perform(["--git-dir=" + remote.path, "config", "core.hooksPath", remote.appendingPathComponent("hooks").path])
      try await git.perform(["remote", "add", "origin", remote.path])
      try await git.perform(["push", "--set-upstream", "origin", "main"])
      try await git.perform(["clone", "--branch", "main", remote.path, peer.path])
      let peerGit = GitService(root: peer)
      for pair in [["user.name", "Recovery Peer"], ["user.email", "peer@example.invalid"],
        ["commit.gpgsign", "false"], ["core.hooksPath", peer.appendingPathComponent(".git/hooks").path]] {
        try await peerGit.perform(["config"] + pair)
      }
      let remoteFile = retry ? "first.txt" : "second.txt"
      try Data("remote\n".utf8).write(to: peer.appendingPathComponent(remoteFile))
      try await peerGit.perform(["add", "--", remoteFile])
      try await peerGit.perform(["commit", "-m", "recovery peer change"])
      try await peerGit.perform(["push", "origin", "main"])
      let remoteBefore = try await peerGit.resolveCommit("HEAD")
      try Data("local\n".utf8).write(to: fixture.appendingPathComponent("first.txt"))
      try await git.perform(["add", "--", "first.txt"])
      try await git.perform(["commit", "-m", "recovery local change"])
      let localBefore = try await git.resolveCommit("HEAD")
      let rejection: PushRejection
      do {
        _ = try await git.network("push")
        throw GitPierError.invalidInput("Recovery fixture did not diverge")
      } catch let rejected as PushRejection { rejection = rejected }
      if noOp { try await git.perform(["--git-dir=" + remote.path, "update-ref", "refs/heads/main", baseHead]) }
      let wrapper = fixture.appendingPathComponent(".git/recovery-git")
      try """
        #!/bin/sh
        verb=
        for argument in "$@"; do
          case "$argument" in commit|merge|push) verb="$argument"; break ;; esac
        done
        case " $* " in
          *" rev-parse --absolute-git-dir "*)
            if [ -e .git/recovery-refresh-gate ]; then
              : > .git/recovery-refresh-entered
              while [ -e .git/recovery-refresh-gate ]; do /bin/sleep 0.01; done
            fi ;;
        esac
        case "$verb" in
          commit|merge) printf '%s\\n' "$verb" >> .git/recovery-writes ;;
          push)
            /usr/bin/git "$@"
            result=$?
            if [ "$result" = 0 ] && [ -e .git/recovery-inject ]; then
              \(cancelled ? "echo 'Synthetic recovery cancellation after remote acceptance' >&2" : "echo 'Synthetic recovery client error after remote acceptance' >&2")
              # Publish readiness only after the required diagnostic is in the pipe.
              /usr/bin/git rev-parse HEAD > .git/recovery-accepted
              \(cancelled ? "exec /bin/sleep 30" : "exit 84")
            fi
            exit "$result" ;;
        esac
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
      let persistence = ConfigurationStore(url: fixture.deletingLastPathComponent().appendingPathComponent(name + ".json"))
      var configuration = WorkspaceConfiguration()
      configuration.settings.gitPath = wrapper.path
      configuration.settings.language = language
      configuration.settings.automaticRefresh = false
      configuration.settings.completionNotifications = false
      try persistence.save(configuration)
      let store = AppStore(persistence: persistence)
      defer { store.shutdown() }
      await store.addRepository(fixture)
      guard let model = store.current else { throw GitPierError.invalidInput("Missing recovery model") }
      await model.activate(); store.workspace.shutdown()
      let inject = fixture.appendingPathComponent(".git/recovery-inject")
      if !retry && !success { try Data().write(to: inject) }
      model.confirmMergeAndPush(rejection)
      guard let confirmation = model.confirmation, confirmation.readyForConfirmation else {
        throw GitPierError.invalidInput("Recovery confirmation missing")
      }
      model.confirmation = nil; confirmation.performConfirmedAction()
      var previous: WorkflowOperationRecord?
      func retryWithReview() throws {
        model.retryPush()
        if let review = model.confirmation {
          guard review.readyForConfirmation else { throw GitPierError.invalidInput("Saved Push review is not ready") }
          model.confirmation = nil; review.performConfirmedAction()
        }
      }
      if retry {
        try await waitFor { !model.busy && !model.refreshing }
        guard model.conflictPush != nil, model.status.operation == .merge else {
          throw GitPierError.invalidInput("The real merge conflict did not retain its push destination")
        }
        try Data("resolved\n".utf8).write(to: fixture.appendingPathComponent("first.txt"))
        try await git.perform(["add", "--", "first.txt"])
        await model.refresh()
        let hook = remote.appendingPathComponent("hooks/pre-receive")
        try "#!/bin/sh\nif [ -e recovery-block-first ]; then rm -f -- recovery-block-first; echo 'Synthetic first recovery push rejection' >&2; exit 1; fi\nexit 0\n"
          .write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        try Data().write(to: remote.appendingPathComponent("recovery-block-first"))
        guard model.canContinueMerge else { throw GitPierError.invalidInput("Resolved merge cannot continue") }
        model.reviewMergeContinuation(push: true)
        try await waitFor { !model.busy && !model.refreshing }
        guard let continuation = model.confirmation, continuation.readyForConfirmation else {
          throw GitPierError.invalidInput("Merge continuation confirmation missing")
        }
        model.confirmation = nil; continuation.performConfirmedAction()
        try await waitFor { !model.busy && !model.refreshing }
        guard model.conflictPush != nil, model.status.operation == nil else {
          throw GitPierError.invalidInput("The native first push rejection did not retain recovery")
        }
        previous = store.operations.records.first { $0.kind == .mergeAndPush }
        if !success { try Data().write(to: inject) }
        try retryWithReview()
      }
      if cancelled {
        try await waitFor { FileManager.default.fileExists(atPath: fixture.appendingPathComponent(".git/recovery-accepted").path) }
        model.cancel()
      }
      model.setPage("history"); store.showDashboard = true
      try await waitFor { !model.busy && !model.refreshing }
      let created = try await git.resolveCommit("HEAD")
      let pushed = try await git.read(["--git-dir=" + remote.path, "rev-parse", "main"]).text.trimmingCharacters(in: .newlines)
      let parents = try await git.read(["show", "-s", "--format=%P", "HEAD"]).text.split(whereSeparator: \.isWhitespace).map(String.init)
      let kind: WorkflowOperationKind = retry ? .push : .mergeAndPush
      let operation = store.operations.records.first { $0.kind == kind }
      let expectedState: WorkflowOperationState = success ? .succeeded : .resultUnknown
      let diagnosis = success || (cancelled
        ? operation?.detail?.contains(store.text("cancelled", "取消")) == true
          && operation?.detail?.contains("Synthetic recovery cancellation") == true
          && operation?.detail?.contains(CancellationError().localizedDescription) == true
        : operation?.detail?.contains("Synthetic recovery client error") == true)
      var passed = (noOp ? created == localBefore : created != localBefore && parents == [localBefore, remoteBefore]) && pushed == created
        && operation?.localCommit == created && model.lastCommit == created
        && operation?.state == expectedState && diagnosis && model.available
      if !success {
        passed = passed && operation?.detail?.contains(store.text("remote", "远端")) == true && model.conflictPush != nil
      }
      if let previous { passed = passed && store.operations.records.first(where: { $0.id == previous.id })?.detail == previous.detail }
      let writes = fixture.appendingPathComponent(".git/recovery-writes")
      let beforeRetry = try Data(contentsOf: writes)
      var intermediateTargetRetained = true, repeatedUnknownTargetRetained = true
      if noOp && !success {
        var refresh: Task<Void, Never>?
        let refreshGate = fixture.appendingPathComponent(".git/recovery-refresh-gate")
        if inFlightRefresh {
          try Data().write(to: refreshGate)
          refresh = Task { await model.refresh() }
          try await waitFor { FileManager.default.fileExists(atPath: fixture.appendingPathComponent(".git/recovery-refresh-entered").path) }
        } else {
          try Data("unrelated staging\n".utf8).write(to: fixture.appendingPathComponent("unrelated.txt"))
          await model.refresh()
          guard let file = model.status.files.first(where: { $0.path == "unrelated.txt" }) else {
            throw GitPierError.invalidInput("Missing unrelated local stage fixture")
          }
          model.stageGroup([file], unstage: false)
          try await waitFor { !model.busy && !model.refreshing }
          intermediateTargetRetained = model.conflictPush != nil
        }
        let indexBefore = try Data(contentsOf: fixture.appendingPathComponent(".git/index"))
        let accepted = fixture.appendingPathComponent(".git/recovery-accepted")
        try FileManager.default.removeItem(at: accepted)
        // The first attempt reached the server. A matching remote now avoids
        // another transfer; move this disposable remote back to exercise a
        // genuinely necessary second attempt and its interrupted observation.
        try await git.perform(["--git-dir=" + remote.path, "update-ref", "refs/heads/main", baseHead])
        try retryWithReview()
        if inFlightRefresh {
          try FileManager.default.removeItem(at: refreshGate)
          await refresh?.value
        }
        if cancelled {
          try await waitFor { FileManager.default.fileExists(atPath: accepted.path) }
          model.cancel()
        }
        try await waitFor { !model.busy && !model.refreshing }
        let again = store.operations.records.first { $0.kind == .push }
        repeatedUnknownTargetRetained = model.conflictPush != nil
        let indexAfter = try Data(contentsOf: fixture.appendingPathComponent(".git/index"))
        let repeatedHead = try await git.resolveCommit("HEAD")
        passed = passed && intermediateTargetRetained && repeatedUnknownTargetRetained
          && again?.state == .resultUnknown && again?.localCommit == created && repeatedHead == created
          && indexAfter == indexBefore
      }
      if !success {
        try FileManager.default.removeItem(at: inject)
        try retryWithReview()
        try await waitFor { !model.busy && !model.refreshing }
        let after = try await git.resolveCommit("HEAD")
        let afterWrites = try Data(contentsOf: writes)
        passed = passed && after == created && afterWrites == beforeRetry
          && store.operations.records.first(where: { $0.id == operation?.id })?.detail == operation?.detail
      }
      let report: [String: Any] = ["scenario": scenario, "language": language.rawValue, "passed": passed,
        "localHead": created, "remoteAccepted": pushed == created, "parents": parents,
        "checkpoint": operation?.localCommit ?? "missing", "state": operation?.state.rawValue ?? "missing",
        "targetAfterOtherOperation": intermediateTargetRetained, "targetAfterRepeatedUnknown": repeatedUnknownTargetRetained,
        "diagnosis": operation?.detail ?? "", "pageChanged": model.page == "history",
        "writeCommandsBeforeRetry": String(decoding: beforeRetry, as: UTF8.self)]
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent(name + ".json"))
      if !passed { failures.append(name) }
    }
    guard failures.isEmpty else { throw GitPierError.invalidInput("Recovery stability failed: " + failures.joined(separator: ", ")) }
  }
}
#endif
