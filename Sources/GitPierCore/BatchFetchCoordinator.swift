import Foundation

public struct WorkspaceFetchTarget: Identifiable, Equatable, Sendable {
  public var id: String { commonDirectory + "\0" + remote.name + "\0" + configurationIdentity }
  public let record: RepositoryRecord
  public var repositoryIDs: Set<UUID>
  public let commonDirectory: String
  public let remote: GitRemote
  public let configurationIdentity: String
  public init(record: RepositoryRecord, commonDirectory: String, remote: GitRemote, configurationIdentity: String) {
    self.record = record; self.commonDirectory = commonDirectory; self.remote = remote
    repositoryIDs = [record.id]; self.configurationIdentity = configurationIdentity
  }
  public static func deduplicated(_ targets: [WorkspaceFetchTarget]) -> [WorkspaceFetchTarget] {
    var result: [WorkspaceFetchTarget] = []
    for target in targets {
      if let index = result.firstIndex(where: { $0.id == target.id }) { result[index].repositoryIDs.formUnion(target.repositoryIDs) }
      else { result.append(target) }
    }
    return result
  }
}
public enum WorkspaceFetchState: String, Sendable { case queued, running, succeeded, failed, cancelled }
public struct WorkspaceFetchJob: Identifiable, Sendable {
  public var id: String { target.id }
  public let target: WorkspaceFetchTarget
  public var state: WorkspaceFetchState = .queued
  public var summary = ""
  public var automatic = false
  public var referencesUpdated = false
  public var phase: RemoteCheckPhase = .queued
  public var authenticationFailure: BackgroundAuthenticationState?
  public var authentication: BackgroundAuthentication?
  public var attemptID = UUID()
  public var startedAt = Date()
  public var startedUptime = ProcessInfo.processInfo.systemUptime
  public var completedAt: Date?
  public var active: Bool { state == .queued || state == .running }
  public init(target: WorkspaceFetchTarget, automatic: Bool = false) {
    self.target = target; self.automatic = automatic
  }
}
public struct WorkspaceFetchAcceptance: Sendable {
  public let accepted: Set<String>
  public let rejected: Set<String>
}

public actor BatchFetchCoordinator {
  public typealias Executor = @Sendable (WorkspaceFetchTarget, Bool) async throws -> WorkspaceFetchResult
  private let executor: Executor
  public let concurrency: Int
  private var jobs: [WorkspaceFetchJob] = []
  private var running: [String: Task<Void, Never>] = [:]
  private var subscribers: [UUID: AsyncStream<[WorkspaceFetchJob]>.Continuation] = [:]
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  private var stopped = false
  private var manualSessions = 0
  public init(concurrency: Int = 2, checkedExecutor: @escaping Executor = { target, automatic in
    let git = await GitServiceRegistry.shared.service(for: URL(fileURLWithPath: target.record.path))
    return try await git.checkedWorkspaceFetch(target, automatic: automatic)
  }) { self.concurrency = max(1, min(concurrency, 2)); self.executor = checkedExecutor }
  public init(concurrency: Int = 2, executor: @escaping @Sendable (WorkspaceFetchTarget) async throws -> String) {
    self.concurrency = max(1, min(concurrency, 2))
    self.executor = { target, _ in WorkspaceFetchResult(output: try await executor(target)) }
  }
  /// User operations preempt automatic transport; cancellation waits for process exit before the
  /// manual write enters GitService's existing FIFO. Manual batch work also pauses auto admission.
  public func beginManualOperation() async {
    manualSessions += 1
    let tasks = jobs.filter { $0.automatic && $0.active }.compactMap { running[$0.id] }
    cancel(Set(jobs.filter { $0.automatic && $0.active }.map(\.id)))
    for task in tasks { await task.value }
  }
  public func endManualOperation() { manualSessions = max(0, manualSessions - 1); pump() }
  public func updates() -> AsyncStream<[WorkspaceFetchJob]> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      guard !stopped else { continuation.finish(); return }
      subscribers[id] = continuation; continuation.yield(jobs)
      continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
    }
  }
  private func unsubscribe(_ id: UUID) { subscribers[id] = nil }
  private func publish() { for subscriber in subscribers.values { subscriber.yield(jobs) } }
  public func current() -> [WorkspaceFetchJob] { jobs }
  /// Accept only reviewed targets. Repeated submissions cannot start an active target twice.
  @discardableResult public func submit(_ targets: [WorkspaceFetchTarget], automatic: Bool = false) -> WorkspaceFetchAcceptance {
    let ids = Set(targets.map(\.id))
    guard !stopped, !Task.isCancelled, !automatic || manualSessions == 0 && !jobs.contains(where: { !$0.automatic && $0.active }) else { return WorkspaceFetchAcceptance(accepted: [], rejected: ids) }
    for target in WorkspaceFetchTarget.deduplicated(targets) {
      if let index = jobs.firstIndex(where: { $0.id == target.id }) {
        guard !jobs[index].active else { continue }
        jobs[index] = WorkspaceFetchJob(target: target, automatic: automatic)
      } else { jobs.append(WorkspaceFetchJob(target: target, automatic: automatic)) }
    }
    pump()
    return WorkspaceFetchAcceptance(accepted: ids, rejected: [])
  }
  private func pump() {
    while !stopped && running.count < concurrency, let index = jobs.firstIndex(where: { $0.state == .queued && !$0.automatic }) ?? jobs.firstIndex(where: { $0.state == .queued && (manualSessions == 0 || !$0.automatic) }) {
      let target = jobs[index].target, automatic = jobs[index].automatic
      jobs[index].state = .running; jobs[index].phase = .checking
      running[target.id] = Task(priority: automatic ? .background : .userInitiated) { [executor] in
        let result: Result<WorkspaceFetchResult, Error>
        do { result = .success(try await WorkspaceOperationBudget.shared.perform { try await executor(target, automatic) }) }
        catch { result = .failure(error) }
        self.finish(target.id, result: result)
      }
    }
    publish()
    if running.isEmpty && !jobs.contains(where: \.active) {
      let waiters = idleWaiters; idleWaiters.removeAll(); for waiter in waiters { waiter.resume() }
    }
  }
  private func finish(_ id: String, result: Result<WorkspaceFetchResult, Error>) {
    guard let task = running.removeValue(forKey: id), let index = jobs.firstIndex(where: { $0.id == id }) else { return }
    if task.isCancelled { jobs[index].state = .cancelled; jobs[index].summary = "" }
    else {
      switch result {
      case .success(let value):
        jobs[index].state = .succeeded; jobs[index].summary = ""
        jobs[index].referencesUpdated = value.referencesUpdated
        jobs[index].authentication = value.authentication
        jobs[index].phase = value.referencesUpdated ? .referencesUpdated : .upToDate
      case .failure(let error):
        jobs[index].state = error is CancellationError ? .cancelled : .failed
        jobs[index].phase = RemoteCheckPhase.forFailure(error)
        jobs[index].authenticationFailure = jobs[index].phase == .skipped ? nil : AuthenticationFailure.classify(error)
        if let failure = error as? AuthenticationFailure {
          let target = jobs[index].target
          jobs[index].authentication = BackgroundAuthentication(transport: target.remote.fetchURL.hasPrefix("https://") ? "HTTPS" : "SSH",
            source: failure.source ?? "none", state: failure.state, remote: target.remote.fetchURL)
        }
        jobs[index].summary = error is CancellationError ? "" : String(GitService.redact(error.localizedDescription).prefix(2000))
      }
    }
    jobs[index].completedAt = Date()
    pump()
  }
  public func cancel(_ ids: Set<String>? = nil) {
    for index in jobs.indices where ids == nil || ids!.contains(jobs[index].id) {
      if jobs[index].state == .queued { jobs[index].state = .cancelled }
      running[jobs[index].id]?.cancel()
    }
    pump()
  }
  public func cancelAutomatic() { cancel(Set(jobs.filter(\.automatic).map(\.id))) }
  public func waitUntilIdle() async {
    if !jobs.contains(where: \.active) { return }
    await withCheckedContinuation { idleWaiters.append($0) }
  }
  public func shutdown() { stopped = true; cancel(); for subscriber in subscribers.values { subscriber.finish() }; subscribers.removeAll() }
}
