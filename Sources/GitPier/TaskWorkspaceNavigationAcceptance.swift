import AppKit
import GitPierCore
import SwiftUI

@MainActor extension UIAcceptance {
  static func verifyTaskNavigationBoundaries(store: AppStore, primary: RepositoryModel,
    task: TaskWorkspace, other: TaskWorkspace, output: URL) async throws -> [String] {
    let manager = store.taskWorkspaces, navigation = WorkflowRequest()
    let originalTerminals = Set(store.models.values.flatMap { $0.terminal.sessions.map(\.id) })
    defer {
      for model in store.models.values {
        for session in model.terminal.sessions where !originalTerminals.contains(session.id) { model.terminal.close(session.id) }
      }
    }
    var checks: [String] = []
    func require(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
      guard try value() else { throw GitPierError.invalidInput("Task navigation: " + label) }
      checks.append(label)
      try Data(checks.joined(separator: "\n").utf8).write(to: output.appendingPathComponent("task-navigation-results.txt"))
    }
    func terminals() -> Set<UUID> { Set(store.models.values.flatMap { $0.terminal.sessions.map(\.id) }) }
    func openOperation() -> WorkflowOperationRecord? { store.operations.records.first { $0.kind == .openTask } }
    let persisted = try await manager.persistence.records()
    // The real validation/snapshot completes before a continuation releases navigation.
    // Switching away and back also changes identity, even though paths and IDs match.
    for scenario in ["task", "repository", "task-return", "repository-return", "page-return", "dashboard-return", "cancel", "compare", "working-tree", "removal-review"] {
      store.select(primary.record.id); manager.selectedID = task.id; primary.setPage("history")
      let gate = TaskInteractionGate(), finished = TaskInteractionGate(), previousTerminals = terminals()
      navigation.startTaskNavigation(task.id, manager: manager) { isCurrent in
        defer { finished.resume() }
        if scenario == "compare" || scenario == "working-tree" { _ = try await manager.snapshot(task.id) }
        else { _ = try await manager.git(task).validateTaskWorkspace(task) }
        await gate.wait()
        do {
          if scenario == "compare" || scenario == "working-tree" {
            try await manager.review(task.id, baseline: scenario == "compare", isCurrent: isCurrent)
          } else if scenario == "removal-review" { try await manager.requestRemoval(task.id, isCurrent: isCurrent) }
          else { _ = try await manager.open(task.id, terminal: true, isCurrent: isCurrent) }
        } catch {
          // Signal actual action completion even when the request was cancelled.
          await finished.wait(); throw error
        }
        await finished.wait()
      }
      await gate.waitUntilEntered()
      switch scenario {
      case "task", "compare", "working-tree", "removal-review": manager.selectedID = other.id
      case "repository": store.select(store.models.values.first { $0.record.path == other.path }!.record.id)
      case "task-return": manager.selectedID = other.id; manager.selectedID = task.id
      case "repository-return": store.select(store.models.values.first { $0.record.path == other.path }!.record.id); store.select(primary.record.id)
      case "page-return": primary.setPage("worktrees"); primary.setPage("history")
      case "dashboard-return": store.showDashboard = true; store.showDashboard = false
      default: navigation.cancel()
      }
      let selection = store.selectedID, page = store.current?.page, comparison = store.current?.workflowComparison
      let removal = store.taskRemovalRequest
      let operationIDs = Set(store.operations.records.map(\.id))
      gate.resume(); await finished.waitUntilEntered(); finished.resume()
      try await waitFor { !navigation.loading }
      let late = store.models.values.flatMap { $0.terminal.sessions }.filter { !previousTerminals.contains($0.id) }
      for session in late { session.close() }
      let operations = store.operations.records.filter { !operationIDs.contains($0.id) }
      try require(store.selectedID == selection && store.current?.page == page
        && store.current?.workflowComparison?.id == comparison?.id && store.taskRemovalRequest == removal && late.isEmpty
        && operations.allSatisfy { $0.state == .failed || $0.state == .cancelled }
        && (scenario != "cancel" || openOperation()?.state == .cancelled),
        "Superseded " + scenario + " navigation preserves selection, page, comparison and terminal count")
    }
    let afterRejected = try await manager.persistence.records()
    try require(afterRejected == persisted, "Rejected navigation preserves exact task records on disk")
    let previousError = store.error, previousSelection = store.selectedID
    store.error = "Current selection error"
    let selectedMissing = await store.addRepository(URL(fileURLWithPath: task.path + "/missing-navigation-target"), ifCurrent: { false })
    try require(!selectedMissing && store.selectedID == previousSelection && store.error == "Current selection error",
      "A superseded repository validation failure cannot overwrite the current selection's error")
    store.error = previousError

    store.select(primary.record.id); manager.selectedID = task.id
    let duplicateGate = TaskInteractionGate(), previousTerminals = terminals()
    var calls = 0, oldNavigationFinished = false
    navigation.startTaskNavigation(task.id, manager: manager) { isCurrent in
      defer { oldNavigationFinished = true }
      calls += 1; await duplicateGate.wait()
      _ = try await manager.open(task.id, terminal: true, isCurrent: isCurrent)
    }
    await duplicateGate.waitUntilEntered()
    navigation.startTaskNavigation(task.id, manager: manager) { isCurrent in
      calls += 1; _ = try await manager.open(task.id, terminal: true, isCurrent: isCurrent)
    }
    try await waitFor { !navigation.loading }
    guard let target = store.current, target.record.path == task.path else { throw TaskWorkspaceError.changed }
    let successfulOpen = openOperation()?.id
    duplicateGate.resume(); try await waitFor { oldNavigationFinished }
    try require(calls == 2 && store.current === target && terminals().subtracting(previousTerminals).count == 1
      && store.operations.records.first { $0.id == successfulOpen }?.state == .succeeded && openOperation()?.state == .cancelled,
      "The latest repeated detail navigation wins while its cancelled predecessor creates no terminal")
    let openedTerminals = terminals(), terminalID = target.terminal.selectedID
    navigation.startTaskNavigation(task.id, manager: manager) { _ = try await manager.open(task.id, terminal: true, isCurrent: $0) }
    try await waitFor { !navigation.loading }
    try require(terminals() == openedTerminals && target.terminal.selectedID == terminalID && openOperation()?.state == .succeeded,
      "Opening an already-current task reuses its live terminal")

    store.select(primary.record.id); manager.selectedID = task.id
    let olderGate = TaskInteractionGate()
    var olderFinished = false
    navigation.startTaskNavigation(task.id, manager: manager) { isCurrent in
      defer { olderFinished = true }; await olderGate.wait()
      _ = try await manager.open(task.id, page: "commit", isCurrent: isCurrent)
    }
    await olderGate.waitUntilEntered()
    navigation.startTaskNavigation(task.id, manager: manager) { try await manager.review(task.id, baseline: true, isCurrent: $0) }
    try await waitFor { !navigation.loading }
    let latestComparison = target.workflowComparison?.id
    olderGate.resume(); try await waitFor { olderFinished }
    try require(store.current === target && target.page == "compare" && latestComparison != nil
      && target.workflowComparison?.id == latestComparison && terminals() == openedTerminals,
      "A newer comparison request wins over an older open request from the same task and selection")
    target.workflowComparison = nil

    // At addRepository's final guard, a real validation has already suspended.
    store.select(primary.record.id); manager.selectedID = task.id
    var validations = 0
    navigation.startTaskNavigation(task.id, manager: manager) { isCurrent in
      _ = try await manager.open(task.id, terminal: true, isCurrent: {
        validations += 1
        if validations == 3 { store.select(primary.record.id) }
        return isCurrent()
      })
    }
    try await waitFor { !navigation.loading }
    try require(validations == 3 && store.current === primary && terminals() == openedTerminals && openOperation()?.state == .failed,
      "The final repository-selection guard rejects a new selection of the same source repository")

    manager.selectedID = other.id
    let lease = try store.reserveWorktreeLifecycle(other.path)
    navigation.startTaskNavigation(other.id, manager: manager) { _ = try await manager.open(other.id, isCurrent: $0) }
    try await waitFor { !navigation.loading }; store.releaseWorktreeLifecycle(other.path, reservation: lease)
    try require(navigation.problem != nil && store.current === primary && openOperation()?.state == .failed,
      "A genuine opening failure remains visible with a failed operation")
    navigation.startTaskNavigation(other.id, manager: manager) { _ = try await manager.open(other.id, isCurrent: $0) }
    try await waitFor { !navigation.loading }
    try require(navigation.problem == nil && store.current?.record.path == other.path && openOperation()?.state == .succeeded,
      "Explicit retry clears the opening error and selects the saved task")

    store.select(primary.record.id); manager.selectedID = task.id
    let observer = store.$selectedID.sink { if $0 == target.record.id { navigation.cancel() } }
    navigation.startTaskNavigation(task.id, manager: manager) { _ = try await manager.open(task.id, terminal: true, isCurrent: $0) }
    try await waitFor { store.current === target && openOperation()?.state == .succeeded }; observer.cancel()
    try require(terminals() == openedTerminals && navigation.problem == nil && target.page == "worktrees",
      "Cancellation from committed selection preserves success, destination and existing terminal")

    store.select(primary.record.id); manager.selectedID = task.id
    let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 640, height: 460),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: AnyView(TaskWorkspaceDetail(taskID: task.id, manager: manager, navigation: navigation)
      .environmentObject(store).modifier(AppAppearance(store: store))))
    window.contentView = host; window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    try await settle()
    let teardown = TaskInteractionGate()
    navigation.startTaskNavigation(task.id, manager: manager) { isCurrent in
      _ = try await manager.open(task.id, page: "compare", isCurrent: isCurrent)
      await teardown.wait()
    }
    await teardown.waitUntilEntered()
    host.rootView = AnyView(Color.clear)
    try await waitFor { !navigation.loading }
    try require(store.current === target && target.page == "compare" && openOperation()?.state == .succeeded,
      "Real SwiftUI detail disappearance after selection cancels only its owner and preserves committed success")
    teardown.resume()

    // Operations Center intentionally uses an independent navigation, without a detail lease.
    store.select(primary.record.id); manager.selectedID = other.id
    let independent = try await manager.open(task.id, terminal: true)
    try require(independent === target && manager.selectedID == task.id && terminals() == openedTerminals
      && openOperation()?.state == .succeeded, "Operations Center independent navigation opens its requested task and records success")
    store.select(primary.record.id); manager.selectedID = other.id
    let center = OperationsCenter(), centerRecord = UUID()
    center.begin(id: centerRecord, kind: .agentSession, repositoryID: primary.record.id)
    center.linkTask(centerRecord, taskID: task.id); center.update(centerRecord, state: .agentExited)
    host.rootView = AnyView(OperationsCenterView(center: center).environmentObject(store).modifier(AppAppearance(store: store)))
    try await settle()
    try require(try taskAcceptancePressButton("Open Task", host: host, window: window),
      "The native Operations Center task entry is actionable from another selected task")
    try await waitFor { store.current === target && openOperation()?.state == .succeeded }
    try require(manager.selectedID == task.id && terminals() == openedTerminals,
      "Operations Center dismissal preserves its independent navigation and reuses the task terminal")
    try await manager.review(task.id, baseline: true)
    try require(target.page == "compare" && target.workflowComparison?.left == task.baseCommit
      && store.operations.records.first { $0.kind == .reviewTask }?.state == .succeeded,
      "Independent baseline review commits its exact comparison and operation")
    target.workflowComparison = nil
    store.select(primary.record.id); manager.selectedID = task.id
    return checks
  }

}
