import AppKit
import GitPierCore
import SwiftUI

struct BlameRequest: Identifiable {
  let id = UUID()
  let path: String
  var revision: String? = nil
}
extension GitBranch {
  var reference: String { (remote ? "refs/remotes/" : "refs/heads/") + name }
}

@MainActor extension AppStore {
  func rememberWorktree(_ ownership: WorktreeOwnership) {
    configuration.ownedWorktrees.removeAll { $0.gitDirectory == ownership.gitDirectory }
    configuration.ownedWorktrees.append(ownership)
    save()
  }
  private func lifecycleKey(_ path: String) -> String {
    let key = URL(fileURLWithPath: path).standardizedFileURL.path
    return key == "/var" || key.hasPrefix("/var/") || key == "/tmp" || key.hasPrefix("/tmp/") ? "/private" + key : key
  }
  func requireWorktreeAvailable(_ path: String, reservation: UUID? = nil) throws {
    if let owner = worktreeLifecycleReservations[lifecycleKey(path)], owner != reservation {
      throw GitPierError.invalidInput(text("This worktree is being removed or repaired. Wait for the operation to finish.", "此工作树正在移除或修复，请等待操作完成。"))
    }
  }
  func admitWorktreeProcess(_ path: String) -> Bool {
    do { try requireWorktreeAvailable(path); return true }
    catch { self.error = error.localizedDescription; return false }
  }
  func reserveWorktreeLifecycle(_ path: String) throws -> UUID {
    try validateWorktreeSessions(path)
    let token = UUID(); worktreeLifecycleReservations[lifecycleKey(path)] = token
    return token
  }
  func releaseWorktreeLifecycle(_ path: String, reservation: UUID) {
    let key = lifecycleKey(path)
    if worktreeLifecycleReservations[key] == reservation { worktreeLifecycleReservations[key] = nil }
  }
  func validateWorktreeSessions(_ path: String, reservation: UUID? = nil) throws {
    try requireWorktreeAvailable(path, reservation: reservation)
    try taskWorkspaces.validateSessions(path)
    for model in models.values where model.record.path == path {
      guard !model.busy, !model.committing, model.record.draft.isEmpty,
        model.conflictEditor.unsavedPaths.isEmpty,
        !model.terminal.sessions.contains(where: { !$0.exited }) else {
        throw GitPierError.invalidInput(text(
          "Close this worktree's terminal sessions and preserve its commit/conflict drafts before removing or repairing it.",
          "移除或修复前，请关闭此工作树的终端会话，并保存其提交与冲突草稿。"))
      }
    }
  }
  func forgetWorktree(_ ownership: WorktreeOwnership) {
    configuration.ownedWorktrees.removeAll { $0 == ownership }
    let ids = repositories.filter { $0.path == ownership.path }.map(\.id)
    for id in ids { remove(id) }
    save()
  }
  func validateWorktreeRepairRecords(previous: String, destination: String) throws {
    if previous != destination, repositories.contains(where: { $0.path == previous }),
      repositories.contains(where: { $0.path == destination }) {
      throw GitPierError.invalidInput(text("Both worktree locations are registered in GitPier. Preserve their drafts and remove the duplicate sidebar record before repair.", "工作树的新旧位置均已在 GitPier 中注册。请保存各自草稿并移除重复的侧栏记录，再进行修复。"))
    }
  }
  func reconcileMovedWorktree(_ ownership: WorktreeOwnership, previousPath: String? = nil) async {
    let owned = configuration.ownedWorktrees.first { $0.gitDirectory == ownership.gitDirectory && $0.creationID != nil && $0.creationID == ownership.creationID }
    guard let oldPath = previousPath ?? owned?.path else { return }
    do { try await taskWorkspaces.relocate(previousPath: oldPath, ownership: ownership) }
    catch { self.error = error.localizedDescription; return }
    for model in models.values where model.record.path == oldPath {
      await model.relocateWorktree(to: ownership.path)
    }
    // Repairing an external tree updates known records without granting deletion ownership.
    if owned != nil { rememberWorktree(ownership) }
  }
  func refreshWorktreeFamily(_ common: String) async {
    for model in models.values where !model.busy {
      if (try? await model.git().commonDirectory().path) == common { await model.refresh() }
    }
  }
}

/// Every query owns a ticket as well as cancellation. A cancelled process can never publish
/// a result into a later selection, even if it finishes while cancellation is propagating.
@MainActor final class WorkflowRequest: ObservableObject {
  private var generation = UUID()
  private var task: Task<Void, Never>?
  @Published private(set) var loading = false
  @Published private(set) var problem: String?
  func start(_ action: @escaping (UUID) async throws -> Void) {
    cancel()
    let ticket = generation
    loading = true; problem = nil
    task = Task {
      do { try await action(ticket) }
      catch { if current(ticket) { problem = localizedUI(GitService.redact(error.localizedDescription)) } }
      if current(ticket) { loading = false; task = nil }
    }
  }
  func current(_ ticket: UUID) -> Bool { ticket == generation && !Task.isCancelled }
  func cancel() { generation = UUID(); task?.cancel(); task = nil; loading = false }
}

/// Confirmed writes outlive a detail view. A refresh or second click must never cancel them.
@MainActor final class WorkflowMutationRequest: ObservableObject {
  @Published private(set) var loading = false
  @Published private(set) var problem: String?
  @Published private(set) var revision: UInt64 = 0
  private let stateChanged: () -> Void
  init(stateChanged: @escaping () -> Void = {}) { self.stateChanged = stateChanged }
  func start(_ action: @escaping () async throws -> Void) {
    guard !loading else { return }
    loading = true; problem = nil
    stateChanged()
    Task {
      defer { loading = false; revision &+= 1; stateChanged() }
      do { try await action() }
      catch { problem = localizedUI(GitService.redact(error.localizedDescription)) }
    }
  }
}

/// Registration commits the creation result. Opening is a separate, retryable read/navigation.
@MainActor final class TaskWorkspaceCreationRequest: ObservableObject {
  @Published private(set) var created: TaskWorkspace?
  @Published private(set) var loading = false
  @Published private(set) var opening = false
  @Published private(set) var problem: String?
  @Published private(set) var navigationProblem: String?
  private var work: Task<Void, Never>?
  func start(create: @escaping () async throws -> TaskWorkspace, open: ((TaskWorkspace) async throws -> Void)?) {
    guard !loading, created == nil else { return }
    loading = true; problem = nil
    work = Task {
      do {
        let value = try await create()
        created = value; loading = false
        if let open, !Task.isCancelled { await navigate(value, open: open) }
      } catch { problem = localizedUI(GitService.redact(error.localizedDescription)); loading = false }
      work = nil
    }
  }
  func retryOpen(_ open: @escaping (TaskWorkspace) async throws -> Void) {
    guard let created, !loading, !opening else { return }
    // Reserve synchronously, before the next click can start another navigation.
    opening = true
    work = Task { await navigate(created, open: open); work = nil }
  }
  private func navigate(_ value: TaskWorkspace, open: (TaskWorkspace) async throws -> Void) async {
    opening = true; navigationProblem = nil
    defer { opening = false }
    do { try Task.checkCancellation(); try await open(value) }
    catch { navigationProblem = localizedUI(GitService.redact(error.localizedDescription)) }
  }
  func cancel() { work?.cancel() }
}

struct WorkflowProblem: View {
  @ObservedObject var request: WorkflowRequest
  @EnvironmentObject var store: AppStore
  var body: some View {
    if let problem = request.problem {
      Text(problem).font(uiFont(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
    } else if request.loading { ProgressView().controlSize(.small).padding(10) }
  }
}

struct WorkflowCommitSheet: View {
  @ObservedObject var model: RepositoryModel
  let commit: CommitRecord
  var path: String? = nil
  @State private var blame: BlameRequest?
  @Environment(\.dismiss) var dismiss
  @EnvironmentObject var store: AppStore
  var body: some View {
    VStack(spacing: 0) {
      CommitDetailView(model: model, commit: commit, initialPath: path, onClose: { dismiss() }, onBlame: { path, hash in blame = BlameRequest(path: path, revision: hash) })
      Divider()
      HStack { Text(commit.hash).textSelection(.enabled); Spacer(); Button(store.text("Done", "完成")) { dismiss() }.keyboardShortcut(.cancelAction) }.padding(12)
    }.frame(minWidth: 780, idealWidth: 1040, minHeight: 440, idealHeight: 620)
      .sheet(item: $blame) { BlameView(model: model, request: $0).environmentObject(store) }
  }
}
