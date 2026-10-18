import AppKit
import Combine
import GitPierCore

/// A workspace owns one coordinator across all windows. Drafts stay in memory;
/// only minimal write intent and receipt metadata enter the operation journal.
@MainActor final class HostingReviewSessionRegistry: ObservableObject {
  let coordinator: HostingReviewSubmissionCoordinator
  let journalURL: URL
  @Published var recoveredOperations: [HostingReviewOperationRecord] = []
  @Published var recoveryError: String?
  @Published var recoveryActionError: String?
  @Published var recovering = false
  @Published var recoveryEvidence: [UUID: String] = [:]
  var recoveryLifecycle = UUID()
  var recoveryTicket = UUID()
  init(journalURL: URL) {
    self.journalURL = journalURL
    coordinator = HostingReviewSubmissionCoordinator(journal: HostingReviewOperationJournal(root: journalURL))
  }
  private(set) var sessions: [String: HostingReviewSession] = [:]
  private var observations: [String: AnyCancellable] = [:]
  var pending: [HostingReviewSession] { sessions.values.filter(\.hasUnsavedContent).sorted { $0.displayName < $1.displayName } }
  func unfinished(accountID: UUID) -> [HostingReviewSession] { pending.filter { $0.account.id == accountID } }
  func disconnectAccount(_ id: UUID) {
    for key in Array(sessions.keys) where sessions[key]?.account.id == id {
      sessions[key]?.invalidateForDisconnect()
      observations[key] = nil; sessions[key] = nil
    }
    Task { [coordinator] in await coordinator.discardPrivateContent(accountID: id) }
    objectWillChange.send()
  }
  func session(hosting: HostingModel, binding: RepositoryHostingBinding, account: HostingAccount, request: HostingPullRequest) -> HostingReviewSession {
    if let value = sessions.values.first(where: { $0.hosting === hosting && $0.account == account && $0.binding == binding && $0.number == request.number }) { return value }
    let key = UUID().uuidString
    let value = HostingReviewSession(hosting: hosting, binding: binding, account: account, request: request, coordinator: coordinator)
    value.registry = self
    sessions[key] = value
    observations[key] = value.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    return value
  }
  func stop() {
    recoveryLifecycle = UUID()
    sessions.values.forEach { $0.invalidateForDisconnect() }
    sessions.removeAll(); observations.removeAll(); objectWillChange.send()
    Task { [coordinator] in await coordinator.discardPrivateContent() }
  }
  /// Keep is explicit: changing pages never silently discards or publishes a draft.
  func confirmNavigation(store: AppStore, session: HostingReviewSession?) -> Bool {
    guard let session, session.hasUnsavedContent else { return true }
    let alert = NSAlert()
    alert.messageText = store.text("Keep this review work?", "保留此审查状态？")
    alert.informativeText = session.displayName + "\n\n" + store.text("Keep drafts and unresolved results in memory while switching pages. They remain bound to this account, request and commit. Navigation does not publish drafts or resolve unknown results. A submission already sent may still complete.", "切换页面时将草稿与待核实结果保留在内存中，并继续绑定此账号、请求与提交版本。切换页面不会发布草稿，也不会消除未知结果；已经发送的提交仍可能完成。")
    alert.addButton(withTitle: store.text("Keep & Continue", "保留并继续"))
    alert.addButton(withTitle: store.text("Cancel", "取消"))
    if !session.submitting && session.hasPrivateDraftContent { alert.addButton(withTitle: store.text("Discard Draft & Continue", "丢弃草稿并继续")) }
    style(alert, store: store)
    switch alert.runModal() {
    case .alertFirstButtonReturn: return true
    case .alertThirdButtonReturn: session.discardDraft(); return true
    default: return false
    }
  }
  func confirmClose(store: AppStore, quitting: Bool) -> Bool {
    guard let alert = closeAlert(store: store, quitting: quitting) else { return true }
    return alert.runModal() == .alertFirstButtonReturn
  }
  /// Shared by the real close guard and native acceptance, including operations with no body.
  func closeAlert(store: AppStore, quitting: Bool) -> NSAlert? {
    let values = pending
    guard !values.isEmpty else { return nil }
    let alert = NSAlert()
    alert.messageText = store.text(quitting ? "Quit with review work to check?" : "Close with review work to check?", quitting ? "仍有审查状态需要核实，确定退出？" : "仍有审查状态需要核实，确定关闭？")
    alert.informativeText = store.text("Unpublished review bodies are held in memory and will be discarded. Minimal metadata for possibly sent operations remains in the local journal across restart. Closing does not prove that an unknown write failed. Check the platform before submitting again, including reviewer requests or discussion resolution.", "未发布的审查正文仅保存在内存中，关闭后将丢弃。可能已发送操作的最小元数据会保留在本机日志中，供重启后核实。关闭不能证明未知写入失败，再次提交前请核实平台，包括审查者请求与讨论解决操作。") + "\n\n" + values.map(\.displayName).joined(separator: "\n")
    let hasDrafts = values.contains { $0.hasPrivateDraftContent }
    alert.addButton(withTitle: hasDrafts ? store.text(quitting ? "Discard Drafts & Quit" : "Discard Drafts & Close", quitting ? "丢弃草稿并退出" : "丢弃草稿并关闭") : store.text(quitting ? "Quit Anyway" : "Close Anyway", quitting ? "仍然退出" : "仍然关闭"))
    alert.addButton(withTitle: store.text("Cancel", "取消"))
    style(alert, store: store)
    return alert
  }
  private func style(_ alert: NSAlert, store: AppStore) {
    alert.icon = AppResources.applicationIcon
    alert.window.appearance = store.settings.appearance == .system ? nil : NSAppearance(named: store.settings.appearance == .dark ? .darkAqua : .aqua)
    alert.buttons[0].keyEquivalent = ""; alert.buttons[1].keyEquivalent = "\r"
  }
}

@MainActor final class HostingReviewSession: ObservableObject {
  enum Status { case pendingSaved, submittedVerified }
  let id = UUID()
  enum Composer: Equatable {
    case comment
    case inline(HostingDiffAnchor)
    case reply(HostingReviewThread, HostingReviewComment)
  }
  struct InlineStartCandidate: Identifiable { let id: Int; let number: Int; let code: String }
  private struct InlineSelection { let file: HostingChangedFile; let document: DiffDocument; let endLineID: Int; let side: HostingReviewSide }
  let hosting: HostingModel
  let binding: RepositoryHostingBinding
  let account: HostingAccount
  let number: Int
  let request: HostingPullRequest
  let coordinator: HostingReviewSubmissionCoordinator
  weak var registry: HostingReviewSessionRegistry?
  @Published private(set) var context: HostingReviewContext?
  @Published var draft: HostingReviewDraft? { didSet { if oldValue?.comments != draft?.comments { rebuildCommentIndex() } } }
  @Published var composer: Composer?
  private var composerContext: HostingReviewContext?
  @Published var composerBody = ""
  @Published var editingComment: UUID?
  @Published private(set) var inlineStartCandidates: [InlineStartCandidate] = []
  @Published private(set) var inlineStartLineID: Int?
  private var inlineSelection: InlineSelection?
  private var inlineSources: [String: InlineSelection] = [:]
  @Published var confirmation: HostingReviewConfirmation?
  @Published private(set) var contextLoading = false
  @Published private(set) var contextError: String?
  @Published private(set) var threads: [HostingReviewSource: [HostingReviewThread]] = [:] { didSet { rebuildCommentIndex() } }
  @Published private(set) var states: [HostingReviewSource: HostingDetailLoadState] = [:]
  @Published private(set) var nextPages: [HostingReviewSource: Int] = [:]
  @Published private(set) var replyLoading: Set<String> = []
  @Published private(set) var replyErrors: [String: String] = [:]
  @Published private(set) var replyPages: [String: Int] = [:]
  @Published private(set) var replyLoaded: Set<String> = []
  @Published private(set) var submitting = false
  @Published private(set) var report: HostingReviewSubmissionReport?
  @Published private(set) var targetBlocked = false
  @Published private(set) var disconnected = false
  @Published var reviewersPresented = false
  @Published private(set) var reviewerCandidates: [HostingReviewer] = []
  @Published private(set) var existingReviewers: [HostingReviewer] = []
  @Published private(set) var reviewerNextPage: Int?
  @Published private(set) var reviewerLoading = false
  @Published private(set) var reviewerError: String?
  @Published private(set) var existingReviewersLoaded = false
  @Published private(set) var approvalRules: HostingApprovalRuleState?
  @Published private(set) var approvalRulesLoading = false
  @Published private(set) var approvalRulesError: String?
  private var approvalRulesTask: Task<Void, Never>?
  private var approvalRulesTicket: UUID?
  private var reviewerContext: HostingReviewContext?
  private var stagedReviewers: HostingReviewerSelection?
  private var reviewerTask: Task<Void, Never>?
  private var reviewerTicket: UUID?
  @Published var actionError: String?
  @Published private(set) var status: Status?
  private var contextTask: Task<Void, Never>?
  private var contextTicket: UUID?
  private var timelineRequested = false
  private var sourceTasks: [HostingReviewSource: Task<Void, Never>] = [:]
  private var sourceTickets: [HostingReviewSource: UUID] = [:]
  private var replyTasks: [String: Task<Void, Never>] = [:]
  private var replyTickets: [String: UUID] = [:]
  private var submissionTask: Task<Void, Never>?
  private var generation = UUID()
  private var readers: Set<UUID> = []
  private var draftConfirmations: [UUID: HostingReviewDraft] = [:]
  private struct ComposerSnapshot: Equatable {
    let context: HostingReviewContext
    let composer: Composer
    let body: String
    let editingComment: UUID?
    let draftID: UUID?
    let originalDraftComment: HostingReviewDraftComment?
  }
  private var composerConfirmations: [UUID: ComposerSnapshot] = [:]
  private struct CommentIndexKey: Hashable { let path: String; let sha: String }
  private struct CommentPositions { var old: [Int: Set<String>] = [:]; var new: [Int: Set<String>] = [:] }
  private struct CountKey: Hashable { let document: UUID; let path: String; let sha: String }
  private var commentIndex: [CommentIndexKey: CommentPositions] = [:]
  private var countCache: [CountKey: [Int: Int]] = [:]
  init(hosting: HostingModel, binding: RepositoryHostingBinding, account: HostingAccount, request: HostingPullRequest, coordinator: HostingReviewSubmissionCoordinator) {
    self.hosting = hosting; self.binding = binding; self.account = account; self.request = request; number = request.number; self.coordinator = coordinator
  }
  var displayName: String { account.instance.provider.title + " · @" + account.user.login + " · " + binding.repository + " #\(number)" }
  var hasPrivateDraftContent: Bool { draft?.hasContent == true || !composerBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  var hasUnresolvedResult: Bool { targetBlocked || report?.hasUnknown == true }
  var hasUnsavedContent: Bool { submitting || hasPrivateDraftContent || hasUnresolvedResult }
  var identityValid: Bool { !disconnected && hosting.account(account.id) == account && hosting.binding(binding.id) == binding }
  var outdated: Bool { if let draft, let context { return draft.context.target != context.target || draft.context.revision != context.revision }; return false }
  var canCompose: Bool { context != nil && identityValid && !submitting && !targetBlocked }
  var reviewBrowserExplanation: String? {
    guard account.instance.provider == .gitea else { return nil }
    return hosting.store.text("Submit Gitea reviews, approvals and pending reviews in the browser. The API can publish comments from another pending review belonging to this account, without a conditional update that isolates this confirmation. Ordinary issue comments, existing review replies and additive reviewer requests remain available when permitted.", "请在浏览器提交 Gitea 审查、批准与待定审查。其 API 可能同时发布此账号在其他客户端创建的待定审查评论，且没有条件更新机制隔离本次确认。具备权限时仍可发布普通 Issue 评论、回复既有审查及追加审查者。")
  }
  var orderedThreads: [HostingReviewThread] {
    threads.values.flatMap { $0 }.sorted { ($0.comments.first?.createdAt ?? "", $0.id) < ($1.comments.first?.createdAt ?? "", $1.id) }
  }
  /// Rebuilt only for remote thread changes or saved inline draft changes, never per keystroke.
  private func rebuildCommentIndex() {
    var index: [CommentIndexKey: CommentPositions] = [:]
    func add(path: String, sha: String, old: Int?, new: Int?, id: String) {
      let key = CommentIndexKey(path: path, sha: sha)
      if let old { index[key, default: CommentPositions()].old[old, default: []].insert(id) }
      if let new { index[key, default: CommentPositions()].new[new, default: []].insert(id) }
    }
    for thread in threads.values.flatMap({ $0 }) {
      for comment in thread.comments where !comment.outdated && !comment.path.isEmpty && (comment.kind == .inline || comment.kind == .reply) {
        add(path: comment.path, sha: comment.commitSHA, old: comment.oldLine, new: comment.newLine, id: "remote|" + comment.id)
        if let start = comment.startLine, let end = comment.newLine ?? comment.oldLine, start > 0, start < end, end - start < 200 {
          for number in start..<end { add(path: comment.path, sha: comment.commitSHA, old: comment.newLine == nil ? number : nil, new: comment.newLine != nil ? number : nil, id: "remote|" + comment.id) }
        }
      }
    }
    for comment in draft?.comments ?? [] {
      add(path: comment.anchor.path, sha: comment.anchor.revision.headSHA, old: comment.anchor.oldLine, new: comment.anchor.newLine, id: "draft|" + comment.id.uuidString)
      if let start = comment.anchor.startLine, let end = comment.anchor.side == .old ? comment.anchor.oldLine : comment.anchor.newLine, start < end, end - start < 200 {
        for number in start..<end { add(path: comment.anchor.path, sha: comment.anchor.revision.headSHA, old: comment.anchor.side == .old ? number : nil, new: comment.anchor.side == .new ? number : nil, id: "draft|" + comment.id.uuidString) }
      }
    }
    commentIndex = index; countCache = [:]
  }
  func lineCommentCounts(path: String, headSHA: String, document: DiffDocument) -> [Int: Int] {
    let key = CountKey(document: document.revision, path: path, sha: headSHA)
    if let cached = countCache[key] { return cached }
    let positions = [commentIndex[CommentIndexKey(path: path, sha: headSHA)], commentIndex[CommentIndexKey(path: path, sha: "")]].compactMap { $0 }
    var result: [Int: Int] = [:]
    for line in document.hunks.flatMap(\.lines) {
      var ids = Set<String>()
      for position in positions {
        if let old = line.oldNumber { ids.formUnion(position.old[old] ?? []) }
        if let new = line.newNumber { ids.formUnion(position.new[new] ?? []) }
      }
      if !ids.isEmpty { result[line.id] = ids.count }
    }
    if countCache.count >= 16 { countCache.removeAll() }
    countCache[key] = result; return result
  }
  func message(_ error: Error) -> String {
    if let journal = error as? HostingReviewJournalError {
      guard hosting.store.settings.language != .english else { return journal.localizedDescription }
      switch journal {
      case .unavailable: return "无法安全保存审查操作日志，新的写入已停止。请恢复磁盘访问后重试；可能已发送的操作仍需在平台核实。"
      case .corrupt: return "无法安全恢复审查操作日志。请保留原始文件并核实平台，修复日志后再提交。"
      case .unsupportedSchema: return "审查操作日志由不兼容的版本写入，新的审查写入已被阻止。"
      case .capacityReached: return "审查操作日志已满。请主动清理已完成记录；待核实记录必须保留。"
      }
    }
    guard let value = error as? HostingReviewError else { return hosting.message(error) }
    if hosting.store.settings.language == .english { return value.localizedDescription }
    switch value {
    case .targetChanged: return "账号或审查目标已变化，请重新打开目标请求。"
    case .revisionChanged: return "PR/MR 已更新，请刷新差异后重新确认评论位置。"
    case .requestClosed: return "此请求已关闭，无法提交审查。"
    case .permissionRequired: return "此操作需要额外的平台权限。请主动重新授权或替换 PAT。"
    case .invalidBody: return "请输入有效评论（最多 60,000 UTF-8 字节；每次审查最多 50 条逐行评论）。"
    case .unanchorable: return "当前文件无法安全定位逐行评论，请在浏览器中查看。"
    case .selfReview: return "平台不允许批准自己的请求或对其请求更改。"
    case .unsupported: return "此平台或实例不支持该审查操作。"
    case .resultUnknown, .readbackRequired: return "提交结果未知，草稿已保留。再次发布前请在平台核实。"
    case .alreadySubmitting: return "此审查正在提交，请勿重复提交。"
    case .alreadySubmitted: return "此确认内容已经发送。"
    case .partialSubmission: return "部分评论已发布，请先逐条核实结果。"
    }
  }
  private func validateIdentity() throws {
    guard identityValid else { throw HostingReviewError.targetChanged }
    try Task.checkCancellation()
  }
  private func apiCall<T: Sendable>(_ operation: @escaping @Sendable (HostingAPIClient, HostingToken) async throws -> T) async throws -> T {
    try validateIdentity()
    let token = try await hosting.tokens.token(for: account), api = hosting.api
    try validateIdentity()
    return try await hosting.performAPI(account: account) { try await operation(api, token) }
  }
  private func currentContext() async throws -> HostingReviewContext {
    let binding = binding, account = account, number = number
    return try await apiCall { try await $0.reviewContext(binding, number: number, account: account, token: $1) }
  }
  func start(loadTimeline: Bool = true, refresh: Bool = false) {
    timelineRequested = timelineRequested || loadTimeline
    guard contextTask == nil else { return }
    if refresh { stopReading() }
    let ticket = UUID(); contextTicket = ticket
    contextLoading = true; contextError = nil
    contextTask = Task {
      defer { if contextTicket == ticket { contextLoading = false; contextTask = nil; contextTicket = nil } }
      do {
        let value = try await currentContext(); try Task.checkCancellation()
        let blocked = await coordinator.isBlocked(value.target); try Task.checkCancellation()
        guard contextTicket == ticket else { return }
        let changed = context?.revision != nil && context?.revision != value.revision
        context = value; targetBlocked = blocked
        if draft == nil || (draft?.hasContent == false && !submitting) { draft = HostingReviewDraft(context: value) }
        if changed || refresh {
          generation = UUID()
          sourceTasks.values.forEach { $0.cancel() }; sourceTasks = [:]; sourceTickets = [:]
          replyTasks.values.forEach { $0.cancel() }; replyTasks = [:]; replyTickets = [:]; replyLoading = []
          threads = [:]; states = [:]; nextPages = [:]; replyPages = [:]; replyLoaded = []
          approvalRulesTicket = nil; approvalRulesTask?.cancel(); approvalRulesTask = nil; approvalRulesLoading = false; approvalRules = nil; approvalRulesError = nil
        }
        if timelineRequested { for source in HostingReviewSource.allCases { load(source, refresh: refresh) } }
      } catch is CancellationError {} catch { if contextTicket == ticket { contextError = message(error); await hosting.failed(error, account: account) } }
    }
  }
  func load(_ source: HostingReviewSource, more: Bool = false, refresh: Bool = false) {
    guard sourceTasks[source] == nil, let context, more || states[source]?.loaded != true else { return }
    let page = more ? nextPages[source] ?? 1 : 1, ticket = generation, sourceTicket = UUID()
    sourceTickets[source] = sourceTicket
    var state = states[source] ?? HostingDetailLoadState(); state.loading = true; state.error = nil; states[source] = state
    let binding = binding, account = account, number = number
    sourceTasks[source] = Task {
      defer { if generation == ticket && sourceTickets[source] == sourceTicket { sourceTasks[source] = nil; states[source]?.loading = false } }
      do {
        try validateIdentity()
        let revision = context.revision
        let key = HostingRequestDetailCache.Key(account: account, binding: binding, request: request, section: .reviews,
          page: "timeline|\(source.rawValue)|\(page)|\(revision.headSHA)|\(revision.baseSHA)|\(revision.startSHA)|\(revision.diffID)")
        let cached = try await hosting.detailCache.value(for: key, refresh: refresh) {
          .threads(try await self.apiCall { try await $0.reviewTimeline(binding, number: number, account: account, token: $1, source: source, page: page) })
        }
        try validateIdentity()
        guard case .threads(let value) = cached else { throw HostingError.invalidResponse }
        try Task.checkCancellation(); guard generation == ticket, sourceTickets[source] == sourceTicket else { return }
        var values = more ? threads[source] ?? [] : []
        for thread in value.items {
          if let index = values.firstIndex(where: { $0.id == thread.id }) { values[index].append(thread.comments) }
          else { values.append(thread) }
        }
        threads[source] = values; nextPages[source] = value.nextPage; states[source]?.loaded = true
      } catch is CancellationError {} catch { if generation == ticket && sourceTickets[source] == sourceTicket { states[source]?.error = error as? HostingError ?? .networkFailure; await hosting.failed(error, account: account) } }
    }
  }
  func loadReplies(_ thread: HostingReviewThread) {
    guard replyTasks[thread.id] == nil else { return }
    let page = replyPages[thread.id] ?? 1, ticket = generation, replyTicket = UUID()
    replyTickets[thread.id] = replyTicket
    let binding = binding, account = account, number = number
    replyLoading.insert(thread.id); replyErrors[thread.id] = nil
    replyTasks[thread.id] = Task {
      defer { if generation == ticket && replyTickets[thread.id] == replyTicket { replyTasks[thread.id] = nil; replyLoading.remove(thread.id) } }
      do {
        let result = try await apiCall { try await $0.reviewReplies(binding, number: number, thread: thread, account: account, token: $1, page: page) }
        try Task.checkCancellation(); guard generation == ticket, replyTickets[thread.id] == replyTicket else { return }
        if let index = threads[thread.source]?.firstIndex(where: { $0.id == thread.id }) { threads[thread.source]?[index].append(result.items) }
        replyPages[thread.id] = result.nextPage
        replyLoaded.insert(thread.id)
      } catch is CancellationError {} catch { if generation == ticket && replyTickets[thread.id] == replyTicket { replyErrors[thread.id] = message(error) } }
    }
  }
  func stopReading() {
    generation = UUID(); contextTicket = nil; contextTask?.cancel(); contextTask = nil; contextLoading = false
    sourceTasks.values.forEach { $0.cancel() }; sourceTasks = [:]; sourceTickets = [:]
    for key in states.keys { states[key]?.loading = false }
    replyTasks.values.forEach { $0.cancel() }; replyTasks = [:]; replyTickets = [:]; replyLoading = []
    reviewerTicket = nil; reviewerTask?.cancel(); reviewerTask = nil; reviewerLoading = false
    approvalRulesTicket = nil; approvalRulesTask?.cancel(); approvalRulesTask = nil; approvalRulesLoading = false
  }
  /// Called synchronously once disconnect has been explicitly confirmed across windows.
  /// A late HTTP response may update the durable coordinator, but cannot restore private UI state.
  func invalidateForDisconnect() {
    disconnected = true; stopReading(); cancelSubmission()
    composer = nil; composerBody = ""; composerContext = nil; editingComment = nil
    draft = nil; confirmation = nil; draftConfirmations = [:]; composerConfirmations = [:]
    inlineSelection = nil; inlineSources = [:]; inlineStartCandidates = []; inlineStartLineID = nil
    stagedReviewers = nil; reviewerContext = nil; reviewersPresented = false
    threads = [:]; report = nil; status = nil; targetBlocked = true
  }
  func attach(_ reader: UUID) { readers.insert(reader) }
  func detach(_ reader: UUID) { readers.remove(reader); if readers.isEmpty { stopReading() } }
  func begin(_ value: Composer) {
    guard canCompose else { return }
    if !composerBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, composer != value {
      actionError = hosting.store.text("Finish or cancel the current comment first.", "请先完成或取消当前评论。 "); return
    }
    composer = value; composerContext = context; actionError = nil
  }
  func beginInline(file: HostingChangedFile, document: DiffDocument, line: DiffLine, side: HostingReviewSide) {
    guard let context else { start(loadTimeline: false); return }
    do {
      let anchor = try HostingDiffAnchor.make(context: context, file: file, document: document, lineID: line.id, side: side)
      begin(.inline(anchor))
      guard composer == .inline(anchor) else { return }
      let selection = InlineSelection(file: file, document: document, endLineID: line.id, side: side)
      inlineSources[sourceKey(anchor)] = selection; configureInlineSelection(selection, anchor: anchor)
    }
    catch { actionError = message(error) }
  }
  private func sourceKey(_ anchor: HostingDiffAnchor) -> String { anchor.patchID + "|" + anchor.path + "|" + anchor.hunkID + "|" + anchor.side.rawValue }
  private func configureInlineSelection(_ selection: InlineSelection?, anchor: HostingDiffAnchor) {
    inlineSelection = selection; inlineStartCandidates = []; inlineStartLineID = nil
    guard let selection, context?.capabilities.contains(.multiLineComment) == true,
      let hunk = selection.document.hunks.first(where: { $0.lines.contains { $0.id == selection.endLineID } }),
      let end = hunk.lines.first(where: { $0.id == selection.endLineID }), let last = selection.side == .old ? end.oldNumber : end.newNumber else { return }
    inlineStartCandidates = hunk.lines.compactMap { line in
      guard let number = selection.side == .old ? line.oldNumber : line.newNumber,
        number <= last, last - number < 200 else { return nil }
      return InlineStartCandidate(id: line.id, number: number, code: line.text)
    }
    inlineStartLineID = inlineStartCandidates.first(where: { $0.number == (anchor.startLine ?? last) })?.id
  }
  func selectInlineStartLine(_ id: Int) {
    guard let context = composerContext, let selection = inlineSelection, inlineStartCandidates.contains(where: { $0.id == id }) else { return }
    do {
      let anchor = id == selection.endLineID
        ? try HostingDiffAnchor.make(context: context, file: selection.file, document: selection.document, lineID: selection.endLineID, side: selection.side)
        : try HostingDiffAnchor.makeRange(context: context, file: selection.file, document: selection.document, startLineID: id, endLineID: selection.endLineID, side: selection.side)
      composer = .inline(anchor); inlineStartLineID = id; actionError = nil
    } catch { actionError = message(error) }
  }
  func saveInlineDraft() {
    guard case .inline(let anchor) = composer, let context else { return }
    do {
      try HostingReviewMutation.inline(body: composerBody, anchor: anchor).validate(context: context)
      if draft == nil { draft = HostingReviewDraft(context: context) }
      guard draft?.context == context else { throw HostingReviewError.revisionChanged }
      if let editingComment, let i = draft?.comments.firstIndex(where: { $0.id == editingComment }) { draft?.comments[i] = HostingReviewDraftComment(id: editingComment, body: composerBody, anchor: anchor) }
      else { draft?.comments.append(HostingReviewDraftComment(body: composerBody, anchor: anchor)) }
      composer = nil; composerBody = ""; editingComment = nil; actionError = nil
    } catch { actionError = message(error) }
  }
  func edit(_ comment: HostingReviewDraftComment) {
    composer = .inline(comment.anchor); composerContext = draft?.context; composerBody = comment.body; editingComment = comment.id
    configureInlineSelection(inlineSources[sourceKey(comment.anchor)], anchor: comment.anchor)
  }
  func discardDraft() {
    guard !submitting else { return }
    composer = nil; composerBody = ""; composerContext = nil; editingComment = nil; confirmation = nil
    draftConfirmations = [:]; composerConfirmations = [:]
    inlineSelection = nil; inlineSources = [:]; inlineStartCandidates = []; inlineStartLineID = nil
    draft = context.map { HostingReviewDraft(context: $0) }; actionError = nil
  }
  func prepareComposer() {
    guard let context = composerContext, let composer else { return }
    let mutation: HostingReviewMutation
    switch composer {
    case .comment: mutation = .comment(body: composerBody)
    case .inline(let anchor): mutation = .inline(body: composerBody, anchor: anchor)
    case .reply(let thread, let comment): mutation = .reply(threadID: thread.remoteID, commentID: account.instance.provider == .github ? thread.remoteID : comment.id, body: composerBody)
    }
    do {
      confirmation = try HostingReviewConfirmation(context: context, items: [HostingReviewSubmissionItem(mutation: mutation)])
      if let confirmation {
        composerConfirmations[confirmation.id] = ComposerSnapshot(context: context, composer: composer, body: composerBody,
          editingComment: editingComment, draftID: draft?.id, originalDraftComment: draft?.comments.first { $0.id == editingComment })
      }
      actionError = nil
    }
    catch { actionError = message(error) }
  }
  func prepareDraft(pending: Bool = false) {
    guard let draft else { return }
    do {
      if pending {
        confirmation = try HostingReviewConfirmation(context: draft.context, items: [HostingReviewSubmissionItem(mutation: .review(summary: draft.summary, decision: .comment, comments: draft.comments, pending: true))])
      } else { confirmation = try .draft(draft) }
      if let confirmation { draftConfirmations[confirmation.id] = draft }
      actionError = nil
    } catch { actionError = message(error) }
  }
  func preparePending(_ thread: HostingReviewThread) {
    guard let context else { return }
    let localSummary = draft?.summary ?? ""
    let summary: String
    if !localSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { summary = localSummary }
    else if let original = thread.comments.first(where: { $0.kind == .summary }) { summary = original.body }
    else {
      actionError = hosting.store.text("The pending review summary is unavailable. Refresh Reviews before confirming its submission.", "无法读取待定审查的原总结，请刷新审查后再确认提交。")
      return
    }
    do {
      confirmation = try HostingReviewConfirmation(context: context, items: [HostingReviewSubmissionItem(mutation: .submitPending(reviewID: thread.remoteID, summary: summary, decision: draft?.decision ?? .comment))])
      if let confirmation, let draft { draftConfirmations[confirmation.id] = draft }
    }
    catch { actionError = message(error) }
  }
  func prepareResolution(_ thread: HostingReviewThread, resolved: Bool) {
    guard let context, thread.canResolve, thread.resolved != nil else { return }
    do { confirmation = try HostingReviewConfirmation(context: context, items: [HostingReviewSubmissionItem(mutation: .resolve(threadID: thread.remoteID, resolved: resolved))]); actionError = nil }
    catch { actionError = message(error) }
  }
  func beginReviewers() {
    guard canCompose, context?.capabilities.contains(.requestReviewers) == true else { return }
    reviewersPresented = true; reviewerCandidates = []; existingReviewers = []; existingReviewersLoaded = false; reviewerNextPage = nil; stagedReviewers = nil
    loadReviewers(more: false)
  }
  func loadExistingReviewers() { loadReviewers(more: false, candidates: false) }
  func loadReviewers(more: Bool, candidates: Bool = true) {
    guard reviewerTask == nil else { return }
    let id = UUID(); reviewerTicket = id; reviewerLoading = true; reviewerError = nil
    let binding = binding, account = account, number = number
    reviewerTask = Task {
      defer { if reviewerTicket == id { reviewerTask = nil; reviewerLoading = false } }
      do {
        let fresh = try await currentContext()
        if candidates {
          if let original = context { try original.validateCurrent(fresh) }
          guard fresh.capabilities.contains(.requestReviewers) else { throw HostingReviewError.permissionRequired }
        } else if let original = context, original.target != fresh.target { throw HostingReviewError.targetChanged }
        if !more {
          var existing: [HostingReviewer] = [], page = 1
          while page <= 20 {
            let currentPage = page
            let result = try await apiCall { try await $0.requestedReviewers(binding, number: number, account: account, token: $1, page: currentPage) }
            try Task.checkCancellation(); guard reviewerTicket == id else { return }
            for user in result.items where !existing.contains(where: { $0.id == user.id }) { existing.append(user) }
            guard let next = result.nextPage, next > page else { break }
            guard page < 20 else { throw HostingError.responseTooLarge }; page = next
          }
          existingReviewers = existing; existingReviewersLoaded = true; reviewerContext = fresh
        }
        guard candidates else { return }
        let page = more ? reviewerNextPage ?? 1 : 1
        let result = try await apiCall { try await $0.reviewerCandidates(binding, context: fresh, account: account, token: $1, page: page) }
        try Task.checkCancellation(); guard reviewerTicket == id else { return }
        var values = more ? reviewerCandidates : []
        for user in result.items { if let i = values.firstIndex(where: { $0.id == user.id }) { values[i] = user } else { values.append(user) } }
        reviewerCandidates = values; reviewerNextPage = result.nextPage
      } catch is CancellationError {} catch { if reviewerTicket == id { reviewerError = message(error) } }
    }
  }
  func loadApprovalRules() {
    guard account.instance.provider == .gitlab, approvalRulesTask == nil else { return }
    let id = UUID(); approvalRulesTicket = id; approvalRulesLoading = true; approvalRulesError = nil
    let binding = binding, account = account, number = number
    approvalRulesTask = Task {
      defer { if approvalRulesTicket == id { approvalRulesTask = nil; approvalRulesLoading = false } }
      do {
        let value = try await apiCall { try await $0.approvalRules(binding, number: number, account: account, token: $1) }
        try Task.checkCancellation(); guard approvalRulesTicket == id else { return }
        approvalRules = value
      } catch is CancellationError {} catch { if approvalRulesTicket == id { approvalRulesError = message(error) } }
    }
  }
  func stageReviewers(_ users: [HostingReviewer]) {
    guard let context = reviewerContext, !reviewerLoading else { return }
    do {
      let selection = HostingReviewerSelection(context: context, reviewers: users, existingReviewers: existingReviewers)
      try selection.validate(context: context)
      stagedReviewers = selection; reviewersPresented = false
    } catch { reviewerError = message(error) }
  }
  func prepareStagedReviewers() {
    reviewerTicket = nil; reviewerTask?.cancel(); reviewerTask = nil; reviewerLoading = false
    guard let selection = stagedReviewers, let context = reviewerContext else { return }
    stagedReviewers = nil
    do { confirmation = try HostingReviewConfirmation(context: context, items: [HostingReviewSubmissionItem(mutation: .requestReviewers(selection))]); actionError = nil }
    catch { actionError = message(error) }
  }
  private func validateAnchor(_ anchor: HostingDiffAnchor) async throws {
    let binding = binding, account = account, number = number
    var page = 1
    while page <= 100 {
      try validateIdentity()
      let currentPage = page
      let files = try await apiCall { try await $0.files(binding, number: number, account: account, token: $1, page: currentPage) }
      if var file = files.items.first(where: { $0.path == anchor.path }) {
        if file.patch == nil, account.instance.provider == .gitea {
          let original = file
          let patch = try await apiCall { try await $0.giteaPatch(binding, number: number, file: original, account: account, token: $1) }
          file = HostingChangedFile(path: file.path, oldPath: file.oldPath, kind: file.kind, patch: patch)
        }
        guard let patch = file.patch else { throw HostingReviewError.unanchorable }
        let fresh = try await currentContext()
        try anchor.validate(context: fresh, file: file, document: DiffParser.parse(Data(patch.utf8))); return
      }
      guard let next = files.nextPage, next > page else { break }; page = next
    }
    throw HostingReviewError.unanchorable
  }
  private func readback(_ receipt: HostingReviewReceipt, mutation: HostingReviewMutation, context: HostingReviewContext) async throws -> HostingReviewReceipt {
    let account = account
    return try await apiCall { try await $0.readReviewReceipt(receipt, mutation: mutation, context: context, account: account, token: $1) }
  }
  private func send(_ mutation: HostingReviewMutation, context: HostingReviewContext) async throws -> HostingReviewReceipt {
    try validateIdentity()
    let token = try await hosting.tokens.token(for: account), api = hosting.api, account = account
    try validateIdentity()
    return try await hosting.performReviewWrite(account: account) {
      try await api.performReviewMutation(mutation, context: context, account: account, token: token)
    }
  }
  func submit(_ snapshot: HostingReviewConfirmation) {
    guard identityValid, !submitting else { return }
    submitting = true; confirmation = nil; actionError = nil; status = nil
    submissionTask = Task {
      defer { submitting = false; submissionTask = nil; Task { [weak registry] in await registry?.refreshRecovery() } }
      guard identityValid else { return }
      do {
        let result = try await coordinator.submit(snapshot,
          current: { try await self.currentContext() }, validate: { try await self.validateIdentity() },
          validateAnchor: { try await self.validateAnchor($0) },
          send: { try await self.send($0, context: $1) },
          readback: { try await self.readback($0, mutation: $1, context: $2) })
        guard identityValid else { return }
        apply(result, confirmation: snapshot)
      } catch {
        guard identityValid else { return }
        if error as? HostingReviewError == .resultUnknown { targetBlocked = true }
        actionError = message(error)
      }
    }
  }
  private func apply(_ result: HostingReviewSubmissionReport, confirmation snapshot: HostingReviewConfirmation?) {
    report = result; targetBlocked = result.hasUnknown
    let submittedDraft = draftConfirmations[result.confirmationID]
    let sameDraft = submittedDraft != nil && draft?.id == submittedDraft?.id && draft?.context == submittedDraft?.context
    let submittedComposer = composerConfirmations[result.confirmationID]
    for item in result.results {
      guard case .submitted = item.outcome else { continue }
      switch item.mutation {
      case .inline(let body, let anchor):
        if sameDraft, submittedDraft?.comments.contains(where: { $0.id == item.id && $0.body == body && $0.anchor == anchor }) == true {
          draft?.comments.removeAll { $0.id == item.id && $0.body == body && $0.anchor == anchor }
        }
        // Directly submitting an edited saved comment consumes only its unchanged source draft.
        if let saved = submittedComposer?.originalDraftComment, draft?.id == submittedComposer?.draftID,
          draft?.context == submittedComposer?.context {
          draft?.comments.removeAll { $0 == saved }
        }
      case .review(let summary, let decision, let comments, let pending):
        if pending { status = .pendingSaved }
        if sameDraft {
          draft?.comments.removeAll { comments.contains($0) }
          if draft?.summary == summary { draft?.summary = "" }
          if !pending && submittedDraft?.decision == decision && draft?.decision == decision { draft?.decision = .comment }
        }
      case .comment(let body): if sameDraft, draft?.summary == body { draft?.summary = "" }
      case .submitPending(_, let summary, let decision):
        if sameDraft {
          if draft?.summary == summary { draft?.summary = "" }
          if submittedDraft?.decision == decision && draft?.decision == decision { draft?.decision = .comment }
        }
      case .resolve(let remoteID, let resolved):
        for source in HostingReviewSource.allCases {
          if let i = threads[source]?.firstIndex(where: { $0.remoteID == remoteID }), let old = threads[source]?[i] {
            threads[source]?[i] = HostingReviewThread(id: old.id, remoteID: old.remoteID, source: old.source, comments: old.comments,
              state: old.state, resolved: resolved, canResolve: old.canResolve, hasMoreReplies: old.hasMoreReplies)
          }
        }
      case .requestReviewers(let selection):
        var values = existingReviewers
        for user in selection.reviewers where !values.contains(where: { $0.id == user.id }) { values.append(user) }
        existingReviewers = values
        existingReviewersLoaded = false; loadExistingReviewers()
      default: break
      }
    }
    if result.complete {
      if let saved = submittedComposer, composerContext == saved.context, composer == saved.composer,
        composerBody == saved.body, editingComment == saved.editingComment {
        composer = nil; composerBody = ""; editingComment = nil
        inlineSelection = nil; inlineStartCandidates = []; inlineStartLineID = nil
      }
      draftConfirmations[result.confirmationID] = nil; composerConfirmations[result.confirmationID] = nil
      status = status ?? .submittedVerified
    } else if result.hasUnknown { actionError = message(HostingReviewError.resultUnknown) }
    else if result.submittedCount > 0 { actionError = message(HostingReviewError.partialSubmission) }
    else if let failure = result.results.compactMap({ result -> HostingReviewSubmissionFailure? in if case .failed(let failure) = result.outcome { failure } else { nil } }).first {
      switch failure { case .review(let value): actionError = message(value); case .hosting(let value): actionError = message(value); case .journal(let value): actionError = message(value); case .cancelled: actionError = hosting.store.text("Cancelled before sending. Draft preserved.", "发送前已取消，草稿已保留。") }
    }
    // Invalidate the affected remote modules only. No Git refresh, Fetch or workspace scan.
    if result.submittedCount > 0 {
      Task {
        await hosting.detailCache.invalidate(account: account, binding: binding, number: number)
        var sources = Set<HostingReviewSource>()
        for result in result.results {
          guard case .submitted = result.outcome else { continue }
          switch result.mutation {
          case .comment: sources.insert(.conversation)
          case .inline: sources.insert(.inline)
          case .reply(let remoteID, _, _):
            if let thread = orderedThreads.first(where: { $0.remoteID == remoteID }) { replyPages[thread.id] = nil; loadReplies(thread) }
          case .review(_, _, let comments, _): sources.insert(.reviews); if !comments.isEmpty { sources.insert(.inline) }
          case .submitPending: sources.formUnion([.reviews, .inline])
          case .resolve: break // The receipt already verified this exact thread's resolved field.
          case .requestReviewers: break
          }
        }
        for source in sources { states[source]?.loaded = false; load(source, refresh: true) }
      }
    }
  }
  func reconcile() {
    guard let report, !submitting else { return }
    submitting = true
    submissionTask = Task {
      defer { submitting = false; submissionTask = nil; Task { [weak registry] in await registry?.refreshRecovery() } }
      do {
        let result = try await coordinator.reconcile(report.confirmationID, validate: { try await self.validateIdentity() }, readback: { try await self.readback($0, mutation: $1, context: $2) })
        guard identityValid else { return }
        apply(result, confirmation: nil)
      } catch { if identityValid { actionError = message(error) } }
    }
  }
  func acknowledgePlatformCheck() {
    guard let context, !submitting else { return }
    Task {
      defer { Task { [weak registry] in await registry?.refreshRecovery() } }
      do {
        try await coordinator.acknowledgePlatformCheck(context.target)
        let blocked = await coordinator.isBlocked(context.target)
        guard self.context?.target == context.target, identityValid else { return }
        targetBlocked = blocked
        if blocked { actionError = message(HostingReviewError.resultUnknown) }
        else { report = nil; actionError = nil }
      } catch { if identityValid { actionError = message(error) } }
    }
  }
  func cancelSubmission() { submissionTask?.cancel() }
  func refreshBlockState() async {
    guard let context else { return }
    let blocked = await coordinator.isBlocked(context.target)
    guard self.context?.target == context.target else { return }
    targetBlocked = disconnected || blocked
  }
}
