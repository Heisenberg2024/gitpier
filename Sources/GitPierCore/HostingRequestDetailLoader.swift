import Foundation
import Observation

public enum HostingDetailSection: String, Hashable, Sendable {
  case overview, commits, files, reviews, comments, conversations, checks
}

public struct HostingDetailLoadState: Sendable {
  public var loading = false
  public var loaded = false
  public var error: HostingError?
  public init() {}
}

public enum HostingDetailValue: Sendable {
  case overview(HostingPullRequest)
  case commits(HostingPage<HostingCommit>)
  case files(HostingPage<HostingChangedFile>)
  case reviews(HostingPage<HostingReview>)
  case threads(HostingPage<HostingReviewThread>)
  case checks(HostingChecksPage)
}

/// Memory only. Each page is isolated by account, instance, repository and request revision.
/// Cancelling the last reader, disconnecting, or clearing credentials also cancels its HTTP task.
public actor HostingRequestDetailCache {
  public struct Key: Hashable, Sendable {
    let accountID: UUID
    let repository: String
    let requestNumber: Int
    let section: HostingDetailSection
    let value: String
    public init(account: HostingAccount, binding: RepositoryHostingBinding, request: HostingPullRequest,
      section: HostingDetailSection, page: String) {
      accountID = account.id
      repository = binding.repository; requestNumber = request.number; self.section = section
      value = account.identity + "|" + account.id.uuidString + "|" + binding.repository + "|\(request.number)|" + request.sha + "|" + request.updatedAt + "|" + section.rawValue + "|" + page
    }
  }
  private struct Entry { let expires: Date; let value: HostingDetailValue }
  private struct Flight { let id: UUID; let task: Task<HostingDetailValue, Error>; var readers: Set<UUID> }
  private var entries: [Key: Entry] = [:]
  private var flights: [Key: Flight] = [:]
  private let lifetime: TimeInterval
  public init(lifetime: TimeInterval = 60) { self.lifetime = lifetime }
  public func value(for key: Key, refresh: Bool = false,
    load: @escaping @Sendable () async throws -> HostingDetailValue) async throws -> HostingDetailValue {
    try Task.checkCancellation()
    if !refresh, let entry = entries[key], entry.expires > Date() { return entry.value }
    let reader = UUID()
    if var flight = flights[key] { flight.readers.insert(reader); flights[key] = flight }
    else { flights[key] = Flight(id: UUID(), task: Task { try Task.checkCancellation(); return try await load() }, readers: [reader]) }
    let flight = flights[key]!
    return try await withTaskCancellationHandler {
      do {
        let value = try await flight.task.value
        try Task.checkCancellation()
        guard flights[key]?.id == flight.id else { throw CancellationError() }
        if entries.count >= 200 { entries.removeAll() }
        entries[key] = Entry(expires: Date().addingTimeInterval(lifetime), value: value)
        remove(reader: reader, key: key, flight: flight.id)
        return value
      } catch { remove(reader: reader, key: key, flight: flight.id); throw error }
    } onCancel: { Task { await self.cancel(reader: reader, key: key, flight: flight.id) } }
  }
  private func remove(reader: UUID, key: Key, flight id: UUID) {
    guard var flight = flights[key], flight.id == id else { return }
    flight.readers.remove(reader)
    if flight.readers.isEmpty { flights[key] = nil } else { flights[key] = flight }
  }
  private func cancel(reader: UUID, key: Key, flight id: UUID) {
    guard let flight = flights[key], flight.id == id else { return }
    remove(reader: reader, key: key, flight: id)
    if flights[key] == nil { flight.task.cancel() }
  }
  public func clear(account: HostingAccount) {
    entries = entries.filter { $0.key.accountID != account.id }
    for (key, flight) in flights where key.accountID == account.id { flight.task.cancel(); flights[key] = nil }
  }
  /// Review writes invalidate only their remote target, including any in-flight stale pages.
  public func invalidate(account: HostingAccount, binding: RepositoryHostingBinding, number: Int,
    sections: Set<HostingDetailSection> = [.overview, .reviews, .comments, .conversations]) {
    func matches(_ key: Key) -> Bool {
      key.accountID == account.id && key.repository == binding.repository && key.requestNumber == number && sections.contains(key.section)
    }
    entries = entries.filter { !matches($0.key) }
    for (key, flight) in flights where matches(key) { flight.task.cancel(); flights[key] = nil }
  }
}

/// The selected module starts only its first page. Overview always renders the supplied list
/// snapshot immediately; its refresh and every module have independent tasks, errors and retries.
@Observable @MainActor public final class HostingRequestDetailLoader {
  public private(set) var detail: HostingPullRequest
  public private(set) var commits: [HostingCommit] = []
  public private(set) var files: [HostingChangedFile] = []
  public private(set) var reviews: [HostingReview] = []
  public private(set) var comments: [HostingReview] = []
  public private(set) var conversations: [HostingReview] = []
  public private(set) var checks: [HostingCheck] = []
  public private(set) var states: [HostingDetailSection: HostingDetailLoadState] = [:]
  public private(set) var nextPages: [HostingDetailSection: Int] = [:]
  public private(set) var nextChecks: HostingChecksCursor?
  @ObservationIgnored private let api: HostingAPIClient
  @ObservationIgnored private let cache: HostingRequestDetailCache
  @ObservationIgnored private let account: HostingAccount
  @ObservationIgnored private let binding: RepositoryHostingBinding
  @ObservationIgnored private let token: @Sendable () async throws -> HostingToken
  @ObservationIgnored private let validate: @Sendable () async throws -> Void
  @ObservationIgnored private let failed: @Sendable (HostingError) async -> Void
  @ObservationIgnored private var tasks: [HostingDetailSection: Task<Void, Never>] = [:]
  @ObservationIgnored private var generations: [HostingDetailSection: UUID] = [:]
  @ObservationIgnored private var retryMore: [HostingDetailSection: Bool] = [:]
  @ObservationIgnored private var initialChecksPending = false
  @ObservationIgnored private var selected: HostingDetailSection = .overview
  public init(request: HostingPullRequest, binding: RepositoryHostingBinding, account: HostingAccount,
    api: HostingAPIClient, cache: HostingRequestDetailCache,
    token: @escaping @Sendable () async throws -> HostingToken,
    validate: @escaping @Sendable () async throws -> Void = {},
    failed: @escaping @Sendable (HostingError) async -> Void = { _ in }) {
    detail = request; self.binding = binding; self.account = account; self.api = api; self.cache = cache
    self.token = token; self.validate = validate; self.failed = failed
  }
  public func state(_ section: HostingDetailSection) -> HostingDetailLoadState { states[section] ?? HostingDetailLoadState() }
  public func select(_ section: HostingDetailSection) {
    selected = section
    let visible: Set<HostingDetailSection> = section == .reviews ? [.overview, .reviews, .comments, .conversations] : [.overview, section]
    for key in Array(tasks.keys) where !visible.contains(key) { cancel(key) }
    if !state(.overview).loaded && state(.overview).error == nil { load(.overview) }
    if !state(section).loaded && state(section).error == nil { load(section) }
    if section == .reviews, !state(.comments).loaded && state(.comments).error == nil { load(.comments) }
    if section == .reviews, account.instance.provider == .github, !state(.conversations).loaded && state(.conversations).error == nil { load(.conversations) }
    if section == .checks { loadInitialChecksIfNeeded() }
  }
  public func loadMore(_ section: HostingDetailSection) { load(section, more: true) }
  public func retry(_ section: HostingDetailSection) { load(section, more: retryMore[section] ?? false, refresh: true) }
  public func cancelAll() { for section in Array(tasks.keys) { cancel(section) } }
  private func cancel(_ section: HostingDetailSection) {
    generations[section] = UUID(); tasks.removeValue(forKey: section)?.cancel(); states[section]?.loading = false
  }
  private func load(_ section: HostingDetailSection, more: Bool = false, refresh: Bool = false) {
    guard tasks[section] == nil else { return }
    if more, section == .checks ? nextChecks == nil : nextPages[section] == nil { return }
    let page = more ? nextPages[section] ?? 1 : 1
    let cursor = more ? nextChecks ?? HostingChecksCursor() : HostingChecksCursor()
    let seed = detail, ticket = UUID(); generations[section] = ticket
    var state = self.state(section); state.loading = true; state.error = nil; states[section] = state
    let account = account, binding = binding, api = api, cache = cache, token = token, validate = validate
    let key = HostingRequestDetailCache.Key(account: account, binding: binding, request: seed, section: section,
      page: section == .checks ? cursor.cacheKey : String(page))
    tasks[section] = Task {
      var applied = false
      do {
        try await validate()
        let value = try await cache.value(for: key, refresh: refresh) {
          let secret = try await token(); try Task.checkCancellation(); try await validate()
          let value: HostingDetailValue
          switch section {
          case .overview: value = .overview(try await api.request(binding, number: seed.number, account: account, token: secret))
          case .commits: value = .commits(try await api.commits(binding, number: seed.number, account: account, token: secret, page: page))
          case .files: value = .files(try await api.files(binding, number: seed.number, account: account, token: secret, page: page))
          case .reviews, .comments: value = .reviews(try await api.reviews(binding, number: seed.number, account: account, token: secret, comments: section == .comments, page: page))
          case .conversations: value = .reviews(try await api.conversationComments(binding, number: seed.number, account: account, token: secret, page: page))
          case .checks: value = .checks(try await api.checksPage(binding, sha: seed.sha, account: account, token: secret, cursor: cursor))
          }
          try Task.checkCancellation(); try await validate(); return value
        }
        try Task.checkCancellation(); try await validate()
        guard generations[section] == ticket else { return }
        apply(value, section: section, more: more)
        if section == .checks {
          if cursor.source == .checkRuns { initialChecksPending = false }
          else if !more, cursor.page == 1, checks.isEmpty, nextChecks == HostingChecksCursor(source: .checkRuns) {
            // GitHub Actions are the common first visible CI result. An empty status
            // response must not make the user choose an internal API before seeing it.
            initialChecksPending = true
          }
        }
        states[section]?.loaded = true; retryMore[section] = nil; applied = true
      } catch is CancellationError {} catch {
        guard generations[section] == ticket else { return }
        let error = error as? HostingError ?? .networkFailure
        states[section]?.error = error; retryMore[section] = more
        await failed(error)
      }
      guard generations[section] == ticket else { return }
      states[section]?.loading = false; tasks[section] = nil
      if applied, section == .checks { loadInitialChecksIfNeeded() }
    }
  }
  private func loadInitialChecksIfNeeded() {
    guard selected == .checks, initialChecksPending, state(.checks).error == nil,
      nextChecks == HostingChecksCursor(source: .checkRuns) else { return }
    // This continuation fetches only the first checks page. Later pages remain explicit.
    load(.checks, more: true)
  }
  private func append<T: Identifiable>(_ old: [T], _ page: [T], more: Bool) -> [T] {
    var ids = Set<T.ID>(); return ((more ? old : []) + page).filter { ids.insert($0.id).inserted }
  }
  private func apply(_ value: HostingDetailValue, section: HostingDetailSection, more: Bool) {
    switch value {
    case .overview(let value):
      let changed = detail.sha != value.sha || detail.updatedAt != value.updatedAt
      detail = value
      if changed {
        for section in [HostingDetailSection.commits, .files, .reviews, .comments, .conversations, .checks] { cancel(section); states[section] = nil; nextPages[section] = nil }
        commits = []; files = []; reviews = []; comments = []; conversations = []; checks = []; nextChecks = nil; initialChecksPending = false
        if selected != .overview { select(selected) }
      }
    case .commits(let page): commits = append(commits, page.items, more: more); nextPages[section] = page.nextPage
    case .files(let page): files = append(files, page.items, more: more); nextPages[section] = page.nextPage
    case .reviews(let page):
      if section == .comments { comments = append(comments, page.items, more: more) }
      else if section == .conversations { conversations = append(conversations, page.items, more: more) }
      else { reviews = append(reviews, page.items, more: more) }
      nextPages[section] = page.nextPage
    case .checks(let page):
      checks = append(checks, page.items, more: more); nextChecks = page.next
    case .threads: break // Review sessions share this cache without replacing the detail loader.
    }
  }
}
