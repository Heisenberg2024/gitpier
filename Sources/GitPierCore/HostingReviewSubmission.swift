import Foundation

public struct HostingReviewSubmissionItem: Identifiable, Sendable, Equatable {
  public let id: UUID
  public let mutation: HostingReviewMutation
  public init(id: UUID = UUID(), mutation: HostingReviewMutation) { self.id = id; self.mutation = mutation }
}
/// Value snapshot shown by the final confirmation sheet. Editing creates a new confirmation.
public struct HostingReviewConfirmation: Identifiable, Sendable, Equatable {
  public let id: UUID
  public let context: HostingReviewContext
  public let items: [HostingReviewSubmissionItem]
  public init(id: UUID = UUID(), context: HostingReviewContext, items: [HostingReviewSubmissionItem]) throws {
    guard context.revision.valid, !items.isEmpty, items.count <= 52,
      Set(items.map(\.id)).count == items.count else { throw HostingReviewError.invalidBody }
    for item in items { try item.mutation.validate(context: context) }
    self.id = id; self.context = context; self.items = items
  }
  public static func draft(_ draft: HostingReviewDraft) throws -> Self {
    let items: [HostingReviewSubmissionItem]
    if draft.context.target.instance.provider == .gitlab {
      // Discussions and Approval are independent writes. Preserve their individual outcomes.
      guard draft.decision != .requestChanges else { throw HostingReviewError.unsupported }
      var values = draft.comments.map { HostingReviewSubmissionItem(id: $0.id, mutation: .inline(body: $0.body, anchor: $0.anchor)) }
      if !draft.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { values.append(HostingReviewSubmissionItem(id: draft.id, mutation: .comment(body: draft.summary))) }
      if draft.decision == .approve { values.append(HostingReviewSubmissionItem(mutation: .review(summary: "", decision: .approve, comments: [], pending: false))) }
      items = values
    } else {
      items = [HostingReviewSubmissionItem(id: draft.id, mutation: .review(summary: draft.summary, decision: draft.decision, comments: draft.comments, pending: false))]
    }
    return try Self(context: draft.context, items: items)
  }
}
public enum HostingReviewSubmissionFailure: Sendable, Equatable {
  case review(HostingReviewError), hosting(HostingError), cancelled
  public var message: String {
    switch self { case .review(let value): value.localizedDescription; case .hosting(let value): value.localizedDescription; case .cancelled: "Cancelled before sending." }
  }
}
public enum HostingReviewSubmissionOutcome: Sendable, Equatable {
  case submitted(HostingReviewReceipt)
  case failed(HostingReviewSubmissionFailure)
  case unknown(HostingReviewReceipt?)
  case notSent
}
public struct HostingReviewSubmissionResult: Sendable, Identifiable, Equatable {
  public let id: UUID
  public let mutation: HostingReviewMutation
  public var outcome: HostingReviewSubmissionOutcome
}
public struct HostingReviewSubmissionReport: Sendable, Equatable {
  public let confirmationID: UUID
  public let target: HostingReviewTarget
  public var results: [HostingReviewSubmissionResult]
  public var complete: Bool { results.allSatisfy { if case .submitted = $0.outcome { true } else { false } } }
  public var hasUnknown: Bool { results.contains { if case .unknown = $0.outcome { true } else { false } } }
  public var submittedCount: Int { results.filter { if case .submitted = $0.outcome { true } else { false } }.count }
}

/// Shared by all windows. Remote API writes have their own queue; no local Git queue is involved.
public actor HostingReviewSubmissionCoordinator {
  public typealias Current = @Sendable () async throws -> HostingReviewContext
  public typealias Validate = @Sendable () async throws -> Void
  public typealias ValidateAnchor = @Sendable (HostingDiffAnchor) async throws -> Void
  public typealias Send = @Sendable (HostingReviewMutation, HostingReviewContext) async throws -> HostingReviewReceipt
  public typealias Readback = @Sendable (HostingReviewReceipt, HostingReviewMutation, HostingReviewContext) async throws -> HostingReviewReceipt
  /// API paths can differ in case or change after a rename while identifying the same
  /// remote request. Only the shared lock uses stable IDs; confirmations stay exact.
  private struct TargetKey: Hashable, Sendable {
    let instance: HostingInstance
    let accountID: UUID
    let userID: String
    let repositoryID: String
    let requestID: String
    init(_ target: HostingReviewTarget) {
      instance = target.instance; accountID = target.accountID; userID = target.userID
      repositoryID = target.repositoryID; requestID = target.requestID
    }
  }
  private var active: Set<TargetKey> = []
  private var reports: [UUID: HostingReviewSubmissionReport] = [:]
  private var uncertain: [UUID: TargetKey] = [:]
  public init() {}
  public func report(_ id: UUID) -> HostingReviewSubmissionReport? { reports[id] }
  public func isBlocked(_ target: HostingReviewTarget) -> Bool { uncertain.values.contains(TargetKey(target)) }
  /// Explicit user acknowledgement after inspecting the platform. Never triggered by a timer or reload.
  public func acknowledgePlatformCheck(_ target: HostingReviewTarget) {
    let key = TargetKey(target); uncertain = uncertain.filter { $0.value != key }
  }

  public func submit(_ confirmation: HostingReviewConfirmation, current: Current, validate: Validate,
    validateAnchor: ValidateAnchor, send: Send, readback: Readback) async throws -> HostingReviewSubmissionReport {
    let target = confirmation.context.target
    let key = TargetKey(target)
    guard !active.contains(key) else { throw HostingReviewError.alreadySubmitting }
    if let previous = reports[confirmation.id] {
      guard previous.target == target, contexts[confirmation.id] == confirmation.context,
        previous.results.map(\.mutation) == confirmation.items.map(\.mutation) else { throw HostingReviewError.targetChanged }
      return previous
    }
    guard !uncertain.values.contains(key) else { throw HostingReviewError.resultUnknown }
    active.insert(key); defer { active.remove(key) }
    var report = HostingReviewSubmissionReport(confirmationID: confirmation.id, target: target,
      results: confirmation.items.map { HostingReviewSubmissionResult(id: $0.id, mutation: $0.mutation, outcome: .notSent) })
    // Publish the attempt before the first suspension to prevent duplicate sends of the same ticket.
    reports[confirmation.id] = report; contexts[confirmation.id] = confirmation.context
    for index in report.results.indices {
      let mutation = report.results[index].mutation
      do {
        try Task.checkCancellation(); try await validate()
        let latest = try await current()
        try Task.checkCancellation(); try await validate()
        try confirmation.context.validateCurrent(latest)
        try mutation.validate(context: latest)
        for anchor in Self.anchors(mutation) {
          try await validateAnchor(anchor); try Task.checkCancellation(); try await validate()
        }
        // Recheck revision after potentially slow file reads and immediately before every write.
        let final = try await current()
        try confirmation.context.validateCurrent(final); try mutation.validate(context: final)
        try Task.checkCancellation(); try await validate()
      } catch {
        report.results[index].outcome = .failed(Self.failure(error))
        break
      }
      var receipt: HostingReviewReceipt?
      do {
        // Cancellation from here onward can mean that the server accepted the write.
        receipt = try await send(mutation, confirmation.context)
        guard let receipt, !receipt.id.isEmpty else { throw HostingReviewError.resultUnknown }
        let verified = try await readback(receipt, mutation, confirmation.context)
        guard Self.matches(receipt, verified, context: confirmation.context, mutation: mutation) else {
          throw HostingReviewError.readbackRequired
        }
        report.results[index].outcome = .submitted(verified)
        // The result remains recorded even if navigation/account cancellation arrives after success.
        try Task.checkCancellation(); try await validate()
      } catch {
        if case .submitted = report.results[index].outcome { break }
        if receipt != nil || Self.ambiguous(error) {
          report.results[index].outcome = .unknown(receipt); uncertain[confirmation.id] = key
        } else { report.results[index].outcome = .failed(Self.failure(error)) }
        break
      }
      reports[confirmation.id] = report
    }
    reports[confirmation.id] = report
    return report
  }
  /// Only stable IDs returned by the server can resolve an unknown receipt by readback.
  /// If no ID was received, keep the unknown result; matching a body/date cannot prove identity.
  public func reconcile(_ id: UUID, validate: Validate, readback: Readback) async throws -> HostingReviewSubmissionReport {
    guard var report = reports[id] else { throw HostingReviewError.targetChanged }
    let key = TargetKey(report.target)
    guard !active.contains(key) else { throw HostingReviewError.alreadySubmitting }
    active.insert(key); defer { active.remove(key) }
    for index in report.results.indices {
      guard case .unknown(let known?) = report.results[index].outcome else { continue }
      try await validate()
      // Context is retained separately, without persisting the draft or any private content.
      guard let context = contexts[id] else { continue }
      let receipt = try await readback(known, report.results[index].mutation, context)
      guard Self.matches(known, receipt, context: context, mutation: report.results[index].mutation) else { continue }
      report.results[index].outcome = .submitted(receipt)
    }
    reports[id] = report
    if !report.hasUnknown { uncertain[id] = nil }
    return report
  }
  private var contexts: [UUID: HostingReviewContext] = [:]
  private static func anchors(_ mutation: HostingReviewMutation) -> [HostingDiffAnchor] {
    switch mutation { case .inline(_, let anchor): [anchor]; case .review(_, _, let comments, _): comments.map(\.anchor); default: [] }
  }
  private static func failure(_ error: Error) -> HostingReviewSubmissionFailure {
    if error is CancellationError { return .cancelled }
    if let value = error as? HostingReviewError { return .review(value) }
    return .hosting(error as? HostingError ?? .networkFailure)
  }
  private static func ambiguous(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let value = error as? HostingReviewError { return [.resultUnknown, .readbackRequired, .targetChanged].contains(value) }
    guard let value = error as? HostingError else { return true }
    return [.networkFailure, .serverFailure, .responseTooLarge, .invalidResponse, .accountChanged].contains(value)
  }
  private static func matches(_ sent: HostingReviewReceipt, _ read: HostingReviewReceipt,
    context: HostingReviewContext, mutation: HostingReviewMutation) -> Bool {
    guard sent.id == read.id, read.authorID == context.target.userID else { return false }
    switch mutation {
    case .review(_, let decision, _, let pending):
      return read.commitSHA == context.revision.headSHA && read.state == (pending ? .pending : decision == .approve ? .approved : decision == .requestChanges ? .changesRequested : .commented)
    case .submitPending(_, _, let decision):
      return read.commitSHA == context.revision.headSHA && read.state == (decision == .approve ? .approved : decision == .requestChanges ? .changesRequested : .commented)
    case .inline: return read.commitSHA == context.revision.headSHA
    case .requestReviewers(let selection):
      return read.id == context.target.requestID && read.commitSHA == context.revision.headSHA
        && Set(read.requestedReviewerIDs).isSuperset(of: selection.reviewers.map(\.id))
        && Set(read.requestedReviewerIDs).isSuperset(of: sent.requestedReviewerIDs)
    default: return true
    }
  }
}
