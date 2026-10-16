import Foundation
import AppKit
import Network
import GitPierCore

/// App-owned observation bridge. Card state survives view changes; repository sessions remain separate.
@MainActor final class WorkspaceModel: ObservableObject {
  @Published private(set) var entries: [UUID: WorkspaceEntry] = [:]
  @Published var selected: Set<UUID> = []
  @Published var filters: Set<WorkspaceFilter> = []
  @Published var showFetchReview = false
  @Published private(set) var preparingFetch = false
  @Published private(set) var submittingFetch = false
  @Published private(set) var fetchTargets: [WorkspaceFetchTarget] = []
  @Published private(set) var fetchReviewErrors: [String] = []
  @Published private(set) var fetchJobs: [WorkspaceFetchJob] = []
  @Published private(set) var remoteChecks: [String: RemoteCheckRecord] = [:]
  @Published private(set) var authentication: [String: BackgroundAuthentication] = [:]
  @Published private(set) var authenticationBusy: Set<String> = []
  private var authenticationGeneration: [String: UUID] = [:]
  private var authenticationTasks: [String: Task<Void, Never>] = [:]
  @Published private(set) var remoteMetadataError: String?
  @Published private(set) var fetchTrayExpanded = true
  private var allFetchJobs: [WorkspaceFetchJob] = []
  private var processedAttempts: [String: UUID] = [:]
  private var attemptOrder = RemoteCheckAttemptOrder()
  private var observedActiveAttempts: [String: UUID] = [:]
  private var manualFetchAttempts: [String: WorkspaceFetchJob] = [:]
  private let remotePersistence: RemoteCheckStore
  private var canSaveRemoteMetadata = true
  private var schedule = RemoteCheckSchedule()
  private var scheduler: Task<Void, Never>?
  private var evaluationRequest: Task<Void, Never>?
  private var trayCollapse: Task<Void, Never>?
  private var evaluating = false
  private var stopped = false
  private var quiescingAutomatic = false
  private var networkAvailable = false
  private let networkMonitor = NWPathMonitor()
  private var lifecycleObservers: [NSObjectProtocol] = []
  private var nextWorkspaceAdmission: TimeInterval = 0
  private var recordCursor = 0
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
    remotePersistence = RemoteCheckStore(url: store.persistence.url.deletingPathExtension().appendingPathExtension("remote-checks.json"))
    do { remoteChecks = try remotePersistence.load() }
    catch { canSaveRemoteMetadata = false; remoteMetadataError = store.text("Remote check history could not be read. Original file preserved; automatic checks are paused.", "无法读取远程检查记录，原文件已保留；自动检查已暂停。") }
    fetch = BatchFetchCoordinator(checkedExecutor: { [weak store] target, automatic in
      guard let store else { throw CancellationError() }
      let model = await MainActor.run { store.models[target.record.id] }
      guard let model, await model.record.path == target.record.path else {
        throw GitPierError.invalidInput("The repository was removed or moved. Review Fetch again.")
      }
      if automatic {
        let allowed = await MainActor.run {
          RemoteCheckPolicy.mayEvaluate(store.settings, active: NSApp.isActive,
            online: store.workspace.networkAvailable, writing: store.models.values.contains { $0.busy || $0.committing })
            && !store.workspace.stopped && !store.workspace.quiescingAutomatic && store.workspace.canSaveRemoteMetadata
            && RemoteCheckPolicy.includes(target.record.id, current: store.selectedID, settings: store.settings)
        }
        guard allowed else { throw AutomaticFetchError.skipped("Automatic check deferred.") }
      }
      guard await model.configure(reportErrors: !automatic) else {
        if automatic { throw AuthenticationFailure(.configurationInvalid) }
        throw GitPierError.invalidInput(await model.error ?? "Authentication could not be configured.")
      }
      return try await model.git().checkedWorkspaceFetch(target, automatic: automatic)
    })
    status = WorkspaceStatusService { [weak store] record in
      let gitPath = await store?.settings.gitPath ?? "/usr/bin/git"
      let service = await GitServiceRegistry.shared.service(for: URL(fileURLWithPath: record.path), gitPath: gitPath)
      if let model = await store?.models[record.id] { _ = await model.configure(reportErrors: false) }
      else { await service.configureExecutable(gitPath) }
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
          for entry in entries.values {
            if let snapshot = entry.usable { self.store.models[entry.record.id]?.applyRemoteSnapshot(snapshot) }
          }
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
          self.allFetchJobs = jobs
          self.fetchJobs = jobs.filter { !$0.automatic }
          self.store.objectWillChange.send()
          for job in jobs { await self.observeFetch(job) }

        }
      }
    }
    startRemoteScheduler()
  }
  func sync() {
    guard !stopped else { return }
    let records = store.repositories
    let revision = nextRevision()
    let newIDs = records.filter { entries[$0.id] == nil || entries[$0.id]?.record.path != $0.path }.map(\.id)
    let ids = Set(records.map(\.id)); selected.formIntersection(ids)
    let retained = remoteChecks.mapValues { record in
      var record = record; record.repositoryIDs.formIntersection(ids); return record
    }.filter { !$0.value.repositoryIDs.isEmpty }
    if retained != remoteChecks { remoteChecks = retained; persistRemoteChecks() }
    let cancelled = Set(allFetchJobs.filter { !ids.contains($0.target.record.id) }.map(\.id))
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
    stopped = true
    for task in authenticationTasks.values { task.cancel() }
    scheduler?.cancel(); evaluationRequest?.cancel(); trayCollapse?.cancel(); networkMonitor.cancel()
    for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
    lifecycleObservers.removeAll()
    startup?.cancel(); observation?.cancel(); preparation?.cancel(); fetchObservation?.cancel()
    for watcher in watchers.values { watcher.stop() }; watchers.removeAll()
    Task { await status.shutdown(); await fetch.shutdown() }
  }
  var fetching: Bool { allFetchJobs.contains(where: \.active) }
  var automaticallyFetching: Bool { allFetchJobs.contains { $0.automatic && $0.active } }
  var manuallyFetching: Bool { fetchJobs.contains(where: \.active) }
  func prepareFetch(_ ids: Set<UUID>? = nil) {
    guard !submittingFetch, !stopped else { return }
    preparation?.cancel(); reviewGeneration = UUID()
    let generation = reviewGeneration
    let records = store.repositories.filter { (ids ?? selected).contains($0.id) }
    fetchTargets = []; fetchReviewErrors = []; preparingFetch = true; showFetchReview = true
    preparation = Task { [weak self] in
      guard let self else { return }
      await fetch.beginManualOperation()
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
      await fetch.endManualOperation()
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
    guard !preparingFetch, !submittingFetch, !fetchTargets.isEmpty else { return }
    let targets = fetchTargets, selection = selected, generation = reviewGeneration
    submittingFetch = true
    Task {
      await fetch.beginManualOperation()
      guard generation == reviewGeneration, !Task.isCancelled, !stopped else {
        await fetch.endManualOperation(); submittingFetch = false; return
      }
      let receipt = await fetch.submit(targets)
      await fetch.endManualOperation()
      submittingFetch = false
      let acceptedIDs = Set(targets.filter { receipt.accepted.contains($0.id) }.flatMap(\.repositoryIDs))
      selected.subtract(acceptedIDs.intersection(selection))
      if receipt.rejected.isEmpty { showFetchReview = false }
      else { fetchReviewErrors.append(store.text("Some targets were not accepted. Your selection is preserved.", "部分目标未被队列接受，已保留对应选择。")) }
    }
  }
  func cancelFetchReview() { preparation?.cancel(); reviewGeneration = UUID(); preparingFetch = false; showFetchReview = false }
  func cancelFetch() { Task { await fetch.cancel(Set(fetchJobs.map(\.id))) } }
}

extension WorkspaceModel {
  func retryFailedFetch() { prepareFetch(Set(fetchJobs.filter { $0.state == .failed }.flatMap { $0.target.repositoryIDs })) }
}

extension WorkspaceModel {
  func authenticationInfo(_ id: UUID) -> BackgroundAuthentication? {
    guard let target = entries[id]?.snapshot?.remoteTarget else { return nil }
    let key = RemoteCheckStore.key(target)
    if var info = authentication[key] {
      if let failure = remoteChecks[key]?.authenticationFailure { info.state = failure }
      return info
    }
    guard let failure = remoteChecks[key]?.authenticationFailure else { return nil }
    return BackgroundAuthentication(transport: target.remote.fetchURL.hasPrefix("https://") ? "HTTPS" : "SSH",
      source: target.remote.fetchURL.hasPrefix("https://") ? "none" : "sshAgent", state: failure, remote: target.remote.fetchURL)
  }
  func authenticationIsBusy(_ id: UUID) -> Bool {
    guard let target = entries[id]?.snapshot?.remoteTarget else { return false }
    return authenticationBusy.contains(RemoteCheckStore.key(target)) || allFetchJobs.contains { $0.id == target.id && $0.active }
  }
  /// Explicit user action only. Never poll Keychain or SSH on a timer or selection change.
  func retryAuthentication(_ id: UUID, authorize: Bool = false, prepareSSH: Bool = false) {
    guard let target = entries[id]?.snapshot?.remoteTarget, let model = store.models[id],
      !model.busy, !stopped, !authenticationIsBusy(id) else { return }
    let key = RemoteCheckStore.key(target)
    guard authenticationBusy.insert(key).inserted else { return }
    let generation = UUID(); authenticationGeneration[key] = generation
    let task = Task {
      await fetch.beginManualOperation()
      defer { authenticationBusy.remove(key); authenticationTasks[key] = nil }
      do {
        guard await model.configure(reportErrors: false) else { throw AuthenticationFailure(.configurationInvalid) }
        let git = await model.git()
        let info: BackgroundAuthentication
        if prepareSSH { info = try await git.prepareSSHAuthentication(target) }
        else { info = try await git.backgroundAuthentication(target, authorize: authorize) }
        guard !stopped, store.models[id] === model,
          authenticationGeneration[key] == generation,
          entries[id]?.snapshot?.remoteTarget?.id == target.id else { throw CancellationError() }
        authentication[key] = info
        resetAuthenticationBlock(key)
      } catch {
        if !(error is CancellationError), authenticationGeneration[key] == generation {
          let state = AuthenticationFailure.classify(error)
          let transport = target.remote.fetchURL.hasPrefix("https://") ? "HTTPS" : "SSH"
          authentication[key] = BackgroundAuthentication(transport: transport,
            source: (error as? AuthenticationFailure)?.source ?? (transport == "SSH" ? "sshAgent" : "none"), state: state,
            remote: target.remote.fetchURL)
          var value = remoteChecks[key] ?? RemoteCheckRecord()
          value.repositoryIDs.formUnion(target.repositoryIDs)
          value.phase = AuthenticationFailure(state).blocksAutomaticRetry ? .authenticationRequired : .failed
          value.authenticationFailure = state
          value.lastAttempt = Date()
          if value.phase == .authenticationRequired { value.nextEligible = nil }
          else {
            value.failures += 1
            let delay = RemoteCheckPolicy.backoff(value.failures)
            value.nextEligible = Date().addingTimeInterval(delay)
            schedule.attempted(key, delay: delay, uptime: ProcessInfo.processInfo.systemUptime)
          }
          remoteChecks[key] = value; persistRemoteChecks()
        }
        await fetch.endManualOperation()
        return
      }
      await fetch.endManualOperation()
      await evaluateRemoteChecks(only: id)
    }
    authenticationTasks[key] = task
  }
  private func resetAuthenticationBlock(_ key: String) {
    var value = remoteChecks[key] ?? RemoteCheckRecord()
    let uptime = ProcessInfo.processInfo.systemUptime
    // Reject retained jobs and completions from before this explicit recovery event.
    _ = attemptOrder.accepts(target: key, attempt: UUID(), startedUptime: uptime)
    schedule.retry(key, record: &value, now: Date(), uptime: uptime)
    remoteChecks[key] = value; persistRemoteChecks()
  }
  func credentialsChanged(_ ids: Set<UUID>) {
    let targets = entries.values.filter { ids.contains($0.record.id) }.compactMap { $0.snapshot?.remoteTarget }
    for target in targets {
      let key = RemoteCheckStore.key(target)
      authentication[key] = nil
      authenticationGeneration[key] = UUID()
      authenticationTasks[key]?.cancel()
      resetAuthenticationBlock(key)
    }
    Task {
      await fetch.cancel(Set(targets.map(\.id)))
      await refresh(Array(ids))
      requestRemoteEvaluation()
    }
  }
  func remoteCheck(_ id: UUID) -> RemoteCheckRecord {
    guard let target = entries[id]?.snapshot?.remoteTarget else { return RemoteCheckRecord() }
    return remoteChecks[RemoteCheckStore.key(target)] ?? RemoteCheckRecord()
  }
  func remoteInterval(_ id: UUID) -> TimeInterval {
    RemoteCheckPolicy.interval(store.settings, current: store.selectedID == id)
  }
  private func persistRemoteChecks() {
    guard canSaveRemoteMetadata else { return }
    do { try remotePersistence.save(remoteChecks); remoteMetadataError = nil }
    catch { remoteMetadataError = store.text("Remote check history could not be saved.", "无法保存远程检查记录。") }
  }
  private func startRemoteScheduler() {
    networkMonitor.pathUpdateHandler = { [weak self] path in
      let available = path.status == .satisfied
      Task { @MainActor [weak self] in self?.networkAvailable = available }
    }
    networkMonitor.start(queue: DispatchQueue(label: "GitPier.remote-network", qos: .background))
    for name in [NSApplication.didResignActiveNotification, NSApplication.willTerminateNotification] {
      lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in
          // A delayed resign-active notification must not cancel a check admitted after reactivation.
          guard name == NSApplication.willTerminateNotification || !NSApp.isActive else { return }
          await self?.fetch.cancelAutomatic()
        }
      })
    }
    scheduler = Task(priority: .background) { [weak self] in
      try? await Task.sleep(for: .seconds(5))
      while !Task.isCancelled {
        guard let self, !self.stopped else { return }
        await self.evaluateRemoteChecks()
        try? await Task.sleep(for: .seconds(15))
      }
    }
  }
  /// UI lifecycle events ask for an evaluation; they never fetch unconditionally.
  func requestRemoteEvaluation() {
    guard evaluationRequest == nil else { return }
    evaluationRequest = Task(priority: .background) { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      self?.evaluationRequest = nil
      await self?.evaluateRemoteChecks()
    }
  }
  func remoteSettingsChanged() {
    if !store.settings.automaticFetch {
      Task {
        guard !store.settings.automaticFetch else { return }
        await fetch.cancelAutomatic()
      }
    }
    requestRemoteEvaluation()
  }
  func evaluateRemoteChecks(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime, only: UUID? = nil) async {
    guard !stopped, canSaveRemoteMetadata, !quiescingAutomatic, !evaluating,
      RemoteCheckPolicy.mayEvaluate(store.settings, active: NSApp.isActive, online: networkAvailable, writing: store.hasRunningGitOperations) else { return }
    evaluating = true
    defer { evaluating = false }
    let records = store.repositories.filter { only == nil || $0.id == only }
    guard !records.isEmpty else { return }
    var candidates: [RepositoryRecord] = []
    if let current = store.selectedID.flatMap({ id in records.first { $0.id == id } }) { candidates.append(current) }
    if store.settings.remoteCheckScope == "workspace", uptime >= nextWorkspaceAdmission {
      // Rotate a bounded batch so opening a large workspace never creates N network tasks.
      for offset in 0..<min(4, records.count) {
        let record = records[(recordCursor + offset) % records.count]
        if !candidates.contains(where: { $0.id == record.id }) { candidates.append(record) }
      }
      recordCursor = (recordCursor + min(4, records.count)) % records.count
    }
    var targets: [WorkspaceFetchTarget] = []
    for record in candidates {
      guard RemoteCheckPolicy.includes(record.id, current: store.selectedID, settings: store.settings),
        let entry = entries[record.id], entry.state == .fresh, let snapshot = entry.usable, snapshot.operation == nil,
        snapshot.conflicts == 0, let target = snapshot.remoteTarget else { continue }
      let key = RemoteCheckStore.key(target), value = remoteChecks[key] ?? RemoteCheckRecord()
      let interval = remoteInterval(record.id)
      guard schedule.eligible(key, record: value, interval: interval, now: now, uptime: uptime) else { continue }
      targets.append(target)
      if WorkspaceFetchTarget.deduplicated(targets).count == 2 { break }
    }
    guard !targets.isEmpty, store.settings.automaticFetch, NSApp.isActive, !stopped else { return }
    let receipt = await fetch.submit(WorkspaceFetchTarget.deduplicated(targets), automatic: true)
    for target in targets where receipt.accepted.contains(target.id) {
      schedule.attempted(RemoteCheckStore.key(target), delay: remoteInterval(target.record.id), uptime: uptime)
    }
    if !receipt.accepted.isEmpty { nextWorkspaceAdmission = uptime + 30 }
  }
  private func observeFetch(_ job: WorkspaceFetchJob) async {
    let liveIDs = Set(store.repositories.map(\.id))
    let key = RemoteCheckStore.key(job.target)
    guard attemptOrder.accepts(target: key, attempt: job.attemptID, startedUptime: job.startedUptime) else { return }
    if let info = job.authentication { authentication[key] = info }
    let related = entries.values.filter { liveIDs.contains($0.record.id) && $0.snapshot?.remoteTarget?.id == job.target.id }.map { $0.record.id }
    let members = job.target.repositoryIDs.union(related).intersection(liveIDs)
    guard !members.isEmpty else {
      if remoteChecks.removeValue(forKey: key) != nil { persistRemoteChecks() }
      return
    }
    var value = remoteChecks[key] ?? RemoteCheckRecord()
    value.repositoryIDs.formUnion(members); value.repositoryIDs.formIntersection(liveIDs)
    if job.active {
      value.phase = job.state == .queued ? .queued : .checking
      if observedActiveAttempts[key] != job.attemptID {
        observedActiveAttempts[key] = job.attemptID
        value.lastAttempt = job.startedAt
        value.nextEligible = job.startedAt.addingTimeInterval(remoteInterval(job.target.record.id))
        remoteChecks[key] = value
        persistRemoteChecks()
      } else { remoteChecks[key] = value }
      return
    }
    guard processedAttempts[key] != job.attemptID else { return }
    processedAttempts[key] = job.attemptID
    let now = job.completedAt ?? Date()
    value.lastAttempt = job.startedAt
    let delay: TimeInterval
    if job.state == .succeeded {
      value.phase = job.phase; value.lastSuccess = now; value.failures = 0; value.diagnostic = nil
      value.authenticationFailure = nil
      delay = remoteInterval(job.target.record.id)
    } else if job.state == .cancelled {
      value.phase = .skipped; value.diagnostic = store.text("Check cancelled or deferred.", "检查已取消或延后。")
      delay = 60
    } else {
      value.phase = job.phase; value.diagnostic = String(GitService.redact(job.summary).prefix(500))
      value.authenticationFailure = job.authenticationFailure
      if job.phase == .skipped { delay = 60 }
      else { value.failures += 1; delay = RemoteCheckPolicy.backoff(value.failures) }
    }
    let interval = remoteInterval(job.target.record.id)
    let remaining = value.lastSuccess.map { min(interval, max(0, interval - now.timeIntervalSince($0))) } ?? 0
    let effectiveDelay = max(delay, remaining)
    value.nextEligible = value.phase == .authenticationRequired ? nil : now.addingTimeInterval(effectiveDelay)
    remoteChecks[key] = value
    schedule.attempted(key, delay: effectiveDelay, uptime: ProcessInfo.processInfo.systemUptime)
    persistRemoteChecks()
    if job.state != .cancelled || job.phase == .checking {
      // A cancelled running Fetch can already have committed tracking refs (or a hook may
      // still have been finishing). Queued cancellations need no Git refresh.
      // Refresh local counts only; the observation bridge patches tracking counts into open
      // sessions without rebuilding Diff, history, Worktree views or editor drafts.
      let ids = entries.values.filter { $0.snapshot?.commonDirectory == job.target.commonDirectory }.map { $0.record.id }
      await refresh(ids)
    }
    if !job.automatic, !manuallyFetching {
      fetchTrayExpanded = true; trayCollapse?.cancel()
      if !fetchJobs.contains(where: { $0.state == .failed }) {
        trayCollapse = Task { [weak self] in
          try? await Task.sleep(for: .seconds(5))
          guard !Task.isCancelled else { return }; self?.fetchTrayExpanded = false
        }
      }
    }
  }
  func stopAutomaticChecks() async {
    quiescingAutomatic = true
    await fetch.cancelAutomatic()
    await fetch.waitUntilIdle()
    let jobs = await fetch.current()
    allFetchJobs = jobs
    for job in jobs where job.automatic && !job.active { await observeFetch(job) }
    quiescingAutomatic = false
  }
  func revealFetchTray() { fetchTrayExpanded = true }
  func beginManualOperation() async { await fetch.beginManualOperation() }
  func endManualOperation() async { await fetch.endManualOperation() }
  func recordManualFetchStarted(_ targets: [WorkspaceFetchTarget]) async {
    for target in targets {
      var job = WorkspaceFetchJob(target: target); job.state = .running; job.phase = .checking
      manualFetchAttempts[target.id] = job
      await observeFetch(job)
    }
  }
  func recordManualFetch(_ targets: [WorkspaceFetchTarget], updated: Set<String> = [], error: Error? = nil) async {
    for target in targets {
      var job = manualFetchAttempts.removeValue(forKey: target.id) ?? WorkspaceFetchJob(target: target)
      job.state = error == nil ? .succeeded : error is CancellationError ? .cancelled : .failed
      job.phase = error.map(RemoteCheckPhase.forFailure) ?? (updated.contains(target.id) ? .referencesUpdated : .upToDate)
      job.summary = error.map { GitService.redact($0.localizedDescription) } ?? ""
      job.completedAt = Date()
      await observeFetch(job)
    }
  }
}
