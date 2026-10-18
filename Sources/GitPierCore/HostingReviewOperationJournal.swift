import Darwin
import Foundation

public enum HostingReviewJournalError: String, Error, LocalizedError, Sendable {
  case unavailable, corrupt, unsupportedSchema, capacityReached
  public var errorDescription: String? {
    switch self {
    case .unavailable: "Review operation history could not be saved safely. Check recovery before posting again."
    case .corrupt: "Review operation history could not be recovered safely. Preserve the original files and check the platform before posting again."
    case .unsupportedSchema: "Review operation history was written by an unsupported version. New review writes are blocked."
    case .capacityReached: "Review operation history is full. Explicitly clear completed history before posting again; unresolved operations must be kept."
    }
  }
}

/// Stable IDs only. Repository names, local/source paths and web URLs are deliberately absent.
public struct HostingReviewOperationIdentity: Codable, Hashable, Sendable {
  public let instance: HostingInstance
  public let accountID: UUID
  public let userID: String
  public let repositoryID: String
  public let requestID: String
  public let requestNumber: Int
  public init(_ target: HostingReviewTarget) {
    instance = target.instance; accountID = target.accountID; userID = target.userID
    repositoryID = target.repositoryID; requestID = target.requestID; requestNumber = target.requestNumber
  }
  public func matches(_ target: HostingReviewTarget) -> Bool {
    instance == target.instance && accountID == target.accountID && userID == target.userID
      && repositoryID == target.repositoryID && requestID == target.requestID
  }
  /// Only duplicate-write barriers ignore a local account UUID recreated on reconnect.
  /// Receipt inspection, account ownership and acknowledgement keep using matches().
  public func matchesRemoteWriteTarget(_ target: HostingReviewTarget) -> Bool {
    instance == target.instance && userID == target.userID
      && repositoryID == target.repositoryID && requestID == target.requestID
  }
  public func sameRemoteWriteTarget(_ other: Self) -> Bool {
    instance == other.instance && userID == other.userID
      && repositoryID == other.repositoryID && requestID == other.requestID
  }
  func sameTarget(_ other: Self) -> Bool {
    instance == other.instance && accountID == other.accountID && userID == other.userID
      && repositoryID == other.repositoryID && requestID == other.requestID
  }
  func validate() throws {
    guard try HostingInstance(provider: instance.provider, url: instance.baseURL.absoluteString) == instance,
      Self.opaque(userID), Self.opaque(repositoryID), Self.opaque(requestID), requestNumber > 0
    else { throw HostingReviewJournalError.corrupt }
  }
  static func opaque(_ value: String, optional: Bool = false) -> Bool {
    (optional || !value.isEmpty) && value.utf8.count <= 1024
      && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }
}

public struct HostingReviewOperationRevision: Codable, Equatable, Sendable {
  public let headSHA: String
  public let baseSHA: String
  public let startSHA: String
  public let diffID: String
  public init(_ revision: HostingReviewRevision) {
    headSHA = revision.headSHA; baseSHA = revision.baseSHA; startSHA = revision.startSHA; diffID = revision.diffID
  }
  public var value: HostingReviewRevision { HostingReviewRevision(headSHA: headSHA, baseSHA: baseSHA, startSHA: startSHA, diffID: diffID) }
  func validate() throws {
    guard value.valid, baseSHA.isEmpty || HostingReviewRevision.isSHA(baseSHA),
      startSHA.isEmpty || HostingReviewRevision.isSHA(startSHA), HostingReviewOperationIdentity.opaque(diffID, optional: true)
    else { throw HostingReviewJournalError.corrupt }
  }
}

public enum HostingReviewOperationKind: String, Codable, Sendable {
  case comment, inline, reply, review, submitPending, resolve, requestReviewers
}

/// Only the routing/expected-state metadata needed for a stable-ID, read-only inspection.
/// No body, body hash, diff, anchor, code or source path is encoded.
public struct HostingReviewOperationDescriptor: Codable, Equatable, Sendable {
  public let kind: HostingReviewOperationKind
  private let expectedStateRaw: String?
  public let threadID: String?
  public let parentCommentID: String?
  public let reviewID: String?
  public let resolved: Bool?
  public let requestedReviewerIDs: [String]
  public var rawValue: String { kind.rawValue }
  public var expectedState: HostingReviewState? { expectedStateRaw.flatMap(HostingReviewState.init(rawValue:)) }
  init(_ mutation: HostingReviewMutation) {
    var thread: String?, parent: String?, review: String?, resolution: Bool?, state: HostingReviewState?
    var reviewers: [String] = []
    switch mutation {
    case .comment: kind = .comment
    case .inline: kind = .inline
    case .reply(let threadID, let commentID, _): kind = .reply; thread = threadID; parent = commentID
    case .review(_, let decision, _, let pending):
      kind = .review; state = pending ? .pending : Self.state(decision)
    case .submitPending(let reviewID, _, let decision): kind = .submitPending; review = reviewID; state = Self.state(decision)
    case .resolve(let threadID, let resolved): kind = .resolve; thread = threadID; resolution = resolved
    case .requestReviewers(let selection): kind = .requestReviewers; reviewers = selection.reviewers.map(\.id)
    }
    threadID = thread; parentCommentID = parent; self.reviewID = review; resolved = resolution
    expectedStateRaw = state?.rawValue; requestedReviewerIDs = reviewers
  }
  private static func state(_ decision: HostingReviewDecision) -> HostingReviewState {
    decision == .approve ? .approved : decision == .requestChanges ? .changesRequested : .commented
  }
  func validate() throws {
    let ids = [threadID, parentCommentID, reviewID].compactMap { $0 } + requestedReviewerIDs
    guard ids.allSatisfy({ HostingReviewOperationIdentity.opaque($0) }), requestedReviewerIDs.count <= 100,
      Set(requestedReviewerIDs).count == requestedReviewerIDs.count,
      expectedStateRaw == nil || expectedState != nil else { throw HostingReviewJournalError.corrupt }
    switch kind {
    case .comment, .inline:
      guard threadID == nil, parentCommentID == nil, reviewID == nil, resolved == nil, expectedState == nil, requestedReviewerIDs.isEmpty else { throw HostingReviewJournalError.corrupt }
    case .reply:
      guard threadID != nil, parentCommentID != nil, reviewID == nil, resolved == nil, expectedState == nil, requestedReviewerIDs.isEmpty else { throw HostingReviewJournalError.corrupt }
    case .review, .submitPending:
      guard let expected = expectedState, [.commented, .approved, .changesRequested, .pending].contains(expected),
        kind != .submitPending || (reviewID != nil && expectedState != .pending),
        kind != .review || reviewID == nil, threadID == nil, parentCommentID == nil, resolved == nil, requestedReviewerIDs.isEmpty
      else { throw HostingReviewJournalError.corrupt }
    case .resolve:
      guard threadID != nil, resolved != nil, parentCommentID == nil, reviewID == nil, expectedState == nil, requestedReviewerIDs.isEmpty else { throw HostingReviewJournalError.corrupt }
    case .requestReviewers:
      guard !requestedReviewerIDs.isEmpty, threadID == nil, parentCommentID == nil, reviewID == nil, resolved == nil, expectedState == nil else { throw HostingReviewJournalError.corrupt }
    }
  }
}

public struct HostingReviewOperationReceipt: Codable, Equatable, Sendable {
  public let id: String
  public let threadID: String?
  private let stateRaw: String
  public let authorID: String
  public let commitSHA: String
  public let createdAt: String
  public let requestedReviewerIDs: [String]
  public init(_ receipt: HostingReviewReceipt) {
    id = receipt.id; stateRaw = receipt.state.rawValue
    threadID = receipt.threadID.flatMap { HostingReviewOperationIdentity.opaque($0) ? $0 : nil }
    authorID = HostingReviewOperationIdentity.opaque(receipt.authorID, optional: true) ? receipt.authorID : ""
    commitSHA = HostingReviewRevision.isSHA(receipt.commitSHA) ? receipt.commitSHA : ""
    createdAt = receipt.createdAt.utf8.count <= 128 && !receipt.createdAt.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? receipt.createdAt : ""
    requestedReviewerIDs = Array(Set(receipt.requestedReviewerIDs)).sorted()
  }
  public var value: HostingReviewReceipt {
    HostingReviewReceipt(id: id, threadID: threadID, state: HostingReviewState(rawValue: stateRaw) ?? .unknown,
      authorID: authorID, commitSHA: commitSHA, createdAt: createdAt, requestedReviewerIDs: requestedReviewerIDs)
  }
  func validate() throws {
    guard HostingReviewOperationIdentity.opaque(id), threadID.map({ HostingReviewOperationIdentity.opaque($0) }) ?? true,
      HostingReviewState(rawValue: stateRaw) != nil, HostingReviewOperationIdentity.opaque(authorID, optional: true),
      commitSHA.isEmpty || HostingReviewRevision.isSHA(commitSHA), createdAt.utf8.count <= 128,
      !createdAt.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      requestedReviewerIDs.count <= 1000, requestedReviewerIDs.allSatisfy({ HostingReviewOperationIdentity.opaque($0) })
    else { throw HostingReviewJournalError.corrupt }
  }
}

public enum HostingReviewOperationState: String, Codable, Sendable {
  case notSent, possiblySent, submittedAndVerified, definitelyFailedBeforeSend, definitelyRejected, resultUnknown, manuallyAcknowledged
  public var isUnresolved: Bool { self == .possiblySent || self == .resultUnknown }
}

public struct HostingReviewOperationRecord: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let confirmationID: UUID
  public let itemID: UUID
  public let sequence: Int
  public let identity: HostingReviewOperationIdentity
  public let revision: HostingReviewOperationRevision
  public let operation: HostingReviewOperationDescriptor
  public let startedAt: Date
  public private(set) var updatedAt: Date
  public private(set) var state: HostingReviewOperationState
  public private(set) var receipt: HostingReviewOperationReceipt?
  public var isUnresolved: Bool { state.isUnresolved }
  public var needsManualCheck: Bool { isUnresolved }
  init(confirmation: HostingReviewConfirmation, item: HostingReviewSubmissionItem, sequence: Int = 0, now: Date) {
    id = UUID(); confirmationID = confirmation.id; itemID = item.id; self.sequence = sequence
    identity = HostingReviewOperationIdentity(confirmation.context.target)
    revision = HostingReviewOperationRevision(confirmation.context.revision); operation = HostingReviewOperationDescriptor(item.mutation)
    startedAt = now; updatedAt = now; state = .notSent; receipt = nil
  }
  mutating func update(_ state: HostingReviewOperationState, receipt: HostingReviewReceipt? = nil) {
    self.state = state; updatedAt = max(Date(), updatedAt)
    if let receipt { self.receipt = HostingReviewOperationReceipt(receipt) }
  }
  mutating func recover() { if state == .possiblySent { state = .resultUnknown } }
  mutating func retainUnknown() { state = .resultUnknown }
  func validate() throws {
    try identity.validate(); try revision.validate(); try operation.validate(); try receipt?.validate()
    guard (0..<52).contains(sequence), startedAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite, updatedAt >= startedAt,
      state != .submittedAndVerified || receipt != nil,
      !(state == .notSent || state == .definitelyFailedBeforeSend) || receipt == nil
    else { throw HostingReviewJournalError.corrupt }
  }
}

/// Synchronous descriptor-relative persistence used inside the existing submission actor.
/// The advisory file lock protects journal transactions across processes; it is not a second submission queue.
public struct HostingReviewOperationJournal: Sendable {
  public let root: URL
  public static let maximumBatches = 1024
  public static let maximumRecords = 16_384
  private let checkpoint: @Sendable (String) throws -> Void
  private struct Batch: Codable {
    let version: Int
    let confirmationID: UUID
    var records: [HostingReviewOperationRecord]
  }
  public init(root: URL) { self.root = root; checkpoint = { _ in } }
  init(root: URL, checkpoint: @escaping @Sendable (String) throws -> Void) { self.root = root; self.checkpoint = checkpoint }
  private func withFiles<T>(_ body: (HostingPrivateDirectory, [Batch]) throws -> T) throws -> T {
    do {
      let directory = try HostingPrivateDirectory(root, durableCreation: true, durabilityCheckpoint: checkpoint)
      defer { directory.closeDirectory() }
      let lock = try directory.lock("journal.lock"); defer { close(lock) }
      return try body(directory, readBatches(directory))
    } catch let error as HostingReviewJournalError { throw error }
    catch let error as HostingReviewError { throw error }
    catch { throw HostingReviewJournalError.unavailable }
  }
  private func readBatches(_ directory: HostingPrivateDirectory) throws -> [Batch] {
    // HostingPrivateDirectory.names() deliberately tolerates enumeration failures for orphan cleanup.
    // Recovery must instead distinguish an empty journal from an unreadable directory.
    let duplicate = dup(directory.fd)
    guard duplicate >= 0 else { throw HostingReviewJournalError.unavailable }
    guard let stream = fdopendir(duplicate) else { close(duplicate); throw HostingReviewJournalError.unavailable }
    defer { closedir(stream) }
    var batches: [Batch] = [], total = 0, entries = 0
    while true {
      errno = 0
      guard let entry = readdir(stream) else {
        guard errno == 0 else { throw HostingReviewJournalError.unavailable }; break
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
      if name == "." || name == ".." || name == "journal.lock" { continue }
      entries += 1
      guard entries <= Self.maximumBatches * 2 + 32 else { throw HostingReviewJournalError.capacityReached }
      if name.hasPrefix(".write-"), UUID(uuidString: String(name.dropFirst(7))) != nil { continue }
      guard name.hasSuffix(".json"), let fileID = UUID(uuidString: String(name.dropLast(5))), name == fileID.uuidString + ".json",
        let data = try directory.read(name) else { throw HostingReviewJournalError.corrupt }
      let batch: Batch
      do { batch = try JSONDecoder().decode(Batch.self, from: data) }
      catch { throw HostingReviewJournalError.corrupt }
      guard batch.version == 1 else { throw HostingReviewJournalError.unsupportedSchema }
      guard batch.confirmationID == fileID, !batch.records.isEmpty, batch.records.count <= 52,
        Set(batch.records.map(\.id)).count == batch.records.count, Set(batch.records.map(\.itemID)).count == batch.records.count,
        batch.records.enumerated().allSatisfy({ $0.offset == $0.element.sequence && $0.element.confirmationID == fileID
          && $0.element.identity == batch.records[0].identity && $0.element.revision == batch.records[0].revision })
      else { throw HostingReviewJournalError.corrupt }
      for record in batch.records { try record.validate() }
      batches.append(batch); total += batch.records.count
      guard batches.count <= Self.maximumBatches, total <= Self.maximumRecords else { throw HostingReviewJournalError.capacityReached }
    }
    guard Set(batches.map(\.confirmationID)).count == batches.count,
      Set(batches.flatMap(\.records).map(\.id)).count == total else { throw HostingReviewJournalError.corrupt }
    return batches
  }
  private func write(_ batch: Batch, in directory: HostingPrivateDirectory, checkpoint stage: String) throws {
    for record in batch.records { try record.validate() }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(batch)
    try checkpoint(stage)
    try directory.write(data, name: batch.confirmationID.uuidString + ".json", fullSync: true, durabilityCheckpoint: checkpoint)
  }
  public func records() throws -> [HostingReviewOperationRecord] {
    try withFiles { _, batches in
      batches.flatMap(\.records).map { record in
        var recovered = record
        recovered.recover()
        return recovered
      }.sorted { ($0.startedAt, $0.confirmationID.uuidString, $0.sequence) < ($1.startedAt, $1.confirmationID.uuidString, $1.sequence) }
    }
  }
  func prepare(_ confirmation: HostingReviewConfirmation) throws {
    try withFiles { directory, batches in
      guard !batches.contains(where: { $0.confirmationID == confirmation.id }) else { throw HostingReviewError.alreadySubmitted }
      let identity = HostingReviewOperationIdentity(confirmation.context.target)
      guard !batches.flatMap(\.records).contains(where: { $0.identity.sameRemoteWriteTarget(identity) && $0.isUnresolved }) else { throw HostingReviewError.resultUnknown }
      guard batches.count < Self.maximumBatches, batches.reduce(0, { $0 + $1.records.count }) + confirmation.items.count <= Self.maximumRecords
      else { throw HostingReviewJournalError.capacityReached }
      let now = Date()
      try write(Batch(version: 1, confirmationID: confirmation.id,
        records: confirmation.items.enumerated().map { HostingReviewOperationRecord(confirmation: confirmation, item: $0.element, sequence: $0.offset, now: now) }), in: directory, checkpoint: "prepare")
    }
  }
  func update(confirmationID: UUID, itemID: UUID, state: HostingReviewOperationState, receipt: HostingReviewReceipt? = nil) throws {
    try withFiles { directory, batches in
      guard var batch = batches.first(where: { $0.confirmationID == confirmationID }),
        let index = batch.records.firstIndex(where: { $0.itemID == itemID }) else { throw HostingReviewJournalError.corrupt }
      if state == .possiblySent, receipt == nil {
        guard batch.records[index].state == .notSent else { throw HostingReviewError.alreadySubmitted }
        let identity = batch.records[index].identity
        guard !batches.flatMap(\.records).contains(where: { $0.id != batch.records[index].id && $0.identity.sameRemoteWriteTarget(identity) && $0.isUnresolved })
        else { throw HostingReviewError.resultUnknown }
      }
      batch.records[index].update(state, receipt: receipt)
      try write(batch, in: directory, checkpoint: receipt != nil && state == .possiblySent ? "receipt" : state.rawValue)
    }
  }
  public func acknowledge(_ operationID: UUID) throws {
    try acknowledge(operationID, retryUncertain: false)
  }
  /// Only the coordinator's explicit retry uses this after a prior rename may
  /// have succeeded without the required durability barrier returning success.
  func acknowledge(_ operationID: UUID, retryUncertain: Bool) throws {
    try withFiles { directory, batches in
      guard var batch = batches.first(where: { $0.records.contains { $0.id == operationID } }),
        let index = batch.records.firstIndex(where: { $0.id == operationID }),
        batch.records[index].isUnresolved || retryUncertain && [.manuallyAcknowledged, .submittedAndVerified, .definitelyRejected].contains(batch.records[index].state)
      else { throw HostingReviewJournalError.corrupt }
      batch.records[index].update(.manuallyAcknowledged)
      try write(batch, in: directory, checkpoint: "manuallyAcknowledged")
    }
  }
  func acknowledge(_ target: HostingReviewTarget) throws {
    try withFiles { directory, batches in
      for var batch in batches where batch.records.contains(where: { $0.identity.matches(target) && $0.isUnresolved }) {
        for index in batch.records.indices where batch.records[index].identity.matches(target) && batch.records[index].isUnresolved {
          batch.records[index].update(.manuallyAcknowledged)
        }
        try write(batch, in: directory, checkpoint: "manuallyAcknowledged")
      }
    }
  }
  /// Explicit housekeeping only. Unresolved records are never removed, regardless of age.
  public func pruneCompletedRecords() throws {
    try pruneCompletedRecords(excluding: [])
  }
  func pruneCompletedRecords(excluding confirmations: Set<UUID>) throws {
    try withFiles { directory, batches in
      for batch in batches where !confirmations.contains(batch.confirmationID) && !batch.records.contains(where: \.isUnresolved) {
        try checkpoint("remove")
        try directory.remove(batch.confirmationID.uuidString + ".json")
        guard fsync(directory.fd) == 0 else { throw HostingReviewJournalError.unavailable }
      }
    }
  }
}
