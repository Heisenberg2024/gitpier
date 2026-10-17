import CryptoKit
import Foundation

public enum HostingReviewCapability: String, CaseIterable, Sendable, Hashable {
  case generalComment, inlineComment, reply, draft, submitReview, approve, requestChanges
  case resolveDiscussion, requestReviewers, multiLineComment
}
public enum HostingReviewDecision: String, CaseIterable, Sendable { case comment, approve, requestChanges }
public enum HostingReviewSide: String, Sendable, Hashable { case old, new }
public enum HostingReviewSource: String, CaseIterable, Sendable { case conversation, reviews, inline }
public enum HostingReviewCommentKind: String, Sendable { case conversation, inline, summary, reply, system }
public enum HostingReviewState: String, Sendable {
  case commented, approved, changesRequested, dismissed, pending, unapproved, unknown
  public init(provider: HostingProvider, value: String) {
    switch (provider, value.uppercased()) {
    case (_, "APPROVED"), (_, "APPROVE"): self = .approved
    case (.github, "CHANGES_REQUESTED"), (.gitea, "REQUEST_CHANGES"): self = .changesRequested
    case (_, "COMMENTED"), (.gitea, "COMMENT"): self = .commented
    case (_, "DISMISSED"): self = .dismissed
    case (_, "PENDING"): self = .pending
    case (.gitlab, "UNAPPROVED"): self = .unapproved
    default: self = .unknown
    }
  }
}

/// Stable remote identities are kept in addition to the user-visible repository path and IID.
public struct HostingReviewTarget: Hashable, Sendable {
  public let instance: HostingInstance
  public let accountID: UUID
  public let userID: String
  public let repository: String
  public let repositoryID: String
  public let requestNumber: Int
  public let requestID: String
  public init(instance: HostingInstance, accountID: UUID, userID: String, repository: String,
    repositoryID: String, requestNumber: Int, requestID: String) {
    self.instance = instance; self.accountID = accountID; self.userID = userID; self.repository = repository
    self.repositoryID = repositoryID; self.requestNumber = requestNumber; self.requestID = requestID
  }
  public func validate(account: HostingAccount, binding: RepositoryHostingBinding) throws {
    try account.validateCredentialContext()
    guard account.id == accountID, account.instance == instance, account.user.stableID == userID,
      binding.accountID == accountID, binding.repository == repository,
      !repositoryID.isEmpty, !requestID.isEmpty, requestNumber > 0 else { throw HostingReviewError.targetChanged }
  }
}
public struct HostingReviewRevision: Hashable, Sendable {
  public let headSHA: String
  public let baseSHA: String
  public let startSHA: String
  public let diffID: String
  public init(headSHA: String, baseSHA: String = "", startSHA: String = "", diffID: String = "") {
    self.headSHA = headSHA; self.baseSHA = baseSHA; self.startSHA = startSHA; self.diffID = diffID
  }
  public var valid: Bool { Self.isSHA(headSHA) }
  public static func isSHA(_ value: String) -> Bool {
    (value.count == 40 || value.count == 64) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}
public struct HostingReviewContext: Sendable, Equatable {
  public let target: HostingReviewTarget
  public let revision: HostingReviewRevision
  public let capabilities: Set<HostingReviewCapability>
  public let state: String
  public let authorID: String
  public let webURL: URL?
  public let permissionExplanation: String
  public init(target: HostingReviewTarget, revision: HostingReviewRevision, capabilities: Set<HostingReviewCapability>,
    state: String, authorID: String, webURL: URL? = nil, permissionExplanation: String = "") {
    self.target = target; self.revision = revision; self.capabilities = capabilities; self.state = state
    self.authorID = authorID; self.webURL = webURL; self.permissionExplanation = permissionExplanation
  }
  public func validateCurrent(_ current: Self) throws {
    guard target == current.target else { throw HostingReviewError.targetChanged }
    guard revision.valid, revision == current.revision else { throw HostingReviewError.revisionChanged }
    guard current.state == "open" || current.state == "opened" else { throw HostingReviewError.requestClosed }
  }
}

public struct HostingDiffAnchor: Sendable, Equatable, Hashable {
  public let target: HostingReviewTarget
  public let revision: HostingReviewRevision
  public let path: String
  public let oldPath: String
  public let newPath: String
  public let oldLine: Int?
  public let newLine: Int?
  public let side: HostingReviewSide
  public let hunkID: String
  public let patchID: String
  public let code: String
  public private(set) var startLine: Int?
  public private(set) var rangeCode: String?
  /// Only DiffParser coordinates from a complete, bounded file patch can become an anchor.
  public static func make(context: HostingReviewContext, file: HostingChangedFile, document: DiffDocument,
    lineID: Int, side: HostingReviewSide) throws -> Self {
    guard context.revision.valid, !document.binary, !document.complexMetadata,
      document.raw.utf8.count <= 1024 * 1024, !document.hunks.isEmpty,
      !file.path.isEmpty, file.path.utf8.count <= 4096, !file.path.contains("\0"),
      !file.oldPath.contains("\0"), Self.safePatch(document),
      ["added", "deleted", "removed", "modified", "renamed", "changed"].contains(file.kind),
      let hunk = document.hunks.first(where: { $0.lines.contains { $0.id == lineID } }),
      let line = hunk.lines.first(where: { $0.id == lineID }),
      line.kind == .addition || line.kind == .deletion || line.kind == .context,
      (side == .old ? line.oldNumber : line.newNumber).map({ $0 > 0 }) == true,
      line.text.utf8.count <= 100_000 else { throw HostingReviewError.unanchorable }
    // A caller cannot attach a document from another file even when it has the same line numbers.
    guard let patch = file.patch, patch == document.raw else { throw HostingReviewError.unanchorable }
    if file.kind == "renamed", file.oldPath.isEmpty || file.oldPath == file.path { throw HostingReviewError.unanchorable }
    if context.target.instance.provider == .gitlab {
      guard HostingReviewRevision.isSHA(context.revision.baseSHA), HostingReviewRevision.isSHA(context.revision.startSHA),
        !context.revision.diffID.isEmpty else { throw HostingReviewError.unanchorable }
    }
    let oldPath = file.oldPath.isEmpty ? file.path : file.oldPath
    return Self(target: context.target, revision: context.revision, path: file.path, oldPath: oldPath,
      newPath: file.path, oldLine: line.oldNumber, newLine: line.newNumber, side: side,
      hunkID: digest(hunk.header + "\n" + String(decoding: hunk.patch, as: UTF8.self)),
      patchID: digest(document.raw), code: line.text)
  }
  public static func makeRange(context: HostingReviewContext, file: HostingChangedFile, document: DiffDocument,
    startLineID: Int, endLineID: Int, side: HostingReviewSide) throws -> Self {
    guard context.target.instance.provider == .github, context.capabilities.contains(.multiLineComment) else { throw HostingReviewError.unsupported }
    let start = try make(context: context, file: file, document: document, lineID: startLineID, side: side)
    var end = try make(context: context, file: file, document: document, lineID: endLineID, side: side)
    guard start.hunkID == end.hunkID, let first = side == .old ? start.oldLine : start.newLine,
      let last = side == .old ? end.oldLine : end.newLine, first < last, last - first < 200,
      let hunk = document.hunks.first(where: { $0.lines.contains { $0.id == endLineID } }) else { throw HostingReviewError.unanchorable }
    let selected = hunk.lines.filter {
      guard let number = side == .old ? $0.oldNumber : $0.newNumber else { return false }
      return number >= first && number <= last
    }
    guard selected.count == last - first + 1 else { throw HostingReviewError.unanchorable }
    end.startLine = first; end.rangeCode = selected.map(\.text).joined(separator: "\n")
    return end
  }
  public func validate(context: HostingReviewContext, file: HostingChangedFile, document: DiffDocument) throws {
    guard context.target == target else { throw HostingReviewError.targetChanged }
    guard context.revision == revision else { throw HostingReviewError.revisionChanged }
    guard patchID == Self.digest(document.raw), file.path == path,
      let line = document.hunks.flatMap(\.lines).first(where: {
        $0.oldNumber == oldLine && $0.newNumber == newLine && $0.text == code
      }) else { throw HostingReviewError.unanchorable }
    if let startLine {
      guard let start = document.hunks.flatMap(\.lines).first(where: { (side == .old ? $0.oldNumber : $0.newNumber) == startLine }),
        try Self.makeRange(context: context, file: file, document: document, startLineID: start.id, endLineID: line.id, side: side) == self
      else { throw HostingReviewError.unanchorable }
    } else if try Self.make(context: context, file: file, document: document, lineID: line.id, side: side) != self {
      throw HostingReviewError.unanchorable
    }
  }
  private static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
  private static func safePatch(_ document: DiffDocument) -> Bool {
    let lines = document.hunks.flatMap(\.lines)
    // Overlapping or reversed hunks can assign multiple code rows to one file coordinate.
    for coordinates in [lines.compactMap(\.oldNumber), lines.compactMap(\.newNumber)] {
      guard coordinates == coordinates.sorted(), Set(coordinates).count == coordinates.count else { return false }
    }
    var inHunk = false, files = 0
    let rows = document.raw.components(separatedBy: "\n")
    for (index, row) in rows.enumerated() {
      if row.hasPrefix("@@ ") { inHunk = true; continue }
      if row.hasPrefix("diff --git ") { files += 1; if files > 1 || inHunk { return false }; continue }
      if inHunk {
        if row.hasPrefix(" ") || row.hasPrefix("+") || row.hasPrefix("-") { continue }
        if row == "\\ No newline at end of file" || row == "\\ No newline at end of file\r" { continue }
        if row.isEmpty && index == rows.count - 1 { continue }
        return false
      }
      guard row.hasPrefix("index ") || row.hasPrefix("--- ") || row.hasPrefix("+++ ")
        || ["new file mode 100644", "new file mode 100755", "deleted file mode 100644", "deleted file mode 100755"].contains(row)
      else { return false }
    }
    return inHunk
  }
}

public struct HostingReviewComment: Sendable, Identifiable, Equatable {
  public let id: String
  public let authorID: String
  public let author: String
  public let body: String
  public let kind: HostingReviewCommentKind
  public let createdAt: String
  public let path: String
  public let oldLine: Int?
  public let newLine: Int?
  public let commitSHA: String
  public let replyToID: String?
  public let outdated: Bool
  public let webURL: URL?
  public let startLine: Int?
  public init(id: String, authorID: String, author: String, body: String, kind: HostingReviewCommentKind,
    createdAt: String = "", path: String = "", oldLine: Int? = nil, newLine: Int? = nil, commitSHA: String = "",
    replyToID: String? = nil, outdated: Bool = false, webURL: URL? = nil, startLine: Int? = nil) {
    self.id = id; self.authorID = authorID; self.author = author; self.body = body; self.kind = kind
    self.createdAt = createdAt; self.path = path; self.oldLine = oldLine; self.newLine = newLine
    self.commitSHA = commitSHA; self.replyToID = replyToID; self.outdated = outdated; self.webURL = webURL; self.startLine = startLine
  }
}
public struct HostingReviewThread: Sendable, Identifiable, Equatable {
  public let id: String
  public let remoteID: String
  public let source: HostingReviewSource
  public var comments: [HostingReviewComment]
  public let state: HostingReviewState
  public let resolved: Bool?
  public let canResolve: Bool
  public let hasMoreReplies: Bool
  public init(id: String, remoteID: String, source: HostingReviewSource, comments: [HostingReviewComment],
    state: HostingReviewState = .unknown, resolved: Bool? = nil, canResolve: Bool = false, hasMoreReplies: Bool = false) {
    self.id = id; self.remoteID = remoteID; self.source = source; self.comments = comments
    self.state = state; self.resolved = resolved; self.canResolve = canResolve; self.hasMoreReplies = hasMoreReplies
  }
  /// Merge by server IDs, never by body, author or timestamp; keep an existing root across pagination.
  public mutating func append(_ values: [HostingReviewComment]) {
    for value in values { if let i = comments.firstIndex(where: { $0.id == value.id }) { comments[i] = value } else { comments.append(value) } }
    comments.sort { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
  }
}
public struct HostingReviewDraftComment: Sendable, Identifiable, Equatable {
  public let id: UUID
  public var body: String
  public let anchor: HostingDiffAnchor
  public init(id: UUID = UUID(), body: String, anchor: HostingDiffAnchor) { self.id = id; self.body = body; self.anchor = anchor }
}
public struct HostingReviewDraft: Sendable, Identifiable, Equatable {
  public let id: UUID
  public let context: HostingReviewContext
  public var summary: String
  public var decision: HostingReviewDecision
  public var comments: [HostingReviewDraftComment]
  public init(id: UUID = UUID(), context: HostingReviewContext, summary: String = "", decision: HostingReviewDecision = .comment,
    comments: [HostingReviewDraftComment] = []) {
    self.id = id; self.context = context; self.summary = summary; self.decision = decision; self.comments = comments
  }
  public var hasContent: Bool { !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !comments.isEmpty || decision != .comment }
}
public enum HostingReviewMutation: Sendable, Equatable {
  case comment(body: String)
  case inline(body: String, anchor: HostingDiffAnchor)
  case reply(threadID: String, commentID: String, body: String)
  case review(summary: String, decision: HostingReviewDecision, comments: [HostingReviewDraftComment], pending: Bool)
  case submitPending(reviewID: String, summary: String, decision: HostingReviewDecision)
  case resolve(threadID: String, resolved: Bool)
  case requestReviewers(HostingReviewerSelection)
  public var capability: HostingReviewCapability {
    switch self { case .comment: .generalComment; case .inline: .inlineComment; case .reply: .reply
    case .review(_, let decision, _, let pending): pending ? .draft : decision == .approve ? .approve : decision == .requestChanges ? .requestChanges : .submitReview
    case .submitPending(_, _, let decision): decision == .approve ? .approve : decision == .requestChanges ? .requestChanges : .submitReview
    case .resolve: .resolveDiscussion; case .requestReviewers: .requestReviewers }
  }
  public func validate(context: HostingReviewContext) throws {
    guard context.capabilities.contains(capability) else { throw HostingReviewError.permissionRequired }
    func body(_ value: String, required: Bool = true) throws {
      guard value.utf8.count <= 60_000, !required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HostingReviewError.invalidBody }
    }
    func anchor(_ value: HostingDiffAnchor) throws {
      guard context.target == value.target else { throw HostingReviewError.targetChanged }
      guard context.revision == value.revision else { throw HostingReviewError.revisionChanged }
      guard context.capabilities.contains(.inlineComment) else { throw HostingReviewError.permissionRequired }
      if value.startLine != nil, !context.capabilities.contains(.multiLineComment) { throw HostingReviewError.permissionRequired }
    }
    switch self {
    case .comment(let text): try body(text)
    case .inline(let text, let value): try body(text); try anchor(value)
    case .reply(let thread, let comment, let text):
      guard !thread.isEmpty, !comment.isEmpty else { throw HostingReviewError.targetChanged }; try body(text)
    case .review(let text, let decision, let comments, let pending):
      guard comments.count <= 50, Set(comments.map(\.id)).count == comments.count else { throw HostingReviewError.invalidBody }
      try body(text, required: decision == .requestChanges || (decision == .comment && comments.isEmpty && !pending))
      for comment in comments { try body(comment.body); try anchor(comment.anchor) }
      if decision != .comment, !pending, context.target.userID == context.authorID { throw HostingReviewError.selfReview }
      if context.target.instance.provider == .gitlab,
        pending || decision != .approve || !comments.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw HostingReviewError.unsupported
      }
    case .submitPending(let reviewID, let text, let decision):
      guard !reviewID.isEmpty else { throw HostingReviewError.targetChanged }; try body(text, required: decision == .requestChanges)
      if decision != .comment, context.target.userID == context.authorID { throw HostingReviewError.selfReview }
    case .resolve(let thread, _): guard !thread.isEmpty else { throw HostingReviewError.targetChanged }
    case .requestReviewers(let selection): try selection.validate(context: context)
    }
  }
}
public struct HostingReviewReceipt: Sendable, Equatable {
  public let id: String
  public let threadID: String?
  public let state: HostingReviewState
  public let authorID: String
  public let commitSHA: String
  public let createdAt: String
  public let requestedReviewerIDs: [String]
  public init(id: String, threadID: String? = nil, state: HostingReviewState = .unknown, authorID: String,
    commitSHA: String = "", createdAt: String = "", requestedReviewerIDs: [String] = []) {
    self.id = id; self.threadID = threadID; self.state = state; self.authorID = authorID; self.commitSHA = commitSHA; self.createdAt = createdAt
    self.requestedReviewerIDs = requestedReviewerIDs
  }
}
public enum HostingReviewError: String, Error, LocalizedError, Sendable {
  case targetChanged, revisionChanged, requestClosed, permissionRequired, invalidBody, unanchorable, selfReview
  case unsupported, resultUnknown, readbackRequired, alreadySubmitting, alreadySubmitted, partialSubmission
  public var errorDescription: String? {
    switch self {
    case .targetChanged: "The account or review target changed. Open the intended request again."
    case .revisionChanged: "The request has changed. Refresh the diff and confirm the comment locations again."
    case .requestClosed: "This request is no longer open."
    case .permissionRequired: "This operation needs additional platform permissions. Explicitly reauthorize or replace the PAT."
    case .invalidBody: "Enter a comment within the supported size limit (60,000 UTF-8 bytes; 50 inline comments per review)."
    case .unanchorable: "This file cannot be safely anchored for inline comments. Open it in your browser."
    case .selfReview: "The platform does not allow approving or requesting changes on your own request."
    case .unsupported: "This platform or instance does not support this review operation."
    case .resultUnknown: "Submission result unknown. The draft is preserved. Check the platform before posting again."
    case .readbackRequired: "The platform accepted the request, but the result could not be verified. Check it before posting again."
    case .alreadySubmitting: "This review is already being submitted."
    case .alreadySubmitted: "This confirmed submission has already been sent."
    case .partialSubmission: "Some comments were published. Review each result before continuing."
    }
  }
}
