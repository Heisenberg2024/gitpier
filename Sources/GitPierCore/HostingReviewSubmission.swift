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
  case review(HostingReviewError), hosting(HostingError), journal(HostingReviewJournalError), cancelled
  public var message: String {
    switch self { case .review(let value): value.localizedDescription; case .hosting(let value): value.localizedDescription; case .journal(let value): value.localizedDescription; case .cancelled: "Cancelled before sending." }
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
    init(_ identity: HostingReviewOperationIdentity) {
      instance = identity.instance; accountID = identity.accountID; userID = identity.userID
      repositoryID = identity.repositoryID; requestID = identity.requestID
    }
    var writeKey: WriteKey { WriteKey(self) }
  }
  /// A reconnect can assign another local UUID to the same remote user. It must
  /// share active/unknown write barriers without inheriting the old UUID's data.
  private struct WriteKey: Hashable, Sendable {
    let instance: HostingInstance
    let userID: String
    let repositoryID: String
    let requestID: String
    init(_ target: TargetKey) {
      instance = target.instance; userID = target.userID
      repositoryID = target.repositoryID; requestID = target.requestID
    }
  }
  private var active: Set<WriteKey> = []
  private var reports: [UUID: HostingReviewSubmissionReport] = [:]
  private var uncertain: [UUID: TargetKey] = [:]
  private let journal: HostingReviewOperationJournal?
  private var journalRecords: [HostingReviewOperationRecord] = []
  private var journalRecoveryFailed = false
  private var pendingAcknowledgements: [UUID: HostingReviewOperationRecord] = [:]
  private var acknowledgedOperations: Set<UUID> = []
  // These contain stable identities/UUIDs only, never mutations, bodies or anchors.
  private var consumedConfirmations: [UUID: TargetKey] = [:]
  private var discardedConfirmations: Set<UUID> = []
  private var uncertainItemIDs: [UUID: Set<UUID>] = [:]
  public init(journal: HostingReviewOperationJournal? = nil) { self.journal = journal }
  public func report(_ id: UUID) -> HostingReviewSubmissionReport? { reports[id] }
  /// Drop private cached payloads on disconnect/shutdown. An active request frame
  /// can retain its confirmed value until it unwinds; this does not promise secure
  /// String erasure. Stable locks, unknown item IDs and consumed tickets remain.
  public func discardPrivateContent(accountID: UUID? = nil) {
    for (id, target) in consumedConfirmations where accountID == nil || target.accountID == accountID {
      discardedConfirmations.insert(id); reports[id] = nil; contexts[id] = nil
    }
  }
  private func requirePrivateContent(_ id: UUID) throws {
    guard !discardedConfirmations.contains(id) else { throw HostingError.accountChanged }
  }
  private func saveReport(_ report: HostingReviewSubmissionReport) {
    uncertainItemIDs[report.confirmationID] = Set(report.results.compactMap { result in
      switch result.outcome {
      case .unknown: result.id
      case .failed where uncertain[report.confirmationID] != nil: result.id
      default: nil
      }
    })
    if !discardedConfirmations.contains(report.confirmationID) { reports[report.confirmationID] = report }
  }
  private func requiresUncertainOverlay(_ record: HostingReviewOperationRecord) -> Bool {
    if pendingAcknowledgements[record.id] != nil { return true }
    guard uncertain[record.confirmationID] != nil, !acknowledgedOperations.contains(record.id),
      uncertainItemIDs[record.confirmationID]?.contains(record.itemID) == true else { return false }
    return true
  }
  private func refreshJournal() throws {
    do {
      journalRecords = try journal?.records() ?? []
      for record in pendingAcknowledgements.values where !journalRecords.contains(where: { $0.id == record.id }) { journalRecords.append(record) }
      for index in journalRecords.indices where requiresUncertainOverlay(journalRecords[index]) { journalRecords[index].retainUnknown() }
      journalRecords.sort { ($0.startedAt, $0.confirmationID.uuidString, $0.sequence) < ($1.startedAt, $1.confirmationID.uuidString, $1.sequence) }
      journalRecoveryFailed = false
    }
    catch { journalRecoveryFailed = true; throw error }
  }
  public func recoveredOperations(accountID: UUID? = nil) throws -> [HostingReviewOperationRecord] {
    try refreshJournal()
    return journalRecords.filter { accountID == nil || $0.identity.accountID == accountID }
  }
  public func recoveryFailure() -> Bool { journalRecoveryFailed }
  public func isBlocked(_ target: HostingReviewTarget) -> Bool {
    do { try refreshJournal() } catch { return true }
    return hasUnknownWriteBarrier(target)
  }
  private func hasUnknownWriteBarrier(_ target: HostingReviewTarget) -> Bool {
    let key = TargetKey(target).writeKey
    return uncertain.values.contains { $0.writeKey == key }
      || journalRecords.contains { $0.identity.matchesRemoteWriteTarget(target) && $0.isUnresolved }
  }
  /// Explicit user acknowledgement after inspecting the platform. Never triggered by a timer or reload.
  public func acknowledgePlatformCheck(_ target: HostingReviewTarget) throws {
    let key = TargetKey(target)
    guard !active.contains(key.writeKey) else { throw HostingReviewError.alreadySubmitting }
    try refreshJournal()
    let records = journalRecords.filter { $0.identity.matches(target) && $0.isUnresolved }
    if records.isEmpty, hasUnknownWriteBarrier(target), !uncertain.values.contains(key) { throw HostingReviewError.resultUnknown }
    if journal != nil, uncertain.values.contains(key), records.isEmpty { throw HostingReviewJournalError.corrupt }
    for record in records { pendingAcknowledgements[record.id] = record }
    do {
      // Retry only this target's current unresolved/pending IDs. Historical
      // acknowledgements must not be rewritten as a side effect of another check.
      for record in records { try journal?.acknowledge(record.id, retryUncertain: true) }
    } catch {
      for record in records { uncertain[record.confirmationID] = key }
      throw error
    }
    for record in records { pendingAcknowledgements[record.id] = nil; acknowledgedOperations.insert(record.id) }
    // Durability already succeeded. Converge the barrier before a presentation
    // reload that may independently fail, otherwise a transient read can strand it.
    uncertain = uncertain.filter { $0.value != key }
    try refreshJournal()
    if hasUnknownWriteBarrier(target) { throw HostingReviewError.resultUnknown }
  }
  public func ackRecoveredOperation(_ id: UUID) throws {
    try refreshJournal()
    guard let record = journalRecords.first(where: { $0.id == id }), record.isUnresolved else { throw HostingReviewError.targetChanged }
    guard !active.contains(TargetKey(record.identity).writeKey) else { throw HostingReviewError.alreadySubmitting }
    pendingAcknowledgements[id] = record
    do { try journal?.acknowledge(id, retryUncertain: true) }
    catch { uncertain[record.confirmationID] = TargetKey(record.identity); throw error }
    pendingAcknowledgements[id] = nil; acknowledgedOperations.insert(id)
    let otherUnresolved = journalRecords.contains {
      $0.confirmationID == record.confirmationID && $0.id != id && $0.isUnresolved && !acknowledgedOperations.contains($0.id)
    } || pendingAcknowledgements.values.contains { $0.confirmationID == record.confirmationID }
    if !otherUnresolved {
      uncertain[record.confirmationID] = nil
    }
    try refreshJournal()
  }
  public func pruneCompletedOperations() throws {
    guard active.isEmpty else { throw HostingReviewError.alreadySubmitting }
    guard pendingAcknowledgements.isEmpty else { throw HostingReviewError.resultUnknown }
    try refreshJournal()
    let unresolved = Set(journalRecords.filter(\.isUnresolved).map(\.confirmationID))
    try journal?.pruneCompletedRecords(excluding: unresolved); try refreshJournal()
  }
  public typealias RecoveredReadback = @Sendable (HostingReviewOperationRecord) async throws -> HostingReviewReceipt
  /// Evidence from a stable-ID GET is useful, but cannot restore the missing body or diff anchor.
  /// Keep the unknown barrier until the user separately acknowledges checking the platform.
  public func inspectRecoveredReceipt(_ id: UUID, validate: Validate, readback: RecoveredReadback) async throws -> HostingReviewReceipt {
    try refreshJournal()
    guard let record = journalRecords.first(where: { $0.id == id }), let known = record.receipt?.value,
      record.isUnresolved else { throw HostingReviewError.readbackRequired }
    let key = TargetKey(record.identity)
    guard !active.contains(key.writeKey) else { throw HostingReviewError.alreadySubmitting }
    active.insert(key.writeKey); defer { active.remove(key.writeKey) }
    try await validate()
    let receipt = try await readback(record)
    try await validate()
    guard receipt.id == known.id, receipt.authorID == record.identity.userID,
      known.threadID == nil || receipt.threadID == known.threadID,
      record.operation.expectedState == nil || receipt.state == record.operation.expectedState
    else { throw HostingReviewError.readbackRequired }
    if [.inline, .review, .submitPending, .requestReviewers].contains(record.operation.kind) {
      guard receipt.commitSHA == record.revision.headSHA else { throw HostingReviewError.readbackRequired }
    }
    if record.operation.kind == .requestReviewers {
      guard receipt.id == record.identity.requestID,
        Set(receipt.requestedReviewerIDs).isSuperset(of: record.operation.requestedReviewerIDs),
        Set(receipt.requestedReviewerIDs).isSuperset(of: known.requestedReviewerIDs)
      else { throw HostingReviewError.readbackRequired }
    }
    return receipt
  }

  public func submit(_ confirmation: HostingReviewConfirmation, current: Current, validate: Validate,
    validateAnchor: ValidateAnchor, send: Send, readback: Readback) async throws -> HostingReviewSubmissionReport {
    // A disconnected session can cancel before its queued actor call begins.
    // Reject it before any private payload is cached or ticket is consumed.
    try Task.checkCancellation()
    let target = confirmation.context.target
    let key = TargetKey(target)
    guard !active.contains(key.writeKey) else { throw HostingReviewError.alreadySubmitting }
    if let previous = reports[confirmation.id] {
      guard previous.target == target, contexts[confirmation.id] == confirmation.context,
        previous.results.map(\.mutation) == confirmation.items.map(\.mutation) else { throw HostingReviewError.targetChanged }
      return previous
    }
    guard consumedConfirmations[confirmation.id] == nil else { throw HostingReviewError.alreadySubmitted }
    try refreshJournal()
    guard !journalRecords.contains(where: { $0.confirmationID == confirmation.id }) else { throw HostingReviewError.alreadySubmitted }
    guard !hasUnknownWriteBarrier(target) else { throw HostingReviewError.resultUnknown }
    active.insert(key.writeKey); defer { active.remove(key.writeKey) }
    var report = HostingReviewSubmissionReport(confirmationID: confirmation.id, target: target,
      results: confirmation.items.map { HostingReviewSubmissionResult(id: $0.id, mutation: $0.mutation, outcome: .notSent) })
    // Publish the attempt before the first suspension to prevent duplicate sends of the same ticket.
    consumedConfirmations[confirmation.id] = key
    saveReport(report); contexts[confirmation.id] = confirmation.context
    var prepared = false
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
        try requirePrivateContent(confirmation.id)
      } catch {
        report.results[index].outcome = .failed(Self.failure(error))
        if prepared {
          do { try journal?.update(confirmationID: confirmation.id, itemID: report.results[index].id, state: .definitelyFailedBeforeSend) }
          catch { journalRecoveryFailed = true }
        }
        break
      }
      do {
        if !prepared { try journal?.prepare(confirmation); prepared = true }
        // Each independent GitLab discussion gets its own durable intent immediately before sending.
        try journal?.update(confirmationID: confirmation.id, itemID: report.results[index].id, state: .possiblySent)
      } catch {
        report.results[index].outcome = .failed(Self.failure(error)); journalRecoveryFailed = true
        break
      }
      var receipt: HostingReviewReceipt?
      do {
        // Cancellation from here onward can mean that the server accepted the write.
        receipt = try await send(mutation, confirmation.context)
        guard let receipt, !receipt.id.isEmpty else { throw HostingReviewError.resultUnknown }
        // Save the server ID before any GET or further await can fail or be cancelled.
        try journal?.update(confirmationID: confirmation.id, itemID: report.results[index].id, state: .possiblySent, receipt: receipt)
        try requirePrivateContent(confirmation.id)
        let verified = try await readback(receipt, mutation, confirmation.context)
        try requirePrivateContent(confirmation.id)
        guard Self.matches(receipt, verified, context: confirmation.context, mutation: mutation) else {
          throw HostingReviewError.readbackRequired
        }
        try journal?.update(confirmationID: confirmation.id, itemID: report.results[index].id, state: .submittedAndVerified, receipt: verified)
        report.results[index].outcome = .submitted(verified)
        // The result remains recorded even if navigation/account cancellation arrives after success.
        try Task.checkCancellation(); try await validate()
      } catch {
        if case .submitted = report.results[index].outcome { break }
        if receipt != nil || Self.ambiguous(error) {
          report.results[index].outcome = .unknown(receipt); uncertain[confirmation.id] = key
          do { try journal?.update(confirmationID: confirmation.id, itemID: report.results[index].id, state: .resultUnknown, receipt: receipt) }
          catch { journalRecoveryFailed = true }
        } else {
          report.results[index].outcome = .failed(Self.failure(error))
          do { try journal?.update(confirmationID: confirmation.id, itemID: report.results[index].id, state: .definitelyRejected) }
          catch { uncertain[confirmation.id] = key; journalRecoveryFailed = true }
        }
        break
      }
      saveReport(report)
    }
    saveReport(report)
    try requirePrivateContent(confirmation.id)
    return report
  }
  /// Only stable IDs returned by the server can resolve an unknown receipt by readback.
  /// If no ID was received, keep the unknown result; matching a body/date cannot prove identity.
  public func reconcile(_ id: UUID, validate: Validate, readback: Readback) async throws -> HostingReviewSubmissionReport {
    try Task.checkCancellation()
    guard var report = reports[id] else { throw HostingReviewError.targetChanged }
    let key = TargetKey(report.target)
    guard !active.contains(key.writeKey) else { throw HostingReviewError.alreadySubmitting }
    active.insert(key.writeKey); defer { active.remove(key.writeKey) }
    for index in report.results.indices {
      guard case .unknown(let known?) = report.results[index].outcome else { continue }
      try await validate()
      try requirePrivateContent(id)
      // Context is retained separately, without persisting the draft or any private content.
      guard let context = contexts[id] else { continue }
      let receipt = try await readback(known, report.results[index].mutation, context)
      try requirePrivateContent(id)
      guard Self.matches(known, receipt, context: context, mutation: report.results[index].mutation) else { continue }
      try journal?.update(confirmationID: id, itemID: report.results[index].id, state: .submittedAndVerified, receipt: receipt)
      let itemID = report.results[index].id
      pendingAcknowledgements = pendingAcknowledgements.filter { $0.value.confirmationID != id || $0.value.itemID != itemID }
      report.results[index].outcome = .submitted(receipt)
    }
    saveReport(report)
    if !report.hasUnknown { uncertain[id] = nil }
    try requirePrivateContent(id)
    return report
  }
  private var contexts: [UUID: HostingReviewContext] = [:]
  private static func anchors(_ mutation: HostingReviewMutation) -> [HostingDiffAnchor] {
    switch mutation { case .inline(_, let anchor): [anchor]; case .review(_, _, let comments, _): comments.map(\.anchor); default: [] }
  }
  private static func failure(_ error: Error) -> HostingReviewSubmissionFailure {
    if error is CancellationError { return .cancelled }
    if let value = error as? HostingReviewJournalError { return .journal(value) }
    if let value = error as? HostingReviewError { return .review(value) }
    return .hosting(error as? HostingError ?? .networkFailure)
  }
  private static func ambiguous(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let value = error as? HostingReviewError { return [.resultUnknown, .readbackRequired, .targetChanged].contains(value) }
    guard let value = error as? HostingError else { return true }
    return [.networkFailure, .serverFailure, .responseTooLarge, .invalidResponse, .redirectRejected, .accountChanged].contains(value)
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
