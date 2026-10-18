import AppKit
import GitPierCore
import SwiftUI
import UserNotifications

@MainActor final class AppStore: ObservableObject {
  static let shared: AppStore = {
    let info = Bundle.main
    let testing = info.object(forInfoDictionaryKey: "GitPierTestingUpdates") as? Bool == true
      && (info.bundleIdentifier ?? "").hasPrefix("com.heisenberg2024.gitpier.update-test.")
    if info.object(forInfoDictionaryKey: "GitPierWorkflowTesting") as? Bool == true,
      (info.bundleIdentifier ?? "").hasPrefix("com.heisenberg2024.gitpier.workspace-test.workflow170"),
      let path = info.object(forInfoDictionaryKey: "GitPierTestWorkspacePath") as? String,
      (path.contains("/.cache/v170/") || path.hasPrefix("/private/tmp/GitPier-workflow170-")) {
      return AppStore(persistence: ConfigurationStore(url: URL(fileURLWithPath: path)))
    }
    if testing {
      guard let path = info.object(forInfoDictionaryKey: "GitPierTestWorkspacePath") as? String,
            path.contains("/.cache/update-acceptance/") || path.hasPrefix("/private/tmp/GitPier-update-acceptance-") else {
        fatalError("Update tests require persistent isolated workspace metadata")
      }
      return AppStore(persistence: ConfigurationStore(url: URL(fileURLWithPath: path)))
    }
    return AppStore(persistence: ConfigurationStore(
      url: ProcessInfo.processInfo.environment["GITPIER_WORKSPACE_FILE"].map { URL(fileURLWithPath: $0) }))
  }()
  @Published var configuration: WorkspaceConfiguration
  @Published var selectedID: UUID?
  @Published var showDashboard = true
  @Published var error: String?
  @Published var notice: String?
  let operations = OperationsCenter()
  var pendingNavigation: [NavigationRequest] = []
  var routingNavigation = false
  var recentNavigationIDs: [UUID] = []
  var operationNavigation: [UUID: OperationNavigationSnapshot] = [:]
  @Published var showOperationsCenter = false
  @Published var showReviewRecovery = false
  lazy var updates = UpdateManager(store: self)
  lazy var workspace = WorkspaceModel(store: self)
  lazy var hosting = HostingModel(store: self)
  let reviewSessions: HostingReviewSessionRegistry
  @Published var hostingReviewDestination: HostingReviewDashboardItem?
  var hasRunningGitOperations: Bool { hasBlockingGitOperations || workspace.automaticallyFetching }
  var hasBlockingGitOperations: Bool { cloning || workspace.manuallyFetching || models.values.contains { $0.busy || $0.committing } }
  let cloneActivity = OperationProgress()
  @Published var cloning = false
  @Published var cloneTask: Task<Void, Never>?
  @Published var showClone = false
  @Published var showCredentials = false
  @Published var showOrganizations = false
  @Published var showWorkspaceSearch = false
  @Published var showQuickOpen = false
  @Published var recentCommands: [WorkspaceCommand] = []
  @Published var dashboardOrganization: String?
  @Published private(set) var systemColorScheme: ColorScheme = .light
  private var pendingSave: Task<Void, Never>?
  nonisolated(unsafe) private var appearanceObserver: NSObjectProtocol?
  nonisolated(unsafe) private var foregroundObserver: NSObjectProtocol?
  @Published var models: [UUID: RepositoryModel] = [:]
  let persistence: ConfigurationStore
  private var canSave = true
  var managedWindows: Set<ObjectIdentifier> = []
  @Published var navigationPresentationPending = false
  var settings: AppSettings { configuration.settings }
  var repositories: [RepositoryRecord] { configuration.repositories }
  var current: RepositoryModel? { selectedID.flatMap { models[$0] } }
  var colorScheme: ColorScheme? {
    settings.appearance == .system ? nil : settings.appearance == .dark ? .dark : .light
  }
  var resolvedColorScheme: ColorScheme { colorScheme ?? systemColorScheme }
  init(persistence: ConfigurationStore = ConfigurationStore()) {
    self.persistence = persistence
    reviewSessions = HostingReviewSessionRegistry(journalURL: persistence.url.deletingPathExtension().appendingPathExtension("review-operations"))
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
    applyNativeAppearance()
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
    configureFrameworkLanguage()
    selectedID = configuration.selectedRepository
    showDashboard = settings.launchPage == "dashboard" || selectedID == nil
    for record in configuration.repositories {
      models[record.id] = RepositoryModel(record: record, store: self)
    }
    cloneActivity.center = operations
    cloneActivity.cancelOperation = { [weak self] in self?.cloneTask?.cancel() }
    reviewSessions.operationCenter = operations
    workspace.start()
    Task { await reviewSessions.refreshRecovery() }
    if !showDashboard, let selectedID, let model = models[selectedID] { Task { await model.activate() } }
  }
  private func configureFrameworkLanguage() {
    guard Bundle.main.bundlePath.hasSuffix(".app"),
          (Bundle.main.bundleIdentifier ?? "").hasPrefix("com.heisenberg2024.gitpier") else { return }
    // App-owned preferences only. Sparkle/AppKit read their language at process startup.
    UserDefaults.standard.set([settings.language == .english ? "en" : "zh-Hans"], forKey: "AppleLanguages")
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
  private func applyNativeAppearance() {
    NSApplication.shared.appearance = settings.appearance == .system
      ? nil : NSAppearance(named: settings.appearance == .dark ? .darkAqua : .aqua)
  }
  func save() {
    workspace.sync()
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
    let old = configuration.repositories[i]
    configuration.repositories[i] = record
    configuration.reconcileOrganizations()
    if debounce { saveSoon() } else { save() }
    if old.credentialID != record.credentialID || old.useDefaultCredential != record.useDefaultCredential {
      workspace.credentialsChanged([record.id])
    }
  }
  func updateSettings(_ settings: AppSettings) {
    let previous = configuration.settings
    guard previous != settings else { return }
    configuration.settings = settings
    if previous.language != settings.language {
      configureFrameworkLanguage()
      notice = text("Restart GitPier for update dialogs to use the selected language.", "重新启动 GitPier 后，更新对话框会使用所选语言。")
    }
    if previous.appearance != settings.appearance {
      applyNativeAppearance()
      updateSystemAppearance()
    }
    save()
    workspace.configureWatchers()
    workspace.remoteSettingsChanged()
    if previous.defaultCredentialID != settings.defaultCredentialID || previous.gitPath != settings.gitPath {
      workspace.credentialsChanged(Set(repositories.filter {
        previous.gitPath != settings.gitPath || $0.credentialID == nil && $0.useDefaultCredential
      }.map(\.id)))
    }
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
  func refreshDashboard() async { await workspace.refresh() }
  func refreshVisibleRepositories() async {
    workspace.requestRemoteEvaluation()
    if showDashboard {
      await workspace.refresh()
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
    workspace.requestRemoteEvaluation()
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
  func addRepository(_ url: URL, group: String? = nil, credential: UUID? = nil) async {
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
      record.credentialID = credential
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
    let progressTicket = cloneActivity.begin(text("Cloning", "克隆仓库"), kind: .clone)
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
        cloneActivity.markRunning()
        try await GitService.clone(
          url: url, destination: destination, gitPath: settings.gitPath,
          environment: auth.environment, authArguments: auth.arguments, progress: progress)
        showClone = false
        await addRepository(destination, credential: credential)
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
    workspace.credentialsChanged(Set(repositories.filter {
      ($0.credentialID ?? ($0.useDefaultCredential ? settings.defaultCredentialID : nil)) == profile.id
    }.map(\.id)))
  }
  func deleteCredential(_ id: UUID) throws {
    let affected = Set(repositories.filter {
      ($0.credentialID ?? ($0.useDefaultCredential ? settings.defaultCredentialID : nil)) == id
    }.map(\.id))
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
    workspace.credentialsChanged(affected)
  }
  var unsavedConflictDrafts: [String] {
    models.values.flatMap { model in
      model.conflictEditor.unsavedPaths.map { model.record.name + " / " + $0 }
    }.sorted()
  }
  func confirmDiscardConflictDrafts(quitting: Bool) -> Bool {
    guard let alert = makeConflictDraftDiscardAlert(quitting: quitting) else { return true }
    return alert.runModal() == .alertFirstButtonReturn
  }
  func makeConflictDraftDiscardAlert(quitting: Bool) -> NSAlert? {
    let drafts = unsavedConflictDrafts
    guard !drafts.isEmpty else { return nil }
    let alert = NSAlert()
    alert.messageText = text(
      quitting ? "Discard conflict drafts and quit?" : "Discard conflict drafts and close?",
      quitting ? "丢弃冲突草稿并退出？" : "丢弃冲突草稿并关闭？")
    alert.informativeText =
      text(
        "These conflict editor drafts have not been saved. Their files on disk are preserved. Running terminal sessions and jobs will stop.",
        "这些冲突编辑草稿尚未保存，磁盘文件会保留。运行中的终端会话及作业将停止。") + "\n\n" + drafts.joined(separator: "\n")
    alert.addButton(
      withTitle: text(quitting ? "Discard & Quit" : "Discard & Close", quitting ? "丢弃并退出" : "丢弃并关闭")
    )
    alert.addButton(withTitle: text("Cancel", "取消"))
    if let icon = AppResources.applicationIcon { alert.icon = icon }
    alert.window.appearance =
      settings.appearance == .system
      ? nil
      : NSAppearance(named: settings.appearance == .dark ? .darkAqua : .aqua)
    // The explicit title identifies discarding. Keep the system's neutral, legible button style.
    alert.buttons[0].hasDestructiveAction = false
    alert.buttons[0].keyEquivalent = ""
    alert.buttons[1].keyEquivalent = "\r"
    return alert
  }
  func shutdown() {
    reviewSessions.stop()
    hosting.shutdown()
    if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver); self.foregroundObserver = nil }
    workspace.shutdown()
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
  @Published var busy = false {
    didSet {
      if busy != oldValue {
        if !busy { applyPendingRemoteSnapshot() }
        store.objectWillChange.send()
        store.workspace.invalidate(record.id, collect: !busy)
      }
    }
  }
  @Published var committing = false
  @Published var refreshing = false
  @Published var available = false
  @Published var error: String?
  @Published var output: String?
  @Published var outputResult: OperationResult = .succeeded
  @Published var pushFailed = false
  @Published var rejectedPush: PushRejection?
  private var pendingPushRecovery: PushRejection?
  @Published private(set) var conflictPush: PushRejection?
  private var pendingMergeReview: (MergeReview, Bool)?
  lazy var conflictEditor = ConflictEditorModel(repository: self)
  @Published private(set) var networkFetching = false
  @Published var showRebaseRecovery = false
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
  @Published var historyQuery: HistoryQuery?
  @Published private(set) var historyError: String?
  @Published var selectedHistoryCommit: CommitRecord?
  @Published var comparisonRight: String?
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
  private var refreshGeneration = 0
  private var trackingReadUptime: TimeInterval = 0
  private var pendingRemoteSnapshot: WorkspaceSnapshot?
  private var activationTask: Task<Void, Never>?
  private var activationRefreshRequested = false
  private(set) var refreshCount = 0
  @Published var hasExternalChanges = false
  @Published private(set) var stagedAdditions = 0
  @Published private(set) var stagedDeletions = 0
  private var activeTask: Task<Void, Never>?
  private var confirmationReviewTask: Task<Void, Never>?
  private var confirmationReviewID = UUID()
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
    activity.center = store.operations
    activity.repositoryID = record.id
    activity.repositoryIdentity = { [weak self] in
      guard let self else { return nil }
      return OperationRepositoryIdentity(workingTree: self.record.path,
        commonDirectory: self.store.workspace.entries[self.record.id]?.snapshot?.commonDirectory)
    }
    activity.cancelOperation = { [weak self] in self?.cancel() }
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
  @discardableResult func configure(reportErrors: Bool = true) async -> Bool {
    do {
      let id =
        record.credentialID
        ?? (record.useDefaultCredential ? store.settings.defaultCredentialID : nil)
      let profile = store.configuration.credentials.first { $0.id == id }
      var auth = try AuthenticationContext.make(
        profile: profile, executable: Bundle.main.executablePath ?? CommandLine.arguments[0],
        configurationPath: store.persistence.url.path)
      let canonical = URL(fileURLWithPath: record.path).resolvingSymlinksInPath().path
      if let socket = await SSHAgentSession.shared.currentSocket(repository: canonical,
        authenticationIdentity: auth.environment["GITPIER_AUTH_IDENTITY"] ?? "") { auth.environment["SSH_AUTH_SOCK"] = socket }
      await git().configure(
        gitPath: store.settings.gitPath, authArguments: auth.arguments,
        authEnvironment: auth.environment)
      terminal.configure(authentication: auth)
      return true
    } catch { if reportErrors { self.error = error.localizedDescription }; return false }
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
    refreshGeneration += 1
    let generation = refreshGeneration
    refreshing = true
    let progressTicket =
      busy
      ? nil
      : activity.begin(
        store.text(available ? "Refreshing" : "Opening repository", available ? "刷新仓库" : "打开仓库"),
        cancellable: false, observed: false)
    let task = Task { [weak self] in
      guard let self else { return }
      await self.performRefresh()
    }
    refreshTask = task
    await task.value
    guard generation == refreshGeneration else { return }
    refreshTask = nil
    refreshing = false
    applyPendingRemoteSnapshot()
    if let progressTicket {
      activity.finish(available ? .succeeded : .failed, ticket: progressTicket)
    }
  }
  func applyRemoteSnapshot(_ value: WorkspaceSnapshot) {
    guard value.repositoryID == record.id, value.path == record.path else { return }
    if busy || refreshing {
      if value.collectedUptime >= (pendingRemoteSnapshot?.collectedUptime ?? 0) { pendingRemoteSnapshot = value }
      return
    }
    guard available, value.branch == status.branch, value.head == status.head, value.upstream == status.upstream,
      value.collectedUptime >= trackingReadUptime else { return }
    trackingReadUptime = value.collectedUptime
    if status.ahead != value.ahead || status.behind != value.behind || status.upstreamComparable != value.upstreamComparable {
      var updated = status; updated.ahead = value.ahead; updated.behind = value.behind
      updated.upstreamComparable = value.upstreamComparable; status = updated
    }
  }
  private func applyPendingRemoteSnapshot() {
    guard !busy, !refreshing, let pending = pendingRemoteSnapshot else { return }
    pendingRemoteSnapshot = nil; applyRemoteSnapshot(pending)
  }
  private func performRefresh() async {
    refreshCount += 1
    do {
      let git = await git()
      let new = try await git.status()
      trackingReadUptime = ProcessInfo.processInfo.systemUptime
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
      if status != new {
        status = new
        if !busy { store.workspace.invalidate(record.id, collect: true) }
      }
      if let target = conflictPush, new.operation == nil, new.head == target.localHead {
        conflictPush = nil
      }
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
      if remotes != newRemotes {
        remotes = newRemotes
        if !busy { store.workspace.invalidate(record.id, collect: true) }
      }
      if page == "history" {
        await loadHistory(reset: true)
      } else {
        await loadPage(page)
      }
      warmDiffCache()
      if page == "conflicts" { conflictEditor.repositoryDidRefresh() }
    } catch is CancellationError {} catch {
      available = false
      if !busy { store.workspace.invalidate(record.id, collect: true) }
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
    if !unstage, let conflict = files.first(where: \.isConflicted) {
      openConflicts(conflict.path)
      return
    }
    run { git in if unstage { try await git.unstage(files) } else { try await git.stage(files) } }
  }
  func run(
    label: String? = nil, completion: String? = nil, notify: Bool = false,
    kind: WorkflowOperationKind = .git,
    _ action: @escaping (GitService) async throws -> Void
  ) {
    guard !busy else { return }
    confirmationReviewID = UUID()
    confirmationReviewTask?.cancel()
    confirmationReviewTask = nil
    busy = true
    error = nil
    output = nil
    outputResult = .succeeded
    let progressTicket = activity.begin(label ?? store.text("Git operation", "Git 操作"), kind: kind)
    let hadConflicts = status.files.contains(where: \.isConflicted)
    activeTask = Task {
      defer {
        busy = false
        activeTask = nil
        if let rejection = pendingPushRecovery {
          pendingPushRecovery = nil
          confirmMergeAndPush(rejection)
        }
        if let (review, push) = pendingMergeReview {
          pendingMergeReview = nil
          confirmMergeContinuation(review, push: push)
        }
      }
      await store.workspace.beginManualOperation()
      // Finish any older read before writing, so the refresh after this action reads its result.
      if let refreshTask { await refreshTask.value }
      var result = OperationResult.succeeded
      do {
        try Task.checkCancellation()
        activity.markRunning()
        try await action(await git())
        if error != nil {
          result = .failed
        } else if outputResult == .needsAttention {
          result = .needsAttention
        }
        let details = GitOutputSummary.details(output ?? "")
        let summary = result == .succeeded
          ? (completion ?? (label ?? store.text("Git operation", "Git 操作"))
            + store.text(" · Completed", " · 已完成")) : ""
        output = [summary, details].filter { !$0.isEmpty }.joined(separator: "\n")
        if result == .failed { outputResult = .needsAttention }
      } catch is CancellationError {
        result = .cancelled
        outputResult = .cancelled
        output = store.text("Operation cancelled.", "操作已取消。")
      } catch {
        result = .failed
        if output != nil { outputResult = .needsAttention }
        self.error = localizedUI(error.localizedDescription)
      }
      await store.workspace.endManualOperation()
      activity.advance(store.text("Refreshing", "刷新仓库"), cancellable: false, phase: .refreshing)
      await refresh()
      if !hadConflicts, status.files.contains(where: \.isConflicted) {
        setPage("conflicts")
        let diagnosis = error.map { "\n\n" + $0 } ?? ""
        output =
          store.text(
            "Conflicts need resolution. Review the files in Resolve Conflicts, save each result, then continue the Git operation.",
            "存在需要解决的冲突。请在“解决冲突”中审查文件、保存结果，再继续 Git 操作。") + diagnosis
        outputResult = .needsAttention
        error = nil
        result = .needsAttention
      }
      if result == .needsAttention || status.operation != nil || status.files.contains(where: \.isConflicted) {
        await captureOperationRecovery(progressTicket.id)
      }
      activity.finish(result, ticket: progressTicket,
        waitingForUser: result == .needsAttention && (pendingPushRecovery != nil || pendingMergeReview != nil || needsUpstream))
      if notify, let output { store.notifyCompletion(output) }
    }
  }
  func cancel() {
    guard !committing else { return }
    activity.advance(store.text("Cancelling", "取消中"), cancellable: false, phase: .cancelling)
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
      completion: "", notify: true, kind: push ? .commitAndPush : .commit
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
      rejectedPush = nil
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
          } catch let rejection as PushRejection {
            queuePushRecovery(rejection)
            output = localOutput + indexNote
              + store.text("\nRemote commits must be merged before pushing.", "\n远程有尚未合并的提交，需要合并后推送。")
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
    _ operation: String, remote: String? = nil, branch: String? = nil, force: Bool = false, forceReview: ForcePushReview? = nil
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
    run(label: title, completion: completed, notify: true, kind: operation == "push" ? .push : operation == "pull" ? .pull : .fetch) { [weak self] git in
      guard let self else { return }
      networkFetching = operation == "fetch"
      defer { networkFetching = false }
      let progress = activity.receiver()
      var targets: [WorkspaceFetchTarget] = []
      var initialReferences: [String: String] = [:]
      if operation == "fetch" {
        targets = (try? await git.reviewWorkspaceFetch(record)) ?? []
        if let remote { targets = targets.filter { $0.remote.name == remote } }
        targets = await git.confirmedManualFetchTargets(targets, all: remote == nil)
        await store.workspace.recordManualFetchStarted(targets)
        for target in targets { initialReferences[target.id] = try? await git.trackingReferenceIdentity(target.remote.name) }
      }
      do {
        output = try await git.network(
          operation, remote: remote, branch: branch, strategy: store.settings.pullStrategy,
          forceWithLease: force, forceReview: forceReview, progress: progress)
        if operation == "fetch" {
          let confirmed = await git.confirmedManualFetchTargets(targets, all: remote == nil)
          var updated: Set<String> = []
          for target in confirmed {
            if let before = initialReferences[target.id], let after = try? await git.trackingReferenceIdentity(target.remote.name), before != after {
              updated.insert(target.id)
            }
          }
          await store.workspace.recordManualFetch(confirmed, updated: updated)
          let rejected = targets.filter { target in !confirmed.contains(where: { $0.id == target.id }) }
          await store.workspace.recordManualFetch(rejected, error: AutomaticFetchError.skipped("Remote configuration changed during Fetch."))
        }
        if operation == "push" {
          pushFailed = false
          rejectedPush = nil
          needsUpstream = false
        }
      } catch let rejection as PushRejection {
        queuePushRecovery(rejection)
        output = store.text(
          "Push rejected because the remote has commits to merge. Your local commits are preserved.",
          "远程有尚未合并的提交，推送被拒绝。本地提交已保留。")
      } catch {
        if operation == "fetch" { await store.workspace.recordManualFetch(targets, error: error) }
        if operation == "push" {
          pushFailed = true
          rejectedPush = nil
        }
        throw error
      }
    }
  }
  private func queuePushRecovery(_ rejection: PushRejection) {
    pushFailed = true
    rejectedPush = rejection
    pendingPushRecovery = rejection
    outputResult = .needsAttention
  }
  func confirmMergeAndPush(_ rejection: PushRejection) {
    guard !busy else { return }
    confirmation = PendingAction(
      title: store.text("Merge remote changes and push?", "合并远程更改并推送？"),
      detail: store.text(
        "The remote contains commits missing locally. Fetch its latest commits, merge them into the current branch, then push? Your local commit is already saved. Conflicts stop the push for you to resolve. Commit or stash remaining tracked changes first.",
        "远程包含本地尚未合并的提交。是否获取最新提交，合并到当前分支后继续推送？本地提交已经保存。出现冲突时会停止推送，交由你解决。若有剩余的已跟踪文件修改，请先提交或 Stash。")
        + "\n\n" + GitService.redact(rejection.remoteURL) + "\n"
        + String(rejection.localReference.dropFirst("refs/heads/".count)) + " → "
        + String(rejection.remoteReference.dropFirst("refs/heads/".count)),
      confirmTitle: store.text("Merge & Push", "合并并推送"), destructive: false
    ) { [weak self] in self?.mergeAndPush(rejection) }
  }
  private func mergeAndPush(_ rejection: PushRejection) {
    run(
      label: store.text("Merge & Push", "合并并推送"), completion: "", notify: true, kind: .mergeAndPush
    ) { [weak self] git in
      guard let self else { return }
      defer { committing = false }
      do {
        let details = try await git.mergeAndPush(rejection) { [weak self] phase in
          await MainActor.run {
            guard let self else { return nil }
            self.committing = phase == .merging
            let title: String
            switch phase {
            case .fetching: title = self.store.text("Fetching", "获取")
            case .merging: title = self.store.text("Merging", "合并")
            case .pushing: title = self.store.text("Pushing", "推送")
            }
            self.activity.advance(title, cancellable: phase != .merging)
            return self.activity.receiver()
          }
        }
        pushFailed = false
        rejectedPush = nil
        needsUpstream = false
        output = store.text("Merge & push completed.", "合并并推送已完成。") + "\n" + details
      } catch {
        committing = false
        pushFailed = true
        rejectedPush = nil
        outputResult = .needsAttention
        let state = try? await git.status()
        if let updated = error as? PushRejection {
          queuePushRecovery(updated)
          output = store.text(
            "New remote commits arrived during recovery. Your merge commit is saved; review Merge & Push again.",
            "恢复过程中远程又出现新提交，合并提交已保存；请再次确认合并并推送。")
          return
        }
        if state?.files.contains(where: \.isConflicted) == true {
          conflictPush = rejection
          output = store.text(
            "Merge has conflicts; push stopped. Resolve and stage the files, continue the merge, then retry Push. Your local commit is preserved.",
            "合并出现冲突，已停止推送。请解决并暂存冲突文件，继续合并后重试推送。本地提交已保留。")
          self.error = output! + "\n\n" + error.localizedDescription
        } else if state?.operation == .merge {
          output = store.text(
            "Merge is unfinished; push stopped. Review the Git error and continue or abort the merge before retrying Push. Your local commit is preserved.",
            "合并尚未完成，已停止推送。请检查 Git 错误，继续或中止合并后重试推送。本地提交已保留。")
          self.error = output! + "\n\n" + error.localizedDescription
        } else {
          output = store.text(
            "Merge & Push did not complete. Your local commits are preserved; review the repository before retrying Push.",
            "合并并推送尚未完成。本地提交已保留，请检查仓库后重试推送。")
          if error is CancellationError { throw error }
          self.error = error.localizedDescription
        }
      }
    }
  }
  func openConflicts(_ path: String? = nil) {
    setPage("conflicts")
    conflictEditor.select(path ?? status.files.first(where: \.isConflicted)?.path)
  }
  func reviewMergeContinuation(push: Bool = false) {
    guard status.operation == .merge, !status.files.contains(where: \.isConflicted) else { return }
    run(label: store.text("Reviewing merge", "审查合并"), completion: "", kind: .merge) { [weak self] git in
      guard let self else { return }
      pendingMergeReview = (try await git.reviewMerge(), push)
      outputResult = .needsAttention
      output = store.text("Review the staged merge result before continuing.", "请审查已暂存的合并结果，再继续合并。")
    }
  }
  private func confirmMergeContinuation(_ review: MergeReview, push: Bool) {
    let target = push ? conflictPush : nil
    confirmation = PendingAction(
      title: store.text(
        target == nil ? "Continue merge?" : "Continue merge and push?",
        target == nil ? "继续合并？" : "继续合并并推送？"),
      detail: store.text(
        "Create the merge commit from these staged files? Hooks and signing stay enabled. Unstaged edits are excluded.",
        "是否使用以下已暂存文件创建合并提交？Hooks 和签名仍有效，不包含未暂存修改。")
        + "\n\n"
        + (review.index.paths.isEmpty
          ? store.text("The merge keeps the current file tree.", "合并将保留当前文件树。")
          : review.index.paths.joined(separator: "\n"))
        + (target.map {
          "\n\n" + GitService.redact($0.remoteURL) + "\n" + review.index.branch + " → "
            + String($0.remoteReference.dropFirst("refs/heads/".count))
        } ?? ""),
      confirmTitle: store.text(
        target == nil ? "Continue Merge" : "Continue & Push", target == nil ? "继续合并" : "继续并推送"),
      destructive: false
    ) { [weak self] in self?.finishMerge(review, target: target) }
  }
  private func finishMerge(_ review: MergeReview, target: PushRejection?) {
    run(
      label: store.text(
        target == nil ? "Continuing merge" : "Continue Merge & Push",
        target == nil ? "继续合并" : "继续合并并推送"),
      completion: "", notify: true, kind: target == nil ? .merge : .mergeAndPush
    ) { [weak self] git in
      guard let self else { return }
      committing = true
      activity.advance(store.text("Creating merge commit", "创建合并提交"), cancellable: false)
      defer { committing = false }
      let commit = try await git.completeMerge(review)
      committing = false
      conflictPush = nil
      output = store.text("Merge completed: ", "合并已完成：") + String(commit.hash.prefix(8))
      if let target {
        conflictPush = target
        activity.advance(store.text("Pushing", "推送"), cancellable: true)
        do {
          let details = try await git.pushCompletedMerge(
            target, head: commit.hash, progress: activity.receiver())
          pushFailed = false
          conflictPush = nil
          needsUpstream = false
          output = store.text("Merge & push completed.", "合并并推送已完成。") + "\n" + details
        } catch let updated as PushRejection {
          conflictPush = nil
          queuePushRecovery(updated)
          output = store.text(
            "Merge commit saved; new remote commits need another merge before pushing.",
            "合并提交已保存；远程又有新提交，需要再次合并后推送。")
        } catch {
          pushFailed = true
          outputResult = .needsAttention
          output = store.text(
            "Merge commit saved; push did not complete. Retry Push sends the existing commit to the same destination.",
            "合并提交已保存，推送尚未完成。重试推送会将已有提交发送到同一目标。")
          if error is CancellationError {
            output = store.text(
              "Merge commit saved; push cancelled. Retry Push sends the existing commit to the same destination.",
              "合并提交已保存，推送已取消。重试推送会将已有提交发送到同一目标。")
          } else {
            self.error = error.localizedDescription
          }
        }
      }
    }
  }
  func retryPush() {
    guard let target = conflictPush, let head = status.head, status.operation == nil else {
      network("push")
      return
    }
    run(
      label: store.text("Pushing", "推送"), completion: store.text("Push completed.", "推送已完成。"),
      notify: true, kind: .push
    ) { [weak self] git in
      guard let self else { return }
      do {
        output = try await git.pushCompletedMerge(target, head: head, progress: activity.receiver())
        pushFailed = false
        conflictPush = nil
      } catch let updated as PushRejection {
        conflictPush = nil
        queuePushRecovery(updated)
        output = store.text(
          "New remote commits need to be merged before pushing.", "远程新提交需要合并后才能推送。")
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
  func confirmForcePush(remote: String) {
    guard !busy else { return }
    let id = UUID()
    confirmationReviewID = id
    confirmationReviewTask?.cancel()
    let branch = status.branch
    confirmationReviewTask = Task { [weak self] in
      guard let self else { return }
      do {
        let review = try await git().reviewForcePush(remote: remote, branch: branch)
        try Task.checkCancellation()
        guard confirmationReviewID == id, store.current === self, !store.showDashboard,
              page == "remotes", !busy else { return }
        guard status.head == review.localHead, status.branch == review.localBranch else {
          error = store.text("The repository changed. Refresh before reviewing Force with Lease.", "仓库已改变，请刷新后重新审查强制推送。")
          return
        }
        confirmation = PendingAction(
          title: store.text("Force Push with Lease?", "使用固定租约强制推送？"),
          detail: store.text("This rewrites remote history. Only the reviewed commit and remote lease will be used.",
                             "这会重写远程历史，仅使用已审查的本地提交与远程租约。")
            + "\n" + String(review.localHead.prefix(8)) + " → " + remote + "/" + branch
            + "\n" + store.text("Expected remote: ", "预期远程提交：")
            + (review.remoteHead.isEmpty ? store.text("branch must not exist", "分支必须不存在") : String(review.remoteHead.prefix(8)))) { [weak self] in
              self?.network("push", remote: remote, branch: branch, force: true, forceReview: review)
            }
      } catch {
        if !Task.isCancelled, confirmationReviewID == id { self.error = GitService.redact(error.localizedDescription) }
      }
    }
  }
  func confirmRemoteDeletion(remote: String, reference: String, expectedHash: String? = nil) {
    guard !busy else { return }
    let id = UUID()
    confirmationReviewID = id
    confirmationReviewTask?.cancel()
    let requestedPage = page
    confirmationReviewTask = Task { [weak self] in
      guard let self else { return }
      do {
        let review = try await git().reviewRemoteDeletion(remote: remote, reference: reference, expectedHash: expectedHash)
        try Task.checkCancellation()
        guard confirmationReviewID == id, store.current === self, !store.showDashboard,
          page == requestedPage, !busy else { return }
        confirmation = PendingAction(title: store.text("Delete remote reference?", "删除远程引用？"),
          detail: store.text("This removes the selected branch or tag from the reviewed server and affects collaborators. A fixed lease protects a changed remote version.",
                             "这会从已审查的服务器删除所选分支或标签，并影响协作者；固定租约将保护发生变化的远程版本。")
            + "\n\n" + remote + " · " + reference + " · " + String(review.expectedHash.prefix(8))) { [weak self] in
              self?.run { [weak self] git in self?.output = try await git.deleteRemoteReference(review) }
            }
      } catch {
        if !Task.isCancelled, confirmationReviewID == id { self.error = GitService.redact(error.localizedDescription) }
      }
    }
  }
  func perform(_ args: [String], confirmation detail: String? = nil) {
    guard !busy else { return }
    confirmationReviewID = UUID()
    confirmationReviewTask?.cancel()
    let action: (GitOperationReview?) -> Void = { [weak self] review in
      self?.run(kind: args.first == "rebase" ? .rebase : args.first == "merge" ? .merge : .git) { [weak self] git in
        self?.output = try await git.perform(args, expected: review)
        if args == ["merge", "--abort"] { self?.conflictPush = nil }
      }
    }
    guard let detail else { action(nil); return }
    let localRewrite = ["reset", "switch", "merge", "rebase", "cherry-pick", "revert"].contains(args.first ?? "")
    if !localRewrite {
      confirmation = PendingAction(title: store.text("Confirm Git operation", "确认 Git 操作"), detail: detail) { action(nil) }
      return
    }
    let id = UUID()
    confirmationReviewID = id
    confirmationReviewTask?.cancel()
    let requestedPage = page
    let expectedIndex = snapshot
    confirmationReviewTask = Task { [weak self] in
      guard let self else { return }
      do {
        let review = try await git().reviewOperation(expectedIndex: expectedIndex)
        try Task.checkCancellation()
        guard confirmationReviewID == id, store.current === self, !store.showDashboard,
              page == requestedPage, !busy else { return }
        guard status.head == review.head, status.branch == review.branch else {
          error = store.text("The repository changed. Refresh before confirming this operation.", "仓库已改变，请刷新后重新确认操作。")
          return
        }
        confirmation = PendingAction(title: store.text("Confirm Git operation", "确认 Git 操作"),
          detail: detail + "\n\n" + review.branch + " · " + String((review.head ?? "unborn").prefix(8))) { action(review) }
      } catch {
        if !Task.isCancelled, confirmationReviewID == id { self.error = GitService.redact(error.localizedDescription) }
      }
    }
  }
  func ensureHistory() async {
    let key = (status.head ?? "") + "\0" + (historyPath ?? "") + "\0" + (historyQuery?.identity ?? "")
    guard historyReadyKey != key else { return }
    await loadHistory(reset: true)
  }
  func cancelHistoryLoading() {
    historyGeneration += 1
    historyTask?.cancel()
    historyTask = nil
    historyLoading = false
  }
  func loadHistory(reset: Bool = false, path: String? = nil) async {
    let filter = path ?? historyPath
    let requestedQuery = historyQuery
    let headKey = (status.head ?? "") + "\0" + (filter ?? "") + "\0" + (requestedQuery?.identity ?? "")
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
    historyError = nil
    if reset {
      historyReadyKey = nil
      history = []
      historyGraph = [:]
      selectedHistoryCommit = nil
      historyHasMore = false
    }
    historyReadCount += 1
    let previous = reset ? [] : history
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        let records = try await git().history(skip: offset, path: filter, query: requestedQuery)
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
        if generation == historyGeneration, !Task.isCancelled { historyError = GitService.redact(error.localizedDescription) }
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
  func relocateWorktree(to path: String) async {
    // The manager has already protected this model's drafts and active terminal sessions.
    watcher?.stop(); watcher = nil
    activationTask?.cancel()
    if let activationTask { await activationTask.value }
    self.activationTask = nil
    refreshTask?.cancel()
    if let refreshTask { await refreshTask.value }
    refreshGeneration += 1
    refreshTask = nil; refreshing = false
    cancelHistoryLoading()
    diffTask?.cancel(); confirmationReviewTask?.cancel()
    confirmationReviewID = UUID(); confirmation = nil
    invalidateDiffCache()
    service = nil
    terminal.shutdown(); terminal = TerminalManager(root: path)
    record.path = path; store.update(record)
    historyReadyKey = nil; selectedHistoryCommit = nil
    available = false; snapshot = nil; error = nil
    await configure(); await configureWatcher(); await refresh()
  }
  func shutdown() {
    conflictEditor.shutdown()
    watcher?.stop()
    watcher = nil
    activationTask?.cancel()
    refreshTask?.cancel()
    activeTask?.cancel()
    confirmationReviewTask?.cancel()
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
  var confirmTitle: String? = nil
  var destructive = true
  var action: () -> Void
}

func copyText(_ text: String) {
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(text, forType: .string)
}
