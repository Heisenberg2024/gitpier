import AppKit
import Combine
import GitPierCore

struct TaskWorktreeRemovalRoute: Equatable {
  let taskID: UUID
  let sourcePath: String
}

/// Owns metadata and observes real PTYs. Git execution stays in GitService; no second Git queue.
@MainActor final class TaskWorkspaceManager: ObservableObject {
  unowned let store: AppStore
  let persistence: TaskWorkspaceStore
  @Published private(set) var tasks: [TaskWorkspace] = []
  @Published private(set) var problem: String?
  @Published private(set) var ready = false
  @Published private(set) var busy: Set<UUID> = []
  @Published private(set) var creatingCount = 0
  @Published private(set) var summaries: [UUID: RepositoryStatus] = [:]
  @Published private(set) var observationProblems: [UUID: String] = [:]
  @Published private(set) var reviewCurrent: Set<UUID> = []
  @Published var selectedID: UUID?
  private var sessions: [UUID: TerminalSession] = [:]
  private var operations: [UUID: UUID] = [:]
  private var restoring: Task<Void, Never>?
  private var exitTasks: [UUID: Task<Void, Never>] = [:]
  private var mutationWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
  private func finishMutation(_ id: UUID) {
    busy.remove(id)
    for waiter in mutationWaiters.removeValue(forKey: id) ?? [] { waiter.resume() }
  }
  private func waitForMutation(_ id: UUID) async {
    while busy.contains(id) { await withCheckedContinuation { mutationWaiters[id, default: []].append($0) } }
  }
  init(store: AppStore) {
    self.store = store
    persistence = TaskWorkspaceStore(root: store.persistence.url.deletingPathExtension().appendingPathExtension("tasks"))
  }
  var active: [TaskWorkspace] { tasks.filter { sessions[$0.id]?.exited == false || $0.agent?.state.active == true } }
  func isActive(path: String) -> Bool { active.contains { $0.path == path } }
  func task(_ id: UUID) -> TaskWorkspace? { tasks.first { $0.id == id } }
  func restore() async {
    if let restoring { await restoring.value; return }
    guard !ready else { return }
    let work = Task { @MainActor in
      do { tasks = try await persistence.recover(); problem = nil; ready = true }
      catch { problem = error.localizedDescription }
    }
    restoring = work; await work.value; restoring = nil
  }
  func save(_ task: TaskWorkspace, replacing previous: TaskWorkspace?) async throws {
    guard ready, problem == nil else { throw TaskWorkspaceError.corrupt }
    try await persistence.save(task, replacing: previous)
    tasks.removeAll { $0.id == task.id }; tasks.append(task); tasks.sort { $0.createdAt > $1.createdAt }
  }
  func register(_ task: TaskWorkspace) async throws {
    try store.requireWorktreeAvailable(task.path)
    if task.binding.managed { store.rememberWorktree(task.binding.ownership) }
    try await save(task, replacing: nil)
    selectedID = task.id
  }
  func create(repositoryID: UUID, action: () async throws -> TaskWorkspace) async throws -> TaskWorkspace {
    guard ready, problem == nil else { throw TaskWorkspaceError.corrupt }
    creatingCount += 1; store.objectWillChange.send()
    let operation = UUID()
    store.operations.begin(id: operation, kind: .createTask, repositoryID: repositoryID, state: .running)
    defer { creatingCount -= 1; store.objectWillChange.send() }
    do {
      let task = try await action()
      try await register(task)
      store.operations.linkTask(operation, taskID: task.id); store.operations.update(operation, state: .succeeded)
      return task
    } catch {
      store.operations.update(operation, state: error is CancellationError ? .cancelled : .failed)
      throw error
    }
  }
  func archive(_ id: UUID, archived: Bool) async throws {
    guard let old = task(id), !busy.contains(id), !isActive(path: old.path) else { throw TaskWorkspaceError.activeSession }
    try store.requireWorktreeAvailable(old.path)
    busy.insert(id); defer { finishMutation(id) }
    var updated = old; try updated.setArchived(archived)
    try await save(updated, replacing: old)
    event(.archiveTask, task: updated)
  }
  func git(_ task: TaskWorkspace) async -> GitService {
    await GitServiceRegistry.shared.service(for: URL(fileURLWithPath: task.path), gitPath: store.settings.gitPath)
  }
  func snapshot(_ id: UUID) async throws -> TaskWorkspaceSnapshot {
    guard let task = task(id) else { throw TaskWorkspaceError.changed }
    let snapshot = try await git(task).taskWorkspaceSnapshot(task)
    guard self.task(id) == task else { throw TaskWorkspaceError.changed }
    summaries[id] = snapshot.status; observationProblems[id] = nil
    if let review = task.review {
      let current = try? await git(task).taskWorkspaceReview(task)
      guard self.task(id) == task else { throw TaskWorkspaceError.changed }
      if current?.fingerprint == review.fingerprint { reviewCurrent.insert(id) } else { reviewCurrent.remove(id) }
    }
    return snapshot
  }
  func observe(_ id: UUID) async {
    guard let task = task(id) else { return }
    do {
      let service = await git(task)
      let state = try await WorkspaceOperationBudget.shared.perform { try await service.taskWorkspaceSummary(task) }
      guard self.task(id) == task, !Task.isCancelled else { return }
      summaries[id] = state; observationProblems[id] = nil
      if let review = task.review {
        let current = try? await service.taskWorkspaceReview(task)
        guard self.task(id) == task, !Task.isCancelled else { return }
        if current?.fingerprint == review.fingerprint { reviewCurrent.insert(id) } else { reviewCurrent.remove(id) }
      }
    } catch {
      guard self.task(id) == task, !Task.isCancelled else { return }
      summaries[id] = nil; observationProblems[id] = error.localizedDescription
      reviewCurrent.remove(id)
    }
  }
  func displayStatus(_ task: TaskWorkspace) -> TaskWorkspaceStatus {
    if task.archived { return .archived }
    if task.agent?.state.active == true { return .running }
    if observationProblems[task.id] != nil { return .unavailable }
    if let state = summaries[task.id] {
      if state.operation != nil || state.files.contains(where: \.isConflicted) { return .needsAttention }
      if task.status == .reviewed, reviewCurrent.contains(task.id) { return .reviewed }
      if !state.files.isEmpty || state.head != task.baseCommit { return .changesAvailable }
    }
    return task.status == .reviewed ? .ready : task.status
  }
  func markReviewed(_ id: UUID) async throws {
    guard let previous = task(id), !previous.archived, !isActive(path: previous.path), !busy.contains(id) else { throw TaskWorkspaceError.activeSession }
    try store.requireWorktreeAvailable(previous.path)
    busy.insert(id); defer { finishMutation(id) }
    let receipt = try await git(previous).taskWorkspaceReview(previous)
    guard task(id) == previous else { throw TaskWorkspaceError.changed }
    var updated = previous; updated.review = receipt; updated.status = .reviewed; updated.updatedAt = max(Date(), previous.updatedAt)
    try await save(updated, replacing: previous); reviewCurrent.insert(id)
    event(.reviewTask, task: updated)
  }
  func relocate(previousPath: String, ownership: WorktreeOwnership) async throws {
    for previous in tasks.filter({ $0.path == previousPath }) {
      guard !busy.contains(previous.id), !isActive(path: previousPath) else { throw TaskWorkspaceError.activeSession }
      let service = await GitServiceRegistry.shared.service(for: URL(fileURLWithPath: ownership.path), gitPath: store.settings.gitPath)
      let updated = try await service.relocateTaskWorkspace(previous, ownership: ownership)
      try await save(updated, replacing: previous)
      summaries[previous.id] = nil; observationProblems[previous.id] = nil
    }
  }
  func open(_ id: UUID, page: String = "worktrees", terminal: Bool = false) async throws -> RepositoryModel {
    guard let task = task(id), !task.archived else { throw TaskWorkspaceError.unavailable }
    try store.requireWorktreeAvailable(task.path)
    _ = try await git(task).validateTaskWorkspace(task)
    guard self.task(id) == task else { throw TaskWorkspaceError.changed }
    await store.addRepository(URL(fileURLWithPath: task.path))
    guard let model = store.current, model.record.path == task.path else { throw TaskWorkspaceError.changed }
    selectedID = id; model.setPage(page)
    if terminal {
      try store.requireWorktreeAvailable(task.path)
      var layout = model.panels.layout; layout.terminalVisible = true; model.editLayout(layout)
      var settings = store.settings; settings.terminalDirectory = "repository"
      if let session = sessions[id] { model.terminal.selectedID = session.id }
      else { model.terminal.add(settings: settings) }
    }
    return model
  }
  func review(_ id: UUID, baseline: Bool) async throws {
    let snapshot = try await snapshot(id)
    guard let task = task(id) else { throw TaskWorkspaceError.changed }
    let model = try await open(id, page: baseline ? "compare" : "commit")
    if baseline {
      var targets: [String: BranchComparisonTarget] = [task.baseCommit: .commit(task.baseCommit)]
      targets[snapshot.head] = .commit(snapshot.head)
      model.workflowComparison = WorkflowComparisonRequest(left: task.baseCommit, right: snapshot.head,
        leftTitle: store.text("Task baseline", "任务基准"), rightTitle: store.text("Current HEAD", "当前 HEAD"), mode: .tips,
        targets: targets)
    }
    event(.reviewTask, task: task)
  }
  func launch(_ id: UUID, configuration: AgentLaunchConfiguration) async throws {
    guard let old = task(id), !old.archived, !busy.contains(id), !isActive(path: old.path), configuration.taskID == id else { throw TaskWorkspaceError.activeSession }
    try store.requireWorktreeAvailable(old.path)
    busy.insert(id); defer { finishMutation(id) }
    let selection = store.selectedID
    let current = try await snapshot(id)
    guard current.head == configuration.head, current.status == configuration.status, old.branch == configuration.branch,
      old.path == configuration.directory, current.status.operation == nil else { throw TaskWorkspaceError.changed }
    try configuration.executable.validate()
    let model: RepositoryModel
    if let existing = store.models.values.first(where: { $0.record.path == old.path }) { model = existing }
    else {
      let record = RepositoryRecord(path: old.path)
      model = RepositoryModel(record: record, store: store)
      store.configuration.repositories.append(record); store.models[record.id] = model; store.save()
    }
    var updated = old
    updated.agent = TaskAgentSession(taskID: id, executablePath: configuration.executable.path, executableVersion: configuration.executable.version)
    updated.status = .running; updated.updatedAt = max(Date(), old.updatedAt)
    updated.agent?.state = .launching
    try await save(updated, replacing: old)
    // Recheck immediately before the synchronous PTY spawn, after all disk/model awaits.
    do {
      var admitted = updated; admitted.agent?.state = .running
      try await save(admitted, replacing: updated); updated = admitted
      let service = await git(updated)
      let checked = try await service.validateTaskWorkspace(updated)
      let launchStatus = try await service.status(localOnly: true)
      guard checked.head == configuration.head, self.task(id) == updated, store.selectedID == selection,
        launchStatus == configuration.status, launchStatus.operation == nil, !Task.isCancelled else { throw TaskWorkspaceError.changed }
      try updated.binding.validateDirectories()
      try configuration.executable.validate()
      try store.requireWorktreeAvailable(old.path)
    } catch {
      let launchError = error
      var interrupted = updated; interrupted.agent?.state = .interrupted; interrupted.agent?.endedAt = Date(); interrupted.status = .interrupted
      do { try await save(interrupted, replacing: updated) }
      catch {
        // No child was spawned. Preserve the disk record for recovery, disable changes,
        // and do not strand an unstarted in-memory session behind a nonfunctional Stop.
        problem = error.localizedDescription
        if let index = tasks.firstIndex(where: { $0.id == id }) { tasks[index] = interrupted }
      }
      throw launchError
    }
    let sessionID = updated.agent!.id
    let operation = UUID(); operations[id] = operation
    store.operations.begin(id: operation, kind: .agentSession, repositoryID: old.repositoryID, state: .running,
      identity: OperationRepositoryIdentity(workingTree: old.path, commonDirectory: old.commonDirectory), cancel: { [weak self] in self?.stop(id) })
    store.operations.linkTask(operation, taskID: id)
    let session = model.terminal.addAgent(configuration, settings: store.settings) { [weak self] code, stopped in
      guard let self else { return }
      self.exitTasks[id] = Task { @MainActor in await self.exited(id, sessionID: sessionID, code: code, stopped: stopped); self.exitTasks[id] = nil }
    }
    sessions[id] = session
    var layout = model.panels.layout; layout.terminalVisible = true; model.editLayout(layout)
    selectedID = id; store.selectedID = model.record.id; store.showDashboard = false; model.setPage("worktrees"); store.save()
    Task { await model.activate(refresh: true) }
  }
  func stop(_ id: UUID) { sessions[id]?.close() }
  /// Explicit user annotation; terminal output is never parsed as an agent protocol.
  func setWaitingForInput(_ id: UUID, waiting: Bool, beforePersist: (() async -> Void)? = nil) async throws {
    guard let old = task(id), let session = sessions[id], !session.exited, !session.stopping,
      old.agent?.state.active == true, !busy.contains(id) else { throw TaskWorkspaceError.activeSession }
    busy.insert(id); defer { finishMutation(id) }
    var updated = old; updated.agent?.state = waiting ? .waitingForInput : .running
    updated.updatedAt = max(Date(), old.updatedAt)
    // The native acceptance harness can suspend this mutation to exercise a real PTY exit.
    if let beforePersist { await beforePersist() }
    try await save(updated, replacing: old)
  }
  func stopAllAndWait() async -> Bool {
    let current = sessions
    for session in current.values { session.close() }
    var stopped = true
    for (id, session) in current {
      if !(await session.stopAgentAndWait()) { stopped = false }
      if let work = exitTasks[id] { await work.value }
    }
    if !stopped { store.error = store.text("Agent process cleanup could not be verified. GitPier remains open; inspect the task terminal.", "无法核验 Agent 进程清理。GitPier 将保持打开，请检查任务终端。") }
    return stopped
  }
  private func exited(_ id: UUID, sessionID: UUID, code: Int32?, stopped: Bool) async {
    await waitForMutation(id)
    guard let old = task(id), old.agent?.id == sessionID else { return }
    busy.insert(id); defer { finishMutation(id) }
    sessions[id] = nil
    var updated = old
    updated.agent?.state = stopped ? .interrupted : code == 0 ? .exited : .failed
    updated.agent?.exitCode = code; updated.agent?.endedAt = max(Date(), old.agent!.startedAt)
    updated.updatedAt = max(Date(), old.updatedAt); updated.status = stopped ? .interrupted : code == 0 ? .agentExited : .needsAttention
    // Exit zero describes process exit only; no test or task-success claim is made.
    do {
      try await save(updated, replacing: old)
      if let snapshot = try? await snapshot(id), !updated.archived, self.task(id) == updated {
        var observed = updated
        if snapshot.status.files.contains(where: \.isConflicted) || snapshot.status.operation != nil { observed.status = .needsAttention }
        else if snapshot.hasChanges { observed.status = .changesAvailable }
        if observed != updated { try await save(observed, replacing: updated) }
      }
    } catch { problem = error.localizedDescription }
    if let operation = operations.removeValue(forKey: id) {
      store.operations.update(operation, state: stopped ? .cancelled : code == 0 ? .agentExited : .failed)
    }
  }
  func event(_ kind: WorkflowOperationKind, task: TaskWorkspace) {
    let operation = UUID()
    store.operations.begin(id: operation, kind: kind, repositoryID: task.repositoryID, state: .running,
      identity: OperationRepositoryIdentity(workingTree: task.path, commonDirectory: task.commonDirectory))
    store.operations.linkTask(operation, taskID: task.id)
    store.operations.update(operation, state: .succeeded)
  }
  func validateSessions(_ path: String) throws {
    guard ready, problem == nil else { throw TaskWorkspaceError.inUse }
    guard !isActive(path: path), !tasks.contains(where: { $0.path == path && busy.contains($0.id) }) else { throw TaskWorkspaceError.activeSession }
  }
  func validateRemoval(_ path: String) throws {
    try validateSessions(path)
    for task in tasks where task.path == path {
      guard task.binding.managed else { throw TaskWorkspaceError.changed }
      try task.binding.validateDirectories()
    }
  }
  func removalTasks(_ path: String) throws -> [TaskWorkspace] {
    try validateRemoval(path)
    return tasks.filter { $0.path == path }.sorted { $0.id.uuidString < $1.id.uuidString }
  }
  func requestRemoval(_ id: UUID) async throws {
    guard let task = task(id), task.binding.managed,
      store.configuration.ownedWorktrees.contains(task.binding.ownership) else { throw TaskWorkspaceError.changed }
    try validateRemoval(task.path)
    let family = try await git(task).worktrees(includeStatus: false)
    let candidates = family.filter { $0.path != task.path && !$0.bare && !$0.missing }
    guard let source = candidates.first(where: { $0.path == task.repositoryRoot }) ?? candidates.first(where: \.main) ?? candidates.first else { throw TaskWorkspaceError.unavailable }
    await store.addRepository(URL(fileURLWithPath: source.path))
    guard let model = store.current, model.record.path == source.path, self.task(id) == task,
      try await model.git().commonDirectory().path == task.commonDirectory, store.current === model else { throw TaskWorkspaceError.changed }
    try validateRemoval(task.path)
    selectedID = nil; store.taskRemovalRequest = TaskWorktreeRemovalRoute(taskID: id, sourcePath: source.path); model.setPage("worktrees")
  }
  func worktreeRemoved(_ path: String) async {
    for previous in tasks.filter({ $0.path == path }) {
      var updated = previous
      if !updated.archived { updated.status = .unavailable }
      updated.updatedAt = max(Date(), previous.updatedAt)
      do { try await save(updated, replacing: previous) } catch { problem = error.localizedDescription }
      summaries[previous.id] = nil; observationProblems[previous.id] = TaskWorkspaceError.unavailable.localizedDescription
    }
  }
  func confirmQuit() -> Bool {
    guard !active.isEmpty else { return true }
    let alert = NSAlert()
    alert.messageText = store.text("Stop agents and close GitPier?", "停止 Agent 并关闭 GitPier？")
    alert.informativeText = store.text("Running Codex sessions and attached processes will be stopped. Worktree files remain; a new session requires confirmation. Detached processes may require manual inspection.", "将停止运行中的 Codex 会话及关联进程。工作树文件会保留；新会话需要再次确认。脱离会话的进程可能需要手动检查。") + "\n\n" + active.map(\.name).joined(separator: "\n")
    alert.addButton(withTitle: store.text("Stop and Close", "停止并关闭")); alert.addButton(withTitle: store.text("Cancel", "取消"))
    alert.buttons[0].keyEquivalent = ""; alert.buttons[1].keyEquivalent = "\r"
    return alert.runModal() == .alertFirstButtonReturn
  }
}
