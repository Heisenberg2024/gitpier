import Foundation

public struct WorkspaceFetchTarget: Identifiable, Sendable {
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
  public var active: Bool { state == .queued || state == .running }
}

public actor BatchFetchCoordinator {
  public typealias Executor = @Sendable (WorkspaceFetchTarget) async throws -> String
  private let executor: Executor
  public let concurrency: Int
  private var jobs: [WorkspaceFetchJob] = []
  private var running: [String: Task<Void, Never>] = [:]
  private var subscribers: [UUID: AsyncStream<[WorkspaceFetchJob]>.Continuation] = [:]
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  private var stopped = false
  public init(concurrency: Int = 2, executor: @escaping Executor = { target in
    let git = await GitServiceRegistry.shared.service(for: URL(fileURLWithPath: target.record.path))
    return try await git.workspaceFetch(target)
  }) { self.concurrency = max(1, min(concurrency, 3)); self.executor = executor }
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
  public func submit(_ targets: [WorkspaceFetchTarget]) {
    guard !stopped else { return }
    for target in WorkspaceFetchTarget.deduplicated(targets) {
      if let index = jobs.firstIndex(where: { $0.id == target.id }) {
        guard !jobs[index].active else { continue }
        jobs[index] = WorkspaceFetchJob(target: target)
      } else { jobs.append(WorkspaceFetchJob(target: target)) }
    }
    pump()
  }
  private func pump() {
    while !stopped && running.count < concurrency, let index = jobs.firstIndex(where: { $0.state == .queued }) {
      let target = jobs[index].target; jobs[index].state = .running
      running[target.id] = Task { [executor] in
        let result: Result<String, Error>
        do { result = .success(try await WorkspaceOperationBudget.shared.perform { try await executor(target) }) }
        catch { result = .failure(error) }
        self.finish(target.id, result: result)
      }
    }
    publish()
    if running.isEmpty && !jobs.contains(where: \.active) {
      let waiters = idleWaiters; idleWaiters.removeAll(); for waiter in waiters { waiter.resume() }
    }
  }
  private func finish(_ id: String, result: Result<String, Error>) {
    guard let task = running.removeValue(forKey: id), let index = jobs.firstIndex(where: { $0.id == id }) else { return }
    if task.isCancelled { jobs[index].state = .cancelled; jobs[index].summary = "" }
    else {
      switch result {
      case .success: jobs[index].state = .succeeded; jobs[index].summary = ""
      case .failure(let error):
        jobs[index].state = error is CancellationError ? .cancelled : .failed
        jobs[index].summary = error is CancellationError ? "" : String(GitService.redact(error.localizedDescription).prefix(2000))
      }
    }
    pump()
  }
  public func cancel(_ ids: Set<String>? = nil) {
    for index in jobs.indices where ids == nil || ids!.contains(jobs[index].id) {
      if jobs[index].state == .queued { jobs[index].state = .cancelled }
      running[jobs[index].id]?.cancel()
    }
    pump()
  }
  public func waitUntilIdle() async {
    if !jobs.contains(where: \.active) { return }
    await withCheckedContinuation { idleWaiters.append($0) }
  }
  public func shutdown() { stopped = true; cancel(); for subscriber in subscribers.values { subscriber.finish() }; subscribers.removeAll() }
}
