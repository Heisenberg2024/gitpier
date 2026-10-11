import AppKit
import GitPierCore
import SwiftUI
import UserNotifications

@MainActor final class AppStore: ObservableObject {
  static let shared = AppStore(
    persistence: ConfigurationStore(
      url: ProcessInfo.processInfo.environment["GITPIER_WORKSPACE_FILE"].map {
        URL(fileURLWithPath: $0)
      }))
  @Published var configuration: WorkspaceConfiguration
  @Published var selectedID: UUID?
  @Published var showDashboard = true
  @Published var error: String?
  @Published var notice: String?
  let cloneActivity = OperationProgress()
  @Published var cloning = false
  @Published var cloneTask: Task<Void, Never>?
  @Published var showClone = false
  @Published var showCredentials = false
  @Published var showOrganizations = false
  @Published var dashboardOrganization: String?
  @Published private(set) var systemColorScheme: ColorScheme = .light
  private var pendingSave: Task<Void, Never>?
  nonisolated(unsafe) private var appearanceObserver: NSObjectProtocol?
  nonisolated(unsafe) private var foregroundObserver: NSObjectProtocol?
  @Published var models: [UUID: RepositoryModel] = [:]
  let persistence: ConfigurationStore
  private var canSave = true
  var managedWindows: Set<ObjectIdentifier> = []
  var settings: AppSettings { configuration.settings }
  var repositories: [RepositoryRecord] { configuration.repositories }
  var current: RepositoryModel? { selectedID.flatMap { models[$0] } }
  var colorScheme: ColorScheme? {
    settings.appearance == .system ? nil : settings.appearance == .dark ? .dark : .light
  }
  var resolvedColorScheme: ColorScheme { colorScheme ?? systemColorScheme }
  init(persistence: ConfigurationStore = ConfigurationStore()) {
    self.persistence = persistence
    do { configuration = try persistence.load() } catch {
      configuration = WorkspaceConfiguration()
      canSave = false
      self.error =
        "Configuration could not be read. The original file has been preserved.\n"
        + error.localizedDescription
    }
    if !FileManager.default.fileExists(atPath: persistence.url.path),
      let nerdFont = NSFontManager.shared.availableFonts.sorted().first(where: {
        $0.localizedCaseInsensitiveContains("Nerd")
          && $0.localizedCaseInsensitiveContains("Regular")
          && !$0.localizedCaseInsensitiveContains("Symbols")
      })
    {
      configuration.settings.terminalFont = nerdFont
    }
    configuration.settings.diffFont =
      (NSFont(name: configuration.settings.diffFont, size: configuration.settings.diffFontSize)
      ?? NSFont.monospacedSystemFont(ofSize: configuration.settings.diffFontSize, weight: .regular))
      .fontName
    updateSystemAppearance()
    appearanceObserver = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateSystemAppearance() }
    }
    foregroundObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in await self?.refreshVisibleRepositories() }
    }
    selectedID = configuration.selectedRepository
    showDashboard = settings.launchPage == "dashboard" || selectedID == nil
    for record in configuration.repositories {
      models[record.id] = RepositoryModel(record: record, store: self)
    }
    if let selectedID, let model = models[selectedID] { Task { await model.activate() } }
  }
  func text(_ english: String, _ chinese: String) -> String {
    settings.language == .english ? english : chinese
  }
  func configureNotifications(_ enabled: Bool) {
    if !enabled {
      var settings = settings
      settings.completionNotifications = false
      updateSettings(settings)
      return
    }
    guard Bundle.main.bundleIdentifier != nil else {
      error = text("Notifications require the packaged GitPier.app.", "通知需要打包后的 GitPier.app。 ")
      return
    }
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
      [weak self] granted, _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        var settings = self.settings
        settings.completionNotifications = granted
        self.updateSettings(settings)
      }
    }
  }
  func notifyCompletion(_ message: String) {
    guard settings.completionNotifications, Bundle.main.bundleIdentifier != nil else { return }
    let content = UNMutableNotificationContent()
    content.title = "GitPier"
    content.body = message
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
  }
  func updateSystemAppearance() {
    let scheme: ColorScheme =
      NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? .dark : .light
    if systemColorScheme != scheme { systemColorScheme = scheme }
  }
  func save() {
    pendingSave?.cancel()
    pendingSave = nil
    guard canSave else { return }
    if configuration.selectedRepository != selectedID {
      configuration.selectedRepository = selectedID
    }
    do { try persistence.save(configuration) } catch { self.error = error.localizedDescription }
  }
  func saveSoon() {
    pendingSave?.cancel()
    pendingSave = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
      self?.save()
    }
  }
  func update(_ record: RepositoryRecord, debounce: Bool = false) {
    guard let i = configuration.repositories.firstIndex(where: { $0.id == record.id }),
      configuration.repositories[i] != record
    else { return }
    configuration.repositories[i] = record
    configuration.reconcileOrganizations()
    if debounce { saveSoon() } else { save() }
  }
  func updateSettings(_ settings: AppSettings) {
    let previous = configuration.settings
    guard previous != settings else { return }
    configuration.settings = settings
    if previous.appearance != settings.appearance { updateSystemAppearance() }
    save()
    for model in models.values {
      if previous.gitPath != settings.gitPath
        || previous.defaultCredentialID != settings.defaultCredentialID
      {
        Task {
          await model.configure()
          if previous.gitPath != settings.gitPath && model.available { await model.refresh() }
        }
      }
      if previous.automaticRefresh != settings.automaticRefresh {
        Task { await model.configureWatcher() }
      }
      if previous.ignoreWhitespace != settings.ignoreWhitespace { model.loadDiff() }
    }
  }
  var organizations: [RepositoryOrganization] {
    configuration.organizations.sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }
  @discardableResult func createOrganization(_ name: String) throws -> RepositoryOrganization {
    let result = try configuration.createOrganization(name)
    save()
    return result
  }
  func renameOrganization(_ id: UUID, name: String) throws {
    let old = configuration.organizations.first { $0.id == id }?.name
    try configuration.renameOrganization(id, to: name)
    if dashboardOrganization == old {
      dashboardOrganization = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    syncRepositoryGroups()
    save()
  }
  func moveRepositories(_ ids: Set<UUID>, to organizationID: UUID?) throws {
    try configuration.moveRepositories(ids, to: organizationID)
    syncRepositoryGroups()
    save()
  }
  func removeOrganization(_ id: UUID) {
    if dashboardOrganization == configuration.organizations.first(where: { $0.id == id })?.name {
      dashboardOrganization = nil
    }
    configuration.removeOrganization(id)
    syncRepositoryGroups()
    save()
  }
  private func syncRepositoryGroups() {
    for record in configuration.repositories {
      if models[record.id]?.record.group != record.group {
        models[record.id]?.record.group = record.group
      }
    }
  }
  func refreshDashboard() async { for model in models.values { await model.refresh() } }
  func refreshVisibleRepositories() async {
    if showDashboard {
      for record in repositories
      where dashboardOrganization == nil || record.group == dashboardOrganization {
        await models[record.id]?.activate(refresh: true)
      }
    } else {
      await current?.activate(refresh: true)
    }
  }
  @discardableResult func reorderRepository(_ id: UUID, relativeTo target: UUID) -> Bool {
    guard configuration.reorderRepository(id, relativeTo: target) else { return false }
    save()
    return true
  }
  func select(_ id: UUID) {
    selectedID = id
    showDashboard = false
    guard let model = models[id] else { return }
    model.setPage("commit")
    model.record.lastOpened = Date()
    update(model.record)
    Task { await model.activate(refresh: true) }
  }
  func openRepository(in group: String? = nil) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.message = text("Choose a local Git repository or worktree", "选择本地 Git 仓库或工作树")
    if panel.runModal() == .OK {
      let urls = panel.urls
      Task { for url in urls { await addRepository(url, group: group) } }
    }
  }
  func addRepository(_ url: URL, group: String? = nil) async {
    do {
      let initial = await GitServiceRegistry.shared.service(for: url, gitPath: settings.gitPath)
      let root = try await initial.validate()
      if let group, !group.isEmpty, !organizations.contains(where: { $0.name == group }) {
        throw GitPierError.invalidInput(text("Organization no longer exists.", "组织已不存在。"))
      }
      if let existing = repositories.first(where: {
        URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == root
      }) {
        if let group {
          try moveRepositories([existing.id], to: organizations.first { $0.name == group }?.id)
        }
        select(existing.id)
        return
      }
      var record = RepositoryRecord(path: root.path)
      record.group = group ?? ""
      configuration.repositories.append(record)
      let model = RepositoryModel(record: record, store: self)
      models[record.id] = model
      save()
      select(record.id)
    } catch { self.error = error.localizedDescription }
  }
  func remove(_ id: UUID) {
    models[id]?.shutdown()
    models[id] = nil
    configuration.repositories.removeAll { $0.id == id }
    if selectedID == id {
      selectedID = nil
      showDashboard = true
    }
    save()
  }
  func clone(url: String, destination: URL, credential: UUID?) {
    guard !cloning else { return }
    cloning = true
    notice = nil
    let progressTicket = cloneActivity.begin(text("Cloning", "克隆仓库"))
    let progress = cloneActivity.receiver()
    cloneTask = Task {
      var result = OperationResult.succeeded
      defer {
        cloneActivity.finish(result, ticket: progressTicket)
        cloning = false
        cloneTask = nil
      }
      do {
        let profile = configuration.credentials.first { $0.id == credential }
        let auth = try AuthenticationContext.make(
          profile: profile, executable: Bundle.main.executablePath ?? CommandLine.arguments[0],
          configurationPath: persistence.url.path)
        try await GitService.clone(
          url: url, destination: destination, gitPath: settings.gitPath,
          environment: auth.environment, authArguments: auth.arguments, progress: progress)
        showClone = false
        await addRepository(destination)
        if let current {
          current.record.credentialID = credential
          update(current.record)
          await current.configure()
        }
        notice = text("Clone completed.", "克隆已完成。")
        notifyCompletion(notice!)
      } catch is CancellationError {
        result = .cancelled
        notice = text(
          "Clone cancelled. Any partial destination was preserved.", "已取消 Clone，保留可能产生的目录。")
      } catch {
        result = .failed
        self.error = error.localizedDescription
      }
    }
  }
  func saveCredential(_ profile: CredentialProfile, token: String) throws {
    if profile.kind == .https && !token.isEmpty { try KeychainStore().save(token, id: profile.id) }
    if let i = configuration.credentials.firstIndex(where: { $0.id == profile.id }) {
      configuration.credentials[i] = profile
    } else {
      configuration.credentials.append(profile)
    }
    save()
    for model in models.values { Task { await model.configure() } }
  }
  func deleteCredential(_ id: UUID) throws {
    try KeychainStore().delete(id: id)
    configuration.credentials.removeAll { $0.id == id }
    if configuration.settings.defaultCredentialID == id {
      configuration.settings.defaultCredentialID = nil
    }
    for i in configuration.repositories.indices
    where configuration.repositories[i].credentialID == id {
      configuration.repositories[i].credentialID = nil
    }
    for model in models.values where model.record.credentialID == id {
      model.record.credentialID = nil
      Task { await model.configure() }
    }
    save()
  }
  func shutdown() {
    for model in models.values { model.shutdown() }
    cloneTask?.cancel()
    save()
  }
  deinit {
    if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    if let appearanceObserver {
      DistributedNotificationCenter.default().removeObserver(appearanceObserver)
    }
  }
}

struct DiffTab: Identifiable, Equatable {
  var id: String { path }
  var path: String
  var pinned: Bool
  var preview: Bool
}

@MainActor final class RepositoryModel: ObservableObject {
  @Published var record: RepositoryRecord
  @Published private(set) var page = "commit"
  @Published private(set) var status = RepositoryStatus()
  private var fileIndex = RepositoryFileIndex([])
  private var filteredKey = ""
  private var filteredCache: [FileChange] = []
  private var fileGeneration = 0
  @Published var snapshot: IndexSnapshot?
  @Published var diff = DiffDocument.empty
  @Published var diffError: String?
  @Published var diffLoading = false
  @Published var comparison: DiffComparison = .unstaged
  @Published var selectedPath: String?
  @Published var selectedPaths: Set<String> = []
  @Published private(set) var includedPaths: Set<String> = []
  private var knownPaths: Set<String> = []
  let panels: WorkspacePanels
  let activity = OperationProgress()
  @Published var tabs: [DiffTab] = []
  @Published var selectedHunk = 0
  @Published var query = ""
  @Published var filter = "all"
  @Published var treeMode = false
  @Published var expandedDirectories: Set<String> = []
  @Published var busy = false
  @Published var committing = false
  @Published var refreshing = false
  @Published var available = false
  @Published var error: String?
  @Published var output: String?
  @Published var outputResult: OperationResult = .succeeded
  @Published var pushFailed = false
  @Published var needsUpstream = false
  @Published var lastCommit: String?
  @Published var amend = false
  @Published var requiresIndexReview = false
  @Published private(set) var history: [CommitRecord] = []
  @Published private(set) var historyGraph: [String: GraphRow] = [:]
  @Published private(set) var historyLoading = false
  private var historyTask: Task<Void, Never>?
  private var historyTaskKey = ""
  private var historyReadyKey: String?
  private var historyGeneration = 0
  private(set) var historyReadCount = 0
  @Published var historyPath: String?
  @Published var selectedHistoryCommit: CommitRecord?
  @Published var historyHasMore = true
  @Published var branches: [GitBranch] = []
  @Published var remotes: [GitRemote] = []
  @Published var stashes: [GitStash] = []
  @Published var tags: [String] = []
  @Published var identity: [String: String] = [:]
  @Published var recentMessages: [String] = []
  @Published var terminal: TerminalManager
  @Published var confirmation: PendingAction?
  private var service: GitService?
  private var watcher: RepositoryWatcher?
  private var refreshTask: Task<Void, Never>?
  private var activationTask: Task<Void, Never>?
  private var activationRefreshRequested = false
  private(set) var refreshCount = 0
  @Published var hasExternalChanges = false
  @Published private(set) var stagedAdditions = 0
  @Published private(set) var stagedDeletions = 0
  private var activeTask: Task<Void, Never>?
  private var diffTask: Task<Void, Never>?
  private var diffGeneration = 0
  private var diffCache: [DiffCacheKey: CachedDiff] = [:]
  private var cacheOrder: [DiffCacheKey] = []
  private var diffRequests: [DiffCacheKey: Task<CachedDiff, Error>] = [:]
  private var prefetchTask: Task<Void, Never>?
  private var cacheEpoch = 0
  private var hotDiffKeys: [DiffCacheKey] = []
  private(set) var diffReadCount = 0
  private(set) var foregroundDiffMissCount = 0
  unowned let store: AppStore
  init(record: RepositoryRecord, store: AppStore) {
    self.record = record
    self.store = store
    panels = WorkspacePanels(record.layout)
    terminal = TerminalManager(root: record.path)
  }
  var title: String { record.name }
  var stagedCount: Int { fileIndex.stagedCount }
  var trackedCount: Int { fileIndex.trackedCount }
  var untrackedCount: Int { fileIndex.untrackedCount }
  var canCommit: Bool {
    let title = record.draft.components(separatedBy: "\n").first ?? ""
    return available && !busy && !refreshing && snapshot != nil && !includedPaths.isEmpty
      && !title.trimmingCharacters(in: .whitespaces).isEmpty
      && status.operation == nil && !fileIndex.hasConflicts
  }
  var selectedFile: FileChange? { selectedPath.flatMap { fileIndex.byPath[$0] } }
  var filteredFiles: [FileChange] {
    let key = "\(fileGeneration):\(filter):\(query)"
    if filteredKey == key { return filteredCache }
    filteredCache = fileIndex.ordered.filter {
      (query.isEmpty || $0.path.localizedCaseInsensitiveContains(query))
        && (filter == "all" || filter == "staged" && $0.isStaged
          || filter == "unstaged" && $0.isUnstaged || filter == "conflicts" && $0.isConflicted)
    }
    filteredKey = key
    return filteredCache
  }
  func git() async -> GitService {
    if let service { return service }
    let new = await GitServiceRegistry.shared.service(
      for: URL(fileURLWithPath: record.path), gitPath: store.settings.gitPath)
    service = new
    return new
  }
  func configure() async {
    do {
      let id =
        record.credentialID
        ?? (record.useDefaultCredential ? store.settings.defaultCredentialID : nil)
      let profile = store.configuration.credentials.first { $0.id == id }
      let auth = try AuthenticationContext.make(
        profile: profile, executable: Bundle.main.executablePath ?? CommandLine.arguments[0],
        configurationPath: store.persistence.url.path)
      await git().configure(
        gitPath: store.settings.gitPath, authArguments: auth.arguments,
        authEnvironment: auth.environment)
      terminal.configure(authentication: auth)
    } catch { self.error = error.localizedDescription }
  }
  func activate(refresh: Bool = false) async {
    activationRefreshRequested = activationRefreshRequested || refresh
    if let activationTask {
      await activationTask.value
      return
    }
    let task = Task { [weak self] in
      guard let self else { return }
      await self.configure()
      await self.configureWatcher()
      // Writes already refresh their final result. Never race an activation read with a write.
      if (!self.available || self.activationRefreshRequested) && !self.busy {
        await self.refresh()
      }
      self.activationRefreshRequested = false
    }
    activationTask = task
    await task.value
    activationTask = nil
  }
  func configureWatcher() async {
    watcher?.stop()
    watcher = nil
    guard store.settings.automaticRefresh, let directories = try? await git().metadataDirectories()
    else { return }
    watcher = RepositoryWatcher(paths: [URL(fileURLWithPath: record.path)] + directories) {
      [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.store.settings.automaticRefresh, !self.busy else { return }
        if !self.hasExternalChanges { self.hasExternalChanges = true }
      }
    }
  }
  func refresh() async {
    if let refreshTask {
      await refreshTask.value
      return
    }
    refreshing = true
    let progressTicket =
      busy
      ? nil
      : activity.begin(
        store.text(available ? "Refreshing" : "Opening repository", available ? "刷新仓库" : "打开仓库"),
        cancellable: false)
    let task = Task { [weak self] in
      guard let self else { return }
      await self.performRefresh()
    }
    refreshTask = task
    await task.value
    refreshTask = nil
    refreshing = false
    if let progressTicket {
      activity.finish(available ? .succeeded : .failed, ticket: progressTicket)
    }
  }
  private func performRefresh() async {
    refreshCount += 1
    do {
      let git = await git()
      let new = try await git.status()
      let snap =
        new.files.contains(where: \.isConflicted) ? nil : try await git.snapshot(status: new)
      let previousSnapshot = snapshot
      invalidateDiffCache()
      if let old = previousSnapshot, let snap, old.identity != snap.identity && !busy {
        requiresIndexReview = true
      }
      if status.files != new.files {
        fileIndex = await Task.detached(priority: .userInitiated) { RepositoryFileIndex(new.files) }
          .value
        fileGeneration += 1
      }
      if status != new { status = new }
      if snapshot != snap {
        snapshot = snap
        let patch = snap?.patch ?? Data()
        let statistics = await Task.detached {
          let doc = DiffParser.parse(patch)
          return (doc.additions, doc.deletions)
        }.value
        stagedAdditions = statistics.0
        stagedDeletions = statistics.1
      }
      available = true
      hasExternalChanges = false
      let allPaths = Set(new.files.map(\.path))
      var included = includedPaths.intersection(allPaths)
      // Preserve deliberate exclusions. Newly discovered external staging is selected once.
      included.formUnion(
        new.files.filter { $0.isStaged && !knownPaths.contains($0.path) }.map(\.path))
      if includedPaths != included { includedPaths = included }
      knownPaths = allPaths
      let paths = selectedPaths.intersection(Set(new.files.map(\.path)))
      if paths != selectedPaths { selectedPaths = paths }
      if let path = selectedPath, !new.files.contains(where: { $0.path == path }) {
        selectedPath = nil
        diff = .empty
        tabs.removeAll { $0.path == path }
      } else if selectedPath != nil {
        // Porcelain status can stay identical while unstaged file contents continue changing.
        loadDiff(preserveDisplay: true)
      }
      let newIdentity = try await git.identity()
      if identity != newIdentity { identity = newIdentity }
      let newBranches = try await git.branches()
      if branches != newBranches { branches = newBranches }
      let newRemotes = try await git.remotes()
      if remotes != newRemotes { remotes = newRemotes }
      if page == "history" {
        await loadHistory(reset: true)
      } else {
        await loadPage(page)
      }
      warmDiffCache()
    } catch is CancellationError {} catch {
      available = false
      snapshot = nil
      self.error = error.localizedDescription
    }
  }
  private func loadPage(_ page: String) async {
    do {
      switch page {
      case "history": await ensureHistory()
      case "stash":
        let values = try await git().stashes()
        if stashes != values { stashes = values }
      case "tags":
        let values = try await git().tags()
        if tags != values { tags = values }
      default: break
      }
    } catch { self.error = error.localizedDescription }
  }
  func editDraft(_ value: String) {
    record.draft = value
    store.update(record, debounce: true)
  }
  func editLayout(_ value: PanelLayout, persist: Bool = true) {
    if panels.layout != value { panels.layout = value }
    if persist, record.layout != value {
      record.layout = value
      store.update(record)
    }
  }
  func persistLayout() {
    record.layout = panels.layout
    store.update(record)
  }
  func toggleIncluded(_ files: [FileChange]) {
    let paths = Set(files.filter { !$0.isConflicted }.map(\.path))
    let value =
      paths.isSubset(of: includedPaths)
      ? includedPaths.subtracting(paths) : includedPaths.union(paths)
    if value != includedPaths { includedPaths = value }
  }
  func setPage(_ value: String) {
    guard page != value else { return }
    page = value
    Task { await loadPage(value) }
  }
  func select(
    _ file: FileChange, permanent: Bool = false, extend: Bool = false, toggle: Bool = false
  ) {
    let previous = selectedPath
    if extend, let anchor = previous,
      let start = filteredFiles.firstIndex(where: { $0.path == anchor }),
      let end = filteredFiles.firstIndex(where: { $0.path == file.path })
    {
      selectedPaths.formUnion(filteredFiles[min(start, end)...max(start, end)].map(\.path))
    } else if toggle {
      if selectedPaths.contains(file.path) {
        selectedPaths.remove(file.path)
      } else {
        selectedPaths.insert(file.path)
      }
    } else {
      selectedPaths = [file.path]
    }
    let nextComparison: DiffComparison = file.isStaged ? .staged : .unstaged
    let changed = selectedPath != file.path || comparison != nextComparison
    if selectedPath != file.path { selectedPath = file.path }
    if comparison != nextComparison { comparison = nextComparison }
    if let i = tabs.firstIndex(where: { $0.path == file.path }) {
      if permanent { tabs[i].preview = false }
    } else {
      if !permanent { tabs.removeAll { $0.preview && !$0.pinned } }
      tabs.append(DiffTab(path: file.path, pinned: false, preview: !permanent))
    }
    if changed { loadDiff() }
  }
  private func cacheKey(_ file: FileChange, comparison: DiffComparison, ignore: Bool)
    -> DiffCacheKey
  {
    DiffCacheKey(path: file.path, comparison: comparison, ignoreWhitespace: ignore)
  }
  private func cachedDiff(_ key: DiffCacheKey) -> CachedDiff? {
    guard let value = diffCache[key] else { return nil }
    if key.comparison == .unstaged && value.stamp != FileStamp(root: record.path, path: key.path) {
      diffCache[key] = nil
      cacheOrder.removeAll { $0 == key }
      return nil
    }
    cacheOrder.removeAll { $0 == key }
    cacheOrder.append(key)
    return value
  }
  private func remember(_ value: CachedDiff, key: DiffCacheKey) {
    diffCache[key] = value
    cacheOrder.removeAll { $0 == key }
    cacheOrder.append(key)
    let protected = Set(hotDiffKeys)
    while cacheOrder.count > 64 || diffCache.values.reduce(0, { $0 + $1.cost }) > 32 * 1024 * 1024 {
      guard
        let oldest = cacheOrder.first(where: { !protected.contains($0) && $0.path != selectedPath })
          ?? cacheOrder.first(where: { $0.path != selectedPath }) ?? cacheOrder.first
      else { break }
      cacheOrder.removeAll { $0 == oldest }
      diffCache[oldest] = nil
    }
  }
  private func requestDiff(_ file: FileChange, comparison: DiffComparison, ignore: Bool)
    async throws -> CachedDiff
  {
    let key = cacheKey(file, comparison: comparison, ignore: ignore)
    if let value = cachedDiff(key) { return value }
    if let task = diffRequests[key] {
      let epoch = cacheEpoch
      let result = try await task.value
      if cacheEpoch == epoch {
        if comparison == .staged || result.stamp == FileStamp(root: record.path, path: file.path) {
          remember(result, key: key)
        }
      }
      return result
    }
    let epoch = cacheEpoch
    let root = record.path
    let git = await git()
    diffReadCount += 1
    let task = Task<CachedDiff, Error> {
      let stamp = FileStamp(root: root, path: file.path)
      let bytes = try await git.patch(for: file, comparison: comparison, ignoreWhitespace: ignore)
      let document = await Task.detached(priority: .userInitiated) { DiffParser.parse(bytes) }.value
      try Task.checkCancellation()
      return CachedDiff(bytes: bytes, document: document, stamp: stamp)
    }
    diffRequests[key] = task
    do {
      let result = try await task.value
      if cacheEpoch == epoch {
        diffRequests[key] = nil
        if comparison == .staged || result.stamp == FileStamp(root: root, path: file.path) {
          remember(result, key: key)
        }
      }
      return result
    } catch {
      if cacheEpoch == epoch { diffRequests[key] = nil }
      throw error
    }
  }
  private func invalidateDiffCache() {
    cacheEpoch += 1
    prefetchTask?.cancel()
    for task in diffRequests.values { task.cancel() }
    diffRequests.removeAll()
    diffCache.removeAll()
    cacheOrder.removeAll()
    hotDiffKeys.removeAll()
  }
  private func warmDiffCache(around path: String? = nil) {
    prefetchTask?.cancel()
    let files = filteredFiles
    let index = path.flatMap { value in files.firstIndex { $0.path == value } } ?? 0
    let ordered = Array(files.dropFirst(index)) + Array(files.prefix(index))
    let ignore = store.settings.ignoreWhitespace
    prefetchTask = Task { [weak self] in
      guard let self else { return }
      for file in ordered.prefix(64) {
        guard !Task.isCancelled else { return }
        let comparison: DiffComparison = file.isStaged ? .staged : .unstaged
        _ = try? await requestDiff(file, comparison: comparison, ignore: ignore)
      }
    }
  }
  func loadDiff(preserveDisplay: Bool = false) {
    diffTask?.cancel()
    diffGeneration += 1
    let generation = diffGeneration
    diffError = nil
    guard let file = selectedFile else {
      if !diff.raw.isEmpty { diff = .empty }
      diffLoading = false
      return
    }
    let comparison = comparison
    let ignore = store.settings.ignoreWhitespace
    let key = cacheKey(file, comparison: comparison, ignore: ignore)
    hotDiffKeys.removeAll { $0 == key }
    hotDiffKeys.append(key)
    hotDiffKeys = Array(hotDiffKeys.suffix(16))
    if let cached = cachedDiff(key) {
      if diff.revision != cached.document.revision { diff = cached.document }
      if !preserveDisplay { selectedHunk = 0 }
      diffLoading = false
      return
    }
    if !preserveDisplay {
      if !diff.raw.isEmpty { diff = .empty }
      selectedHunk = 0
    }
    foregroundDiffMissCount += 1
    diffLoading = true
    diffTask = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await requestDiff(file, comparison: comparison, ignore: ignore)
        guard generation == diffGeneration, !Task.isCancelled else { return }
        if diff.raw != result.document.raw { diff = result.document }
        selectedHunk = min(selectedHunk, max(0, diff.hunks.count - 1))
        diffLoading = false
        warmDiffCache(around: file.path)
      } catch is CancellationError { if generation == diffGeneration { diffLoading = false } } catch
      {
        if generation == diffGeneration {
          diffLoading = false
          diffError = error.localizedDescription
        }
      }
    }
  }
  func closeTab(_ path: String) {
    tabs.removeAll { $0.path == path }
    if selectedPath == path {
      selectedPath = tabs.last?.path
      selectedPaths = selectedPath.map { [$0] } ?? []
      loadDiff()
    }
  }
  func promoteTab(_ path: String) {
    guard let index = tabs.firstIndex(where: { $0.path == path }), tabs[index].preview else {
      return
    }
    tabs[index].preview = false
  }
  func activateTab(_ path: String) {
    guard selectedPath != path else { return }
    selectedPath = path
    selectedPaths = [path]
    loadDiff()
  }
  func toggleStage(_ file: FileChange) {
    if file.isConflicted {
      stageGroup([file], unstage: false)
      return
    }
    run { git in
      if file.isStaged && !file.isPartial {
        try await git.unstage([file])
      } else {
        try await git.stage([file])
      }
    }
  }
  func stageGroup(_ files: [FileChange], unstage: Bool) {
    if !unstage { includedPaths.formUnion(files.filter { !$0.isConflicted }.map(\.path)) }
    if !unstage && files.contains(where: \.isConflicted) {
      confirmation = PendingAction(
        title: store.text("Mark conflicts resolved?", "标记冲突已解决？"),
        detail: store.text(
          "Review and edit these files first. Staging records their current content as resolved; it does not remove conflict markers automatically.",
          "请先审查和编辑这些文件；暂存会将当前内容标记为已解决，不会自动移除冲突标记。") + "\n\n"
          + files.filter(\.isConflicted).map(\.path).joined(separator: "\n")
      ) { [weak self] in self?.run { git in try await git.stage(files) } }
      return
    }
    run { git in if unstage { try await git.unstage(files) } else { try await git.stage(files) } }
  }
  func run(
    label: String? = nil, completion: String? = nil, notify: Bool = false,
    _ action: @escaping (GitService) async throws -> Void
  ) {
    guard !busy else { return }
    busy = true
    error = nil
    output = nil
    outputResult = .succeeded
    let progressTicket = activity.begin(label ?? store.text("Git operation", "Git 操作"))
    activeTask = Task {
      defer {
        busy = false
        activeTask = nil
      }
      // Finish any older read before writing, so the refresh after this action reads its result.
      if let refreshTask { await refreshTask.value }
      var result = OperationResult.succeeded
      do {
        try Task.checkCancellation()
        try await action(await git())
        if error != nil {
          result = .failed
        } else if outputResult == .needsAttention {
          result = .needsAttention
        }
        let details = GitOutputSummary.details(output ?? "")
        let summary =
          completion ?? (label ?? store.text("Git operation", "Git 操作"))
          + store.text(" · Completed", " · 已完成")
        output = [summary, details].filter { !$0.isEmpty }.joined(separator: "\n")
        if result == .failed { outputResult = .needsAttention }
      } catch is CancellationError {
        result = .cancelled
        outputResult = .cancelled
        output = store.text("Operation cancelled.", "操作已取消。")
      } catch {
        result = .failed
        if output != nil { outputResult = .needsAttention }
        self.error = error.localizedDescription
      }
      activity.advance(store.text("Refreshing", "刷新仓库"), cancellable: false)
      await refresh()
      activity.finish(result, ticket: progressTicket)
      if notify, let output { store.notifyCompletion(output) }
    }
  }
  func cancel() {
    guard !committing else { return }
    activity.advance(store.text("Cancelling", "取消中"), cancellable: false)
    activeTask?.cancel()
  }
  func commit(push: Bool) {
    guard canCommit, let expected = snapshot else { return }
    let selection = status.files.filter { includedPaths.contains($0.path) }
    if amend || requiresIndexReview {
      let warning =
        amend
        ? store.text(
          "This rewrites commit history. Ensure the last commit has not been shared.",
          "这会重写历史，请确认最后一次提交尚未共享。")
        : store.text(
          "The Index or HEAD changed externally. Confirm the current staged files before committing.",
          "Index 或 HEAD 发生外部变化，请确认当前暂存文件后再提交。")
      confirmation = PendingAction(
        title: store.text("Review Commit", "确认提交"),
        detail: warning + "\n\n" + selection.map(\.path).joined(separator: "\n")
      ) { [weak self] in self?.performCommit(push: push, expected: expected, selection: selection) }
    } else {
      performCommit(push: push, expected: expected, selection: selection)
    }
  }
  private func performCommit(push: Bool, expected: IndexSnapshot, selection: [FileChange]) {
    let message = record.draft
    let amend = amend
    var reviewedPatches: [String: Data] = [:]
    for file in selection where !file.isStaged {
      let key = cacheKey(file, comparison: .unstaged, ignore: false)
      if let cached = diffCache[key] { reviewedPatches[file.path] = cached.bytes }
    }
    let reviewed = reviewedPatches
    run(
      label: store.text(push ? "Commit & Push" : "Committing", push ? "提交并推送" : "提交"),
      completion: "", notify: true
    ) {
      [weak self] git in
      guard let self else { return }
      committing = true
      activity.advance(store.text("Committing", "提交"), cancellable: false)
      defer { committing = false }
      let result = try await git.commit(
        message: message, expected: expected, amend: amend, selection: selection,
        reviewedPatches: reviewed)
      lastCommit = result.hash
      includedPaths.subtract(selection.map(\.path))
      recentMessages.insert(message, at: 0)
      recentMessages = Array(recentMessages.prefix(15))
      editDraft("")
      self.amend = false
      requiresIndexReview = false
      committing = false
      let localOutput =
        store.text("Local commit succeeded: ", "本地提交成功：")
        + String(result.hash.prefix(8))
      let indexNote =
        result.indexChangedDuringCommit
        ? store.text("\nIndex changes made during the commit remain staged.", "\n提交过程中发生的暂存修改已保留。")
        : ""
      pushFailed = false
      if push {
        let status = try await git.status()
        if status.upstream == nil {
          needsUpstream = true
          outputResult = .needsAttention
          output =
            localOutput + store.text("\nChoose a remote and branch to push.", "\n请选择 Remote 和分支推送。")
            + indexNote
        } else {
          activity.advance(store.text("Pushing", "推送"), cancellable: true)
          let progress = activity.receiver()
          do {
            let details = GitOutputSummary.details(
              try await git.network("push", progress: progress))
            output =
              store.text("Commit & push completed: ", "提交并推送已完成：")
              + String(result.hash.prefix(8)) + indexNote
            if !details.isEmpty { output! += "\n" + details }
          } catch is CancellationError {
            outputResult = .needsAttention
            output =
              store.text("Local commit succeeded; push cancelled: ", "本地提交成功，推送已取消：")
              + String(result.hash.prefix(8)) + indexNote
          } catch {
            pushFailed = true
            output =
              store.text("Local commit succeeded; push failed: ", "本地提交成功，推送失败：")
              + String(result.hash.prefix(8)) + indexNote
            self.error =
              store.text(
                "Local commit succeeded. Push failed; retrying will only push.\n",
                "本地提交成功，推送失败；重试只会推送。\n") + error.localizedDescription
          }
        }
      } else {
        output = localOutput + indexNote
      }
    }
  }
  func network(
    _ operation: String, remote: String? = nil, branch: String? = nil, force: Bool = false
  ) {
    let title =
      operation == "push"
      ? store.text("Pushing", "推送")
      : operation == "pull" ? store.text("Pulling", "拉取") : store.text("Fetching", "获取")
    let completed =
      operation == "push"
      ? store.text("Push completed.", "推送已完成。")
      : operation == "pull"
        ? store.text("Pull completed.", "拉取已完成。")
        : store.text("Fetch completed.", "获取已完成。")
    run(label: title, completion: completed, notify: true) { [weak self] git in
      guard let self else { return }
      let progress = activity.receiver()
      do {
        output = try await git.network(
          operation, remote: remote, branch: branch, strategy: store.settings.pullStrategy,
          forceWithLease: force, progress: progress)
        if operation == "push" {
          pushFailed = false
          needsUpstream = false
        }
      } catch {
        if operation == "push" { pushFailed = true }
        throw error
      }
    }
  }
  func applyHunk(_ hunk: DiffHunk, discard: Bool = false) {
    guard !store.settings.ignoreWhitespace, !diff.complexMetadata else { return }
    let reverse = comparison == .staged || discard
    let expected = snapshot
    let action: () -> Void = { [weak self] in
      self?.run { git in
        try await git.applyHunk(hunk.patch, reverse: reverse, toIndex: !discard, expected: expected)
      }
    }
    if discard {
      confirmation = PendingAction(
        title: store.text("Discard this hunk?", "丢弃这个差异块？"),
        detail: store.text(
          "This permanently removes the unstaged changes in this hunk.", "这会永久移除此差异块中的未暂存修改。"),
        action: action)
    } else {
      action()
    }
  }
  func discard(_ file: FileChange) {
    confirmation = PendingAction(
      title: store.text("Discard changes?", "丢弃修改？"),
      detail: file.path + "\n"
        + store.text(
          file.isUntracked
            ? "The untracked file will be deleted."
            : "Unstaged edits will be restored from the Index. Staged content remains.",
          file.isUntracked ? "将删除此未跟踪文件。" : "从 Index 恢复未暂存修改，保留暂存内容。")
    ) { [weak self] in self?.run { git in try await git.discard(file) } }
  }
  func discardSelection() {
    let files = status.files.filter {
      selectedPaths.contains($0.path) && $0.isUnstaged && !$0.isConflicted
    }
    guard !files.isEmpty else { return }
    confirmation = PendingAction(
      title: store.text("Discard selected changes?", "丢弃选中修改？"),
      detail: store.text(
        "Unstaged edits will be removed; untracked files will be deleted. Staged content remains.",
        "将移除未暂存修改、删除未跟踪文件，保留暂存内容。") + "\n\n" + files.map(\.path).joined(separator: "\n")
    ) { [weak self] in self?.run { git in for file in files { try await git.discard(file) } } }
  }
  func perform(_ args: [String], confirmation detail: String? = nil) {
    let action: () -> Void = { [weak self] in
      self?.run { [weak self] git in self?.output = try await git.perform(args) }
    }
    if let detail {
      confirmation = PendingAction(
        title: store.text("Confirm Git operation", "确认 Git 操作"), detail: detail, action: action)
    } else {
      action()
    }
  }
  func ensureHistory() async {
    let key = (status.head ?? "") + "\0" + (historyPath ?? "")
    guard historyReadyKey != key else { return }
    await loadHistory(reset: true)
  }
  func loadHistory(reset: Bool = false, path: String? = nil) async {
    let filter = path ?? historyPath
    let headKey = (status.head ?? "") + "\0" + (filter ?? "")
    let offset = reset ? 0 : history.count
    let key = headKey + ":\(offset)"
    if let task = historyTask, historyTaskKey == key {
      await task.value
      return
    }
    historyTask?.cancel()
    historyGeneration += 1
    let generation = historyGeneration
    historyTaskKey = key
    historyLoading = true
    historyReadCount += 1
    let previous = reset ? [] : history
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        let records = try await git().history(skip: offset, path: filter)
        let presentation = await Task.detached(priority: .userInitiated) {
          var seen: Set<String> = []
          let combined = (previous + records).filter { seen.insert($0.hash).inserted }
          let graph = Dictionary(
            uniqueKeysWithValues: zip(combined, CommitGraph.layout(combined)).map {
              ($0.0.hash, $0.1)
            })
          return (combined, graph)
        }.value
        guard generation == historyGeneration, !Task.isCancelled else { return }
        historyGraph = presentation.1
        history = presentation.0
        historyHasMore = records.count == 100
        historyReadyKey = headKey
      } catch is CancellationError {} catch {
        if generation == historyGeneration { self.error = error.localizedDescription }
      }
    }
    historyTask = task
    await task.value
    if generation == historyGeneration {
      historyTask = nil
      historyLoading = false
    }
  }
  func openEditor(_ path: String? = nil, application: URL? = nil) {
    let url =
      path.map { URL(fileURLWithPath: record.path).appendingPathComponent($0) }
      ?? URL(fileURLWithPath: record.path)
    if let application = ExternalEditors.application(
      settings: store.settings, override: application)
    {
      let config = NSWorkspace.OpenConfiguration()
      NSWorkspace.shared.open(
        [url], withApplicationAt: application,
        configuration: config
      ) { [weak self] _, error in
        if let error { Task { @MainActor [weak self] in self?.error = error.localizedDescription } }
      }
    } else {
      NSWorkspace.shared.open(url)
    }
  }
  func reveal(_ path: String? = nil) {
    NSWorkspace.shared.activateFileViewerSelecting([
      URL(fileURLWithPath: record.path).appendingPathComponent(path ?? "")
    ])
  }
  func shutdown() {
    watcher?.stop()
    watcher = nil
    activationTask?.cancel()
    refreshTask?.cancel()
    activeTask?.cancel()
    historyTask?.cancel()
    diffTask?.cancel()
    invalidateDiffCache()
    terminal.shutdown()
  }
}

struct PendingAction: Identifiable {
  let id = UUID()
  let title: String
  let detail: String
  var action: () -> Void
}

func copyText(_ text: String) {
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(text, forType: .string)
}
