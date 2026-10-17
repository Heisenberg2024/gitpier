import Foundation

public enum HostingRequestFilter: String, CaseIterable, Sendable { case open, draft, closed, merged, all }
public enum HostingCIState: String, Sendable { case pending, running, success, failed, cancelled, skipped, unknown, noChecks }
public struct HostingCheck: Identifiable, Sendable {
  public var id: String { (identifier ?? name) + "|" + sha }
  public let name: String
  public let sha: String
  public let state: HostingCIState
  public let webURL: URL?
  public let identifier: String?
  public init(name: String, sha: String, state: HostingCIState, webURL: URL?, identifier: String? = nil) {
    self.name = name; self.sha = sha; self.state = state; self.webURL = webURL; self.identifier = identifier
  }
}
public struct HostingChecksCursor: Hashable, Sendable {
  public enum Source: String, Sendable { case statuses, checkRuns }
  public let source: Source
  public let page: Int
  public init(source: Source = .statuses, page: Int = 1) { self.source = source; self.page = page }
  public var cacheKey: String { source.rawValue + "|\(page)" }
}
public struct HostingChecksPage: Sendable {
  public let items: [HostingCheck]
  public let next: HostingChecksCursor?
  public init(items: [HostingCheck], next: HostingChecksCursor?) { self.items = items; self.next = next }
}
public struct HostingPullRequest: Identifiable, Sendable {
  public let number: Int
  public var id: Int { number }
  public let title: String
  public let body: String
  public let author: String
  public let state: String
  public let draft: Bool
  public let source: String
  public let target: String
  public let sourceRepository: String
  public let sha: String
  public let webURL: URL?
  public let createdAt: String
  public let updatedAt: String
  public let reviewers: [String]
}
public struct HostingPage<T: Sendable>: Sendable {
  public let items: [T]
  public let nextPage: Int?
  public init(items: [T], nextPage: Int?) { self.items = items; self.nextPage = nextPage }
}
public struct HostingCommit: Identifiable, Sendable {
  public let id: String
  public let message: String
}
public struct HostingChangedFile: Identifiable, Sendable {
  public var id: String { path }
  public let path: String
  public let oldPath: String
  public let kind: String
  public let patch: String?
}
public struct HostingReview: Identifiable, Sendable {
  public let id: String
  public let author: String
  public let body: String
  public let state: String
  public let path: String
  public let line: String
  public let webURL: URL?
}
public struct HostingCreateDraft: Equatable, Sendable {
  public var sourceRepository: String
  public var source: String
  public var target: String
  public var title: String
  public var body: String
  public var draft: Bool
  public init(sourceRepository: String, source: String, target: String, title: String, body: String = "", draft: Bool = false) {
    self.sourceRepository = sourceRepository; self.source = source; self.target = target; self.title = title; self.body = body; self.draft = draft
  }
}
public struct HostingCreationReview: Sendable {
  public let binding: RepositoryHostingBinding
  public let accountIdentity: String
  public let draft: HostingCreateDraft
  public let sourceSHA: String
  public let targetSHA: String
  public let sourceProjectID: String
  public let createdAt: Date
}

public struct HostingAPIClient: Sendable {
  public let http: HostingHTTPClient
  public init(http: HostingHTTPClient = HostingHTTPClient()) { self.http = http }
  func json(_ account: HostingAccount, token: HostingToken, path: String, query: [URLQueryItem] = [], method: String = "GET", body: [String: HostingJSON]? = nil) async throws -> (HostingJSON, HostingHTTPResponse) {
    let data = try body.map { try JSONEncoder().encode(HostingJSON.object($0)) }
    let r = try await http.request(instance: account.instance, path: path, query: query, token: token, method: method, body: data)
    return (try HostingJSON.decode(r.data), r)
  }
  public func user(instance: HostingInstance, token: HostingToken) async throws -> HostingUser {
    let r = try await http.request(instance: instance, path: "user", token: token, limit: 256 * 1024)
    let j = try HostingJSON.decode(r.data)
    let login = j[instance.provider == .gitlab ? "username" : "login"].string
    guard !j["id"].string.isEmpty, !login.isEmpty else { throw HostingError.invalidResponse }
    // Avatars never receive Authorization and are fetched only by the optional image view.
    var avatar = safeWeb(j["avatar_url"].string).flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
    avatar?.query = nil; avatar?.fragment = nil // Metadata must never persist signed/token-bearing avatar queries.
    return HostingUser(stableID: j["id"].string, login: login, name: j["name"].string, avatarURL: avatar?.url)
  }
  public func repositoryPath(_ repository: String, provider: HostingProvider) throws -> String {
    _ = try RepositoryHostingBinding(repositoryID: UUID(), accountID: UUID(), remote: "", repository: repository)
    if provider == .gitlab { return "projects/" + HostingInstance.component(repository) }
    guard repository.split(separator: "/").count == 2 else { throw HostingError.invalidResponse }
    return "repos/" + repository.split(separator: "/").map { HostingInstance.component(String($0)) }.joined(separator: "/")
  }
  public func validateRepository(_ binding: RepositoryHostingBinding, account: HostingAccount, token: HostingToken) async throws {
    guard binding.accountID == account.id else { throw HostingError.accountChanged }
    let (j, _) = try await json(account, token: token, path: repositoryPath(binding.repository, provider: account.instance.provider))
    guard !j["id"].string.isEmpty else { throw HostingError.invalidResponse }
  }
  private func requestPath(_ binding: RepositoryHostingBinding, account: HostingAccount, number: Int? = nil) throws -> String {
    guard binding.accountID == account.id else { throw HostingError.accountChanged }
    return try repositoryPath(binding.repository, provider: account.instance.provider)
      + (account.instance.provider == .gitlab ? "/merge_requests" : "/pulls") + (number.map { "/\($0)" } ?? "")
  }
  public func requests(_ binding: RepositoryHostingBinding, account: HostingAccount, token: HostingToken, filter: HostingRequestFilter = .open, page: Int = 1) async throws -> HostingPage<HostingPullRequest> {
    let provider = account.instance.provider
    let state = filter == .all ? "all" : filter == .merged ? (provider == .gitlab ? "merged" : "closed")
      : filter == .closed ? "closed" : provider == .gitlab ? "opened" : "open"
    let ordering = provider == .gitlab ? [URLQueryItem(name: "order_by", value: "updated_at"), URLQueryItem(name: "sort", value: "desc")]
      : provider == .gitea ? [URLQueryItem(name: "sort", value: "recentupdate")]
      : [URLQueryItem(name: "sort", value: "updated"), URLQueryItem(name: "direction", value: "desc")]
    let query = pagination(provider, page: page) + [URLQueryItem(name: "state", value: state)] + ordering
    let (j, r) = try await json(account, token: token, path: requestPath(binding, account: account), query: query)
    guard case .array = j else { throw HostingError.invalidResponse }
    let items = try j.array.map { try pull($0, provider: provider) }.filter {
      switch filter { case .draft: $0.draft && $0.state == "open"; case .merged: $0.state == "merged"; case .closed: $0.state == "closed"; default: true }
    }
    return HostingPage(items: items, nextPage: next(r, count: j.array.count, page: page))
  }
  public func request(_ binding: RepositoryHostingBinding, number: Int, account: HostingAccount, token: HostingToken) async throws -> HostingPullRequest {
    let (j, _) = try await json(account, token: token, path: requestPath(binding, account: account, number: number))
    return try pull(j, provider: account.instance.provider)
  }
  private func pull(_ j: HostingJSON, provider: HostingProvider) throws -> HostingPullRequest {
    let number = j[provider == .gitlab ? "iid" : "number"].int
    guard number > 0, !j["title"].string.isEmpty else { throw HostingError.invalidResponse }
    let gl = provider == .gitlab
    let rawState = j["state"].string
    let state = j["merged"].bool || !j["merged_at"].string.isEmpty || rawState == "merged" ? "merged" : rawState == "opened" ? "open" : rawState
    return HostingPullRequest(number: number, title: j["title"].string, body: j[gl ? "description" : "body"].string,
      author: j[gl ? "author" : "user"][gl ? "username" : "login"].string, state: state,
      draft: j["draft"].bool || j["work_in_progress"].bool || j["title"].string.hasPrefix("Draft:"),
      source: gl ? j["source_branch"].string : j["head"]["ref"].string,
      target: gl ? j["target_branch"].string : j["base"]["ref"].string,
      sourceRepository: gl ? j["source_project_id"].string : j["head"]["repo"]["full_name"].string,
      sha: gl ? j["sha"].string : j["head"]["sha"].string,
      webURL: safeWeb(j[gl ? "web_url" : "html_url"].string), createdAt: j["created_at"].string,
      updatedAt: j["updated_at"].string,
      reviewers: j[gl ? "reviewers" : "requested_reviewers"].array.map { $0[gl ? "username" : "login"].string })
  }
  public func commits(_ binding: RepositoryHostingBinding, number: Int, account: HostingAccount, token: HostingToken, page: Int = 1) async throws -> HostingPage<HostingCommit> {
    let provider = account.instance.provider
    let (j, r) = try await json(account, token: token, path: requestPath(binding, account: account, number: number) + "/commits", query: pagination(provider, page: page))
    guard case .array = j else { throw HostingError.invalidResponse }
    return HostingPage(items: j.array.map { HostingCommit(id: $0[provider == .gitlab ? "id" : "sha"].string,
      message: provider == .gitlab ? $0["message"].string : $0["commit"]["message"].string) }, nextPage: next(r, count: j.array.count, page: page))
  }
  public func files(_ binding: RepositoryHostingBinding, number: Int, account: HostingAccount, token: HostingToken, page: Int = 1) async throws -> HostingPage<HostingChangedFile> {
    let p = account.instance.provider
    let (j, r) = try await json(account, token: token, path: requestPath(binding, account: account, number: number) + (p == .gitlab ? "/diffs" : "/files"), query: pagination(p, page: page))
    guard case .array = j else { throw HostingError.invalidResponse }
    return HostingPage(items: j.array.map { file in
      let path = file[p == .gitlab ? "new_path" : "filename"].string
      let patch = file[p == .gitlab ? "diff" : "patch"].string
      return HostingChangedFile(path: path, oldPath: file[p == .gitlab ? "old_path" : "previous_filename"].string,
        kind: p == .gitlab ? (file["new_file"].bool ? "added" : file["deleted_file"].bool ? "deleted" : file["renamed_file"].bool ? "renamed" : "modified") : file["status"].string,
        patch: patch.isEmpty || patch.utf8.count > 1024 * 1024 || file["too_large"].bool || file["collapsed"].bool ? nil : patch)
    }, nextPage: next(r, count: j.array.count, page: page))
  }
  public func reviews(_ binding: RepositoryHostingBinding, number: Int, account: HostingAccount, token: HostingToken, comments: Bool = false, page: Int = 1) async throws -> HostingPage<HostingReview> {
    let p = account.instance.provider
    if p == .gitlab && !comments {
      let (j, _) = try await json(account, token: token, path: requestPath(binding, account: account, number: number) + "/approvals")
      guard case .array = j["approved_by"] else { throw HostingError.invalidResponse }
      return HostingPage(items: j["approved_by"].array.map { v in
        HostingReview(id: v["user"]["id"].string, author: v["user"]["username"].string, body: "", state: "APPROVED", path: "", line: "", webURL: nil)
      }, nextPage: nil)
    }
    let suffix = p == .gitlab ? (comments ? "/discussions" : "/notes") : comments ? "/comments" : "/reviews"
    let path = p == .gitea && comments ? try repositoryPath(binding.repository, provider: p) + "/issues/\(number)/comments"
      : try requestPath(binding, account: account, number: number) + suffix
    let (j, r) = try await json(account, token: token, path: path, query: pagination(p, page: page))
    guard case .array = j else { throw HostingError.invalidResponse }
    let values = p == .gitlab && comments ? j.array.flatMap { $0["notes"].array } : j.array
    return HostingPage(items: values.map { v in
      HostingReview(id: v["id"].string, author: v[p == .gitlab ? "author" : "user"][p == .gitlab ? "username" : "login"].string,
        body: v["body"].string, state: v["state"].string,
        path: p == .gitlab ? v["position"]["new_path"].string : v["path"].string,
        line: p == .gitlab ? v["position"]["new_line"].string : v["line"].string.isEmpty ? v["position"].string : v["line"].string,
        webURL: safeWeb(v["html_url"].string))
    }, nextPage: next(r, count: j.array.count, page: page))
  }
  public func giteaReviewComments(_ binding: RepositoryHostingBinding, number: Int, reviewID: String, account: HostingAccount, token: HostingToken) async throws -> [HostingReview] {
    try await giteaReviewCommentsPage(binding, number: number, reviewID: reviewID, account: account, token: token).items
  }
  public func conversationComments(_ binding: RepositoryHostingBinding, number: Int, account: HostingAccount, token: HostingToken, page: Int = 1) async throws -> HostingPage<HostingReview> {
    guard account.instance.provider == .github else { throw HostingError.unsupported }
    guard binding.accountID == account.id, number > 0 else { throw HostingError.accountChanged }
    let path = try repositoryPath(binding.repository, provider: .github) + "/issues/\(number)/comments"
    let (j, r) = try await json(account, token: token, path: path, query: pagination(.github, page: page))
    guard case .array = j else { throw HostingError.invalidResponse }
    return HostingPage(items: j.array.map { v in
      HostingReview(id: v["id"].string, author: v["user"]["login"].string, body: v["body"].string, state: "", path: "", line: "", webURL: safeWeb(v["html_url"].string))
    }, nextPage: next(r, count: j.array.count, page: page))
  }
  public func giteaReviewCommentsPage(_ binding: RepositoryHostingBinding, number: Int, reviewID: String, account: HostingAccount, token: HostingToken, page: Int = 1) async throws -> HostingPage<HostingReview> {
    guard account.instance.provider == .gitea, Int(reviewID) != nil else { throw HostingError.invalidResponse }
    let path = try requestPath(binding, account: account, number: number) + "/reviews/\(reviewID)/comments"
    let (j, r) = try await json(account, token: token, path: path, query: pagination(.gitea, page: page))
    guard case .array = j else { throw HostingError.invalidResponse }
    return HostingPage(items: j.array.map { v in HostingReview(id: v["id"].string, author: v["user"]["login"].string, body: v["body"].string, state: "",
      path: v["path"].string, line: v["position"].string, webURL: safeWeb(v["html_url"].string)) }, nextPage: next(r, count: j.array.count, page: page))
  }
  public func giteaPatch(_ binding: RepositoryHostingBinding, number: Int, file: HostingChangedFile, account: HostingAccount, token: HostingToken) async throws -> String? {
    guard account.instance.provider == .gitea else { return file.patch }
    let r = try await http.request(instance: account.instance, path: requestPath(binding, account: account, number: number) + ".diff", token: token, limit: 1024 * 1024)
    guard let text = String(data: r.data, encoding: .utf8) else { return nil }
    var sections: [[String]] = []
    for line in text.components(separatedBy: "\n") {
      if line.hasPrefix("diff --git ") { sections.append([]) }
      if !sections.isEmpty { sections[sections.count - 1].append(line) }
    }
    for section in sections {
      let new = section.first { $0.hasPrefix("+++ ") }.map { Self.diffPath(String($0.dropFirst(4))) }
      let old = section.first { $0.hasPrefix("--- ") }.map { Self.diffPath(String($0.dropFirst(4))) }
      if new == "b/" + file.path || new == "/dev/null" && old == "a/" + file.path {
        return section.contains(where: { $0.hasPrefix("@@ ") }) ? section.joined(separator: "\n") : nil
      }
    }
    return nil
  }
  private static func diffPath(_ value: String) -> String {
    guard value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
    let bytes = Array(value.dropFirst().dropLast().utf8); var output: [UInt8] = []; var i = 0
    let escapes: [UInt8: UInt8] = [97: 7, 98: 8, 116: 9, 110: 10, 118: 11, 102: 12, 114: 13, 92: 92, 34: 34]
    while i < bytes.count {
      if bytes[i] != 92 { output.append(bytes[i]); i += 1; continue }
      i += 1; guard i < bytes.count else { return "" }
      if (48...55).contains(bytes[i]) {
        var number = 0; var count = 0
        while i < bytes.count && (48...55).contains(bytes[i]) && count < 3 { number = number * 8 + Int(bytes[i] - 48); i += 1; count += 1 }
        guard number <= 255 else { return "" }; output.append(UInt8(number))
      } else { guard let byte = escapes[bytes[i]] else { return "" }; output.append(byte); i += 1 }
    }
    return String(bytes: output, encoding: .utf8) ?? ""
  }
  public func checks(_ binding: RepositoryHostingBinding, sha: String, account: HostingAccount, token: HostingToken) async throws -> [HostingCheck] {
    var result: [HostingCheck] = [], cursor: HostingChecksCursor? = HostingChecksCursor()
    while let current = cursor {
      try Task.checkCancellation()
      let page = try await checksPage(binding, sha: sha, account: account, token: token, cursor: current)
      result += page.items; cursor = page.next
    }
    return result
  }
  /// One provider page per call. A later CI permission failure remains an error even when
  /// commit statuses were empty; callers must not interpret an unfinished cursor as No Checks.
  public func checksPage(_ binding: RepositoryHostingBinding, sha: String, account: HostingAccount, token: HostingToken, cursor: HostingChecksCursor = HostingChecksCursor()) async throws -> HostingChecksPage {
    guard binding.accountID == account.id else { throw HostingError.accountChanged }
    guard sha.count >= 40, sha.count <= 64, sha.allSatisfy(\.isHexDigit) else { throw HostingError.invalidResponse }
    guard (1...20).contains(cursor.page) else { throw HostingError.responseTooLarge }
    let p = account.instance.provider, base = try repositoryPath(binding.repository, provider: account.instance.provider)
    guard cursor.source == .statuses || p == .github else { throw HostingError.invalidResponse }
    let path: String, key: String?
    if p == .gitlab {
      path = base + "/pipelines"; key = nil
    } else { path = base + "/commits/" + sha + (cursor.source == .checkRuns ? "/check-runs" : "/status"); key = cursor.source == .checkRuns ? "check_runs" : "statuses" }
    let query = [URLQueryItem(name: p == .gitea ? "limit" : "per_page", value: "100"), URLQueryItem(name: "page", value: String(cursor.page))]
      + (p == .gitlab ? [URLQueryItem(name: "sha", value: sha)] : [])
    let (j, r) = try await json(account, token: token, path: path, query: query)
    if p != .gitlab && cursor.source == .statuses && j["sha"].string != sha { throw HostingError.invalidResponse }
    var values = key.map { j[$0] } ?? j
    // Gitea serializes an explicitly empty CombinedStatus as null, not an array.
    // Missing keys, coerced counts or contradictory pagination must remain failures.
    if p == .gitea, case .object(let fields) = j,
      case .null? = fields["statuses"], case .integer(0)? = fields["total_count"] {
      guard r.headers["x-hasmore"]?.lowercased() != "true", (r.headers["x-next-page"] ?? "").isEmpty,
        r.headers["link"]?.contains("rel=\"next\"") != true else { throw HostingError.invalidResponse }
      values = .array([])
    }
    guard case .array = values else { throw HostingError.invalidResponse }
    let items = values.array.compactMap { v -> HostingCheck? in
      if p == .gitlab { return v["sha"].string == sha ? HostingCheck(name: "Pipeline #" + v["id"].string, sha: sha, state: ciState(v["status"].string), webURL: safeWeb(v["web_url"].string), identifier: "pipeline:" + v["id"].string) : nil }
      if cursor.source == .checkRuns {
        return v["head_sha"].string == sha ? HostingCheck(name: v["name"].string, sha: sha, state: ciState(v["conclusion"].string.isEmpty ? v["status"].string : v["conclusion"].string), webURL: safeWeb(v["html_url"].string), identifier: "check:" + (v["id"].string.isEmpty ? v["name"].string : v["id"].string)) : nil
      }
      return HostingCheck(name: v["context"].string, sha: sha, state: ciState(v[p == .gitea ? "status" : "state"].string), webURL: safeWeb(v["target_url"].string), identifier: "status:" + v["context"].string)
    }
    let more: Bool
    if let has = r.headers["x-hasmore"] { more = has.lowercased() == "true" }
    else if let next = r.headers["x-next-page"] { more = !next.isEmpty }
    else if let link = r.headers["link"] { more = link.contains("rel=\"next\"") }
    else { more = j["total_count"].int > cursor.page * 100 || values.array.count == 100 }
    let nextCursor = more ? HostingChecksCursor(source: cursor.source, page: cursor.page + 1)
      : p == .github && cursor.source == .statuses ? HostingChecksCursor(source: .checkRuns) : nil
    return HostingChecksPage(items: items, next: nextCursor)
  }
  public func branch(_ repository: String, name: String, account: HostingAccount, token: HostingToken) async throws -> (sha: String, projectID: String) {
    guard !name.isEmpty, !name.contains("\n") else { throw HostingError.branchMissing }
    let base = try repositoryPath(repository, provider: account.instance.provider)
    let path = base + (account.instance.provider == .gitlab ? "/repository/branches/" : "/branches/") + HostingInstance.component(name)
    do {
      let (j, _) = try await json(account, token: token, path: path)
      let sha = j["commit"][account.instance.provider == .github ? "sha" : "id"].string
      guard !sha.isEmpty else { throw HostingError.branchMissing }
      let (repo, _) = try await json(account, token: token, path: base)
      return (sha, repo["id"].string)
    } catch HostingError.notFound { throw HostingError.branchMissing }
  }
  public func canCreate(account: HostingAccount, token: HostingToken) -> Bool {
    if account.kind == .pat { return true } // Fine-grained PAT grants are enforced by platform API.
    switch account.instance.provider {
    case .github: return token.scopes.contains("repo") || token.scopes.contains("public_repo")
    case .gitlab: return token.scopes.contains("api")
    case .gitea: return token.scopes.contains("write:repository")
    }
  }
  public func prepareCreation(_ binding: RepositoryHostingBinding, draft: HostingCreateDraft, localHead: String?, localBranch: String,
    operationInProgress: Bool, account: HostingAccount, token: HostingToken) async throws -> HostingCreationReview {
    guard binding.accountID == account.id else { throw HostingError.accountChanged }
    guard !operationInProgress else { throw HostingError.operationInProgress }
    guard canCreate(account: account, token: token) else { throw HostingError.permissionRequired }
    guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.title.utf8.count < 1024, draft.body.utf8.count < 1024 * 1024 else { throw HostingError.invalidResponse }
    guard draft.source == localBranch, let localHead else { throw HostingError.pushRequired }
    // Gitea's supported API does not expose a portable draft flag across versions. Keep UI explicit.
    guard account.instance.provider != .gitea || !draft.draft else { throw HostingError.unsupported }
    let source = try await branch(draft.sourceRepository, name: draft.source, account: account, token: token)
    let target = try await branch(binding.repository, name: draft.target, account: account, token: token)
    guard source.sha == localHead else { throw HostingError.pushRequired }
    try await rejectDuplicate(binding, draft: draft, sourceID: source.projectID, account: account, token: token)
    return HostingCreationReview(binding: binding, accountIdentity: account.identity, draft: draft, sourceSHA: source.sha,
      targetSHA: target.sha, sourceProjectID: source.projectID, createdAt: Date())
  }
  private func rejectDuplicate(_ binding: RepositoryHostingBinding, draft: HostingCreateDraft, sourceID: String, account: HostingAccount, token: HostingToken) async throws {
    var page: Int? = 1
    while let current = page {
      guard current <= 20 else { throw HostingError.responseTooLarge }
      let list = try await requests(binding, account: account, token: token, page: current)
      if list.items.contains(where: { $0.source == draft.source && $0.target == draft.target &&
        ($0.sourceRepository == draft.sourceRepository || $0.sourceRepository == sourceID) }) { throw HostingError.duplicateRequest }
      page = list.nextPage
    }
  }
  public func create(_ review: HostingCreationReview, localHead: String?, localBranch: String, operationInProgress: Bool,
    account: HostingAccount, token: HostingToken, revalidateLocal: @Sendable () async throws -> Void = {}) async throws -> HostingPullRequest {
    guard review.accountIdentity == account.identity, Date().timeIntervalSince(review.createdAt) < 300 else { throw HostingError.accountChanged }
    let next = try await prepareCreation(review.binding, draft: review.draft, localHead: localHead, localBranch: localBranch,
      operationInProgress: operationInProgress, account: account, token: token)
    guard next.sourceSHA == review.sourceSHA, next.targetSHA == review.targetSHA else { throw HostingError.accountChanged }
    let d = review.draft, p = account.instance.provider
    var body: [String: HostingJSON]
    if p == .gitlab {
      body = ["source_branch": .string(d.source), "target_branch": .string(d.target),
        "title": .string(d.draft && !d.title.hasPrefix("Draft:") ? "Draft: " + d.title : d.title), "description": .string(d.body)]
    } else {
      let fork = d.sourceRepository != review.binding.repository
      let owner = String(d.sourceRepository.split(separator: "/").first ?? "")
      // Gitea needs the exact repository: owner-only heads can resolve a different repo
      // under the same owner. An older server's rejection must never trigger a fallback.
      let forkSource = p == .gitea ? d.sourceRepository : owner
      body = ["head": .string(fork ? forkSource + ":" + d.source : d.source), "base": .string(d.target), "title": .string(d.title), "body": .string(d.body)]
      if p == .github { body["draft"] = .bool(d.draft); if fork { body["head_repo"] = .string(String(d.sourceRepository.split(separator: "/").last ?? "")) } }
    }
    do {
      // GitLab creates against the source project and identifies the target explicitly.
      let path: String
      if p == .gitlab {
        let (_, targetID) = try await branch(review.binding.repository, name: d.target, account: account, token: token)
        guard let id = Int64(targetID), id > 0 else { throw HostingError.invalidResponse }
        body["target_project_id"] = .integer(id)
        path = try repositoryPath(d.sourceRepository, provider: p) + "/merge_requests"
      } else { path = try requestPath(review.binding, account: account) }
      try await revalidateLocal()
      try Task.checkCancellation()
      let (j, _) = try await json(account, token: token, path: path, method: "POST", body: body)
      return try pull(j, provider: p)
    } catch HostingError.networkFailure { throw HostingError.creationUnknown }
      catch HostingError.serverFailure { throw HostingError.creationUnknown }
      catch HostingError.invalidResponse { throw HostingError.creationUnknown }
      catch HostingError.responseTooLarge { throw HostingError.creationUnknown }
      catch is CancellationError { throw HostingError.creationUnknown }
  }
  private func pagination(_ p: HostingProvider, page: Int) -> [URLQueryItem] {
    [URLQueryItem(name: "page", value: String(max(1, page))), URLQueryItem(name: p == .gitea ? "limit" : "per_page", value: "50")]
  }
  private func next(_ response: HostingHTTPResponse, count: Int, page: Int) -> Int? {
    if let value = response.headers["x-hasmore"] { return value.lowercased() == "true" ? page + 1 : nil }
    if let value = response.headers["x-next-page"] { return Int(value) }
    // Only interpret the relation, never follow server-provided URLs with a token.
    if let link = response.headers["link"] { return link.contains("rel=\"next\"") ? page + 1 : nil }
    return count == 50 ? page + 1 : nil
  }
  private func ciState(_ value: String) -> HostingCIState {
    switch value.lowercased() {
    case "pending", "queued", "created", "waiting", "waiting_for_resource", "requested", "blocked": .pending
    case "running", "in_progress", "preparing": .running
    case "success": .success
    case "failure", "failed", "error", "timed_out", "action_required", "startup_failure": .failed
    case "cancelled", "canceled": .cancelled
    case "skipped", "neutral": .skipped
    default: .unknown
    }
  }
  private func safeWeb(_ value: String) -> URL? {
    guard let url = URL(string: value), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }; return url
  }
}

/// Memory only; private data is partitioned by provider, instance, stable account and repository.
public actor HostingAPICache {
  private struct Entry { let expires: Date; let value: HostingPage<HostingPullRequest> }
  private var entries: [String: Entry] = [:]
  public init() {}
  private func key(_ account: HostingAccount, _ binding: RepositoryHostingBinding, _ filter: HostingRequestFilter, _ page: Int) -> String {
    account.identity + "|" + account.id.uuidString + "|" + binding.repository + "|" + filter.rawValue + "|\(page)"
  }
  public func get(account: HostingAccount, binding: RepositoryHostingBinding, filter: HostingRequestFilter, page: Int) -> HostingPage<HostingPullRequest>? {
    let key = key(account, binding, filter, page)
    guard let entry = entries[key], entry.expires > Date() else { entries[key] = nil; return nil }; return entry.value
  }
  public func put(_ value: HostingPage<HostingPullRequest>, account: HostingAccount, binding: RepositoryHostingBinding, filter: HostingRequestFilter, page: Int) {
    if entries.count >= 200 { entries.removeAll() }
    entries[key(account, binding, filter, page)] = Entry(expires: Date().addingTimeInterval(60), value: value)
  }
  public func clear(account: HostingAccount) { entries = entries.filter { !$0.key.hasPrefix(account.identity + "|" + account.id.uuidString + "|") } }
}
