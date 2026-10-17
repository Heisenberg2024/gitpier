import Foundation

extension HostingAPIClient {
  /// Invoked only when the user opens reviewer selection. GitHub/GitLab fetch one
  /// provider page; audited Gitea exposes a single bounded, unpaginated reviewer list.
  public func reviewerCandidates(_ binding: RepositoryHostingBinding, context: HostingReviewContext, account: HostingAccount,
    token: HostingToken, page: Int = 1) async throws -> HostingPage<HostingReviewer> {
    try context.target.validate(account: account, binding: binding)
    guard context.capabilities.contains(.requestReviewers) else { throw HostingReviewError.permissionRequired }
    let provider = account.instance.provider
    if provider == .gitea && page != 1 { return HostingPage(items: [], nextPage: nil) }
    let repo = try repositoryPath(binding.repository, provider: provider)
    let path = repo + (provider == .gitlab ? "/members/all" : provider == .gitea ? "/reviewers" : "/collaborators")
    var query = provider == .gitea ? [] : Self.reviewerPagination(provider, page: page)
    if provider == .github { query.append(URLQueryItem(name: "affiliation", value: "all")) }
    let (value, response) = try await json(account, token: token, path: path, query: query)
    guard case .array = value, value.array.count <= 1000 else { throw HostingError.responseTooLarge }
    var users: [HostingReviewer] = []
    for item in value.array {
      if provider == .github && !Self.reviewerHasWrite(item) { continue }
      // This deliberately offers active Developer-or-higher project members. It
      // does not derive reviewer eligibility from approval rules or approver lists.
      if provider == .gitlab && (item["state"].string != "active" || item["access_level"].int < 30) { continue }
      let user = try Self.reviewer(item, provider: provider)
      guard user.id != context.authorID else { continue }
      if !users.contains(where: { $0.id == user.id }) { users.append(user) }
    }
    return HostingPage(items: users, nextPage: provider == .gitea ? nil : Self.reviewerNext(response, count: value.array.count, page: page))
  }

  /// Requested users are read from native reviewer fields, never inferred from
  /// review counts, usernames, approvals or notifications. Existing teams are untouched.
  public func requestedReviewers(_ binding: RepositoryHostingBinding, number: Int, account: HostingAccount, token: HostingToken,
    page: Int = 1) async throws -> HostingPage<HostingReviewer> {
    let path = try reviewerRequestPath(binding, number: number, account: account)
    guard page == 1 else { return HostingPage(items: [], nextPage: nil) }
    let provider = account.instance.provider
    let (value, _) = try await json(account, token: token, path: path + (provider == .github ? "/requested_reviewers" : ""))
    let values = value[provider == .github ? "users" : provider == .gitlab ? "reviewers" : "requested_reviewers"]
    if provider != .github {
      guard value["id"].string.isEmpty == false, value[provider == .gitlab ? "iid" : "number"].int == number else { throw HostingReviewError.targetChanged }
    }
    return HostingPage(items: try Self.reviewerUsers(values, provider: provider), nextPage: nil)
  }

  /// Called by the existing shared review coordinator after explicit notification
  /// confirmation. There is no second lock and no automatic POST/PUT retry.
  public func performReviewerRequest(_ selection: HostingReviewerSelection, context: HostingReviewContext, account: HostingAccount,
    token: HostingToken) async throws -> HostingReviewReceipt {
    let binding = try reviewerBinding(context, account: account)
    // GitLab only exposes replacement of the complete reviewer list. Without a
    // documented compare-and-swap, GET/union/PUT can remove another client's new
    // reviewer. Keep assignment in the browser until an atomic API is verified.
    guard account.instance.provider != .gitlab else { throw HostingReviewError.unsupported }
    try selection.validate(context: context)
    let initial = try await reviewContext(binding, number: context.target.requestNumber, account: account, token: token)
    try context.validateCurrent(initial); try selection.validate(context: initial)
    let provider = account.instance.provider, repo = try repositoryPath(binding.repository, provider: account.instance.provider)
    if provider == .gitea {
      // This endpoint checks the actor's ability to choose reviewers as well as the
      // candidates' actual eligibility. Querying arbitrary users' permissions would
      // require repository-admin access on this Gitea version.
      let candidates = try await reviewerCandidates(binding, context: initial, account: account, token: token)
      for user in selection.reviewers {
        guard candidates.items.contains(where: { $0.id == user.id && $0.login == user.login }) else { throw HostingReviewError.targetChanged }
      }
    } else {
      for user in selection.reviewers {
        try Task.checkCancellation()
        let path = provider == .gitlab ? repo + "/members/all/" + user.id : repo + "/collaborators/" + HostingInstance.component(user.login) + "/permission"
        let (permission, _) = try await json(account, token: token, path: path)
        let raw = provider == .gitlab ? permission : permission["user"]
        let current = try Self.reviewer(raw, provider: provider)
        guard current.id == user.id, current.login == user.login else { throw HostingReviewError.targetChanged }
        if provider == .gitlab {
          guard permission["state"].string == "active", permission["access_level"].int >= 30 else { throw HostingReviewError.permissionRequired }
        } else {
          guard ["admin", "write", "maintain"].contains(permission["permission"].string) || Self.reviewerHasWrite(raw) else { throw HostingReviewError.permissionRequired }
        }
      }
    }
    let latest = try await reviewContext(binding, number: context.target.requestNumber, account: account, token: token)
    try context.validateCurrent(latest); try selection.validate(context: latest)
    let path = try reviewerRequestPath(binding, number: context.target.requestNumber, account: account)
    // This final GET supplies both the current identity/revision and the reviewers
    // that must be retained. No further slow read occurs before the write.
    let (snapshot, _) = try await json(account, token: token, path: path)
    try Self.reviewerValidateSnapshot(snapshot, context: context)
    let existing = try Self.reviewerUsers(snapshot[provider == .gitlab ? "reviewers" : "requested_reviewers"], provider: provider)
    let existingIDs = Set(existing.map(\.id)), added = selection.reviewers.filter { !existingIDs.contains($0.id) }
    guard !added.isEmpty else { throw HostingReviewError.alreadySubmitted }
    let expectedIDs = existingIDs.union(selection.reviewers.map(\.id)).sorted()
    let body: [String: HostingJSON] = ["reviewers": .array(added.map { .string($0.login) })]
    let receipt = HostingReviewReceipt(id: context.target.requestID, authorID: context.target.userID,
      commitSHA: context.revision.headSHA, requestedReviewerIDs: expectedIDs)
    try Task.checkCancellation()
    do {
      let response = try await http.request(instance: account.instance,
        path: path + "/requested_reviewers", token: token,
        method: "POST", body: try JSONEncoder().encode(HostingJSON.object(body)), oauthResponse: true)
      switch response.status {
      case 200...299: return receipt
      case 401: throw HostingError.unauthorized
      case 403 where provider != .gitea: throw HostingReviewError.permissionRequired
      case 404 where provider != .gitea: throw HostingError.notFound
      case 409 where provider != .gitea: throw HostingReviewError.revisionChanged
      case 422 where provider != .gitea: throw HostingReviewError.invalidBody
      case 429: throw HostingError.rateLimited
      default:
        // Reviewer APIs have no stable operation ID. The known PR/MR ID and exact
        // user IDs permit read-only reconciliation, including Gitea partial writes.
        return receipt
      }
    } catch is CancellationError { return receipt }
      catch let error as HostingReviewError { throw error }
      catch let error as HostingError {
        if [.networkFailure, .serverFailure, .invalidResponse, .responseTooLarge, .redirectRejected].contains(error) { return receipt }
        throw error
      } catch { return receipt }
  }

  public func readReviewerRequest(_ receipt: HostingReviewReceipt, selection: HostingReviewerSelection, context: HostingReviewContext,
    account: HostingAccount, token: HostingToken) async throws -> HostingReviewReceipt {
    let binding = try reviewerBinding(context, account: account)
    guard account.instance.provider != .gitlab else { throw HostingReviewError.unsupported }
    guard selection.target == context.target, selection.revision == context.revision,
      receipt.id == context.target.requestID, receipt.authorID == context.target.userID,
      receipt.commitSHA == context.revision.headSHA,
      Set(receipt.requestedReviewerIDs).isSuperset(of: selection.reviewers.map(\.id)) else { throw HostingReviewError.readbackRequired }
    let latest = try await reviewContext(binding, number: context.target.requestNumber, account: account, token: token)
    try context.validateCurrent(latest)
    // Identity, revision and requested users must come from one final response.
    // A context read followed by a separate users-only response could otherwise
    // clear an unknown result after a concurrent PR update or target change.
    let path = try reviewerRequestPath(binding, number: context.target.requestNumber, account: account)
    let (snapshot, _) = try await json(account, token: token, path: path)
    try Self.reviewerValidateSnapshot(snapshot, context: context)
    let users = try Self.reviewerUsers(snapshot["requested_reviewers"], provider: account.instance.provider)
    let ids = Set(users.map(\.id))
    guard ids.isSuperset(of: receipt.requestedReviewerIDs) else { throw HostingReviewError.readbackRequired }
    return HostingReviewReceipt(id: receipt.id, authorID: receipt.authorID, commitSHA: latest.revision.headSHA, requestedReviewerIDs: ids.sorted())
  }

  private func reviewerRequestPath(_ binding: RepositoryHostingBinding, number: Int, account: HostingAccount) throws -> String {
    try account.validateCredentialContext()
    guard binding.accountID == account.id, number > 0 else { throw HostingReviewError.targetChanged }
    return try repositoryPath(binding.repository, provider: account.instance.provider) + (account.instance.provider == .gitlab ? "/merge_requests/" : "/pulls/") + String(number)
  }
  private func reviewerBinding(_ context: HostingReviewContext, account: HostingAccount) throws -> RepositoryHostingBinding {
    let binding = try RepositoryHostingBinding(repositoryID: UUID(), accountID: context.target.accountID, remote: "", repository: context.target.repository)
    try context.target.validate(account: account, binding: binding); return binding
  }
  private static func reviewerValidateSnapshot(_ value: HostingJSON, context: HostingReviewContext) throws {
    let provider = context.target.instance.provider
    guard value["id"].string == context.target.requestID, value[provider == .gitlab ? "iid" : "number"].int == context.target.requestNumber else { throw HostingReviewError.targetChanged }
    let repositoryID = provider == .gitlab ? value["target_project_id"].string : value["base"]["repo"]["id"].string
    guard repositoryID == context.target.repositoryID else { throw HostingReviewError.targetChanged }
    guard ["open", "opened"].contains(value["state"].string) else { throw HostingReviewError.requestClosed }
    let head = provider == .gitlab ? value["sha"].string : value["head"]["sha"].string
    guard head == context.revision.headSHA else { throw HostingReviewError.revisionChanged }
    if provider == .gitlab {
      guard value["diff_refs"]["head_sha"].string == context.revision.headSHA,
        value["diff_refs"]["base_sha"].string == context.revision.baseSHA,
        value["diff_refs"]["start_sha"].string == context.revision.startSHA else { throw HostingReviewError.revisionChanged }
    } else {
      guard value["base"]["sha"].string == context.revision.baseSHA else { throw HostingReviewError.revisionChanged }
    }
  }
  private static func reviewer(_ value: HostingJSON, provider: HostingProvider) throws -> HostingReviewer {
    let id = value["id"].string, login = value[provider == .gitlab ? "username" : "login"].string
    guard let number = Int64(id), number > 0, String(number) == id, !login.isEmpty, login.utf8.count <= 256,
      !login.contains("/"), !login.contains("\\"), !login.unicodeScalars.contains(where: { $0.value < 33 }) else { throw HostingError.invalidResponse }
    return HostingReviewer(id: id, login: login, name: value["name"].string)
  }
  private static func reviewerUsers(_ value: HostingJSON, provider: HostingProvider) throws -> [HostingReviewer] {
    guard case .array = value else { throw HostingError.invalidResponse }
    guard value.array.count <= 1000 else { throw HostingError.responseTooLarge }
    var result: [HostingReviewer] = []
    for item in value.array {
      let user = try reviewer(item, provider: provider)
      if !result.contains(where: { $0.id == user.id }) { result.append(user) }
    }
    return result
  }
  private static func reviewerHasWrite(_ user: HostingJSON) -> Bool {
    user["permissions"]["push"].bool || user["permissions"]["maintain"].bool || user["permissions"]["admin"].bool
  }
  private static func reviewerPagination(_ provider: HostingProvider, page: Int) -> [URLQueryItem] {
    [URLQueryItem(name: "page", value: String(max(1, page))), URLQueryItem(name: provider == .gitea ? "limit" : "per_page", value: "50")]
  }
  private static func reviewerNext(_ response: HostingHTTPResponse, count: Int, page: Int) -> Int? {
    if let value = response.headers["x-next-page"] { return Int(value).flatMap { $0 > page ? $0 : nil } }
    if let value = response.headers["link"] { return value.contains("rel=\"next\"") ? page + 1 : nil }
    return count == 50 ? page + 1 : nil
  }
}
