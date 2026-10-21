import AppKit
import GitPierCore
import SwiftUI

/// Continuations, rather than delays, decide when the operation crosses each boundary.
@MainActor final class TaskInteractionGate {
  private var entered = false
  private var arrival: CheckedContinuation<Void, Never>?
  private var release: CheckedContinuation<Void, Never>?
  func wait() async {
    entered = true; arrival?.resume(); arrival = nil
    await withCheckedContinuation { release = $0 }
  }
  func waitUntilEntered() async {
    if !entered { await withCheckedContinuation { arrival = $0 } }
  }
  func resume() { release?.resume(); release = nil }
}

@MainActor extension UIAcceptance {
  static func verifyTaskInteractionBoundaries(store: AppStore, primary: RepositoryModel, task: TaskWorkspace, output: URL) async throws -> [String] {
    let manager = store.taskWorkspaces
    let previousSettings = store.settings
    var settings = previousSettings; settings.language = .english; store.updateSettings(settings)
    defer { store.updateSettings(previousSettings) }
    var checks: [String] = []
    func require(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
      guard try value() else { throw GitPierError.invalidInput("Task interaction: " + label) }
      checks.append(label)
      try Data(checks.joined(separator: "\n").utf8).write(to: output.appendingPathComponent("task-interaction-results.txt"))
    }
    func settled(_ request: TaskWorkspaceCreationRequest) async throws {
      try await waitFor { !request.loading && !request.opening }
    }
    let git = await primary.git(), directory = URL(fileURLWithPath: task.path).deletingLastPathComponent()
    let creation = TaskWorkspaceCreationRequest()
    var createCalls = 0
    creation.start(create: {
      createCalls += 1
      return try await manager.create(repositoryID: primary.record.id) {
        try await git.createTaskWorkspace(name: "Navigation recovery", repositoryID: primary.record.id,
          destination: directory.appendingPathComponent("navigation-recovery"), branch: "task/navigation-recovery", registration: manager.persistence)
      }
    }, open: { value in
      let lease = try store.reserveWorktreeLifecycle(value.path)
      defer { store.releaseWorktreeLifecycle(value.path, reservation: lease) }
      _ = try await manager.open(value.id)
    })
    try await settled(creation)
    guard let created = creation.created else { throw GitPierError.invalidInput("Navigation failure hid a successful task creation") }
    try require(creation.problem == nil && creation.navigationProblem != nil, "Opening failure preserves creation success and a separate navigation error")
    let records = try await manager.persistence.records()
    try require(records.contains(created) && manager.tasks.filter { $0.id == created.id }.count == 1, "Created task remains persisted and locatable exactly once")
    try require(store.operations.records.contains { $0.kind == .createTask && $0.state == .succeeded && store.operations.taskID($0.id) == created.id }
      && store.operations.records.contains { $0.kind == .openTask && $0.state == .failed && store.operations.taskID($0.id) == created.id },
      "Operations Center distinguishes successful creation from failed opening and links both to the same task")
    creation.start(create: { createCalls += 1; return created }, open: nil)
    let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 640, height: 360), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: AnyView(TaskWorkspaceCreationSheet(model: primary, manager: manager, request: creation)
      .environmentObject(store).modifier(AppAppearance(store: store))))
    host.sizingOptions = []
    host.frame = window.contentView!.bounds
    window.contentView = host; window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    defer {
      try? workflowAccessibilityText(host).write(to: output.appendingPathComponent("task-created-accessibility.txt"), atomically: true, encoding: .utf8)
      window.close()
    }
    try await settle()
    try capture(host, to: output.appendingPathComponent("task-created-navigation-failure.png"))
    try await waitFor { workflowAccessibilityText(host).contains("Task created") }
    try require(workflowAccessibilityText(host).contains("Open Task") && !workflowAccessibilityText(host).contains("Create Task"),
      "Native creation result offers reopening instead of a duplicate creation action")
    let resultImage = try await ProcessRunner().run(executable: "/usr/sbin/screencapture", arguments: ["-x", "-l", String(window.windowNumber), output.appendingPathComponent("task-created-navigation-failure-window.png").path], directory: nil, timeout: 5)
    try require(resultImage.code == 0, "Visible compositor capture includes the successful creation result and opening error")
    try require(try taskAcceptancePressButton("Open Task", host: host, window: window), "Native saved-task retry button is enabled after an opening failure")
    try await waitFor { store.current?.record.path == created.path && creation.navigationProblem == nil }
    try await settled(creation)
    try require(createCalls == 1 && creation.navigationProblem == nil && store.current?.record.path == created.path,
      "Retry opens the existing task without creating another worktree or branch")
    creation.retryOpen { value in _ = try await manager.open(value.id) }
    try await settled(creation)
    try require(manager.tasks.filter { $0.id == created.id }.count == 1, "Repeated explicit opening retains a single task")

    let success = TaskWorkspaceCreationRequest()
    success.start(create: { created }, open: { value in _ = try await manager.open(value.id) })
    try await settled(success)
    try require(success.created == created && success.problem == nil && success.navigationProblem == nil, "Successful registration and automatic opening report success independently")

    store.select(primary.record.id)
    let targetID = store.models.values.first { $0.record.path == created.path }!.record.id
    var committingNavigation: Task<RepositoryModel, Error>?
    var cancelledBySelection = false
    let selectionObserver = store.$selectedID.sink { id in
      if id == targetID { cancelledBySelection = true; committingNavigation?.cancel() }
    }
    committingNavigation = Task { try await manager.open(created.id) }
    let committedModel = try await committingNavigation!.value
    selectionObserver.cancel()
    try require(cancelledBySelection && committedModel.record.path == created.path
      && store.operations.records.first { $0.kind == .openTask }?.state == .succeeded,
      "Cancellation caused by the committed selection cannot misreport successful opening as cancelled")

    for cancel in [true, false] {
      committedModel.setPage("history")
      let previousPage = committedModel.page
      let previousVisibility = committedModel.panels.layout.terminalVisible
      let previousSessions = Set(committedModel.terminal.sessions.map(\.id))
      let previousSelection = store.selectedID
      var checks = 0
      let rejectedNavigation = Task {
        try await manager.open(created.id, page: "commit", terminal: true, isCurrent: {
          checks += 1
          // The first two checks surround task validation; reject at the repository
          // selection guard, after its real asynchronous root validation completes.
          guard checks < 3 else {
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
            return false
          }
          return true
        })
      }
      var expectedFailure = false
      do { _ = try await rejectedNavigation.value }
      catch is CancellationError { expectedFailure = cancel }
      catch TaskWorkspaceError.changed { expectedFailure = !cancel }
      let unexpectedSessions = committedModel.terminal.sessions.filter { !previousSessions.contains($0.id) }
      // A failing regression must close any shell the old implementation spawned.
      for session in unexpectedSessions { session.close() }
      let operation = store.operations.records.first { $0.kind == .openTask }
      let expectedState = cancel ? operation?.state == .cancelled : operation?.state == .failed
      try require(checks == 3 && expectedFailure && store.selectedID == previousSelection
        && committedModel.page == previousPage && committedModel.panels.layout.terminalVisible == previousVisibility
        && unexpectedSessions.isEmpty && expectedState,
        cancel ? "Cancellation before selection cannot reuse the current task as proof of a committed navigation"
          : "A stale selection cannot change the current task page or create a terminal without committing navigation")
    }

    // Close the owner immediately after registration, while its task still awaits completion.
    let close = TaskWorkspaceCreationRequest(), closeGate = TaskInteractionGate()
    var openedAfterClose = false
    close.start(create: { await closeGate.wait(); return created }, open: { _ in openedAfterClose = true })
    await closeGate.waitUntilEntered(); close.cancel(); closeGate.resume()
    try await settled(close)
    try require(close.created == created && close.problem == nil && !openedAfterClose,
      "Window dismissal after registration preserves success and suppresses automatic opening")

    store.select(primary.record.id)
    let switched = TaskWorkspaceCreationRequest(), switchGate = TaskInteractionGate()
    let source = store.selectedID
    switched.start(create: { await switchGate.wait(); return created }, open: { value in
      _ = try await manager.open(value.id, isCurrent: { store.selectedID == source })
    })
    await switchGate.waitUntilEntered(); store.select(store.models.values.first { $0.record.path == created.path }!.record.id); switchGate.resume()
    let selectedAfterSwitch = store.selectedID
    try await settled(switched)
    try require(switched.created == created && switched.problem == nil && switched.navigationProblem != nil && store.selectedID == selectedAfterSwitch,
      "Repository switching after creation cannot redirect the new selection or misreport creation")
    // Also exercise the last selection guard inside addRepository, after its async validation.
    let beforeNavigation = store.selectedID
    await store.addRepository(URL(fileURLWithPath: primary.record.path), ifCurrent: { false })
    try require(store.selectedID == beforeNavigation, "A stale repository navigation cannot select or register its target after validation")

    let cancelled = TaskWorkspaceCreationRequest(), cancelGate = TaskInteractionGate()
    let recordCount = manager.tasks.count
    cancelled.start(create: {
      try await manager.create(repositoryID: primary.record.id) {
        await cancelGate.wait(); try Task.checkCancellation(); return created
      }
    }, open: nil)
    await cancelGate.waitUntilEntered(); cancelled.cancel(); cancelGate.resume()
    try await settled(cancelled)
    try require(cancelled.created == nil && manager.tasks.count == recordCount && store.operations.records.first { $0.kind == .createTask }?.state == .cancelled,
      "Cancellation before registration cannot report success or create duplicate metadata")

    let persistenceFailure = TaskWorkspaceCreationRequest()
    persistenceFailure.start(create: {
      try await manager.create(repositoryID: primary.record.id) {
        let value = try await git.createTaskWorkspace(name: "Persistence failure", repositoryID: primary.record.id,
          destination: directory.appendingPathComponent("interaction-persistence"), branch: "task/interaction-persistence", registration: manager.persistence)
        let record = await manager.persistence.root.appendingPathComponent(value.id.uuidString + ".json")
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: false)
        return value
      }
    }, open: nil)
    try await settled(persistenceFailure)
    try require(persistenceFailure.created == nil && persistenceFailure.problem != nil && manager.tasks.count == recordCount,
      "Failed task metadata persistence never reports creation success or discards the recovery identity")
    let pending = manager.pendingCreations.first { $0.branch == "task/interaction-persistence" || $0.branch == "refs/heads/task/interaction-persistence" }!
    let blocked = await manager.persistence.root.appendingPathComponent(pending.id.uuidString + ".json")
    try FileManager.default.removeItem(at: blocked)
    try await manager.resumeCreation(pending)

    checks += try await verifyTaskNavigationBoundaries(store: store, primary: primary, task: task, other: created, output: output)

    let mutation = manager.detailMutation(task.id), read = WorkflowRequest(), mutationGate = TaskInteractionGate()
    var writes = 0, mutationWasCancelled = false
    mutation.start {
      writes += 1
      try await manager.markReviewed(task.id, beforePersist: {
        await mutationGate.wait(); mutationWasCancelled = Task.isCancelled
      })
    }
    await mutationGate.waitUntilEntered()
    try require(store.hasBlockingGitOperations && manager.busy.contains(task.id), "A pending confirmed mutation retains the existing last-window and quit safety guard")
    read.start { _ in _ = try await manager.snapshot(task.id) }
    try await waitFor { !read.loading }
    try require(read.problem == nil && mutation.loading, "A real detail snapshot completes while the reviewed fingerprint awaits persistence")
    let cancelledNavigation = WorkflowRequest(), cancelNavigationGate = TaskInteractionGate()
    var navigationFinished = false
    cancelledNavigation.startTaskNavigation(task.id, manager: manager) { isCurrent in
      defer { navigationFinished = true }
      await cancelNavigationGate.wait()
      _ = try await manager.open(task.id, isCurrent: isCurrent)
    }
    await cancelNavigationGate.waitUntilEntered(); cancelledNavigation.cancel(); cancelNavigationGate.resume()
    try await waitFor { navigationFinished }
    read.cancel() // disappearance / switch cancels reads and navigation, never the write
    manager.selectedID = created.id
    mutation.start { writes += 100 }
    mutationGate.resume()
    try await waitFor { !mutation.loading }
    let reviewed = try await manager.persistence.records().first { $0.id == task.id }
    try require(!mutationWasCancelled && writes == 1 && mutation.problem == nil && reviewed?.review != nil && reviewed == manager.task(task.id),
      "Refresh, task switching and duplicate clicks preserve one confirmed review and its exact persisted state")
    try require(manager.detailMutation(task.id) === mutation && manager.detailMutation(created.id) !== mutation,
      "Returning to a task retains its mutation state while another task has an independent controller")

    let archiveGate = TaskInteractionGate()
    mutation.start { try await manager.archive(task.id, archived: true, beforePersist: { await archiveGate.wait() }) }
    await archiveGate.waitUntilEntered()
    read.start { _ in await manager.observe(task.id) }
    try await waitFor { !read.loading }; read.cancel(); archiveGate.resume()
    try await waitFor { !mutation.loading }
    let archived = try await manager.persistence.records().first { $0.id == task.id }
    try require(archived?.archived == true && archived == manager.task(task.id), "List refresh and detail dismissal do not cancel a confirmed archive")
    mutation.start { try await manager.archive(task.id, archived: false) }
    try await waitFor { !mutation.loading }
    try require(manager.task(task.id)?.archived == false && mutation.problem == nil, "Reopening refreshes the actual persisted task after an archive")

    mutation.start { throw GitPierError.invalidInput("Expected mutation failure") }
    try await waitFor { !mutation.loading }
    read.start { _ in _ = try await manager.snapshot(task.id) }
    try await waitFor { !read.loading }
    try require(mutation.problem?.contains("Expected mutation failure") == true && read.problem == nil,
      "Unrelated successful refresh cannot erase a modification error")

    let oldRead = TaskInteractionGate(), newRead = TaskInteractionGate(), lateFinished = TaskInteractionGate()
    var shown: UUID?
    read.start { ticket in
      await oldRead.wait(); if read.current(ticket) { shown = task.id }
      await lateFinished.wait()
    }
    await oldRead.waitUntilEntered()
    read.start { ticket in await newRead.wait(); if read.current(ticket) { shown = created.id } }
    await newRead.waitUntilEntered(); newRead.resume()
    try await waitFor { !read.loading }; oldRead.resume()
    await lateFinished.waitUntilEntered()
    try require(shown == created.id, "A delayed cancelled read cannot replace the newly selected task")
    lateFinished.resume()
    try await manager.markReviewed(task.id)
    try Data("snapshot changed\n".utf8).write(to: URL(fileURLWithPath: task.path).appendingPathComponent("interaction-change.txt"))
    _ = try await manager.snapshot(task.id)
    try require(!manager.reviewCurrent.contains(task.id) && manager.displayStatus(manager.task(task.id)!) != .reviewed,
      "Changing the current snapshot invalidates the reviewed badge")
    try FileManager.default.removeItem(at: URL(fileURLWithPath: task.path).appendingPathComponent("interaction-change.txt"))
    mutation.start {}; try await waitFor { !mutation.loading }
    manager.selectedID = task.id
    try require(try Data(contentsOf: URL(fileURLWithPath: task.path).appendingPathComponent("Sources/workspace.swift")).count > 0,
      "Interaction recovery preserves the original user files")
    if let executablePath = ProcessInfo.processInfo.environment["GITPIER_RC_REAL_CODEX"] {
      // Version/login/start/stop only. Never send a prompt, accept folder trust, or copy credentials.
      let inherited = try AgentEnvironment()
      let real = try await AgentExecutable.detect(explicitPath: executablePath, environment: inherited)
      let loginBefore = try await real.checkLogin()
      let finder = try AgentEnvironment(inheriting: ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
      let finderExecutable = try await AgentExecutable.detect(explicitPath: executablePath, environment: finder)
      try require(finderExecutable.version == real.version, "Real CLI detects with an explicitly selected executable in a Finder-like environment")
      let home = directory.appendingPathComponent("real-cli-empty-home")
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      var values = inherited.values
      for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_IDENTITY_TOKEN_FILE"] { values[key] = nil }
      let isolated = try AgentEnvironment(inheriting: values, codexHome: home.path)
      let isolatedExecutable = try await AgentExecutable.detect(explicitPath: executablePath, environment: isolated)
      let isolatedLogin = try await isolatedExecutable.checkLogin()
      try require(isolatedLogin == .loginRequired, "Real CLI correctly reports an empty custom Codex Home as requiring official login")
      let configuration = try AgentLaunchConfiguration(executable: isolatedExecutable, task: manager.task(task.id)!, snapshot: try await manager.snapshot(task.id))
      do {
        try await manager.launch(task.id, configuration: configuration)
        guard let session = store.current?.terminal.selected else { throw TaskWorkspaceError.unavailable }
        // Let the gated helper exec the real CLI before exercising terminal interruption.
        let childPID = session.view.process.shellPid
        try await waitFor {
          var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
          return proc_pidpath(childPID, &path, UInt32(path.count)) > 0 && String(cString: path) == isolatedExecutable.path
        }
        let cwd = try await ProcessRunner().run(executable: "/usr/sbin/lsof", arguments: ["-a", "-p", String(childPID), "-d", "cwd", "-Fn"], directory: nil, timeout: 5)
        let actualDirectory = cwd.text.split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) } ?? ""
        try require(cwd.code == 0 && ProfessionalWorkflowParser.canonicalPath(actualDirectory) == task.path,
          "Real CLI process executes in the selected linked task worktree rather than the source repository or Home")
        session.view.send(txt: "\u{03}")
        // Ctrl+C is sent through the actual terminal; Stop independently verifies process cleanup.
        let stopped = await manager.stopAllAndWait()
        let stopEvidence: [String: Any] = ["pid": childPID, "stopVerified": stopped, "activeCount": manager.active.count,
          "sessionExited": session.exited, "taskState": manager.task(task.id)?.agent?.state.rawValue ?? "missing", "managerProblem": manager.problem != nil]
        try JSONSerialization.data(withJSONObject: stopEvidence, options: [.prettyPrinted, .sortedKeys])
          .write(to: output.appendingPathComponent("real-cli-stop-diagnostic.json"))
        try require(stopped && manager.active.isEmpty && session.exited, "Real unauthenticated CLI uses the native PTY and Stop verifies attached-process cleanup without a model call")
        let loginAfter = try await real.checkLogin()
        try require(loginAfter == loginBefore, "Official default login status remains unchanged after isolated real CLI PTY startup and exit")
        let evidence: [String: Any] = ["version": real.version, "defaultLoginAvailable": loginBefore == .loggedIn,
          "defaultLoginUnchanged": loginAfter == loginBefore, "customHomeLoginRequired": true, "modelCalls": 0,
          "nativePTY": true, "cleanupVerified": stopped, "safeArguments": configuration.arguments]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
          .write(to: output.appendingPathComponent("real-cli-native.json"))
      } catch {
        // Failed assertions must not let the shell trap delete an unverified live session.
        while !(await manager.stopAllAndWait()) {
          try? Data("Process cleanup unverified; preserve the fixture and inspect before retrying.\n".utf8)
            .write(to: output.appendingPathComponent("real-cli-cleanup-unverified.txt"))
          let retry = output.appendingPathComponent("retry-real-cleanup")
          while !FileManager.default.fileExists(atPath: retry.path) {
            await Task.detached { try? await Task.sleep(for: .milliseconds(250)) }.value
          }
          try? FileManager.default.removeItem(at: retry)
        }
        throw error
      }
    }
    return checks
  }
}
