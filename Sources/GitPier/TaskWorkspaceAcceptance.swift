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
    let task = try await git.createTaskWorkspace(name: "Build task workspace", savedDescription: "Private fixture description", repositoryID: primary.record.id,
      destination: directory.appendingPathComponent("task-one"), branch: "task/one")
    try await manager.register(task)
    try require(manager.tasks.count == 1 && manager.ready, "Task created and registered without starting an agent")
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
    if [ "$1" = --help ]; then printf '%s\n' '--no-daemon --sandbox workspace-write --ask-for-approval on-request'; exit 0; fi
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
      try await manager.setWaitingForInput(task.id, waiting: true, beforePersist: {
        annotationEntered = true
        await withCheckedContinuation { releaseAnnotation = $0 }
      })
    }
    try await waitFor { annotationEntered }
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
    if [ "$1" = --help ]; then printf '%s\n' '--no-daemon --sandbox workspace-write --ask-for-approval on-request'; exit 0; fi
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
      var settings = store.settings; settings.language = .english; settings.appearance = .light; settings.codexExecutablePath = program.path; store.updateSettings(settings)
      host.rootView = AnyView(TaskWorkspacesView(model: model, manager: manager).environmentObject(store).modifier(AppAppearance(store: store)).environment(\.locale, Locale(identifier: "en_US")))
      window.setContentSize(NSSize(width: 960, height: 640)); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
      try await settle()
      try Data("Ready for native task create/launch/cancel/scroll acceptance. Local fixture executable only.\n".utf8).write(to: output.appendingPathComponent("ready-gui"))
      while !FileManager.default.fileExists(atPath: output.appendingPathComponent("finish-gui").path) {
        try await Task.sleep(for: .milliseconds(250))
      }
      guard await manager.stopAllAndWait() else { throw TaskWorkspaceError.activeSession }
      checks.append("Interactive hold ended; physical GUI actions require separate tool evidence")
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

@MainActor private extension TerminalSession {
  var resizeCountForAcceptance: Int { view.resizeCount }
}
