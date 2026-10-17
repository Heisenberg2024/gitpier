import Foundation

extension HostingAPIClient {
  /// All review identities come from the target repository and request, never a source fork.
  public func reviewContext(_ binding: RepositoryHostingBinding, number: Int, account: HostingAccount, token: HostingToken) async throws -> HostingReviewContext {
    let path = try reviewRequestPath(binding, number: number, account: account)
    let (repo, _) = try await json(account, token: token, path: repositoryPath(binding.repository, provider: account.instance.provider))
    let (request, _) = try await json(account, token: token, path: path)
    let provider = account.instance.provider
    let repositoryID = repo["id"].string, requestID = request["id"].string
    guard !repositoryID.isEmpty, !requestID.isEmpty,
      request[provider == .gitlab ? "iid" : "number"].int == number else { throw HostingReviewError.targetChanged }
    let targetRepository = provider == .gitlab ? request["target_project_id"].string : request["base"]["repo"]["id"].string
    guard targetRepository == repositoryID else { throw HostingReviewError.targetChanged }
    let head = provider == .gitlab ? request["sha"].string : request["head"]["sha"].string
    guard HostingReviewRevision.isSHA(head) else { throw HostingError.invalidResponse }
    let target = HostingReviewTarget(instance: account.instance, accountID: account.id, userID: account.user.stableID,
      repository: binding.repository, repositoryID: repositoryID, requestNumber: number, requestID: requestID)
    let base = request["base"]["sha"].string
    var revision = HostingReviewRevision(headSHA: head, baseSHA: provider == .gitlab ? "" : base)
    var capabilities: Set<HostingReviewCapability> = []
    var explanation = ""
    let scopes = Set(token.scopes.isEmpty ? account.scopes : token.scopes)
    // PAT scope introspection is not portable. An opaque PAT still faces the platform's
    // write permission checks; it never gains an OAuth grant or a wider scope here.
    let opaquePAT = account.kind == .pat && scopes.isEmpty
    let authorID = request[provider == .gitlab ? "author" : "user"]["id"].string
    let open = ["open", "opened"].contains(request["state"].string)
    switch provider {
    case .github:
      let granted = opaquePAT || scopes.contains("repo") || (!repo["private"].bool && scopes.contains("public_repo"))
      if granted && open && !repo["archived"].bool {
        capabilities = [.generalComment, .inlineComment, .reply, .draft, .submitReview, .multiLineComment, .requestReviewers]
        if authorID != account.user.stableID { capabilities.formUnion([.approve, .requestChanges]) }
      } else { explanation = "GitHub requires public_repo for public repositories or repo for private repositories; these are write permissions. A fine-grained PAT needs the relevant issue/pull-request write permission." }
    case .gitlab:
      // The current version is the first item. Bind all three SHAs, not just head.
      do {
        let (versions, _) = try await json(account, token: token, path: path + "/versions", query: [URLQueryItem(name: "per_page", value: "1")])
        if let version = versions.array.first, version["head_commit_sha"].string == head,
          HostingReviewRevision.isSHA(version["base_commit_sha"].string), HostingReviewRevision.isSHA(version["start_commit_sha"].string), !version["id"].string.isEmpty {
          revision = HostingReviewRevision(headSHA: head, baseSHA: version["base_commit_sha"].string,
            startSHA: version["start_commit_sha"].string, diffID: version["id"].string)
        }
      } catch HostingError.notFound {} catch HostingError.permissionRequired {}
      if (opaquePAT || scopes.contains("api")) && open && !repo["archived"].bool {
        capabilities = [.generalComment, .reply, .resolveDiscussion]
        if !revision.diffID.isEmpty { capabilities.insert(.inlineComment) }
        do {
          let (approval, _) = try await json(account, token: token, path: path + "/approvals")
          if !revision.diffID.isEmpty, approval["user_can_approve"].bool && !approval["user_has_approved"].bool { capabilities.insert(.approve) }
        } catch HostingError.notFound { explanation = "This instance does not expose merge-request approvals." }
          catch HostingError.permissionRequired { explanation = "This account cannot read merge-request approval permissions." }
      } else { explanation = "GitLab review writes require api, which grants broader API access than comments alone." }
    case .gitea:
      let (version, _) = try await json(account, token: token, path: "version")
      let verified = Self.reviewGiteaVersion(version["version"].string)
      if open && !repo["archived"].bool {
        if opaquePAT || scopes.contains("write:issue") { capabilities.insert(.generalComment) }
        if verified && (opaquePAT || scopes.contains("write:repository")) {
          capabilities.formUnion([.reply, .requestReviewers])
        }
      }
      explanation = verified
        ? "Gitea issue conversations need write:issue; replies and reviewer requests need write:repository. Submit reviews in your browser: creating a review can publish another client's pending comments, and submitting a pending review binds it to the latest head. Inline creation needs instance placement verification. Scope changes can conflict with an existing grant; explicitly reauthorize or replace the PAT."
        : "Review writes are enabled only for the audited Gitea 1.27.3 API family. Open unsupported operations in your browser."
    }
    if provider != .gitlab && !HostingReviewRevision.isSHA(base) {
      capabilities.removeAll(); explanation = "The platform did not return a valid base commit. Refresh this request before submitting a review."
    }
    return HostingReviewContext(target: target, revision: revision, capabilities: capabilities, state: request["state"].string,
      authorID: authorID, webURL: Self.reviewWeb(request[provider == .gitlab ? "web_url" : "html_url"].string), permissionExplanation: explanation)
  }

  public func reviewTimeline(_ binding: RepositoryHostingBinding, number: Int, account: HostingAccount, token: HostingToken,
    source: HostingReviewSource, page: Int = 1) async throws -> HostingPage<HostingReviewThread> {
    let request = try reviewRequestPath(binding, number: number, account: account)
    let provider = account.instance.provider
    let repo = try repositoryPath(binding.repository, provider: provider)
    if provider == .gitlab && source == .reviews {
      guard page == 1 else { return HostingPage(items: [], nextPage: nil) }
      let (value, _) = try await json(account, token: token, path: request + "/approvals")
      guard case .array = value["approved_by"] else { throw HostingError.invalidResponse }
      return HostingPage(items: try value["approved_by"].array.map { item in
        let user = item["user"], id = user["id"].string
        guard !id.isEmpty else { throw HostingError.invalidResponse }
        return HostingReviewThread(id: "approval:" + id, remoteID: id, source: .reviews,
          comments: [HostingReviewComment(id: "approval:" + id, authorID: id, author: user["username"].string,
            body: "", kind: .summary, createdAt: item["approved_at"].string)], state: .approved)
      }, nextPage: nil)
    }
    let path: String
    if provider == .gitlab { path = request + "/discussions" }
    else if source == .conversation { path = repo + "/issues/\(number)/comments" }
    else { path = request + (source == .reviews || provider == .gitea ? "/reviews" : "/comments") }
    let (value, response) = try await json(account, token: token, path: path, query: Self.reviewPagination(provider, page: page))
    guard case .array = value else { throw HostingError.invalidResponse }
    var threads: [HostingReviewThread] = []
    if provider == .gitlab {
      for discussion in value.array {
        let notes = discussion["notes"].array
        guard let root = notes.first, !discussion["id"].string.isEmpty else { throw HostingError.invalidResponse }
        let inline = !root["position"]["head_sha"].string.isEmpty
        guard inline == (source == .inline) else { continue }
        let comments = try notes.enumerated().map { index, note in
          try Self.reviewComment(note, provider: provider, kind: note["system"].bool ? .system : index > 0 ? .reply : inline ? .inline : .conversation,
            replyTo: index > 0 ? root["id"].string : nil)
        }
        let resolvable = root["resolvable"].bool
        threads.append(HostingReviewThread(id: "discussion:" + discussion["id"].string, remoteID: discussion["id"].string,
          source: source, comments: comments, resolved: resolvable ? root["resolved"].bool : nil, canResolve: resolvable))
      }
    } else if provider == .gitea && source == .inline {
      for review in value.array {
        let reviewID = try Self.reviewID(review["id"].string)
        // Review comments are fetched only when the user opens this review. Listing
        // 50 reviews must not start another 50 requests or load all their comments.
        if review["comments_count"].int > 0 {
          threads.append(HostingReviewThread(id: "inline:" + reviewID, remoteID: reviewID,
            source: .inline, comments: [], state: HostingReviewState(provider: provider, value: review["state"].string), hasMoreReplies: true))
        }
      }
    } else {
      for value in value.array {
        let comment = try Self.reviewComment(value, provider: provider, kind: source == .reviews ? .summary : source == .inline ? .inline : .conversation)
        let remote = source == .inline ? comment.replyToID ?? comment.id : comment.id
        if let index = threads.firstIndex(where: { $0.remoteID == remote }) { threads[index].append([comment]) }
        else { threads.append(HostingReviewThread(id: source.rawValue + ":" + remote, remoteID: remote, source: source,
          comments: [comment], state: source == .reviews ? HostingReviewState(provider: provider, value: value["state"].string) : .unknown)) }
      }
    }
    return HostingPage(items: threads, nextPage: Self.reviewNext(response, count: value.array.count, page: page))
  }

  public func reviewReplies(_ binding: RepositoryHostingBinding, number: Int, thread: HostingReviewThread, account: HostingAccount,
    token: HostingToken, page: Int = 1) async throws -> HostingPage<HostingReviewComment> {
    let path = try reviewRequestPath(binding, number: number, account: account)
    switch account.instance.provider {
    case .gitlab:
      let id = try Self.reviewOpaqueID(thread.remoteID)
      let (value, _) = try await json(account, token: token, path: path + "/discussions/" + id)
      guard value["id"].string == thread.remoteID, case .array = value["notes"] else { throw HostingReviewError.targetChanged }
      guard let root = value["notes"].array.first else { throw HostingError.invalidResponse }
      let inline = !root["position"]["head_sha"].string.isEmpty
      return HostingPage(items: try value["notes"].array.enumerated().map { index, note in
        try Self.reviewComment(note, provider: .gitlab, kind: note["system"].bool ? .system : index > 0 ? .reply : inline ? .inline : .conversation,
          replyTo: index > 0 ? root["id"].string : nil)
      }, nextPage: nil)
    case .github:
      guard thread.source == .inline else { throw HostingReviewError.unsupported }
      let root = try Self.reviewID(thread.remoteID)
      let (value, response) = try await json(account, token: token, path: path + "/comments", query: Self.reviewPagination(.github, page: page))
      guard case .array = value else { throw HostingError.invalidResponse }
      let comments = try value.array.filter { $0["id"].string == root || $0["in_reply_to_id"].string == root }
        .map { try Self.reviewComment($0, provider: .github, kind: $0["in_reply_to_id"].string.isEmpty ? .inline : .reply) }
      return HostingPage(items: comments, nextPage: Self.reviewNext(response, count: value.array.count, page: page))
    case .gitea:
      guard thread.source == .inline else { throw HostingReviewError.unsupported }
      _ = try Self.reviewID(thread.remoteID)
      guard page == 1 else { return HostingPage(items: [], nextPage: nil) }
      let comments = try await boundedGiteaReviewComments(path: path, reviewID: thread.remoteID, account: account, token: token)
      return HostingPage(items: try comments.map { try Self.reviewComment($0, provider: .gitea, kind: .inline) }, nextPage: nil)
    }
  }

  /// The caller owns confirmation, per-draft serialization and current-account validation.
  /// This boundary also checks a fresh target/revision and never retries a write.
  public func performReviewMutation(_ mutation: HostingReviewMutation, context: HostingReviewContext, account: HostingAccount,
    token: HostingToken) async throws -> HostingReviewReceipt {
    if case .requestReviewers(let selection) = mutation {
      return try await performReviewerRequest(selection, context: context, account: account, token: token)
    }
    if account.instance.provider == .gitea {
      // Both create and submit can consume pending comments written by another client.
      // A preceding list cannot make that operation conditional on the confirmed draft.
      switch mutation { case .review, .submitPending: throw HostingReviewError.unsupported; default: break }
    }
    let binding = try reviewBinding(context, account: account)
    let current = try await reviewContext(binding, number: context.target.requestNumber, account: account, token: token)
    try context.validateCurrent(current); try mutation.validate(context: current)
    let path = try reviewRequestPath(binding, number: context.target.requestNumber, account: account)
    let provider = account.instance.provider
    var destination: String, body: [String: HostingJSON], method = "POST"
    switch mutation {
    case .comment(let text):
      destination = provider == .gitlab ? path + "/discussions" : try repositoryPath(binding.repository, provider: provider) + "/issues/\(context.target.requestNumber)/comments"
      body = ["body": .string(text)]
    case .inline(let text, let anchor):
      if provider == .github {
        destination = path + "/comments"; body = Self.reviewGithubAnchor(anchor)
        body["body"] = .string(text); body["commit_id"] = .string(context.revision.headSHA)
      } else if provider == .gitlab {
        destination = path + "/discussions"; body = ["body": .string(text), "position": .object(Self.reviewGitlabAnchor(anchor))]
      } else { throw HostingReviewError.unsupported }
    case .reply(let threadID, let commentID, let text):
      try await reviewValidateReply(binding, number: context.target.requestNumber, threadID: threadID, commentID: commentID, account: account, token: token)
      destination = provider == .gitlab ? path + "/discussions/" + (try Self.reviewOpaqueID(threadID)) + "/notes"
        : path + "/comments/" + (try Self.reviewID(commentID)) + "/replies"
      body = ["body": .string(text)]
    case .review(let summary, let decision, let comments, let pending):
      if provider == .gitlab {
        guard decision == .approve, summary.isEmpty, comments.isEmpty, !pending else { throw HostingReviewError.unsupported }
        destination = path + "/approve"; body = ["sha": .string(context.revision.headSHA)]
      } else {
        // An existing pending review must be surfaced explicitly instead of silently
        // attaching this app's draft to pending comments created in another client.
        try await reviewRejectExistingPending(path: path, account: account, token: token)
        destination = path + "/reviews"
        body = ["body": .string(summary), "commit_id": .string(context.revision.headSHA), "comments": .array(comments.map { comment in
          var fields = Self.reviewGithubAnchor(comment.anchor); fields["body"] = .string(comment.body); return .object(fields)
        })]
        if provider == .gitea && pending && summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw HostingReviewError.invalidBody }
        if provider == .gitea || !pending { body["event"] = .string(pending ? "PENDING" : Self.reviewEvent(decision, provider: provider)) }
      }
    case .submitPending(let reviewID, let summary, let decision):
      // Gitea 1.27.3's SubmitPullReview always substitutes the current head for
      // the pending review's commit. A prior GET cannot close that race.
      guard provider == .github else { throw HostingReviewError.unsupported }
      let id = try Self.reviewID(reviewID)
      let (review, _) = try await json(account, token: token, path: path + "/reviews/" + id)
      guard review["id"].string == id, review["user"]["id"].string == account.user.stableID,
        review["state"].string == "PENDING", review["commit_id"].string == context.revision.headSHA else { throw HostingReviewError.revisionChanged }
      destination = path + "/reviews/" + id + (provider == .github ? "/events" : "")
      body = ["body": .string(summary), "event": .string(Self.reviewEvent(decision, provider: provider))]
    case .resolve(let threadID, let resolved):
      if provider == .gitlab {
        destination = path + "/discussions/" + (try Self.reviewOpaqueID(threadID)); method = "PUT"; body = ["resolved": .bool(resolved)]
        let (thread, _) = try await json(account, token: token, path: destination)
        guard thread["id"].string == threadID, thread["notes"].array.first?["resolvable"].bool == true else { throw HostingReviewError.unsupported }
      } else { throw HostingReviewError.unsupported }
    case .requestReviewers: throw HostingReviewError.unsupported // dispatched above
    }
    // Reply ownership and pending-review discovery can involve several pages. Check
    // again after those reads, immediately before the only write in this operation.
    let final = try await reviewContext(binding, number: context.target.requestNumber, account: account, token: token)
    try context.validateCurrent(final); try mutation.validate(context: final)
    try Task.checkCancellation()
    let value = try await reviewWrite(account, token: token, path: destination, method: method, body: body)
    return try Self.reviewReceipt(value, mutation: mutation, context: context)
  }

  /// Read back by the server's stable ID. Body similarity never proves a write succeeded.
  public func readReviewReceipt(_ receipt: HostingReviewReceipt, mutation: HostingReviewMutation, context: HostingReviewContext,
    account: HostingAccount, token: HostingToken) async throws -> HostingReviewReceipt {
    if case .requestReviewers(let selection) = mutation {
      return try await readReviewerRequest(receipt, selection: selection, context: context, account: account, token: token)
    }
    let binding = try reviewBinding(context, account: account)
    let path = try reviewRequestPath(binding, number: context.target.requestNumber, account: account)
    let provider = account.instance.provider
    let value: HostingJSON
    switch mutation {
    case .review(_, let decision, _, _ ) where provider == .gitlab && decision == .approve:
      let (current, _) = try await json(account, token: token, path: path)
      guard current["id"].string == context.target.requestID, current["sha"].string == context.revision.headSHA else { throw HostingReviewError.readbackRequired }
      let (approval, _) = try await json(account, token: token, path: path + "/approvals")
      guard let approved = approval["approved_by"].array.first(where: { $0["user"]["id"].string == receipt.id }) else { throw HostingReviewError.readbackRequired }
      // Approval lists have no commit field. Verify the complete target and diff version
      // after that read before associating its current-user state with the confirmed SHA.
      let final = try await reviewContext(binding, number: context.target.requestNumber, account: account, token: token)
      try context.validateCurrent(final)
      // reviewContext also reads approval permissions. End with an authoritative MR
      // snapshot so a change during that last permission GET cannot reuse old SHAs.
      let (snapshot, _) = try await json(account, token: token, path: path)
      let refs = snapshot["diff_refs"]
      guard snapshot["id"].string == context.target.requestID, snapshot["iid"].int == context.target.requestNumber,
        snapshot["target_project_id"].string == context.target.repositoryID,
        snapshot["sha"].string == context.revision.headSHA, refs["head_sha"].string == context.revision.headSHA,
        refs["base_sha"].string == context.revision.baseSHA, refs["start_sha"].string == context.revision.startSHA
      else { throw HostingReviewError.readbackRequired }
      value = .object(["id": .string(receipt.id), "user": approved["user"], "state": .string("APPROVED"), "commit_id": snapshot["sha"]])
    case .review where provider != .gitlab, .submitPending:
      (value, _) = try await json(account, token: token, path: path + "/reviews/" + (try Self.reviewID(receipt.id)))
      if case .review(_, _, let expected, _) = mutation {
        try await reviewVerifyBatch(path: path, reviewID: receipt.id, expected: expected, context: context, account: account, token: token)
      }
    case .comment where provider != .gitlab:
      value = try await reviewFindComment(binding, number: context.target.requestNumber, id: receipt.id, account: account, token: token)
    case .inline where provider == .github, .reply where provider == .github:
      value = try await reviewGithubComment(binding, number: context.target.requestNumber, id: receipt.id, account: account, token: token)
      if case .reply(let threadID, let commentID, _) = mutation {
        guard threadID == commentID, value["in_reply_to_id"].string == commentID else { throw HostingReviewError.readbackRequired }
      }
    case .reply(let threadID, _, _) where provider == .gitea:
      value = try await reviewGiteaComment(path: path, reviewID: threadID, commentID: receipt.id, account: account, token: token)
    default:
      guard provider == .gitlab, let threadID = receipt.threadID else { throw HostingReviewError.readbackRequired }
      let (discussion, _) = try await json(account, token: token, path: path + "/discussions/" + (try Self.reviewOpaqueID(threadID)))
      guard discussion["id"].string == threadID else { throw HostingReviewError.readbackRequired }
      if case .resolve(_, let resolved) = mutation {
        guard discussion["id"].string == threadID, discussion["notes"].array.first?["resolved"].bool == resolved else { throw HostingReviewError.readbackRequired }
        return receipt
      }
      guard let note = discussion["notes"].array.first(where: { $0["id"].string == receipt.id }) else { throw HostingReviewError.readbackRequired }
      if case .reply = mutation { value = note }
      else { value = .object(["id": .string(threadID), "notes": .array([note])]) }
    }
    if case .inline(let body, let anchor) = mutation {
      let comment = provider == .gitlab ? value["notes"].array.first ?? .null : value
      guard Self.reviewMatchesAnchor(comment, body: body, anchor: anchor, provider: provider) else { throw HostingReviewError.readbackRequired }
    }
    // Verify content only inside the object identified by a server receipt. Body matching
    // never discovers an unknown write or substitutes for stable target/object identities.
    switch mutation {
    case .comment(let body):
      let comment = provider == .gitlab ? value["notes"].array.first ?? .null : value
      guard comment["body"].string == body else { throw HostingReviewError.readbackRequired }
    case .reply(_, _, let body):
      guard value["body"].string == body else { throw HostingReviewError.readbackRequired }
    case .review(let summary, _, _, _) where provider != .gitlab, .submitPending(_, let summary, _):
      guard value["body"].string == summary else { throw HostingReviewError.readbackRequired }
    default: break
    }
    let result = try Self.reviewReceipt(value, mutation: mutation, context: context)
    guard result.id == receipt.id, result.authorID == context.target.userID,
      result.state == receipt.state, receipt.commitSHA.isEmpty || result.commitSHA == receipt.commitSHA else { throw HostingReviewError.readbackRequired }
    return result
  }

  private func reviewVerifyBatch(path: String, reviewID: String, expected: [HostingReviewDraftComment], context: HostingReviewContext,
    account: HostingAccount, token: HostingToken) async throws {
    var page: Int? = account.instance.provider == .gitea ? nil : 1, comments: [HostingJSON] = []
    if account.instance.provider == .gitea {
      comments = try await boundedGiteaReviewComments(path: path, reviewID: reviewID, account: account, token: token)
    }
    while let current = page {
      guard current <= 20 else { throw HostingReviewError.readbackRequired }
      let (values, response) = try await json(account, token: token, path: path + "/reviews/" + (try Self.reviewID(reviewID)) + "/comments", query: Self.reviewPagination(account.instance.provider, page: current))
      guard case .array = values else { throw HostingReviewError.readbackRequired }
      for value in values.array where !comments.contains(where: { $0["id"].string == value["id"].string }) { comments.append(value) }
      page = Self.reviewNext(response, count: values.array.count, page: current)
    }
    guard comments.count == expected.count else { throw HostingReviewError.readbackRequired }
    // This comparison is confined to the already identified server review. It never
    // treats matching text as proof that an unknown POST succeeded.
    for draft in expected {
      guard let index = comments.firstIndex(where: {
        !$0["id"].string.isEmpty && $0["user"]["id"].string == context.target.userID
          && $0["pull_request_review_id"].string == reviewID
          && Self.reviewMatchesAnchor($0, body: draft.body, anchor: draft.anchor, provider: account.instance.provider)
      }) else { throw HostingReviewError.readbackRequired }
      comments.remove(at: index)
    }
    guard comments.isEmpty else { throw HostingReviewError.readbackRequired }
  }

  private func reviewRequestPath(_ binding: RepositoryHostingBinding, number: Int, account: HostingAccount) throws -> String {
    try account.validateCredentialContext()
    guard binding.accountID == account.id, number > 0 else { throw HostingReviewError.targetChanged }
    return try repositoryPath(binding.repository, provider: account.instance.provider) + (account.instance.provider == .gitlab ? "/merge_requests/" : "/pulls/") + String(number)
  }
  private func reviewBinding(_ context: HostingReviewContext, account: HostingAccount) throws -> RepositoryHostingBinding {
    let binding = try RepositoryHostingBinding(repositoryID: UUID(), accountID: context.target.accountID, remote: "", repository: context.target.repository)
    try context.target.validate(account: account, binding: binding); return binding
  }
  private func reviewValidateReply(_ binding: RepositoryHostingBinding, number: Int, threadID: String, commentID: String,
    account: HostingAccount, token: HostingToken) async throws {
    let path = try reviewRequestPath(binding, number: number, account: account)
    if account.instance.provider == .github {
      guard threadID == commentID else { throw HostingReviewError.unsupported }
      let root = try await reviewGithubComment(binding, number: number, id: commentID, account: account, token: token)
      guard root["in_reply_to_id"].string.isEmpty else { throw HostingReviewError.unsupported }
    } else if account.instance.provider == .gitlab {
      let (discussion, _) = try await json(account, token: token, path: path + "/discussions/" + (try Self.reviewOpaqueID(threadID)))
      guard discussion["id"].string == threadID, discussion["notes"].array.contains(where: { $0["id"].string == commentID }) else { throw HostingReviewError.targetChanged }
    } else {
      let comment = try await reviewGiteaComment(path: path, reviewID: threadID, commentID: commentID, account: account, token: token)
      guard comment["pull_request_review_id"].string == threadID else { throw HostingReviewError.targetChanged }
    }
  }
  private func reviewGiteaComment(path: String, reviewID: String, commentID: String, account: HostingAccount, token: HostingToken) async throws -> HostingJSON {
    _ = try Self.reviewID(commentID)
    let comments = try await boundedGiteaReviewComments(path: path, reviewID: reviewID, account: account, token: token)
    guard let value = comments.first(where: { $0["id"].string == commentID }), value["pull_request_review_id"].string == reviewID else { throw HostingReviewError.targetChanged }
    return value
  }
  /// Gitea 1.27.3 returns this whole collection; page/limit are not implemented.
  /// Shared with the legacy detail reader so neither reader invents a second page.
  func boundedGiteaReviewComments(path: String, reviewID: String, account: HostingAccount, token: HostingToken) async throws -> [HostingJSON] {
    guard account.instance.provider == .gitea else { throw HostingError.unsupported }
    let id = try Self.reviewID(reviewID)
    let (value, _) = try await json(account, token: token, path: path + "/reviews/" + id + "/comments")
    guard case .array = value else { throw HostingError.invalidResponse }
    guard value.array.count <= 1000 else { throw HostingError.responseTooLarge }
    return value.array
  }
  private func reviewGithubComment(_ binding: RepositoryHostingBinding, number: Int, id: String, account: HostingAccount, token: HostingToken) async throws -> HostingJSON {
    let path = try repositoryPath(binding.repository, provider: .github) + "/pulls/comments/" + (try Self.reviewID(id))
    let (comment, _) = try await json(account, token: token, path: path)
    let expected = try account.instance.endpoint(reviewRequestPath(binding, number: number, account: account), api: true)
    guard comment["id"].string == id, comment["pull_request_url"].string == expected.absoluteString else { throw HostingReviewError.targetChanged }
    return comment
  }
  private func reviewFindComment(_ binding: RepositoryHostingBinding, number: Int, id: String, account: HostingAccount, token: HostingToken) async throws -> HostingJSON {
    _ = try Self.reviewID(id)
    let path = try repositoryPath(binding.repository, provider: account.instance.provider) + "/issues/\(number)/comments"
    var page = 1
    while page <= 20 {
      let (comments, response) = try await json(account, token: token, path: path, query: Self.reviewPagination(account.instance.provider, page: page))
      guard case .array = comments else { throw HostingError.invalidResponse }
      if let result = comments.array.first(where: { $0["id"].string == id }) { return result }
      guard let next = Self.reviewNext(response, count: comments.array.count, page: page) else { break }; page = next
    }
    throw HostingReviewError.readbackRequired
  }
  private func reviewRejectExistingPending(path: String, account: HostingAccount, token: HostingToken) async throws {
    var page: Int? = 1
    while let current = page {
      guard current <= 20 else { throw HostingError.responseTooLarge }
      let (reviews, response) = try await json(account, token: token, path: path + "/reviews", query: Self.reviewPagination(account.instance.provider, page: current))
      guard case .array = reviews else { throw HostingError.invalidResponse }
      if reviews.array.contains(where: { $0["state"].string == "PENDING" && $0["user"]["id"].string == account.user.stableID }) { throw HostingReviewError.alreadySubmitting }
      page = Self.reviewNext(response, count: reviews.array.count, page: current)
    }
  }
  private func reviewWrite(_ account: HostingAccount, token: HostingToken, path: String, method: String, body: [String: HostingJSON]) async throws -> HostingJSON {
    do {
      let data = try JSONEncoder().encode(HostingJSON.object(body))
      let response = try await http.request(instance: account.instance, path: path, token: token, method: method, body: data, oauthResponse: true)
      if account.instance.provider == .gitea, path.hasSuffix("/reviews"), [400, 409, 422].contains(response.status) {
        // Gitea creates pending inline comments before the final review operation.
        // A provider error can therefore leave durable partial side effects.
        throw HostingReviewError.resultUnknown
      }
      switch response.status {
      case 200...299: return response.data.isEmpty ? .object([:]) : try HostingJSON.decode(response.data)
      case 401: throw HostingError.unauthorized
      case 403: throw HostingReviewError.permissionRequired
      case 404: throw HostingError.notFound
      case 409: throw HostingReviewError.revisionChanged
      case 422: throw HostingReviewError.invalidBody
      case 429: throw HostingError.rateLimited
      default: throw HostingReviewError.resultUnknown
      }
    } catch is CancellationError { throw HostingReviewError.resultUnknown }
      catch let error as HostingReviewError { throw error }
      catch let error as HostingError {
        if [.networkFailure, .serverFailure, .invalidResponse, .responseTooLarge, .redirectRejected].contains(error) { throw HostingReviewError.resultUnknown }
        throw error
      } catch { throw HostingReviewError.resultUnknown }
  }
  private static func reviewReceipt(_ value: HostingJSON, mutation: HostingReviewMutation, context: HostingReviewContext) throws -> HostingReviewReceipt {
    let provider = context.target.instance.provider
    var item = value, threadID: String?
    if provider == .gitlab {
      switch mutation {
      case .review(_, .approve, _, _):
        guard value["user_has_approved"].bool || value["approved_by"].array.contains(where: { $0["user"]["id"].string == context.target.userID }) || value["user"]["id"].string == context.target.userID else { throw HostingReviewError.resultUnknown }
        return HostingReviewReceipt(id: context.target.userID, state: .approved, authorID: context.target.userID, commitSHA: context.revision.headSHA)
      case .resolve(let id, _): return HostingReviewReceipt(id: id, threadID: id, authorID: context.target.userID)
      case .reply(let id, _, _): threadID = id
      default:
        threadID = value["id"].string; guard let note = value["notes"].array.first else { throw HostingReviewError.resultUnknown }; item = note
      }
    }
    let id = item["id"].string, author = item[provider == .gitlab ? "author" : "user"]["id"].string
    guard !id.isEmpty, author == context.target.userID else { throw HostingReviewError.resultUnknown }
    let state = HostingReviewState(provider: provider, value: item["state"].string)
    let sha = provider == .gitlab ? item["position"]["head_sha"].string : item["commit_id"].string
    // A reply retains its original thread's commit, which can legitimately be outdated.
    let requiresCurrentSHA: Bool
    switch mutation { case .inline, .review, .submitPending: requiresCurrentSHA = true; default: requiresCurrentSHA = false }
    if requiresCurrentSHA, !sha.isEmpty, sha != context.revision.headSHA { throw HostingReviewError.resultUnknown }
    return HostingReviewReceipt(id: id, threadID: threadID, state: state, authorID: author, commitSHA: sha,
      createdAt: item["submitted_at"].string.isEmpty ? item["created_at"].string : item["submitted_at"].string)
  }
  private static func reviewComment(_ value: HostingJSON, provider: HostingProvider, kind: HostingReviewCommentKind, replyTo: String? = nil) throws -> HostingReviewComment {
    let id = value["id"].string, user = value[provider == .gitlab ? "author" : "user"]
    guard !id.isEmpty, !user["id"].string.isEmpty else { throw HostingError.invalidResponse }
    let position = value["position"], side = value["side"].string
    let oldLine = provider == .gitlab ? position["old_line"].int : provider == .gitea ? value["original_position"].int : side == "LEFT" ? value["line"].int : 0
    let newLine = provider == .gitlab ? position["new_line"].int : provider == .gitea ? value["position"].int : side == "RIGHT" ? value["line"].int : 0
    let reply = value["in_reply_to_id"].string.isEmpty ? replyTo ?? "" : value["in_reply_to_id"].string
    return HostingReviewComment(id: id, authorID: user["id"].string, author: user[provider == .gitlab ? "username" : "login"].string,
      body: value["body"].string, kind: kind == .system ? .system : !reply.isEmpty ? .reply : kind, createdAt: value["created_at"].string.isEmpty ? value["submitted_at"].string : value["created_at"].string,
      path: provider == .gitlab ? position["new_path"].string : value["path"].string, oldLine: oldLine > 0 ? oldLine : nil, newLine: newLine > 0 ? newLine : nil,
      commitSHA: provider == .gitlab ? position["head_sha"].string : value["commit_id"].string, replyToID: reply.isEmpty ? nil : reply,
      outdated: value["stale"].bool || provider == .github && kind == .inline && value["line"].string.isEmpty,
      webURL: reviewWeb(value[provider == .gitlab ? "web_url" : "html_url"].string),
      startLine: provider == .github && value["start_line"].int > 0 ? value["start_line"].int : nil)
  }
  private static func reviewGithubAnchor(_ anchor: HostingDiffAnchor) -> [String: HostingJSON] {
    var fields: [String: HostingJSON] = ["path": .string(anchor.path), "line": .integer(Int64((anchor.side == .old ? anchor.oldLine : anchor.newLine) ?? 0)), "side": .string(anchor.side == .old ? "LEFT" : "RIGHT")]
    if let start = anchor.startLine {
      fields["start_line"] = .integer(Int64(start)); fields["start_side"] = .string(anchor.side == .old ? "LEFT" : "RIGHT")
    }
    return fields
  }
  private static func reviewGitlabAnchor(_ anchor: HostingDiffAnchor) -> [String: HostingJSON] {
    var fields: [String: HostingJSON] = ["position_type": .string("text"), "base_sha": .string(anchor.revision.baseSHA),
      "start_sha": .string(anchor.revision.startSHA), "head_sha": .string(anchor.revision.headSHA), "old_path": .string(anchor.oldPath), "new_path": .string(anchor.newPath)]
    if let line = anchor.oldLine { fields["old_line"] = .integer(Int64(line)) }
    if let line = anchor.newLine { fields["new_line"] = .integer(Int64(line)) }
    return fields
  }
  private static func reviewMatchesAnchor(_ value: HostingJSON, body: String, anchor: HostingDiffAnchor, provider: HostingProvider) -> Bool {
    guard value["body"].string == body else { return false }
    if provider == .github {
      if let start = anchor.startLine {
        guard value["start_line"].int == start, value["start_side"].string == (anchor.side == .old ? "LEFT" : "RIGHT") else { return false }
      } else if case .null = value["start_line"] {} else { return false }
      return value["path"].string == anchor.path && value["commit_id"].string == anchor.revision.headSHA
        && value["side"].string == (anchor.side == .old ? "LEFT" : "RIGHT")
        && value["line"].int == (anchor.side == .old ? anchor.oldLine : anchor.newLine)
    }
    guard provider == .gitlab else { return false }
    let position = value["position"]
    func coordinate(_ field: HostingJSON, _ expected: Int?) -> Bool {
      if let expected { return field.int == expected && expected > 0 }
      if case .null = field { return true }; return false
    }
    return position["position_type"].string == "text" && position["head_sha"].string == anchor.revision.headSHA
      && position["base_sha"].string == anchor.revision.baseSHA && position["start_sha"].string == anchor.revision.startSHA
      && position["old_path"].string == anchor.oldPath && position["new_path"].string == anchor.newPath
      && coordinate(position["old_line"], anchor.oldLine) && coordinate(position["new_line"], anchor.newLine)
  }
  private static func reviewEvent(_ decision: HostingReviewDecision, provider: HostingProvider) -> String {
    switch decision { case .comment: "COMMENT"; case .approve: provider == .gitea ? "APPROVED" : "APPROVE"; case .requestChanges: "REQUEST_CHANGES" }
  }
  private static func reviewGiteaVersion(_ version: String) -> Bool {
    let parts = version.split(separator: ".").prefix(3).map { Int($0.prefix(while: { $0.isNumber })) ?? -1 }
    return parts.count == 3 && parts[0] == 1 && parts[1] == 27 && parts[2] >= 3 && !version.contains("-rc") && !version.contains("-dev")
  }
  private static func reviewID(_ id: String) throws -> String {
    guard let number = Int64(id), number > 0, String(number) == id else { throw HostingReviewError.targetChanged }; return id
  }
  private static func reviewOpaqueID(_ id: String) throws -> String {
    guard !id.isEmpty, id.count <= 256, id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw HostingReviewError.targetChanged }
    return HostingInstance.component(id)
  }
  private static func reviewPagination(_ provider: HostingProvider, page: Int) -> [URLQueryItem] {
    [URLQueryItem(name: "page", value: String(max(1, page))), URLQueryItem(name: provider == .gitea ? "limit" : "per_page", value: "50")]
  }
  private static func reviewNext(_ response: HostingHTTPResponse, count: Int, page: Int) -> Int? {
    if let value = response.headers["x-hasmore"] { return value.lowercased() == "true" ? page + 1 : nil }
    if let value = response.headers["x-next-page"] { return Int(value).flatMap { $0 > page ? $0 : nil } }
    if let value = response.headers["link"] { return value.contains("rel=\"next\"") ? page + 1 : nil }
    return count == 50 ? page + 1 : nil
  }
  private static func reviewWeb(_ value: String) -> URL? {
    guard let url = URL(string: value), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }; return url
  }
}
