import AppKit
import GitPierCore
import SwiftUI
import PTYSupport

@MainActor extension UIAcceptance {
  static func verifyTaskWorkspaces(root: URL, output: URL) async throws {
    guard root.path.contains("/GitPier-ui."), ProcessInfo.processInfo.environment["GIT_CONFIG_GLOBAL"] == "/dev/null" else {
      throw GitPierError.invalidInput("Task acceptance requires the isolated temporary repository")
    }
    var checks: [String] = []
    defer { try? Data(checks.joined(separator: "\n").utf8).write(to: output.appendingPathComponent("task-workspaces-partial.txt")) }
    func stage(_ name: String) throws {
      try Data(name.utf8).write(to: output.appendingPathComponent("task-workspaces-stage.txt"))
    }
    func require(_ value: @autoclosure () throws -> Bool, _ description: String) throws {
      guard try value() else { throw GitPierError.invalidInput("Task acceptance: " + description) }; checks.append(description)
    }
    let directory = root.deletingLastPathComponent()
    let persistence = ConfigurationStore(url: directory.appendingPathComponent("tasks-workspace.json"))
    let store = AppStore(persistence: persistence)
    await store.taskWorkspaces.restore()
    await store.addRepository(root)
    guard let primary = store.current else { throw TaskWorkspaceError.unavailable }
    let manager = store.taskWorkspaces, git = await primary.git()
    let recovering = try await git.createTaskWorkspace(name: "Recover registration", repositoryID: primary.record.id,
      destination: directory.appendingPathComponent("recover-registration"), branch: "task/recover", registration: manager.persistence)
    let metadataRoot = await manager.persistence.root
    let blockedRecord = metadataRoot.appendingPathComponent(recovering.id.uuidString + ".json")
    try FileManager.default.createDirectory(at: blockedRecord, withIntermediateDirectories: false)
    do { try await manager.register(recovering); throw GitPierError.invalidInput("Registration fault did not fail") }
    catch { guard !(error is GitPierError) else { throw error } }
    try require(!store.configuration.ownedWorktrees.contains(recovering.binding.ownership) && !manager.tasks.contains(where: { $0.id == recovering.id }),
      "Failed task persistence does not publish a task or grant application registry ownership")
    try FileManager.default.removeItem(at: blockedRecord)
    let pending = try await manager.persistence.pendingCreations()
    let resumed = try await git.resumeTaskWorkspaceCreation(pending.first { $0.id == recovering.id }!)
    try await manager.register(resumed)
    try require(manager.tasks.filter { $0.id == recovering.id }.count == 1 && store.configuration.ownedWorktrees.contains(recovering.binding.ownership),
      "Original creation identity resumes registration once and restores application ownership")
    try stage("application registry persistence fault")
    let registryTask = try await git.createTaskWorkspace(name: "Recover registry", repositoryID: primary.record.id,
      destination: directory.appendingPathComponent("recover-registry"), branch: "task/registry", registration: manager.persistence)
    do {
      let backup = directory.appendingPathComponent("workspace-preserved.json")
      try FileManager.default.moveItem(at: persistence.url, to: backup)
      try FileManager.default.createDirectory(at: persistence.url, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: persistence.url); try? FileManager.default.moveItem(at: backup, to: persistence.url) }
      do {
        _ = try await manager.create(repositoryID: primary.record.id) { registryTask }
        throw GitPierError.invalidInput("Registry persistence failure was reported as success")
      } catch let failure as WorktreeCreationFailure {
        try require(failure.stage == .taskRegistration && failure.path == registryTask.path, "Application registry failure reports the created worktree and registration stage")
      }
      try require(!manager.tasks.contains(where: { $0.id == registryTask.id }) && !store.configuration.ownedWorktrees.contains(registryTask.binding.ownership)
        && manager.pendingCreations.contains(where: { $0.id == registryTask.id }), "Pending identity survives until task and application registry persistence both succeed")
    }
    try await manager.resumeCreation(manager.pendingCreations.first { $0.id == registryTask.id }!)
    try require(manager.tasks.filter { $0.id == registryTask.id }.count == 1, "Registry persistence failure can resume without duplicate task metadata")
    let task = try await git.createTaskWorkspace(name: "Build task workspace", savedDescription: "Private fixture description", repositoryID: primary.record.id,
      destination: directory.appendingPathComponent("task-one"), branch: "task/one", registration: manager.persistence)
    try await manager.register(task)
    try require(manager.tasks.count == 3 && manager.ready, "Task created and registered without starting an agent")
    try require(manager.active.isEmpty && primary.terminal.sessions.isEmpty, "No terminal or Codex process starts automatically")
    let child = await manager.git(task)
    try Data("committed task change\n".utf8).write(to: URL(fileURLWithPath: task.path).appendingPathComponent("task-commit.txt"))
    try await child.perform(["add", "--", "task-commit.txt"])
    try await child.perform(["commit", "-m", "fixture: agent-created local commit"])
    try Data("staged task change\n".utf8).write(to: URL(fileURLWithPath: task.path).appendingPathComponent("task-commit.txt"))
    try await child.perform(["add", "--", "task-commit.txt"])
    try Data("staged task change\nunstaged task change\n".utf8).write(to: URL(fileURLWithPath: task.path).appendingPathComponent("task-commit.txt"))
    let indexURL = URL(fileURLWithPath: task.binding.ownership.gitDirectory).appendingPathComponent("index")
    let index = try Data(contentsOf: indexURL)
    let snapshot = try await manager.snapshot(task.id)
    try require(snapshot.comparison.rightOnlyCount == 1 && snapshot.status.files.contains(where: \.isPartial), "Review includes local commits and partial staging")
    try await manager.review(task.id, baseline: true)
    try require(store.current?.page == "compare" && store.current?.workflowComparison?.left == task.baseCommit, "Baseline review navigates to the existing fixed-SHA comparison")
    try await manager.review(task.id, baseline: false)
    try require(store.current?.page == "commit", "Working tree review reuses the existing commit workspace")
    try require(try Data(contentsOf: indexURL) == index, "Task review preserves the exact external Index")
    let program = directory.appendingPathComponent("codex-fixture")
    let script = #"""
    #!/bin/sh
    if [ "$1" = --version ]; then printf 'codex-cli 0.163.0\n'; exit 0; fi
    if [ "$1" = --help ] || [ "$6" = --help ]; then printf '%s\n' '--no-daemon --sandbox workspace-write --ask-for-approval on-request'; exit 0; fi
    if [ "$1" = login ] && [ "$2" = status ]; then printf 'Not logged in\n' >&2; exit 1; fi
    [ "$#" = 5 ] && [ "$1" = --no-daemon ] && [ "$2" = --sandbox ] && [ "$3" = workspace-write ] && [ "$4" = --ask-for-approval ] && [ "$5" = on-request ] || exit 23
    printf '%s\n' "$PWD" > agent-cwd.txt
    printf 'agent change\n' > agent-output.txt
    printf 'TASK_AGENT_READY\r\n'
    trap 'exit 130' HUP INT TERM
    while IFS= read -r line; do
      [ "$line" = exit ] && exit 0
      printf 'INPUT:%s\r\n' "$line"
    done
    """#
    try Data((script + "\n").utf8).write(to: program)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
    let executable = try await AgentExecutable.detect(explicitPath: program.path)
    let before = try await manager.snapshot(task.id)
    let launch = try AgentLaunchConfiguration(executable: executable, task: manager.task(task.id)!, snapshot: before)
    let unverifiable = TerminalSession(root: task.path, number: 0, settings: store.settings, agentConfiguration: launch, autoStart: false)
    let uncertainCleanup = await unverifiable.stopAgentAndWait()
    try require(!uncertainCleanup && !unverifiable.exited, "Unverifiable process cleanup cannot publish exit or release the terminal lifecycle guard")
    try await manager.markReviewed(task.id)
    try require(manager.reviewCurrent.contains(task.id), "Explicit full content review publishes the current receipt")
    await manager.observe(task.id)
    try require(!manager.reviewCurrent.contains(task.id), "Lightweight list refresh invalidates review status without a repeated full content scan")
    try await manager.launch(task.id, configuration: launch)
    guard let model = store.current, let session = model.terminal.selected else { throw TaskWorkspaceError.unavailable }
    defer { session.close(); store.shutdown() }
    try await waitFor { FileManager.default.fileExists(atPath: task.path + "/agent-cwd.txt") }
    let actualDirectory = try String(contentsOfFile: task.path + "/agent-cwd.txt", encoding: .utf8).trimmingCharacters(in: .newlines)
    try require(ProfessionalWorkflowParser.canonicalPath(actualDirectory) == task.path, "PTY starts in the task worktree using executable/argument arrays")
    try require(manager.task(task.id)?.agent?.state == .running && !session.exited, "Running state comes from the live PTY lifecycle")
    try await manager.setWaitingForInput(task.id, waiting: true)
    try require(manager.task(task.id)?.agent?.state == .waitingForInput && manager.active.count == 1, "Explicit waiting annotation preserves the live session and its safety blockers")
    try await manager.setWaitingForInput(task.id, waiting: false)
    do { try store.validateWorktreeSessions(task.path); throw GitPierError.invalidInput("Active removal unexpectedly allowed") }
    catch TaskWorkspaceError.activeSession { checks.append("Active agent prevents worktree removal and repair") }
    do { try await manager.archive(task.id, archived: true); throw GitPierError.invalidInput("Active archive unexpectedly allowed") }
    catch TaskWorkspaceError.activeSession { checks.append("Active agent cannot be archived") }
    try await manager.launchDuplicateForAcceptance(task.id, configuration: launch, checks: &checks)
    model.setPage("history"); try await settle()
    try require(!session.exited && manager.active.count == 1, "Closing the task page keeps the agent alive")
    model.setPage("worktrees")
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 960, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "GitPier v1.8 Task Acceptance — Fixture"
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: AnyView(EmptyView())); host.sizingOptions = []
    window.contentView = host; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    defer { host.rootView = AnyView(EmptyView()); window.close() }
    try stage("cancel login check in launch sheet")
    let slowLogin = directory.appendingPathComponent("codex-slow-login"), loginPID = directory.appendingPathComponent("login-check.pid")
    let slowScript = """
    #!/bin/sh
    if [ "$1" = --version ]; then printf 'codex-cli 0.163.0\\n'; exit 0; fi
    if [ "$1" = --help ] || [ "$6" = --help ]; then printf '%s\\n' '--no-daemon --sandbox workspace-write --ask-for-approval on-request'; exit 0; fi
    if [ "$1" = login ] && [ "$2" = status ]; then printf '%s' "$$" > \(InputValidation.shellQuote(loginPID.path)); exec /bin/sleep 30; fi
    exit 2
    """
    try Data(slowScript.utf8).write(to: slowLogin); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: slowLogin.path)
    let priorSettings = store.settings
    var probeSettings = priorSettings; probeSettings.language = .english; probeSettings.codexExecutablePath = slowLogin.path; store.updateSettings(probeSettings)
    host.rootView = AnyView(CodexLaunchSheet(taskID: recovering.id, manager: manager).environmentObject(store).modifier(AppAppearance(store: store)))
    try await settle()
    try require(try taskAcceptancePressButton("Detect", host: host, window: window), "Launch sheet exposes an enabled Detect action")
    try await waitFor { workflowAccessibilityText(host).contains("Installed · login not checked") }
    try require(try taskAcceptancePressButton("Check Login Status", host: host, window: window), "Launch sheet starts login checks only after explicit action")
    try await waitFor { FileManager.default.fileExists(atPath: loginPID.path) }
    try capture(host, to: output.appendingPathComponent("codex-login-checking.png"))
    let cancelStarted = ProcessInfo.processInfo.systemUptime
    try require(try taskAcceptancePressButton("Cancel", host: host, window: window), "Launch sheet keeps cancellation available during a slow login check")
    let checkingPID = Int32(try String(contentsOf: loginPID, encoding: .utf8))!
    try await waitFor { kill(checkingPID, 0) != 0 }
    try require(ProcessInfo.processInfo.systemUptime - cancelStarted < 2.5, "Launch-sheet authentication cancellation stops the child before its timeout")
    try require(!workflowAccessibilityText(host).contains("Login required") && workflowAccessibilityText(host).contains("Installed · login not checked"), "Cancelled authentication probes terminate and cannot publish late login results")
    try capture(host, to: output.appendingPathComponent("codex-login-cancelled.png"))
    host.rootView = AnyView(EmptyView()); store.updateSettings(priorSettings); try await settle()
    try stage("detail refresh after same-timestamp session transition")
    var detailSettings = store.settings; detailSettings.language = .english; store.updateSettings(detailSettings)
    host.rootView = AnyView(TaskWorkspaceDetail(taskID: task.id, manager: manager).environmentObject(store).modifier(AppAppearance(store: store)))
    defer { try? workflowAccessibilityText(host).write(to: output.appendingPathComponent("task-detail-accessibility.txt"), atomically: true, encoding: .utf8) }
    try await waitFor { workflowAccessibilityText(host).contains("2 untracked") }
    try stage("detail initial loaded; waiting for same-timestamp transition")
    let refreshFile = URL(fileURLWithPath: task.path).appendingPathComponent("same-timestamp.txt")
    try Data("new task change\n".utf8).write(to: refreshFile)
    let runningTask = manager.task(task.id)!
    var waitingTask = runningTask; waitingTask.agent?.state = .waitingForInput
    // Launching -> Running also preserves updatedAt; the detail must observe the full record.
    try await manager.save(waitingTask, replacing: runningTask)
    try await waitFor { workflowAccessibilityText(host).contains("3 untracked") }
    try require(manager.task(task.id)?.updatedAt == runningTask.updatedAt,
      "Task detail refreshes actual Git changes after a session transition with unchanged activity time")
    try FileManager.default.removeItem(at: refreshFile)
    try await manager.setWaitingForInput(task.id, waiting: false)
    host.rootView = AnyView(EmptyView()); try await settle()
    for language in AppLanguage.allCases {
      for appearance in [AppearanceMode.light, .dark] {
        var settings = store.settings; settings.language = language; settings.appearance = appearance; store.updateSettings(settings)
        host.rootView = AnyView(TaskWorkspacesView(model: model, manager: manager).environmentObject(store).modifier(AppAppearance(store: store))
          .environment(\.locale, Locale(identifier: language == .english ? "en_US" : "zh_Hans")))
        try await settle()
        try capture(host, to: output.appendingPathComponent("tasks-" + language.rawValue + "-" + appearance.rawValue + ".png"))
        let compositor = try await ProcessRunner().run(executable: "/usr/sbin/screencapture", arguments: ["-x", "-l", String(window.windowNumber), output.appendingPathComponent("tasks-window-" + language.rawValue + "-" + appearance.rawValue + ".png").path], directory: nil, timeout: 5)
        try require(compositor.code == 0, "Visible compositor capture " + language.rawValue + "/" + appearance.rawValue)
        let alert = store.makeExternalNavigationAlert(root: root)
        try require(alert.buttons.count == 2 && alert.buttons[1].keyEquivalent == "\r" && !alert.informativeText.isEmpty, "Unknown external navigation requires explicit consent with Cancel default")
      }
    }
    session.view.setFrameSize(NSSize(width: 720, height: 240)); try await settle()
    try require(session.resizeCountForAcceptance > 0, "Existing SwiftTerm session supports native resize")
    try stage("overlapping annotation and exit")
    var annotationEntered = false
    var releaseAnnotation: CheckedContinuation<Void, Never>?
    let annotation = Task { @MainActor in
      do {
        try await manager.setWaitingForInput(task.id, waiting: true, beforePersist: {
          annotationEntered = true
          await withCheckedContinuation { releaseAnnotation = $0 }
        })
      } catch {
        try? stage("overlap annotation failed: " + error.localizedDescription)
        throw error
      }
    }
    defer { releaseAnnotation?.resume(); annotation.cancel() }
    try stage("overlap waiting for annotation entry")
    try await waitFor { annotationEntered }
    try stage("overlap waiting for PTY exit")
    session.view.send(txt: "exit\n")
    try await waitFor { session.exited }
    try require(manager.busy.contains(task.id) && manager.task(task.id)?.agent?.state.active == true, "A real PTY exit waits for an in-flight annotation before releasing task lifecycle ownership")
    releaseAnnotation?.resume(); releaseAnnotation = nil
    try await annotation.value
    try await waitFor { manager.task(task.id)?.agent?.state == .exited && manager.task(task.id)?.status == .changesAvailable && !manager.busy.contains(task.id) }
    try require(manager.task(task.id)?.agent?.exitCode == 0 && manager.task(task.id)?.status == .changesAvailable, "Exit zero is session exit and changes available, not task/test success")
    try require(try Data(contentsOf: indexURL) == index, "Agent session preserves partial Index fixture content")
    try require(store.operations.records.contains { $0.kind == .agentSession && $0.state == .agentExited }, "Operations Center reports Agent Exited separately from Success")
    try stage("archive after exit")
    try await manager.archive(task.id, archived: true)
    try require(manager.task(task.id)?.archived == true && FileManager.default.fileExists(atPath: task.path + "/agent-output.txt"), "Archive preserves files, commits and worktree")
    try await manager.archive(task.id, archived: false)
    let restored = TaskWorkspaceManager(store: store); await restored.restore()
    try require(!restored.ready && restored.problem != nil && restored.active.isEmpty, "Second task-store owner is refused without recovering or executing the first instance's sessions")
    try stage("restart for explicit stop")
    let finalSnapshot = try await manager.snapshot(task.id)
    let fresh = try AgentLaunchConfiguration(executable: executable, task: manager.task(task.id)!, snapshot: finalSnapshot)
    try await manager.launch(task.id, configuration: fresh)
    try await waitFor { manager.active.count == 1 }
    let stopped = await manager.stopAllAndWait()
    try require(stopped && manager.active.isEmpty && manager.task(task.id)?.agent?.state == .interrupted, "Explicit stop waits for verified PTY cleanup and marks Interrupted")
    try stage("Ctrl+C")
    try FileManager.default.removeItem(atPath: task.path + "/agent-cwd.txt")
    let interruptLaunch = try AgentLaunchConfiguration(executable: executable, task: manager.task(task.id)!, snapshot: try await manager.snapshot(task.id))
    try await manager.launch(task.id, configuration: interruptLaunch)
    try await waitFor { FileManager.default.fileExists(atPath: task.path + "/agent-cwd.txt") }
    model.terminal.selected?.view.send(txt: "\u{03}")
    try await waitFor { manager.active.isEmpty && !manager.busy.contains(task.id) }
    try require(manager.task(task.id)?.agent?.exitCode == 130 && manager.task(task.id)?.agent?.state == .failed,
      "Ctrl+C reaches the real PTY and records exit 130 without claiming task success")
    try stage("lifecycle reservation")
    let idle = try AgentLaunchConfiguration(executable: executable, task: manager.task(task.id)!, snapshot: try await manager.snapshot(task.id))
    let lease = try store.reserveWorktreeLifecycle(task.path)
    let count = model.terminal.sessions.count
    do { try await manager.launch(task.id, configuration: idle); throw GitPierError.invalidInput("Reserved task launched") }
    catch let error as GitPierError { guard case .invalidInput(let detail) = error, detail != "Reserved task launched" else { throw error } }
    model.terminal.add(settings: store.settings)
    try await Task.sleep(for: .milliseconds(30))
    try require(manager.active.isEmpty && model.terminal.sessions.count == count, "Lifecycle reservation blocks agent and ordinary terminal starts across suspension")
    store.releaseWorktreeLifecycle(task.path, reservation: lease); store.error = nil
    try stage("invalid cwd")
    let moved = directory.appendingPathComponent("task-cwd-moved")
    try FileManager.default.moveItem(atPath: task.path, toPath: moved.path)
    let wrongDirectory = TerminalSession(root: task.path, number: 0, settings: store.settings, agentConfiguration: idle, autoStart: false)
    wrongDirectory.start(settings: store.settings)
    try await waitFor { wrongDirectory.exited }
    try require(wrongDirectory.exitCode == 126 && !FileManager.default.fileExists(atPath: task.path), "Child launcher refuses a moved cwd instead of executing in the inherited directory")
    try FileManager.default.createSymbolicLink(atPath: task.path, withDestinationPath: moved.path)
    let linkedDirectory = TerminalSession(root: task.path, number: 0, settings: store.settings, agentConfiguration: idle, autoStart: false)
    linkedDirectory.start(settings: store.settings)
    try await waitFor { linkedDirectory.exited }
    try require(linkedDirectory.exitCode == 126, "Child launcher refuses a substituted cwd symlink")
    try FileManager.default.removeItem(atPath: task.path)
    try FileManager.default.moveItem(atPath: moved.path, toPath: task.path)
    try stage("fast exited parent and child cleanup")
    let fast = directory.appendingPathComponent("codex-fast-fixture")
    let fastScript = #"""
    #!/bin/sh
    if [ "$1" = --version ]; then printf 'codex-cli 0.163.0\n'; exit 0; fi
    if [ "$1" = --help ] || [ "$6" = --help ]; then printf '%s\n' '--no-daemon --sandbox workspace-write --ask-for-approval on-request'; exit 0; fi
    ( trap '' HUP INT TERM; exec /bin/sleep 60 ) </dev/null >/dev/null 2>&1 &
    printf '%s\n' "$!" > fast-child.pid
    exit 0
    """#
    try Data((fastScript + "\n").utf8).write(to: fast)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fast.path)
    let fastExecutable = try await AgentExecutable.detect(explicitPath: fast.path)
    let fastLaunch = try AgentLaunchConfiguration(executable: fastExecutable, task: manager.task(task.id)!, snapshot: try await manager.snapshot(task.id))
    try await manager.launch(task.id, configuration: fastLaunch)
    try await waitFor { manager.active.isEmpty && !manager.busy.contains(task.id) }
    let childPID = Int32(try String(contentsOfFile: task.path + "/fast-child.pid", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
    try require(gitpier_process_identity(childPID).pid == 0 || kill(childPID, 0) != 0, "Fast parent exit cleans its attached child before releasing task metadata")
    try stage("removal navigation for an associated current worktree")
    let associatedOwnership = try await git.createWorktree(destination: directory.appendingPathComponent("associate-self"), branch: "associate-self", newBranch: true)
    let associatedGit = await GitServiceRegistry.shared.service(for: URL(fileURLWithPath: associatedOwnership.path))
    let associatedTree = try await associatedGit.worktrees(includeStatus: false).first { $0.path == associatedOwnership.path }!
    let associated = try await associatedGit.associateTaskWorkspace(name: "Associated current worktree", repositoryID: UUID(), worktree: associatedTree, receipt: associatedOwnership)
    try await manager.register(associated)
    try require(associated.repositoryRoot == associated.path, "A task may associate the current linked worktree without changing its identity")
    try await manager.requestRemoval(associated.id)
    try require(store.current?.record.path == ProfessionalWorkflowParser.canonicalPath(root.path)
      && store.taskRemovalRequest?.taskID == associated.id && store.taskRemovalRequest?.sourcePath != associated.path,
      "Task removal navigates to another family worktree and never attempts to remove its executing repository")
    store.taskRemovalRequest = nil
    if ProcessInfo.processInfo.environment["GITPIER_TASK_ACCEPTANCE_HOLD"] == "1" {
      do {
      var settings = store.settings; settings.language = .english; settings.appearance = .light; settings.codexExecutablePath = program.path; store.updateSettings(settings)
      var realTask: TaskWorkspace?, realExecutable: AgentExecutable?, realLaunches = 0
      let sourceIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
      if let path = ProcessInfo.processInfo.environment["GITPIER_TASK_ACCEPTANCE_REAL_CODEX"], !path.isEmpty {
        let executable = try await AgentExecutable.detect(explicitPath: path)
        let login = try await executable.checkLogin()
        try require(login == .loggedIn, "Real CLI reports existing login without reading or copying credentials")
        let created = try await git.createTaskWorkspace(name: "Real Codex acceptance", repositoryID: primary.record.id,
          destination: directory.appendingPathComponent("real-codex-task"), branch: "task/real-codex", registration: manager.persistence)
        try await manager.register(created)
        let configuration = try AgentLaunchConfiguration(executable: executable, task: created, snapshot: try await manager.snapshot(created.id))
        try await manager.launch(created.id, configuration: configuration)
        if ProcessInfo.processInfo.environment["GITPIER_TASK_ACCEPTANCE_FAIL_AFTER_REAL_START"] == "1" {
          throw GitPierError.invalidInput("Injected failure after real native CLI launch")
        }
        guard let actualModel = store.current else { throw TaskWorkspaceError.unavailable }
        host.rootView = AnyView(VStack(spacing: 0) {
          TaskWorkspacesView(model: actualModel, manager: manager).frame(height: 220)
          TerminalPanel(model: actualModel, manager: actualModel.terminal)
        }.environmentObject(store).modifier(AppAppearance(store: store)))
        window.title = "GitPier Real Codex Acceptance — Temporary Worktree"
        realTask = created; realExecutable = executable; realLaunches = 1
        let evidence: [String: String] = ["version": executable.version, "worktree": created.path,
          "arguments": AgentLaunchConfiguration.safeArguments.joined(separator: " "), "taskID": created.id.uuidString]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
          .write(to: output.appendingPathComponent("real-native-start.json"))
      } else if ProcessInfo.processInfo.environment["GITPIER_TASK_ACCEPTANCE_PAGE"] == "codex-settings" {
        host.rootView = AnyView(SettingsView(initialTab: 3).environmentObject(store).modifier(AppAppearance(store: store)))
      } else {
        host.rootView = AnyView(TaskWorkspacesView(model: model, manager: manager).environmentObject(store).modifier(AppAppearance(store: store)).environment(\.locale, Locale(identifier: "en_US")))
      }
      window.setContentSize(NSSize(width: 960, height: 640)); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
      try await settle()
      try Data((realTask == nil ? "Local fixture ready.\n" : "Real CLI in temporary worktree; never accept configuration changes.\n").utf8)
        .write(to: output.appendingPathComponent("ready-gui"))
      while !FileManager.default.fileExists(atPath: output.appendingPathComponent("finish-gui").path) {
        let restart = output.appendingPathComponent("restart-real-cli")
        if let realTask, let realExecutable, FileManager.default.fileExists(atPath: restart.path) {
          try require(manager.active.isEmpty, "Real CLI exits and releases its verified lifecycle guard before restart")
          let current = manager.task(realTask.id)!
          let configuration = try AgentLaunchConfiguration(executable: realExecutable, task: current, snapshot: try await manager.snapshot(current.id))
          try await manager.launch(current.id, configuration: configuration)
          realLaunches += 1
          try FileManager.default.removeItem(at: restart)
          try Data(String(realLaunches).utf8).write(to: output.appendingPathComponent("real-native-launch-count.txt"))
        }
        try await Task.sleep(for: .milliseconds(250))
      }
      guard await manager.stopAllAndWait() else { throw TaskWorkspaceError.activeSession }
      if let realTask, let realExecutable {
        let login = try await realExecutable.checkLogin()
        try require(login == .loggedIn, "Existing Codex login remains available after all real native sessions stop")
        try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == sourceIndex,
          "Real native CLI sessions preserve the source repository Index")
        let evidence: [String: Any] = ["launches": realLaunches, "activeSessions": manager.active.count,
          "taskState": manager.task(realTask.id)?.agent?.state.rawValue ?? "missing", "loginStillAvailable": true]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
          .write(to: output.appendingPathComponent("real-native-result.json"))
      }
      checks.append("Interactive hold ended; physical GUI actions require separate tool evidence")
      } catch {
        // Never let the outer acceptance exit bypass verified cleanup of a real child.
        while !(await manager.stopAllAndWait()) {
          window.title = "GitPier Acceptance — Cleanup Unverified; Session Retained"
          let retry = output.appendingPathComponent("retry-real-cleanup")
          while !FileManager.default.fileExists(atPath: retry.path) {
            await Task.detached { try? await Task.sleep(for: .milliseconds(250)) }.value
          }
          try? FileManager.default.removeItem(at: retry)
        }
        try? JSONSerialization.data(withJSONObject: ["cleanupVerified": true, "activeSessions": manager.active.count])
          .write(to: output.appendingPathComponent("hold-failure-cleanup.json"))
        throw error
      }
    }
    try Data(checks.joined(separator: "\n").utf8).write(to: output.appendingPathComponent("task-workspaces-results.txt"))
  }
}

@MainActor private extension TaskWorkspaceManager {
  func launchDuplicateForAcceptance(_ id: UUID, configuration: AgentLaunchConfiguration, checks: inout [String]) async throws {
    do { try await launch(id, configuration: configuration); throw GitPierError.invalidInput("Duplicate agent launch was allowed") }
    catch TaskWorkspaceError.activeSession { checks.append("Duplicate agent launch is refused") }
  }
}

@MainActor private func taskAcceptancePressButton(_ title: String, host: NSView, window: NSWindow) throws -> Bool {
  var visited = Set<ObjectIdentifier>(), target: NSRect?
  func walk(_ item: Any) {
    guard target == nil, let object = item as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { return }
    func value(_ key: String) -> Any? { object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil }
    if value("accessibilityLabel") as? String == title,
      value("accessibilityEnabled") as? Bool != false, let frame = value("accessibilityFrame") as? NSValue, !frame.rectValue.isEmpty { target = frame.rectValue; return }
    for child in value("accessibilityChildren") as? [Any] ?? [] { walk(child) }
    if let view = object as? NSView { for child in view.subviews { walk(child) } }
  }
  walk(host)
  guard let target else { return false }
  let point = window.convertPoint(fromScreen: NSPoint(x: target.midX, y: target.midY))
  for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
    guard let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
    NSApp.postEvent(event, atStart: false)
  }
  return true
}

@MainActor private extension TerminalSession {
  var resizeCountForAcceptance: Int { view.resizeCount }
}
