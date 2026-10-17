import AppKit
import GitPierCore
import SwiftUI

private struct HostingReviewProviderFacts: Sendable {
  let writes: Int
  let reviews: Int
  let inlineComments: Int
  let discussions: Int
  let replies: Int
  let approved: Bool
  let lastReviewID: String?
  let lastReviewState: String?
  let events: [String]
  let pinned: Bool
  let multiLineComments: Int
  let reviewerIDs: [String]
}

@MainActor private final class HostingReviewModalObservation {
  var response: NSApplication.ModalResponse?
}

/// No URLSession or production credentials: unknown routes fail inside this synthetic server.
/// Stored responses are the server's own review/comment objects and stable IDs, not receipts
/// fabricated by the client. Assertions below exercise Session -> Coordinator -> API -> readback.
private actor HostingReviewProviderAcceptanceTransport: HostingTransport {
  static let head = String(repeating: "a", count: 40)
  static let base = String(repeating: "b", count: 40)
  static let start = String(repeating: "c", count: 40)
  static let path = "Sources/Review.swift"
  static let patch = "@@ -4,2 +4,2 @@\n context\n-old\n+new\n"
  private struct State {
    var writes = 0
    var reviews: [[String: Any]] = []
    var comments: [[String: Any]] = []
    var conversations: [[String: Any]] = []
    var discussions: [[String: Any]] = []
    var replies = 0
    var approved = false
    var approvalRuleReads = 0
    var discussionAttempts = 0
    var failDiscussion: Int?
    var events: [String] = []
    var pinned = true
    var requestedReviewers: [[String: Any]] = [["id": 81, "login": "existing-reviewer", "username": "existing-reviewer"]]
    var unknownNextWrite = false
    var blockReadbackAtWriteCount: Int?
  }
  private var states: [String: State] = [:]
  private var nextID = 100
  private var rejectedExternal = 0
  private func key(_ provider: HostingProvider, _ number: Int) -> String { provider.rawValue + ":" + String(number) }
  private func id() -> Int { nextID += 1; return nextID }
  private func user() -> [String: Any] { ["id": 42, "login": "provider-fixture", "username": "provider-fixture"] }
  private func response(_ object: Any, status: Int = 200) throws -> HostingHTTPResponse {
    HostingHTTPResponse(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), status: status)
  }
  func failDiscussion(_ attempt: Int, number: Int) {
    let key = key(.gitlab, number); var value = states[key] ?? State(); value.failDiscussion = attempt; states[key] = value
  }
  func makeNextWriteUnknown(_ provider: HostingProvider, number: Int, blockReadback: Bool = false) {
    let key = key(provider, number); var value = states[key] ?? State()
    value.unknownNextWrite = true; value.blockReadbackAtWriteCount = blockReadback ? value.writes + 1 : nil; states[key] = value
  }
  func seedExistingGiteaReview(number: Int) {
    let key = key(.gitea, number); var value = states[key] ?? State(), reviewID = id()
    value.reviews = [["id": reviewID, "user": user(), "body": "Existing platform review", "state": "COMMENT", "commit_id": Self.head, "comments_count": 1]]
    value.comments = [["id": id(), "pull_request_review_id": reviewID, "body": "Existing platform inline comment", "user": user(),
      "path": Self.path, "position": 5, "commit_id": Self.head, "created_at": "2026-10-18T00:01:00Z"]]
    states[key] = value
  }
  func facts(_ provider: HostingProvider, number: Int) -> HostingReviewProviderFacts {
    let value = states[key(provider, number)] ?? State()
    return HostingReviewProviderFacts(writes: value.writes, reviews: value.reviews.count,
      inlineComments: value.comments.filter { $0["in_reply_to_id"] == nil }.count, discussions: value.discussions.count,
      replies: value.replies, approved: value.approved, lastReviewID: value.reviews.last?["id"].map { String(describing: $0) },
      lastReviewState: value.reviews.last?["state"] as? String, events: value.events, pinned: value.pinned,
      multiLineComments: value.comments.filter { $0["start_line"] != nil }.count,
      reviewerIDs: value.requestedReviewers.compactMap { ($0["id"] as? Int).map(String.init) }.sorted())
  }
  func externalRejections() -> Int { rejectedExternal }
  func approvalRuleReads(number: Int) -> Int { states[key(.gitlab, number)]?.approvalRuleReads ?? 0 }
  private func pull(_ provider: HostingProvider, number: Int) -> [String: Any] {
    let reviewers = states[key(provider, number)]?.requestedReviewers ?? [["id": 81, "login": "existing-reviewer", "username": "existing-reviewer"]]
    return ["id": 1000 + number, "number": number, "iid": number, "title": "Synthetic provider review \(number)",
     "body": "Native review provider fixture", "description": "Native review provider fixture", "state": "open", "draft": false,
     "head": ["sha": Self.head, "ref": "feature/review", "repo": ["full_name": "example/review"]],
     "base": ["sha": Self.base, "ref": "main", "repo": ["id": 12]], "sha": Self.head,
     "diff_refs": ["head_sha": Self.head, "base_sha": Self.base, "start_sha": Self.start], "reviewers": reviewers, "requested_reviewers": reviewers,
     "source_branch": "feature/review", "target_branch": "main", "source_project_id": 12, "target_project_id": 12,
     "user": ["id": 99, "login": "fixture-author"], "author": ["id": 99, "username": "fixture-author"],
     "created_at": "2026-10-18T00:00:00Z", "updated_at": "2026-10-18T00:00:00Z",
     "html_url": "https://github.com/example/review/pull/\(number)",
     "web_url": "https://gitlab.provider.invalid/example/review/-/merge_requests/\(number)"]
  }
  private func inline(_ fields: [String: Any], provider: HostingProvider, number: Int, reviewID: Int?) throws -> [String: Any] {
    guard let body = fields["body"] as? String, !body.isEmpty else { throw HostingError.invalidResponse }
    var result: [String: Any] = ["id": id(), "body": body, "user": user(), "author": user(),
      "created_at": "2026-10-18T00:01:00Z", "commit_id": Self.head,
      "pull_request_url": "https://api.github.com/repos/example/review/pulls/\(number)"]
    if let reviewID { result["pull_request_review_id"] = reviewID }
    if provider == .github {
      guard fields["path"] as? String == Self.path, let line = fields["line"] as? Int,
        let side = fields["side"] as? String, ["LEFT", "RIGHT"].contains(side), [4, 5].contains(line) else { throw HostingError.invalidResponse }
      result["path"] = Self.path; result["line"] = line; result["side"] = side
      if let start = fields["start_line"] as? Int {
        guard start == 4, line == 5, fields["start_side"] as? String == side else { throw HostingError.invalidResponse }
        result["start_line"] = start; result["start_side"] = side
      }
    } else {
      guard let position = fields["position"] as? [String: Any], position["position_type"] as? String == "text",
        position["head_sha"] as? String == Self.head, position["base_sha"] as? String == Self.base,
        position["start_sha"] as? String == Self.start, position["old_path"] as? String == Self.path,
        position["new_path"] as? String == Self.path else { throw HostingError.invalidResponse }
      let old = position["old_line"] as? Int, new = position["new_line"] as? Int
      guard (old == 4 && new == 4) || (old == 5 && new == nil) || (old == nil && new == 5) else { throw HostingError.invalidResponse }
      result["position"] = position
      result["resolvable"] = true; result["resolved"] = false
    }
    return result
  }
  func send(_ request: URLRequest, limit: Int) async throws -> HostingHTTPResponse {
    guard let url = request.url, url.scheme == "https", let host = url.host,
      ["api.github.com", "gitlab.provider.invalid", "gitea.provider.invalid"].contains(host),
      request.value(forHTTPHeaderField: "Authorization")?.contains("synthetic-provider-review-only") == true else {
      rejectedExternal += 1; throw HostingError.insecureURL
    }
    let provider: HostingProvider = host == "api.github.com" ? .github : host == "gitlab.provider.invalid" ? .gitlab : .gitea
    let path = url.path, components = path.split(separator: "/").map(String.init), method = request.httpMethod ?? "GET"
    if path.hasSuffix("/user") { return try response(user()) }
    if path.hasSuffix("/version") { return try response(["version": "1.27.3"]) }
    if method == "GET", path.hasSuffix("/example/review") {
      return try response(["id": 12, "private": false, "archived": false, "permissions": ["pull": true, "push": true]])
    }
    let candidate: [String: Any] = ["id": 70, "login": "new-reviewer", "username": "new-reviewer", "name": "Synthetic Reviewer", "state": "active", "access_level": 40, "permissions": ["push": true]]
    if method == "GET", path.hasSuffix("/collaborators") || path.hasSuffix("/members/all") || (path.hasSuffix("/reviewers") && !path.contains("/pulls/")) { return try response([candidate]) }
    if method == "GET", path.hasSuffix("/collaborators/new-reviewer/permission") { return try response(["permission": "write", "user": candidate]) }
    if method == "GET", path.hasSuffix("/members/all/70") { return try response(candidate) }
    if let issueIndex = components.firstIndex(of: "issues"), components.count == issueIndex + 3,
      let number = Int(components[issueIndex + 1]), components.last == "comments" {
      let key = key(provider, number); var value = states[key] ?? State()
      if method == "GET" { return try response(value.conversations) }
      if method == "POST", let data = request.httpBody,
        let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any], let body = fields["body"] as? String {
        let comment: [String: Any] = ["id": id(), "body": body, "user": user(), "created_at": "2026-10-18T00:01:00Z"]
        value.writes += 1; value.conversations.append(comment); states[key] = value
        return try response(comment, status: 201)
      }
      return try response(["message": "unsupported synthetic conversation operation"], status: 405)
    }
    // GitHub's comment readback route has no PR number, so resolve its stable ID
    // from the server store and retain the authoritative pull_request_url.
    if method == "GET", path.contains("/pulls/comments/"), let raw = components.last, let commentID = Int(raw) {
      for (key, state) in states where key.hasPrefix("github:") {
        if let comment = state.comments.first(where: { $0["id"] as? Int == commentID }) { return try response(comment) }
      }
      return try response(["message": "fixture not found"], status: 404)
    }
    let marker = provider == .gitlab ? "merge_requests" : "pulls"
    guard let markerIndex = components.firstIndex(of: marker), components.count > markerIndex + 1,
      let number = Int(components[markerIndex + 1]) else { return try response(["message": "unsupported synthetic route"], status: 404) }
    let tail = Array(components.dropFirst(markerIndex + 2)), key = key(provider, number)
    var value = states[key] ?? State()
    let fields: [String: Any]
    if let data = request.httpBody { fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:] } else { fields = [:] }
    if method == "GET" {
      // A stable PR + user set can verify an ambiguous additive request. This fixture
      // deliberately makes those authoritative reads unavailable after its one write.
      if let threshold = value.blockReadbackAtWriteCount, value.writes >= threshold { return try response(["message": "synthetic target readback unavailable"], status: 503) }
      if tail.isEmpty { return try response(pull(provider, number: number)) }
      if tail == ["versions"] { return try response([["id": 10, "head_commit_sha": Self.head, "base_commit_sha": Self.base, "start_commit_sha": Self.start]]) }
      if tail == ["approvals"] { return try response(["user_can_approve": true, "user_has_approved": value.approved,
        "approved_by": value.approved ? [["user": user(), "approved_at": "2026-10-18T00:03:00Z"]] : []]) }
      if tail == ["approval_state"] {
        value.approvalRuleReads += 1; states[key] = value
        return try response(["approval_rules_overwritten": false, "rules": [["id": 9, "name": "Two maintainers", "rule_type": "regular", "approvals_required": 2, "approved": false, "approved_by": [user()], "eligible_approvers": [["id": 70, "username": "new-reviewer", "name": "Synthetic Reviewer"]], "contains_hidden_groups": true, "overridden": false]]])
      }
      if tail == ["files"] || tail == ["diffs"] {
        return try response([["filename": Self.path, "new_path": Self.path, "old_path": Self.path, "previous_filename": Self.path,
          "status": "modified", "patch": Self.patch, "diff": Self.patch]])
      }
      if tail == ["reviews"] { return try response(value.reviews) }
      if tail == ["requested_reviewers"] { return try response(["users": value.requestedReviewers]) }
      if tail.count >= 2, tail[0] == "reviews", let reviewID = Int(tail[1]) {
        if tail.count == 3, tail[2] == "comments" { return try response(value.comments.filter { $0["pull_request_review_id"] as? Int == reviewID }) }
        if let review = value.reviews.first(where: { $0["id"] as? Int == reviewID }) { return try response(review) }
      }
      if tail == ["comments"] { return try response(value.comments) }
      if tail == ["discussions"] { return try response(value.discussions) }
      if tail.count == 2, tail[0] == "discussions", let discussion = value.discussions.first(where: { $0["id"] as? String == tail[1] }) { return try response(discussion) }
      return try response(["message": "unsupported synthetic read"], status: 404)
    }
    if method == "PUT", provider == .gitlab, tail.count == 2, tail[0] == "discussions",
      let resolved = fields["resolved"] as? Bool, let i = value.discussions.firstIndex(where: { $0["id"] as? String == tail[1] }) {
      var notes = value.discussions[i]["notes"] as? [[String: Any]] ?? []
      guard !notes.isEmpty else { throw HostingError.invalidResponse }
      notes[0]["resolved"] = resolved; value.discussions[i]["notes"] = notes
      value.writes += 1; value.events.append(resolved ? "RESOLVE" : "UNRESOLVE"); states[key] = value
      if value.unknownNextWrite { throw URLError(.timedOut) }
      return try response(value.discussions[i])
    }
    if (method == "POST" && tail == ["requested_reviewers"]) || (method == "PUT" && provider == .gitlab && tail.isEmpty) {
      if provider == .gitlab { guard let ids = fields["reviewer_ids"] as? [Int], Set(ids) == [70, 81] else { throw HostingError.invalidResponse } }
      else { guard fields["reviewers"] as? [String] == ["new-reviewer"] else { throw HostingError.invalidResponse } }
      value.requestedReviewers.append(candidate); value.writes += 1; value.events.append("REQUEST_REVIEWERS"); states[key] = value
      if value.unknownNextWrite { throw URLError(.timedOut) }
      return try response(pull(provider, number: number))
    }
    guard method == "POST" else { return try response(["message": "unsupported synthetic method"], status: 405) }
    value.writes += 1
    if tail == ["reviews"] {
      guard fields["commit_id"] as? String == Self.head, let body = fields["body"] as? String else { return try response(["message": "wrong reviewed commit"], status: 422) }
      let reviewID = id(), event = fields["event"] as? String ?? "PENDING"
      let state = event == "APPROVE" || event == "APPROVED" ? "APPROVED" : event == "REQUEST_CHANGES" && provider == .github ? "CHANGES_REQUESTED" : event == "REQUEST_CHANGES" ? "REQUEST_CHANGES" : event == "PENDING" ? "PENDING" : provider == .github ? "COMMENTED" : "COMMENT"
      let review: [String: Any] = ["id": reviewID, "user": user(), "body": body, "state": state, "commit_id": Self.head,
        "submitted_at": "2026-10-18T00:02:00Z", "comments_count": (fields["comments"] as? [Any])?.count ?? 0]
      for comment in fields["comments"] as? [[String: Any]] ?? [] {
        value.comments.append(try inline(comment, provider: provider, number: number, reviewID: reviewID))
      }
      value.reviews.append(review); value.events.append(event); value.pinned = value.pinned && fields["commit_id"] as? String == Self.head
      states[key] = value; return try response(review)
    }
    if tail.count == 3, tail[0] == "reviews", tail[2] == "events", let reviewID = Int(tail[1]),
      let index = value.reviews.firstIndex(where: { $0["id"] as? Int == reviewID }) {
      let event = fields["event"] as? String ?? "", state = event == "APPROVE" ? "APPROVED" : event == "REQUEST_CHANGES" ? "CHANGES_REQUESTED" : "COMMENTED"
      value.reviews[index]["state"] = state; value.reviews[index]["body"] = fields["body"] as? String ?? ""
      value.events.append(event); let result = value.reviews[index]; states[key] = value; return try response(result)
    }
    if tail.count == 3, tail[0] == "comments", tail[2] == "replies", let parentID = Int(tail[1]),
      let parent = value.comments.first(where: { $0["id"] as? Int == parentID }), let body = fields["body"] as? String {
      var reply = parent; reply["id"] = id(); reply["body"] = body; reply["in_reply_to_id"] = parentID
      value.comments.append(reply); value.replies += 1; states[key] = value; return try response(reply, status: 201)
    }
    if tail == ["discussions"] {
      value.discussionAttempts += 1
      if value.failDiscussion == value.discussionAttempts { states[key] = value; return try response(["message": "synthetic validation failure"], status: 422) }
      let discussionID = "discussion" + String(id()), note: [String: Any]
      if fields["position"] != nil { note = try inline(fields, provider: .gitlab, number: number, reviewID: nil) }
      else { note = ["id": id(), "body": fields["body"] as? String ?? "", "author": user(), "created_at": "2026-10-18T00:02:00Z"] }
      let discussion: [String: Any] = ["id": discussionID, "individual_note": false, "notes": [note]]
      value.discussions.append(discussion); states[key] = value; return try response(discussion, status: 201)
    }
    if tail.count == 3, tail[0] == "discussions", tail[2] == "notes", let index = value.discussions.firstIndex(where: { $0["id"] as? String == tail[1] }) {
      let note: [String: Any] = ["id": id(), "body": fields["body"] as? String ?? "", "author": user(), "created_at": "2026-10-18T00:03:00Z"]
      var notes = value.discussions[index]["notes"] as? [[String: Any]] ?? []; notes.append(note); value.discussions[index]["notes"] = notes
      value.replies += 1; states[key] = value; return try response(note, status: 201)
    }
    if tail == ["approve"], provider == .gitlab, fields["sha"] as? String == Self.head {
      value.approved = true; value.pinned = value.pinned && fields["sha"] as? String == Self.head
      states[key] = value; return try response(["user_has_approved": true, "approved_by": [["user": user()]]], status: 201)
    }
    states[key] = value
    return try response(["message": "unsupported synthetic write"], status: 404)
  }
}

extension UIAcceptance {
  static func verifyHostingReviewProviders(root: URL, output: URL) async throws {
    guard root.resolvingSymlinksInPath().deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui.") else { throw HostingError.invalidInstance }
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-review-providers-" + UUID().uuidString)
    let destination = output.appendingPathComponent("review-providers")
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let persistence = ConfigurationStore(url: fixture.appendingPathComponent("workspace.json"))
    var workspace = WorkspaceConfiguration(); workspace.settings.completionNotifications = false; workspace.settings.language = .english
    try persistence.save(workspace)
    let store = AppStore(persistence: persistence), transport = HostingReviewProviderAcceptanceTransport(), vault = HostingAcceptanceVault()
    defer { store.shutdown() }
    var metadata = HostingMetadata(), accounts: [String: HostingAccount] = [:], bindings: [String: RepositoryHostingBinding] = [:]
    for provider in HostingProvider.allCases {
      let instance = try HostingInstance(provider: provider, url: provider == .github ? "https://github.com" : provider == .gitlab ? "https://gitlab.provider.invalid" : "https://gitea.provider.invalid")
      let scopes = provider == .github ? ["public_repo"] : provider == .gitlab ? ["api"] : ["write:repository", "write:issue"]
      let account = HostingAccount(instance: instance, user: HostingUser(stableID: "42", login: "provider-fixture"), kind: .pat, scopes: scopes, storageMode: .keychain)
      let binding = try RepositoryHostingBinding(repositoryID: UUID(), accountID: account.id, remote: "origin", repository: "example/review")
      accounts[provider.rawValue] = account; bindings[provider.rawValue] = binding; metadata.accounts.append(account); metadata.bindings.append(binding)
      try await vault.save(HostingToken(accessToken: "synthetic-provider-review-only", scopes: scopes), account: account)
    }
    try HostingMetadataStore(url: fixture.appendingPathComponent("workspace.hosting.json")).save(metadata)
    let hosting = HostingModel(store: store, http: HostingHTTPClient(transport: transport), vault: vault, openExternalURL: { _ in false }); store.hosting = hosting
    for account in metadata.accounts { try await hosting.tokens.unlock(account) }
    var assertions: [String: Bool] = [:], scenarios: [[String: Any]] = []
    let patch = HostingReviewProviderAcceptanceTransport.patch, document = DiffParser.parse(Data(patch.utf8))
    let file = HostingChangedFile(path: HostingReviewProviderAcceptanceTransport.path, oldPath: HostingReviewProviderAcceptanceTransport.path, kind: "modified", patch: patch)
    let added = try XCTHostingUnwrap(document.hunks.flatMap(\.lines).first(where: { $0.kind == .addition }))
    let deleted = try XCTHostingUnwrap(document.hunks.flatMap(\.lines).first(where: { $0.kind == .deletion }))

    // A different synthetic PR per decision prevents one workflow's state from proving another.
    for (index, decision) in HostingReviewDecision.allCases.enumerated() {
      let number = 31 + index, account = try XCTHostingUnwrap(accounts["github"]), binding = try XCTHostingUnwrap(bindings["github"])
      let session = try await providerReviewSession(hosting: hosting, store: store, account: account, binding: binding, number: number)
      session.beginInline(file: file, document: document, line: added, side: .new); session.composerBody = "Synthetic added-line review"; session.saveInlineDraft()
      session.beginInline(file: file, document: document, line: deleted, side: .old); session.composerBody = "Synthetic deleted-line review"; session.saveInlineDraft()
      try providerRequire(session.draft?.comments.count == 2, "GitHub did not retain both exact inline drafts")
      session.draft?.summary = "Synthetic pending summary"
      session.prepareDraft(pending: true)
      let before = await transport.facts(.github, number: number)
      try providerRequire(before.writes == 0 && session.confirmation != nil, "GitHub preview published a draft")
      let pending = try await providerReviewSubmit(session)
      try providerRequire(pending.complete, "GitHub pending review failed")
      let pendingFacts = await transport.facts(.github, number: number)
      try providerRequire(pendingFacts.lastReviewState == "PENDING" && pendingFacts.inlineComments == 2 && pendingFacts.reviews == 1, "GitHub pending review lost server comments")
      session.draft?.summary = "Synthetic final " + decision.rawValue; session.draft?.decision = decision
      let reviewID = try XCTHostingUnwrap(pendingFacts.lastReviewID)
      session.preparePending(HostingReviewThread(id: "reviews:" + reviewID, remoteID: reviewID, source: .reviews, comments: [], state: .pending))
      let submitted = try await providerReviewSubmit(session)
      let expected = decision == .approve ? "APPROVED" : decision == .requestChanges ? "CHANGES_REQUESTED" : "COMMENTED"
      try providerRequire(submitted.complete, "GitHub pending submit did not verify its decision")
      try providerRequire(session.draft?.summary.isEmpty == true && session.draft?.decision == .comment, "Submitted Pending Review retained its published local summary or decision")
      session.start(loadTimeline: true, refresh: true)
      try await waitFor { session.states[.inline]?.loaded == true && !session.contextLoading }
      let thread = try XCTHostingUnwrap(session.threads[.inline]?.first), rootComment = try XCTHostingUnwrap(thread.comments.first)
      session.begin(.reply(thread, rootComment)); session.composerBody = "Synthetic native root reply"; session.prepareComposer()
      try providerRequire(try await providerReviewSubmit(session).complete, "GitHub native reply failed")
      let facts = await transport.facts(.github, number: number)
      try providerRequire(facts.lastReviewState == expected && facts.reviews == 1 && facts.replies == 1 && facts.writes == 3 && facts.pinned, "GitHub workflow server state was incorrect")
      assertions["github_" + decision.rawValue + "_pending_inline_reply_verified"] = true
      scenarios.append(["provider": "github", "number": number, "decision": decision.rawValue, "writes": facts.writes, "review_state": expected, "inline_comments": facts.inlineComments, "replies": facts.replies])
      if decision == .requestChanges { try await providerReviewCapture(session, store: store, to: destination.appendingPathComponent("github-request-changes.png")) }
      session.stopReading()
    }

    let github = try XCTHostingUnwrap(accounts["github"]), githubBinding = try XCTHostingUnwrap(bindings["github"])
    let rangeSession = try await providerReviewSession(hosting: hosting, store: store, account: github, binding: githubBinding, number: 40)
    let contextLine = try XCTHostingUnwrap(document.hunks.flatMap(\.lines).first(where: { $0.kind == .context }))
    rangeSession.beginInline(file: file, document: document, line: added, side: .new)
    rangeSession.selectInlineStartLine(contextLine.id)
    guard case .inline(let selectedRange) = rangeSession.composer else { throw HostingReviewError.unanchorable }
    try providerRequire(selectedRange.startLine == 4 && selectedRange.newLine == 5 && selectedRange.rangeCode == "context\nnew", "GitHub range picker did not select exact side coordinates")
    rangeSession.composerBody = "Synthetic two-line range"; rangeSession.saveInlineDraft()
    rangeSession.draft?.summary = "Synthetic range review"; rangeSession.prepareDraft()
    try providerRequire(try await providerReviewSubmit(rangeSession).complete, "GitHub range review failed verified submission")
    rangeSession.start(loadTimeline: true, refresh: true)
    try await waitFor { rangeSession.states[.inline]?.loaded == true && !rangeSession.contextLoading }
    let rangedComment = try XCTHostingUnwrap(rangeSession.threads[.inline]?.first?.comments.first)
    let rangeFacts = await transport.facts(.github, number: 40)
    try providerRequire(rangedComment.startLine == 4 && rangedComment.newLine == 5 && rangeFacts.multiLineComments == 1, "GitHub platform range fields were not read back")
    assertions["github_same_side_range_start_end_code_and_receipt_verified"] = true
    try await providerReviewCapture(rangeSession, store: store, to: destination.appendingPathComponent("github-multiline-range.png"))
    rangeSession.stopReading()

    // Confirmation is immutable; another window can continue editing the shared local draft.
    let changedDraft = try await providerReviewSession(hosting: hosting, store: store, account: github, binding: githubBinding, number: 41)
    for (line, side, body) in [(added, HostingReviewSide.new, "Confirmed first inline"), (deleted, HostingReviewSide.old, "Confirmed unchanged inline")] {
      changedDraft.beginInline(file: file, document: document, line: line, side: side); changedDraft.composerBody = body; changedDraft.saveInlineDraft()
    }
    changedDraft.draft?.summary = "Confirmed review summary"; changedDraft.prepareDraft()
    let changedOriginal = try XCTHostingUnwrap(changedDraft.draft?.comments.first)
    let addedLater = HostingReviewDraftComment(body: "New inline added after preview", anchor: changedOriginal.anchor)
    changedDraft.draft?.comments[0].body = "Inline body edited after preview"
    changedDraft.draft?.comments.append(addedLater)
    changedDraft.draft?.summary = "Summary edited after preview"; changedDraft.draft?.decision = .approve
    try providerRequire(try await providerReviewSubmit(changedDraft).complete, "Confirmed review did not submit its original snapshot")
    try providerRequire(changedDraft.draft?.comments.count == 2 && changedDraft.draft?.comments.first?.id == changedOriginal.id
      && changedDraft.draft?.comments.first?.body == "Inline body edited after preview" && changedDraft.draft?.comments.last == addedLater
      && changedDraft.draft?.summary == "Summary edited after preview" && changedDraft.draft?.decision == .approve,
      "Successful review cleared a draft value edited or added after preview")
    assertions["review_success_consumes_only_exact_confirmed_summary_decision_inline_values"] = true
    changedDraft.discardDraft(); changedDraft.stopReading()

    let gitlab = try XCTHostingUnwrap(accounts["gitlab"]), gitlabBinding = try XCTHostingUnwrap(bindings["gitlab"])
    let gitlabSession = try await providerReviewSession(hosting: hosting, store: store, account: gitlab, binding: gitlabBinding, number: 51)
    try providerRequire(gitlabSession.context?.capabilities.contains(.draft) == false && gitlabSession.context?.capabilities.contains(.requestChanges) == false, "GitLab advertised an invented review decision")
    gitlabSession.begin(.comment); gitlabSession.composerBody = "Synthetic GitLab conversation"; gitlabSession.prepareComposer()
    try providerRequire(try await providerReviewSubmit(gitlabSession).complete, "GitLab conversation failed")
    gitlabSession.beginInline(file: file, document: document, line: added, side: .new); gitlabSession.composerBody = "Synthetic GitLab diff discussion"; gitlabSession.prepareComposer()
    try providerRequire(try await providerReviewSubmit(gitlabSession).complete, "GitLab inline discussion failed")
    gitlabSession.start(loadTimeline: true, refresh: true)
    try await waitFor { gitlabSession.states[.conversation]?.loaded == true && gitlabSession.states[.inline]?.loaded == true && !gitlabSession.contextLoading }
    let glThread = try XCTHostingUnwrap(gitlabSession.threads[.conversation]?.first), glComment = try XCTHostingUnwrap(glThread.comments.first)
    gitlabSession.begin(.reply(glThread, glComment)); gitlabSession.composerBody = String(repeating: "Synthetic GitLab discussion reply with native scroll context.\n", count: 45); gitlabSession.prepareComposer()
    try providerRequire(try await providerReviewSubmit(gitlabSession).complete, "GitLab reply failed")
    gitlabSession.draft?.summary = ""; gitlabSession.draft?.decision = .approve; gitlabSession.prepareDraft()
    try providerRequire(try await providerReviewSubmit(gitlabSession).complete, "GitLab approval failed")
    let glFacts = await transport.facts(.gitlab, number: 51)
    try providerRequire(glFacts.discussions == 2 && glFacts.replies == 1 && glFacts.approved && glFacts.writes == 4 && glFacts.pinned, "GitLab independent operations were combined or lost")
    assertions["gitlab_conversation_inline_reply_approval_independent_verified"] = true
    let guiAssistedRules = ProcessInfo.processInfo.environment["GITPIER_REVIEW_MENU_INTERACTIVE"] == "1"
    if guiAssistedRules {
      try await providerReviewLoadRulesUsingControls(gitlabSession, store: store, transport: transport,
        to: destination.appendingPathComponent("gitlab-rules-expanded.png"))
    } else {
      let initialReads = await transport.approvalRuleReads(number: gitlabSession.number)
      gitlabSession.loadApprovalRules()
      try await waitFor { !gitlabSession.approvalRulesLoading && gitlabSession.approvalRules != nil }
      try providerRequire(await transport.approvalRuleReads(number: gitlabSession.number) == initialReads + 1,
        "Independent project rules read did not use exactly one server response")
    }
    try providerRequire(gitlabSession.approvalRules?.availability == .available && gitlabSession.approvalRules?.rules.first?.approved == false && gitlabSession.approvalRules?.rules.first?.approvalsRequired == 2 && glFacts.approved, "GitLab project rule state was inferred from individual approval")
    assertions["gitlab_project_rules_loaded_independently_not_inferred_from_personal_approval"] = true
    if guiAssistedRules { assertions["gitlab_rules_gui_assisted_disclosure_load_and_server_state_visible"] = true }
    scenarios.append(["provider": "gitlab", "number": 51, "writes": glFacts.writes, "discussions": glFacts.discussions, "replies": glFacts.replies, "approved": glFacts.approved])
    try await providerReviewCapture(gitlabSession, store: store, to: destination.appendingPathComponent("gitlab-approval.png"))
    let glRequest = try await hosting.api.request(gitlabBinding, number: 51, account: gitlab, token: try await hosting.tokens.token(for: gitlab))
    let glHost = NSHostingView(rootView: HostingRequestDetail(hosting: hosting, binding: gitlabBinding, account: gitlab, request: glRequest, initialTab: 3).environmentObject(store))
    glHost.sizingOptions = []; glHost.autoresizingMask = [.width, .height]
    let glWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    glWindow.isReleasedWhenClosed = false; glWindow.contentView = glHost; glWindow.center(); glWindow.makeKeyAndOrderFront(nil)
    try await settle()
    guard let glScroll = descendants(glHost).compactMap({ $0 as? NSScrollView }).first(where: { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 100 }),
      let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -180, wheel2: 0, wheel3: 0).flatMap({ NSEvent(cgEvent: $0) }) else { throw GitPierError.invalidInput("GitLab threaded native scroll unavailable") }
    glScroll.scrollWheel(with: wheel); try await Task.sleep(for: .milliseconds(180))
    let glTop = glScroll.contentView.bounds.minY
    try providerRequire(glTop > 0, "GitLab native thread wheel did not scroll")
    gitlabSession.draft?.summary = "Unsent summary remains while resolving"
    let resolvable = try XCTHostingUnwrap(gitlabSession.threads[.inline]?.first)
    gitlabSession.prepareResolution(resolvable, resolved: true)
    try providerRequire(try await providerReviewNativeSubmit(gitlabSession, window: glWindow).complete, "GitLab resolve did not verify")
    let resolved = try XCTHostingUnwrap(gitlabSession.threads[.inline]?.first)
    try providerRequire(resolved.id == resolvable.id && resolved.resolved == true && abs(glScroll.contentView.bounds.minY - glTop) < 2 && gitlabSession.draft?.summary == "Unsent summary remains while resolving", "GitLab resolve changed thread identity, scroll or unrelated draft")
    gitlabSession.prepareResolution(resolved, resolved: false)
    try providerRequire(try await providerReviewNativeSubmit(gitlabSession, window: glWindow).complete, "GitLab unresolve did not verify")
    try providerRequire(gitlabSession.threads[.inline]?.first?.resolved == false && abs(glScroll.contentView.bounds.minY - glTop) < 2, "GitLab unresolve lost the thread scroll position")
    try await captureHostingWindow(glWindow, to: destination.appendingPathComponent("gitlab-resolve-unresolve-native.png")); glWindow.close()
    assertions["gitlab_resolve_unresolve_native_confirmation_thread_scroll_preserved"] = true
    gitlabSession.draft?.summary = ""
    gitlabSession.stopReading()

    let partial = try await providerReviewSession(hosting: hosting, store: store, account: gitlab, binding: gitlabBinding, number: 52)
    for body in ["Synthetic same-anchor first", "Synthetic same-anchor second"] {
      partial.beginInline(file: file, document: document, line: added, side: .new); partial.composerBody = body; partial.saveInlineDraft()
    }
    let originals = try XCTHostingUnwrap(partial.draft?.comments)
    try providerRequire(originals.count == 2 && originals[0].id != originals[1].id && originals[0].anchor == originals[1].anchor, "GitLab fixture did not preserve independent same-anchor draft identities")
    await transport.failDiscussion(2, number: 52)
    partial.prepareDraft()
    let partialReport = try await providerReviewSubmit(partial)
    try providerRequire(partialReport.submittedCount == 1 && !partialReport.complete && !partialReport.hasUnknown,
      "GitLab partial batch did not retain per-item outcomes")
    try providerRequire(partial.draft?.comments.count == 1 && partial.draft?.comments.first?.id == originals[1].id && partial.draft?.comments.first?.body == originals[1].body,
      "GitLab partial batch removed the failed same-anchor draft")
    let partialFacts = await transport.facts(.gitlab, number: 52)
    try providerRequire(partialFacts.discussions == 1 && partialFacts.writes == 2, "GitLab partial batch repeated a successful discussion")
    assertions["gitlab_same_anchor_partial_success_keeps_only_failed_source_id"] = true
    scenarios.append(["provider": "gitlab", "number": 52, "writes": partialFacts.writes, "published": partialReport.submittedCount, "remaining_drafts": partial.draft?.comments.count ?? -1])
    try await providerReviewCapture(partial, store: store, to: destination.appendingPathComponent("gitlab-partial-same-anchor.png"))
    partial.stopReading()

    let changedInline = try await providerReviewSession(hosting: hosting, store: store, account: gitlab, binding: gitlabBinding, number: 53)
    changedInline.beginInline(file: file, document: document, line: added, side: .new); changedInline.composerBody = "Confirmed GitLab inline"; changedInline.saveInlineDraft()
    changedInline.prepareDraft()
    let changedInlineID = try XCTHostingUnwrap(changedInline.draft?.comments.first?.id)
    changedInline.draft?.comments[0].body = "GitLab inline edited after preview"
    try providerRequire(try await providerReviewSubmit(changedInline).complete, "GitLab confirmed inline did not submit")
    try providerRequire(changedInline.draft?.comments.first?.id == changedInlineID && changedInline.draft?.comments.first?.body == "GitLab inline edited after preview",
      "GitLab inline success deleted a changed draft sharing its original UUID")
    assertions["gitlab_inline_success_preserves_same_id_body_edited_after_preview"] = true
    changedInline.discardDraft(); changedInline.stopReading()

    let gitea = try XCTHostingUnwrap(accounts["gitea"]), giteaBinding = try XCTHostingUnwrap(bindings["gitea"])
    for (index, decision) in HostingReviewDecision.allCases.enumerated() {
      let number = 71 + index, session = try await providerReviewSession(hosting: hosting, store: store, account: gitea, binding: giteaBinding, number: number)
      try providerRequire(session.context?.capabilities.contains(.inlineComment) == false, "Gitea unverified inline creation became enabled")
      session.beginInline(file: file, document: document, line: added, side: .new); session.composerBody = "Synthetic unsupported Gitea inline"; session.saveInlineDraft()
      try providerRequire(session.draft?.comments.isEmpty == true && session.actionError != nil, "Gitea unsupported inline draft was accepted")
      session.composer = nil; session.composerBody = ""; session.actionError = nil
      session.draft?.summary = "Synthetic browser-only Gitea " + decision.rawValue; session.draft?.decision = decision; session.prepareDraft()
      let facts = await transport.facts(.gitea, number: number)
      let disabled: [HostingReviewCapability] = [.draft, .submitReview, .approve, .requestChanges]
      try providerRequire(disabled.allSatisfy { session.context?.capabilities.contains($0) == false }
        && session.confirmation == nil && session.actionError != nil && session.reviewBrowserExplanation?.contains("another pending review") == true
        && facts.writes == 0 && facts.reviews == 0 && session.draft?.summary == "Synthetic browser-only Gitea " + decision.rawValue,
        "Gitea unsafe review became available, wrote remotely or lost its private draft")
      assertions["gitea_" + decision.rawValue + "_browser_only_zero_POST"] = true
      scenarios.append(["provider": "gitea", "number": number, "decision": decision.rawValue, "writes": facts.writes, "review_browser_only": true, "inline_disabled": true])
      if decision == .comment { try await providerReviewCapture(session, store: store, to: destination.appendingPathComponent("gitea-review-browser-only.png")) }
      session.discardDraft(); session.stopReading()
    }
    let unsafePending = try await providerReviewSession(hosting: hosting, store: store, account: gitea, binding: giteaBinding, number: 79)
    unsafePending.draft?.summary = "Synthetic Gitea pending"; unsafePending.prepareDraft(pending: true)
    let afterPending = await transport.facts(.gitea, number: 79)
    try providerRequire(unsafePending.confirmation == nil && unsafePending.actionError != nil && afterPending.writes == 0
      && unsafePending.draft?.summary == "Synthetic Gitea pending", "Gitea unsafe pending creation wrote or lost the draft")
    assertions["gitea_review_and_pending_creation_browser_only_no_external_pending_consumption"] = true
    try await providerReviewCapture(unsafePending, store: store, to: destination.appendingPathComponent("gitea-pending-submit-disabled.png"))
    unsafePending.discardDraft(); unsafePending.stopReading()

    let existingGitea = 80
    await transport.seedExistingGiteaReview(number: existingGitea)
    let giteaReply = try await providerReviewSession(hosting: hosting, store: store, account: gitea, binding: giteaBinding, number: existingGitea)
    giteaReply.begin(.comment); giteaReply.composerBody = "Synthetic Gitea ordinary issue comment"; giteaReply.prepareComposer()
    try providerRequire(try await providerReviewSubmit(giteaReply).complete, "Gitea ordinary issue conversation stopped working with review gate")
    giteaReply.start(loadTimeline: true, refresh: true)
    try await waitFor { giteaReply.states[.inline]?.loaded == true && !giteaReply.contextLoading }
    let giteaThread = try XCTHostingUnwrap(giteaReply.threads[.inline]?.first)
    try providerRequire(giteaThread.comments.isEmpty && giteaThread.hasMoreReplies, "Gitea existing comments were not loaded on demand")
    giteaReply.loadReplies(giteaThread); try await waitFor { !giteaReply.replyLoading.contains(giteaThread.id) }
    let loadedGitea = try XCTHostingUnwrap(giteaReply.threads[.inline]?.first), giteaRoot = try XCTHostingUnwrap(loadedGitea.comments.first)
    try providerRequire(giteaReply.replyPages[loadedGitea.id] == nil, "Gitea native bounded comment collection invented pagination")
    giteaReply.begin(.reply(loadedGitea, giteaRoot)); giteaReply.composerBody = "Synthetic reply to explicitly selected existing Gitea comment"; giteaReply.prepareComposer()
    try providerRequire(try await providerReviewSubmit(giteaReply).complete, "Gitea existing review reply stopped working with review gate")
    let giteaReplyFacts = await transport.facts(.gitea, number: existingGitea)
    try providerRequire(giteaReplyFacts.writes == 2 && giteaReplyFacts.replies == 1 && giteaReplyFacts.reviews == 1, "Gitea reply created or submitted an unrelated review")
    assertions["gitea_issue_comment_existing_review_reply_bounded_read_preserved"] = true
    giteaReply.stopReading()

    for provider in HostingProvider.allCases {
      let account = try XCTHostingUnwrap(accounts[provider.rawValue]), binding = try XCTHostingUnwrap(bindings[provider.rawValue])
      let number = provider == .github ? 45 : provider == .gitlab ? 55 : 85
      let session = try await providerReviewSession(hosting: hosting, store: store, account: account, binding: binding, number: number)
      if provider == .gitlab {
        session.loadExistingReviewers(); try await waitFor { !session.reviewerLoading }
        session.beginReviewers()
        let facts = await transport.facts(provider, number: number)
        try providerRequire(session.context?.capabilities.contains(.requestReviewers) == false && session.existingReviewers.map(\.id) == ["81"] && !session.reviewersPresented && facts.writes == 0, "GitLab unsafe replacement reviewer write was exposed")
        assertions["gitlab_reviewers_readonly_browser_only_no_replacing_PUT"] = true
        session.stopReading(); continue
      }
      session.beginReviewers()
      try await waitFor { !session.reviewerLoading }
      try providerRequire(session.reviewerCandidates.map(\.id) == ["70"] && session.existingReviewers.map(\.id) == ["81"], "Reviewer picker did not use candidate and existing native IDs")
      session.draft?.summary = "Unsent review summary stays independent"
      if provider == .github {
        try await providerReviewCapturePanel(HostingReviewerPicker(session: session), store: store,
          size: NSSize(width: 620, height: 570), to: destination.appendingPathComponent("github-reviewer-picker.png"))
      }
      session.stageReviewers(session.reviewerCandidates); session.prepareStagedReviewers()
      let before = await transport.facts(provider, number: number)
      try providerRequire(before.writes == 0 && session.confirmation != nil, "Reviewer selection sent notifications before confirmation")
      if provider == .github, let confirmation = session.confirmation {
        try await providerReviewCapturePanel(HostingReviewConfirmationView(session: session, snapshot: confirmation), store: store,
          size: NSSize(width: 760, height: 680), to: destination.appendingPathComponent("github-reviewer-confirmation.png"))
      }
      try providerRequire(try await providerReviewSubmit(session).complete, "Reviewer request did not verify native state")
      let after = await transport.facts(provider, number: number)
      try providerRequire(after.writes == 1 && after.reviewerIDs == ["70", "81"] && session.draft?.summary == "Unsent review summary stays independent", "Reviewer request replaced an existing user or cleared a draft")
      assertions[provider.rawValue + "_reviewer_confirmation_notification_existing_users_preserved"] = true
      try await providerReviewCapture(session, store: store, to: destination.appendingPathComponent(provider.rawValue + "-reviewers.png"))
      session.stopReading()
    }

    let unknownReviewers = try await providerReviewSession(hosting: hosting, store: store, account: github, binding: githubBinding, number: 46)
    unknownReviewers.beginReviewers(); try await waitFor { !unknownReviewers.reviewerLoading }
    unknownReviewers.stageReviewers(unknownReviewers.reviewerCandidates); unknownReviewers.prepareStagedReviewers()
    await transport.makeNextWriteUnknown(.github, number: 46, blockReadback: true)
    try providerRequire(try await providerReviewSubmit(unknownReviewers).hasUnknown, "Unknown reviewer request was presented as certain")
    try await providerReviewVerifyUnknownClose(unknownReviewers, store: store, transport: transport, to: destination.appendingPathComponent("reviewer-unknown-close-guard.png"))
    let unknownReviewerFacts = await transport.facts(.github, number: 46)
    try providerRequire(unknownReviewerFacts.writes == 1 && unknownReviewerFacts.reviewerIDs == ["70", "81"], "Unknown reviewer request was repeated or lost its server result")
    assertions["unknown_reviewer_request_without_draft_keeps_native_close_and_quit_guard"] = true

    let unknownResolve = try await providerReviewSession(hosting: hosting, store: store, account: gitlab, binding: gitlabBinding, number: 56)
    unknownResolve.beginInline(file: file, document: document, line: added, side: .new); unknownResolve.composerBody = "Synthetic discussion to resolve"; unknownResolve.prepareComposer()
    try providerRequire(try await providerReviewSubmit(unknownResolve).complete, "Unknown resolve fixture could not establish its discussion")
    unknownResolve.start(loadTimeline: true, refresh: true)
    try await waitFor { unknownResolve.states[.inline]?.loaded == true && !unknownResolve.contextLoading }
    let unknownResolveThread = try XCTHostingUnwrap(unknownResolve.threads[.inline]?.first)
    unknownResolve.prepareResolution(unknownResolveThread, resolved: true)
    await transport.makeNextWriteUnknown(.gitlab, number: 56, blockReadback: true)
    try providerRequire(try await providerReviewSubmit(unknownResolve).hasUnknown, "Unknown discussion resolution was presented as certain")
    try await providerReviewVerifyUnknownClose(unknownResolve, store: store, transport: transport, to: destination.appendingPathComponent("resolve-unknown-close-guard.png"))
    let unknownResolveFacts = await transport.facts(.gitlab, number: 56)
    try providerRequire(unknownResolveFacts.writes == 2 && unknownResolveFacts.events == ["RESOLVE"], "Unknown discussion resolution was repeated")
    assertions["unknown_resolve_without_draft_keeps_native_close_and_quit_guard"] = true
    let external = await transport.externalRejections()
    try providerRequire(external == 0, "Provider fixture attempted an external host")
    assertions["synthetic_transport_only_no_network_or_production_credentials"] = true
    let report: [String: Any] = ["schema": 1, "verification": "native Session and Coordinator with synthetic provider API responses", "guiAssistedRules": guiAssistedRules,
      "real_service_acceptance": false, "assertions": assertions, "scenarios": scenarios,
      "limitations": ["Real remote writes require maintainer authorization.", "Gitea review creation, pending submission, approval and inline creation remain browser-only.", "This fixture does not claim real provider permission or comment-placement acceptance."]]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("provider-flows.json"))
    store.reviewSessions.stop()
  }

  private static func providerReviewSession(hosting: HostingModel, store: AppStore, account: HostingAccount,
    binding: RepositoryHostingBinding, number: Int) async throws -> HostingReviewSession {
    let token = try await hosting.tokens.token(for: account)
    let request = try await hosting.api.request(binding, number: number, account: account, token: token)
    let session = store.reviewSessions.session(hosting: hosting, binding: binding, account: account, request: request)
    session.start(loadTimeline: false)
    try await waitFor { !session.contextLoading && (session.context != nil || session.contextError != nil) }
    try providerRequire(session.context != nil && session.contextError == nil && session.identityValid, "Provider session context failed")
    return session
  }
  private static func providerReviewSubmit(_ session: HostingReviewSession) async throws -> HostingReviewSubmissionReport {
    let confirmation = try XCTHostingUnwrap(session.confirmation)
    session.submit(confirmation)
    try await waitFor { !session.submitting }
    let report = try XCTHostingUnwrap(session.report)
    try providerRequire(report.confirmationID == confirmation.id, "Provider session returned an earlier confirmation result")
    return report
  }
  private static func providerReviewNativeSubmit(_ session: HostingReviewSession, window: NSWindow) async throws -> HostingReviewSubmissionReport {
    let confirmation = try XCTHostingUnwrap(session.confirmation)
    let deadline = Date().addingTimeInterval(8)
    var control: NSObject?
    while Date() < deadline {
      control = window.sheets.compactMap(\.contentView).compactMap { accessibleButton($0, title: "Confirm & Submit", enabled: true) }.first
      if control != nil { break }; try await Task.sleep(for: .milliseconds(50))
    }
    guard let control else { throw GitPierError.invalidInput("Native provider confirmation unavailable") }
    let selector = NSSelectorFromString("accessibilityPerformPress")
    typealias Press = @convention(c) (AnyObject, Selector) -> Bool
    let press = unsafeBitCast(control.method(for: selector), to: Press.self)
    guard press(control, selector) else { throw GitPierError.invalidInput("Native provider confirmation press failed") }
    try await waitFor { !session.submitting && session.report?.confirmationID == confirmation.id && window.sheets.isEmpty }
    return try XCTHostingUnwrap(session.report)
  }
  private static func providerReviewVerifyUnknownClose(_ session: HostingReviewSession, store: AppStore,
    transport: HostingReviewProviderAcceptanceTransport, to url: URL) async throws {
    try providerRequire(!session.hasPrivateDraftContent && session.hasUnresolvedResult && session.hasUnsavedContent
      && store.reviewSessions.pending.contains(where: { $0 === session }), "A bodyless unknown operation escaped the review registry close guard")
    let host = NSHostingView(rootView: HostingReviewStatus(session: session).environmentObject(store).padding(20))
    host.sizingOptions = []; host.autoresizingMask = [.width, .height]
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
    defer { window.close(); session.stopReading() }
    let target = try XCTHostingUnwrap(session.context?.target), provider = session.account.instance.provider
    let initialWrites = await transport.facts(provider, number: session.number).writes
    for quitting in [false, true] {
      let alert = try XCTHostingUnwrap(store.reviewSessions.closeAlert(store: store, quitting: quitting))
      try providerRequire(alert.informativeText.contains(session.displayName), "Native close alert omitted the bodyless unknown target")
      let observation = HostingReviewModalObservation()
      alert.beginSheetModal(for: window) { response in
        Task { @MainActor in observation.response = response }
      }
      try await waitFor { !window.sheets.isEmpty && alert.window.isVisible }
      alert.window.makeKeyAndOrderFront(nil)
      if !quitting { try await captureHostingWindow(alert.window, to: url) }
      try providerRequire(alert.buttons.count == 2, "Native close alert did not expose the expected Cancel button")
      let cancel = alert.buttons[1]
      try providerRequire(cancel.title == store.text("Cancel", "取消") && cancel.isEnabled && cancel.window === alert.window,
        "Native close alert Cancel button was unavailable")
      cancel.performClick(nil) // One real AppKit action; completion proves which button closed it.
      try await waitFor { observation.response != nil && window.sheets.isEmpty }
      let coordinatorBlocked = await store.reviewSessions.coordinator.isBlocked(target)
      let writes = await transport.facts(provider, number: session.number).writes
      let record: [String: Any] = ["quitting": quitting, "modalResponse": observation.response?.rawValue ?? 0,
        "cancelResponse": observation.response == .alertSecondButtonReturn, "sheetDismissed": window.sheets.isEmpty,
        "targetBlocked": session.targetBlocked, "reportUnknown": session.report?.hasUnknown == true,
        "coordinatorBlocked": coordinatorBlocked, "postCountUnchanged": writes == initialWrites]
      try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: url.deletingPathExtension().appendingPathExtension(quitting ? "quit.json" : "close.json"))
      try providerRequire(observation.response == .alertSecondButtonReturn && session.targetBlocked && session.report?.hasUnknown == true
        && coordinatorBlocked && !session.canCompose && writes == initialWrites,
        "Native close Cancel did not preserve the unresolved operation and its write count")
    }
  }
  private static func providerReviewCapture(_ session: HostingReviewSession, store: AppStore, to url: URL) async throws {
    let host = NSHostingView(rootView: HostingReviewView(session: session).environmentObject(store).padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    host.sizingOptions = []; host.autoresizingMask = [.width, .height]
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.title = session.displayName + " · Synthetic Provider Acceptance"; window.contentView = host
    window.center(); window.makeKeyAndOrderFront(nil); defer { window.close() }
    try await settle(); try await captureHostingWindow(window, to: url)
  }
  private static func providerReviewLoadRulesUsingControls(_ session: HostingReviewSession, store: AppStore,
    transport: HostingReviewProviderAcceptanceTransport, to url: URL) async throws {
    let host = NSHostingView(rootView: HostingReviewView(session: session).environmentObject(store).padding(16))
    host.sizingOptions = []; host.autoresizingMask = [.width, .height]
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 820), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.title = "GitLab Approval Rules · GUI-assisted synthetic fixture"
    window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    defer { window.close() }
    try await settle()
    let initial = await transport.approvalRuleReads(number: session.number)
    let pending = url.deletingPathExtension().appendingPathExtension("interactive.json")
    var stage = "waiting-for-real-disclosure-and-load"
    do {
      guard ProcessInfo.processInfo.environment["GITPIER_REVIEW_MENU_INTERACTIVE"] == "1" else {
        throw GitPierError.invalidInput("Native rules control acceptance requires explicit GUI-assisted mode")
      }
      let request: [String: Any] = ["state": "waitingForRealDisclosureAndLoad", "verification": "GUI-assisted real rule controls",
        "requestedAction": "Expand GitLab Project Rules & Reviewers and click Load Approval Rules once",
        "initialRuleReads": initial, "applicationActive": NSApp.isActive, "windowKey": window.isKeyWindow,
        "windowNumber": window.windowNumber]
      try JSONSerialization.data(withJSONObject: request, options: [.prettyPrinted, .sortedKeys]).write(to: pending)
      let deadline = Date().addingTimeInterval(120)
      var completed = false
      while Date() < deadline {
        let reads = await transport.approvalRuleReads(number: session.number)
        try providerRequire(reads <= initial + 1, "GUI-assisted rule controls requested more than one server read")
        if reads == initial + 1 && !session.approvalRulesLoading && session.approvalRules?.availability == .available
          && session.approvalRules?.rules.first?.approvalsRequired == 2 && session.approvalRules?.rules.first?.approved == false {
          completed = true; break
        }
        try await Task.sleep(for: .milliseconds(250))
      }
      try providerRequire(completed, "GUI-assisted rules Disclosure / Load did not produce the required server state")
      stage = "real-control-server-result"
      let result: [String: Any] = ["state": "realControlsReadBack", "verification": "GUI-assisted real rule controls",
        "ruleReads": await transport.approvalRuleReads(number: session.number), "initialRuleReads": initial,
        "requiredApprovals": session.approvalRules?.rules.first?.approvalsRequired ?? -1,
        "ruleApproved": session.approvalRules?.rules.first?.approved ?? true,
        "inProcessAXContainsRuleText": reviewAcceptanceText(host).contains("Required approvals: 2"),
        "applicationActive": NSApp.isActive, "windowKey": window.isKeyWindow]
      try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: pending)
      stage = "expanded-rules-screenshot"
      try await captureHostingWindow(window, to: url)
    } catch {
      let originalError = error.localizedDescription
      let failure = url.deletingPathExtension().appendingPathExtension("failure")
      try? reviewAcceptanceText(host).write(to: failure.appendingPathExtension("ax.txt"), atomically: true, encoding: .utf8)
      var record: [String: Any] = ["stage": stage, "error": originalError, "language": store.settings.language.rawValue,
        "ruleReads": await transport.approvalRuleReads(number: session.number), "initialRuleReads": initial,
        "rulesLoading": session.approvalRulesLoading, "rulesAvailable": session.approvalRules?.availability == .available,
        "rulesCount": session.approvalRules?.rules.count ?? -1, "rulesError": session.approvalRulesError ?? "",
        "loadButtonPresent": accessibleButton(host, title: "Load Approval Rules", enabled: true) != nil,
        "windowVisible": window.isVisible, "windowKey": window.isKeyWindow]
      try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: failure.appendingPathExtension("json"))
      do { try await captureHostingWindow(window, to: failure.appendingPathExtension("png")) }
      catch { record["screenshotError"] = error.localizedDescription }
      try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: failure.appendingPathExtension("json"))
      throw GitPierError.invalidInput("Native GitLab rules stage " + stage + ": " + originalError)
    }
  }
  private static func providerReviewCapturePanel<Content: View>(_ content: Content, store: AppStore, size: NSSize, to url: URL) async throws {
    let host = NSHostingView(rootView: content.environmentObject(store))
    host.sizingOptions = []; host.autoresizingMask = [.width, .height]
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.title = "Synthetic Native Reviewer Controls"; window.contentView = host
    window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    defer { window.close() }
    try await settle(); try await captureHostingWindow(window, to: url)
  }
  private static func providerRequire(_ condition: Bool, _ message: String) throws {
    guard condition else { throw GitPierError.invalidInput(message) }
  }
}
