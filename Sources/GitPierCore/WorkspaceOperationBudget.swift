import Foundation

/// One process budget across local scans, on-demand search and batch Fetch.
/// A workspace operation runs its Git commands sequentially while holding one permit.
public actor WorkspaceOperationBudget {
  public static let shared = WorkspaceOperationBudget()
  private let limit: Int
  private var active = 0
  private var peak = 0
  private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
  public init(limit: Int = 3) { self.limit = max(1, limit) }
  private func acquire(_ id: UUID) async throws {
    try Task.checkCancellation()
    if active < limit { active += 1; peak = max(peak, active); return }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { waiters.append((id, $0)) }
    } onCancel: { Task { await self.cancel(id) } }
  }
  private func cancel(_ id: UUID) {
    if let index = waiters.firstIndex(where: { $0.0 == id }) { waiters.remove(at: index).1.resume(throwing: CancellationError()) }
  }
  private func release() {
    if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().1.resume() }
  }
  public func perform<T: Sendable>(_ action: @Sendable () async throws -> T) async throws -> T {
    try await acquire(UUID())
    defer { release() }
    try Task.checkCancellation()
    return try await action()
  }
  public func metrics() -> (active: Int, peak: Int, limit: Int) { (active, peak, limit) }
}
