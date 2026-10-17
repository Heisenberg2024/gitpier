import Foundation

/// Account-wide provider queries, deliberately independent of the local workspace's repositories.
public enum HostingReviewDashboardKind: String, CaseIterable, Sendable, Identifiable {
  case requestedReviews, myOpenRequests
  public var id: String { rawValue }
}
public struct HostingReviewDashboardItem: Sendable, Equatable, Identifiable {
  public let accountID: UUID
  public let instance: HostingInstance
  public let remoteID: String
  public let repository: String
  public let projectID: String
  public let number: Int
  public let title: String
  public let author: String
  public let authorID: String
  public let webURL: URL
  public let updatedAt: String
  public var id: String { instance.id + "|" + accountID.uuidString + "|" + remoteID }
}
public struct HostingReviewDashboardPage: Sendable {
  public let items: [HostingReviewDashboardItem]
  public let nextPage: Int?
  public let total: Int?
  public let incomplete: Bool
  public let fetchedAt: Date
  public init(items: [HostingReviewDashboardItem], nextPage: Int?, total: Int?, incomplete: Bool = false, fetchedAt: Date = Date()) {
    self.items = items; self.nextPage = nextPage; self.total = total; self.incomplete = incomplete; self.fetchedAt = fetchedAt
  }
}
extension HostingAPIClient {
  /// One explicitly requested page; never enumerates workspace repositories, reviews or diffs.
  /// GitHub resolves @me; GitLab resolves the authenticated user's scope. No login-name heuristic.
  public func reviewDashboard(account: HostingAccount, token: HostingToken, kind: HostingReviewDashboardKind,
    page: Int = 1) async throws -> HostingReviewDashboardPage {
    try account.validateCredentialContext()
    guard (1...100).contains(page) else { throw HostingError.responseTooLarge }
    let provider = account.instance.provider
    guard provider != .gitea else { throw HostingError.unsupported }
    let query: [URLQueryItem]
    let path: String
    if provider == .github {
      guard page <= 34 else { throw HostingError.responseTooLarge }
      path = "search/issues"
      query = [URLQueryItem(name: "q", value: "is:pr state:open " + (kind == .requestedReviews ? "user-review-requested:@me" : "author:@me")),
        URLQueryItem(name: "sort", value: "updated"), URLQueryItem(name: "order", value: "desc"),
        URLQueryItem(name: "per_page", value: "30"), URLQueryItem(name: "page", value: String(page))]
    } else {
      path = "merge_requests"
      query = [URLQueryItem(name: "scope", value: kind == .requestedReviews ? "reviews_for_me" : "created_by_me"),
        URLQueryItem(name: "state", value: "opened"), URLQueryItem(name: "order_by", value: "updated_at"),
        URLQueryItem(name: "sort", value: "desc"), URLQueryItem(name: "per_page", value: "30"), URLQueryItem(name: "page", value: String(page))]
    }
    let (value, response) = try await json(account, token: token, path: path, query: query)
    let rows: [HostingJSON]
    var total: Int?, incomplete = false
    if provider == .github {
      guard case .array = value["items"], case .bool = value["incomplete_results"],
        let count = Int(value["total_count"].string), count >= 0 else { throw HostingError.invalidResponse }
      rows = value["items"].array; total = count; incomplete = value["incomplete_results"].bool || count > 1000
    } else {
      guard case .array = value else { throw HostingError.invalidResponse }
      rows = value.array; total = response.headers["x-total"].flatMap(Int.init)
    }
    guard rows.count <= 100 else { throw HostingError.responseTooLarge }
    var items: [HostingReviewDashboardItem] = [], ids = Set<String>()
    for row in rows {
      let item = try Self.dashboardItem(row, account: account)
      if kind == .myOpenRequests, item.authorID != account.user.stableID { throw HostingError.invalidResponse }
      if provider == .gitlab, kind == .requestedReviews,
        !row["reviewers"].array.contains(where: { $0["id"].string == account.user.stableID }) { throw HostingError.invalidResponse }
      if ids.insert(item.id).inserted { items.append(item) }
    }
    let hasNext: Bool
    if provider == .github { hasNext = page * 30 < min(total ?? 0, 1000) && !rows.isEmpty }
    else if let header = response.headers["x-next-page"] { hasNext = Int(header).map { $0 > page } ?? false }
    else if let header = response.headers["link"] { hasNext = header.contains("rel=\"next\"") }
    else { hasNext = rows.count == 30 }
    let limit = provider == .github ? 34 : 100
    return HostingReviewDashboardPage(items: items, nextPage: hasNext && page < limit ? page + 1 : nil,
      total: total, incomplete: incomplete || hasNext && page == limit)
  }
  /// Explicit branch-shortcut lookup only. GitLab pull-request sources use stable project IDs.
  public func reviewSourceRepositoryID(_ repository: String, account: HostingAccount, token: HostingToken) async throws -> String {
    try account.validateCredentialContext()
    let (value, _) = try await json(account, token: token, path: repositoryPath(repository, provider: account.instance.provider))
    guard !value["id"].string.isEmpty else { throw HostingError.invalidResponse }
    return value["id"].string
  }
  private static func dashboardItem(_ row: HostingJSON, account: HostingAccount) throws -> HostingReviewDashboardItem {
    let provider = account.instance.provider, number = row[provider == .gitlab ? "iid" : "number"].int
    let remoteID = row["id"].string, author = row[provider == .gitlab ? "author" : "user"]
    guard number > 0, !remoteID.isEmpty, !row["title"].string.isEmpty, !author["id"].string.isEmpty,
      row["state"].string == (provider == .gitlab ? "opened" : "open") else { throw HostingError.invalidResponse }
    let repository: String, projectID: String
    if provider == .github {
      guard !row["pull_request"]["url"].string.isEmpty, let repoURL = URL(string: row["repository_url"].string),
        account.instance.accepts(repoURL, api: true), repoURL.query == nil, repoURL.fragment == nil,
        repoURL.path.hasPrefix("/repos/") else { throw HostingError.invalidResponse }
      repository = String(repoURL.path.dropFirst("/repos/".count)); projectID = ""
      guard repository.split(separator: "/").count == 2 else { throw HostingError.invalidResponse }
    } else {
      let reference = row["references"]["full"].string, suffix = "!\(number)"
      guard reference.hasSuffix(suffix), !row["project_id"].string.isEmpty else { throw HostingError.invalidResponse }
      repository = String(reference.dropLast(suffix.count)); projectID = row["project_id"].string
    }
    _ = try RepositoryHostingBinding(repositoryID: UUID(), accountID: account.id, remote: "", repository: repository)
    let encoded = repository.split(separator: "/").map { HostingInstance.component(String($0)) }.joined(separator: "/")
    let expectedURL = try account.instance.endpoint(encoded + (provider == .gitlab ? "/-/merge_requests/" : "/pull/") + String(number))
    guard let webURL = URL(string: row[provider == .gitlab ? "web_url" : "html_url"].string),
      webURL == expectedURL else { throw HostingError.invalidResponse }
    return HostingReviewDashboardItem(accountID: account.id, instance: account.instance, remoteID: remoteID,
      repository: repository, projectID: projectID, number: number, title: row["title"].string,
      author: author[provider == .gitlab ? "username" : "login"].string, authorID: author["id"].string,
      webURL: webURL, updatedAt: row["updated_at"].string)
  }
}

/// Page cache is memory only; each account/instance/scope/page has an independent slot.
public actor HostingReviewDashboardCache {
  private struct Key: Hashable { let identity: String; let accountID: UUID; let kind: HostingReviewDashboardKind; let page: Int }
  private struct Entry { let expires: Date; let value: HostingReviewDashboardPage }
  private var entries: [Key: Entry] = [:]
  private let lifetime: TimeInterval
  public init(lifetime: TimeInterval = 60) { self.lifetime = lifetime }
  public func get(account: HostingAccount, kind: HostingReviewDashboardKind, page: Int) -> HostingReviewDashboardPage? {
    let key = Key(identity: account.identity, accountID: account.id, kind: kind, page: page)
    guard let entry = entries[key], entry.expires > Date() else { entries[key] = nil; return nil }; return entry.value
  }
  public func put(_ value: HostingReviewDashboardPage, account: HostingAccount, kind: HostingReviewDashboardKind, page: Int) {
    if entries.count >= 200 { entries.removeAll() }
    entries[Key(identity: account.identity, accountID: account.id, kind: kind, page: page)] = Entry(expires: Date().addingTimeInterval(lifetime), value: value)
  }
  public func clear(account: HostingAccount) { entries = entries.filter { $0.key.accountID != account.id } }
}

public struct HostingCurrentBranchSnapshot: Sendable, Equatable {
  public let accountID: UUID
  public let userID: String
  public let instance: HostingInstance
  public let branch: String
  public let head: String
  public let sourceRepository: String
  public let sourceRepositoryID: String
  public init(account: HostingAccount, branch: String, head: String?, sourceRemoteURL: String, sourceRepositoryID: String = "") throws {
    try account.validateCredentialContext(); try InputValidation.reference(branch)
    guard !branch.isEmpty, branch != "HEAD", branch != "(detached)", let head, HostingReviewRevision.isSHA(head),
      let repository = HostingRemoteParser.repository(sourceRemoteURL, instance: account.instance),
      account.instance.provider != .gitlab || !sourceRepositoryID.isEmpty,
      account.instance.baseURL.port == nil || sourceRemoteURL.hasPrefix("https://") else { throw HostingReviewError.targetChanged }
    accountID = account.id; userID = account.user.stableID; instance = account.instance; self.branch = branch; self.head = head
    sourceRepository = repository; self.sourceRepositoryID = sourceRepositoryID
  }
  public func matches(_ request: HostingPullRequest, account: HostingAccount) -> Bool {
    sameSource(request, account: account) && request.sha == head
  }
  public func sameSource(_ request: HostingPullRequest, account: HostingAccount) -> Bool {
    guard account.id == accountID, account.user.stableID == userID, account.instance == instance,
      request.source == branch, request.state == "open" else { return false }
    if instance.provider == .gitlab { return request.sourceRepository == sourceRepositoryID }
    return request.sourceRepository.lowercased() == sourceRepository.lowercased()
  }
}
