import Foundation
import GitPierCore

/// App-owned observation bridge. Card state survives view changes; repository sessions remain separate.
@MainActor final class WorkspaceModel: ObservableObject {
  @Published private(set) var entries: [UUID: WorkspaceEntry] = [:]
  @Published var selected: Set<UUID> = []
  @Published var filters: Set<WorkspaceFilter> = []
  @Published var showFetchReview = false
  @Published private(set) var preparingFetch = false
  @Published private(set) var fetchTargets: [WorkspaceFetchTarget] = []
  @Published private(set) var fetchReviewErrors: [String] = []
  @Published private(set) var fetchJobs: [WorkspaceFetchJob] = []
  @Published private(set) var lastFetch: [UUID: Date] = [:]
  private let fetch: BatchFetchCoordinator
  private var fetchObservation: Task<Void, Never>?
  private var preparation: Task<Void, Never>?
  private var reviewGeneration = UUID()
  private let status: WorkspaceStatusService
  private var observation: Task<Void, Never>?
  private var startup: Task<Void, Never>?
  private var watchers: [UUID: RepositoryWatcher] = [:]
  private var watcherPaths: [UUID: [String]] = [:]
  private var configurationRevision = 0
  private func nextRevision() -> Int { configurationRevision += 1; return configurationRevision }
  unowned let store: AppStore
  init(store: AppStore) {
    self.store = store
    fetch = BatchFetchCoordinator { [weak store] target in
      guard let store else { throw CancellationError() }
      let model = await MainActor.run { store.models[target.record.id] }
      guard let model, await model.record.path == target.record.path else {
        throw GitPierError.invalidInput("The repository was removed or moved. Review Fetch again.")
      }
      guard await model.configure() else { throw GitPierError.invalidInput(await model.error ?? "Authentication could not be configured.") }
      return try await model.git().workspaceFetch(target)
    }
    status = WorkspaceStatusService { [weak store] record in
      let gitPath = await store?.settings.gitPath ?? "/usr/bin/git"
      let service = await GitServiceRegistry.shared.service(for: URL(fileURLWithPath: record.path), gitPath: gitPath)
      await service.configureExecutable(gitPath)
      return try await service.workspaceSnapshot(record)
    }
  }
  func start() {
    startup = Task { [weak self] in
      guard let self else { return }
      let records = store.repositories
      let revision = nextRevision()
      let stream = await status.updates()
      guard !Task.isCancelled else { return }
      observation = Task { [weak self] in
        for await entries in stream {
          guard !Task.isCancelled, let self else { return }
          self.entries = entries
          self.configureWatchers()
        }
      }
      await status.reconcile(records, revision: revision)
      await status.request(records.map(\.id))
      guard !Task.isCancelled else { return }
      let fetchStream = await fetch.updates()
      guard !Task.isCancelled else { return }
      fetchObservation = Task { [weak self] in
        for await jobs in fetchStream {
          guard !Task.isCancelled, let self else { return }
          let previous = Dictionary(uniqueKeysWithValues: self.fetchJobs.map { ($0.id, $0.state) })
          let wasFetching = self.fetching
          self.fetchJobs = jobs
          if wasFetching != self.fetching { self.store.objectWillChange.send() }
          for job in jobs where !job.active && previous[job.id] != job.state {
            let ids = self.entries.values.filter { $0.snapshot?.commonDirectory == job.target.commonDirectory }.map { $0.record.id }
            if job.state == .succeeded { for id in ids { self.lastFetch[id] = Date() } }
            await self.refresh(ids)
            guard !Task.isCancelled else { return }
            if let current = self.store.current, ids.contains(current.record.id), !current.busy { await current.refresh() }
          }
        }
      }
    }
  }
  func sync() {
    let records = store.repositories
    let revision = nextRevision()
    let newIDs = records.filter { entries[$0.id] == nil || entries[$0.id]?.record.path != $0.path }.map(\.id)
    let ids = Set(records.map(\.id)); selected.formIntersection(ids)
    lastFetch = lastFetch.filter { ids.contains($0.key) }
    let cancelled = Set(fetchJobs.filter { !ids.contains($0.target.record.id) }.map(\.id))
    if !cancelled.isEmpty { Task { await fetch.cancel(cancelled) } }
    for id in Array(watchers.keys) where !ids.contains(id) { watchers.removeValue(forKey: id)?.stop(); watcherPaths[id] = nil }
    Task { await status.reconcile(records, revision: revision); await status.request(newIDs) }
  }
  func refresh(_ ids: [UUID]? = nil, force: Bool = true) async {
    let records = store.repositories
    let revision = nextRevision()
    let requested = ids ?? records.filter {
      store.dashboardOrganization == nil || $0.group == store.dashboardOrganization
    }.map(\.id)
    await status.reconcile(records, revision: revision)
    await status.request(requested, priority: .userInitiated, force: force)
  }
  func visible(_ id: UUID) { Task { await status.request([id], priority: .visible) } }
  func invalidate(_ id: UUID, collect: Bool) {
    let common = entries[id]?.snapshot?.commonDirectory
    let ids = entries.values.filter { $0.record.id == id || common != nil && $0.snapshot?.commonDirectory == common }.map { $0.record.id }
    Task {
      await status.invalidate(ids.isEmpty ? [id] : ids)
      if collect { await status.request(ids.isEmpty ? [id] : ids, priority: .visible, force: true) }
    }
  }
  func configureWatchers() {
    guard store.settings.automaticRefresh else {
      for watcher in watchers.values { watcher.stop() }; watchers.removeAll(); return
    }
    for entry in entries.values {
      guard let snapshot = entry.usable else { continue }
      let id = entry.record.id
      let paths = [snapshot.path, snapshot.gitDirectory, snapshot.commonDirectory]
      if watchers[id] != nil && watcherPaths[id] == paths { continue }
      watchers[id]?.stop(); watcherPaths[id] = paths
      watchers[id] = RepositoryWatcher(paths: paths.map { URL(fileURLWithPath: $0) }) {
        [weak self] in
        Task { @MainActor [weak self] in
          guard let self, self.store.settings.automaticRefresh else { return }
          // Preserve the existing opt-in notification semantics: stale, not an automatic full refresh.
          self.invalidate(id, collect: false)
        }
      }
    }
  }
  func shutdown() {
    startup?.cancel(); observation?.cancel(); preparation?.cancel(); fetchObservation?.cancel()
    for watcher in watchers.values { watcher.stop() }; watchers.removeAll()
    Task { await status.shutdown(); await fetch.shutdown() }
  }
  var fetching: Bool { fetchJobs.contains(where: \.active) }
  func prepareFetch(_ ids: Set<UUID>? = nil) {
    preparation?.cancel(); reviewGeneration = UUID()
    let generation = reviewGeneration
    let records = store.repositories.filter { (ids ?? selected).contains($0.id) }
    fetchTargets = []; fetchReviewErrors = []; preparingFetch = true; showFetchReview = true
    preparation = Task { [weak self] in
      guard let self else { return }
      var targets: [WorkspaceFetchTarget] = []
      var errors: [String] = []
      // A rolling task group, rather than one task per configured repository.
      await withTaskGroup(of: (Int, [WorkspaceFetchTarget], String?).self) { group in
        var next = 0
        func enqueue(_ index: Int) {
          let record = records[index]
          group.addTask { [weak self] in
            guard let self else { return (index, [], nil) }
            return await self.readFetchTarget(record, index: index)
          }
        }
        for _ in 0..<min(3, records.count) { enqueue(next); next += 1 }
        var results: [(Int, [WorkspaceFetchTarget], String?)] = []
        while let result = await group.next() {
          results.append(result)
          if next < records.count, !Task.isCancelled { enqueue(next); next += 1 }
        }
        for result in results.sorted(by: { $0.0 < $1.0 }) { targets += result.1; if let error = result.2 { errors.append(error) } }
      }
      guard !Task.isCancelled, generation == reviewGeneration else { return }
      fetchTargets = WorkspaceFetchTarget.deduplicated(targets); fetchReviewErrors = errors; preparingFetch = false
    }
  }
  private func readFetchTarget(_ record: RepositoryRecord, index: Int) async -> (Int, [WorkspaceFetchTarget], String?) {
    guard !Task.isCancelled, let model = store.models[record.id], !model.busy else {
      return (index, [], record.name + ": " + store.text("Repository busy or unavailable.", "仓库正忙或不可用。"))
    }
    do {
      guard await model.configure() else { throw GitPierError.invalidInput(model.error ?? "Authentication could not be configured.") }
      let git = await model.git()
      let values = try await WorkspaceOperationBudget.shared.perform { try await git.reviewWorkspaceFetch(record) }
      return (index, values, values.isEmpty ? record.name + ": " + store.text("No remotes", "无远程") : nil)
    } catch { return (index, [], record.name + ": " + GitService.redact(error.localizedDescription)) }
  }
  func startReviewedFetch() {
    guard !preparingFetch, !fetchTargets.isEmpty else { return }
    let targets = fetchTargets; showFetchReview = false
    Task { await fetch.submit(targets) }
  }
  func cancelFetchReview() { preparation?.cancel(); reviewGeneration = UUID(); preparingFetch = false; showFetchReview = false }
  func cancelFetch() { Task { await fetch.cancel() } }
}

extension WorkspaceModel {
  func retryFailedFetch() { prepareFetch(Set(fetchJobs.filter { $0.state == .failed }.flatMap { $0.target.repositoryIDs })) }
}
