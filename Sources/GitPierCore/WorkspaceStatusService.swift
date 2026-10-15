import Foundation

/// Three workers by default; each loader executes Git commands sequentially. Requests are
/// coalesced by stable ID. Cancellation keeps its worker slot until the process has exited.
public actor WorkspaceStatusService {
  public typealias Loader = @Sendable (RepositoryRecord) async throws -> WorkspaceSnapshot
  public enum Priority: Int, Sendable { case background, visible, userInitiated }
  private struct Request {
    let record: RepositoryRecord
    let generation: UUID
    var priority: Priority
    let order: Int
  }
  private struct Running { let generation: UUID; let task: Task<Void, Never> }
  private let loader: Loader
  public let concurrency: Int
  private let lifetime: TimeInterval
  private var entries: [UUID: WorkspaceEntry] = [:]
  private var generations: [UUID: UUID] = [:]
  private var pending: [UUID: Request] = [:]
  private var running: [UUID: Running] = [:]
  private var sequence = 0
  private var stopped = false
  private var configurationRevision = -1
  private var subscribers: [UUID: AsyncStream<[UUID: WorkspaceEntry]>.Continuation] = [:]
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  public init(concurrency: Int = 3, lifetime: TimeInterval = 30, loader: @escaping Loader = { record in
    let git = await GitServiceRegistry.shared.service(for: URL(fileURLWithPath: record.path))
    return try await git.workspaceSnapshot(record)
  }) {
    self.concurrency = max(1, min(concurrency, 8)); self.lifetime = lifetime; self.loader = loader
  }
  public func updates() -> AsyncStream<[UUID: WorkspaceEntry]> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      guard !stopped else { continuation.finish(); return }
      subscribers[id] = continuation
      continuation.yield(entries)
      continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
    }
  }
  private func unsubscribe(_ id: UUID) { subscribers[id] = nil }
  private func publish() { for subscriber in subscribers.values { subscriber.yield(entries) } }
  public func current() -> [UUID: WorkspaceEntry] { entries }
  public func reconcile(_ records: [RepositoryRecord], revision: Int? = nil) {
    if let revision {
      guard revision >= configurationRevision else { return }
      configurationRevision = revision
    }
    let ids = Set(records.map(\.id))
    for id in Array(entries.keys) where !ids.contains(id) {
      running[id]?.task.cancel(); pending[id] = nil; entries[id] = nil; generations[id] = nil
    }
    for record in records {
      if let old = entries[record.id], old.record.path != record.path {
        invalidate([record.id]); entries[record.id] = WorkspaceEntry(record: record)
      } else if entries[record.id] != nil {
        entries[record.id]?.record = record
      } else { entries[record.id] = WorkspaceEntry(record: record) }
    }
    publish(); pump()
  }
  public func request(_ ids: [UUID], priority: Priority = .background, force: Bool = false) {
    guard !stopped else { return }
    if force { invalidate(ids) }
    for id in ids {
      guard let entry = entries[id] else { continue }
      if var request = pending[id] {
        if priority.rawValue > request.priority.rawValue { request.priority = priority; pending[id] = request }
        continue
      }
      if let active = running[id], active.generation == generations[id] { continue }
      if entry.failure != nil, let date = entry.lastAttempt, Date().timeIntervalSince(date) < lifetime, !force { continue }
      if entry.state == .fresh, let date = entry.snapshot?.collectedAt,
         Date().timeIntervalSince(date) < lifetime { continue }
      sequence += 1
      let generation = UUID(); generations[id] = generation
      pending[id] = Request(record: entry.record, generation: generation, priority: priority, order: sequence)
      entries[id]?.state = .queued
    }
    publish(); pump()
  }
  public func invalidate(_ ids: [UUID]) {
    for id in ids where entries[id] != nil {
      generations[id] = UUID(); running[id]?.task.cancel(); pending[id] = nil
      let state: WorkspaceCollectionState = entries[id]?.snapshot == nil ? .unscanned : .stale
      entries[id]?.state = state
    }
    publish()
  }
  private func pump() {
    while !stopped && running.count < concurrency {
      let next = pending.values.filter { running[$0.record.id] == nil }.sorted {
        $0.priority == $1.priority ? $0.order < $1.order : $0.priority.rawValue > $1.priority.rawValue
      }.first
      guard let next else { break }
      let id = next.record.id; pending[id] = nil; entries[id]?.state = .collecting
      let task = Task { [loader] in
        let result: Result<WorkspaceSnapshot, Error>
        do {
          try Task.checkCancellation()
          result = .success(try await WorkspaceOperationBudget.shared.perform { try await loader(next.record) })
        }
        catch { result = .failure(error) }
        self.finish(id, generation: next.generation, result: result)
      }
      running[id] = Running(generation: next.generation, task: task)
    }
    publish()
    if running.isEmpty && pending.isEmpty {
      let waiters = idleWaiters; idleWaiters.removeAll(); for waiter in waiters { waiter.resume() }
    }
  }
  private func finish(_ id: UUID, generation: UUID, result: Result<WorkspaceSnapshot, Error>) {
    guard running[id]?.generation == generation else { return }
    running[id] = nil
    if !stopped, generations[id] == generation, entries[id] != nil {
      entries[id]?.lastAttempt = Date()
      switch result {
      case .success(let value):
        guard value.repositoryID == id, value.path == entries[id]?.record.path else {
          entries[id]?.failure = WorkspaceFailure(.gitQuery, "The snapshot repository identity changed.")
          entries[id]?.state = .failed; pump(); return
        }
        entries[id]?.snapshot = value; entries[id]?.failure = nil; entries[id]?.state = .fresh
      case .failure(let error):
        if error is CancellationError {
          let state: WorkspaceCollectionState = entries[id]?.snapshot == nil ? .unscanned : .stale
          entries[id]?.state = state
        } else {
          entries[id]?.failure = error as? WorkspaceFailure ?? WorkspaceFailure(.gitQuery, error.localizedDescription)
          entries[id]?.state = .failed
        }
      }
    }
    pump()
  }
  public func waitUntilIdle() async {
    if running.isEmpty && pending.isEmpty { return }
    await withCheckedContinuation { idleWaiters.append($0) }
  }
  public func shutdown() {
    stopped = true; pending.removeAll()
    for value in running.values { value.task.cancel() }
    for id in Array(entries.keys) {
      let state: WorkspaceCollectionState = entries[id]?.snapshot == nil ? .unscanned : .stale
      entries[id]?.state = state
    }
    publish(); for subscriber in subscribers.values { subscriber.finish() }; subscribers.removeAll()
    pump()
  }
}
