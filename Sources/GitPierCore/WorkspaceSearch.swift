import Foundation

public enum WorkspaceSearchKind: String, CaseIterable, Sendable { case repository, file, commit }
public enum WorkspaceSearchScope: String, CaseIterable, Sendable {
  case all, organization, current, selected
  public func records(from records: [RepositoryRecord], dashboard: Bool, organization: String?, currentID: UUID?, selected: Set<UUID>) -> [RepositoryRecord] {
    let currentGroup = dashboard ? organization : records.first { $0.id == currentID }?.group
    return records.filter { record in
      switch self {
      case .all: return true
      case .organization: return currentGroup != nil && record.group == currentGroup
      case .current: return record.id == currentID
      case .selected: return selected.contains(record.id)
      }
    }
  }
}
public struct WorkspaceSearchHit: Identifiable, Sendable {
  public var id: String { repositoryID.uuidString + ":" + kind.rawValue + ":" + value }
  public let repositoryID: UUID
  public let kind: WorkspaceSearchKind
  public let value: String
  public let detail: String
  public let commit: CommitRecord?
  public init(repositoryID: UUID, kind: WorkspaceSearchKind, value: String, detail: String, commit: CommitRecord? = nil) {
    self.repositoryID = repositoryID; self.kind = kind; self.value = value; self.detail = detail; self.commit = commit
  }
}
public struct WorkspaceRepositorySearchPage: Sendable {
  public let hits: [WorkspaceSearchHit]
  public let hasMore: Bool
  public init(hits: [WorkspaceSearchHit], hasMore: Bool) { self.hits = hits; self.hasMore = hasMore }
}
public struct WorkspaceSearchPage: Sendable {
  public var hits: [WorkspaceSearchHit] = []
  public var moreRepositories: Set<UUID> = []
  public var errors: [UUID: String] = [:]
  public init() {}
}

/// No index and no startup history reads. Native queries run only for a user's search.
public actor WorkspaceSearchService {
  public typealias Loader = @Sendable (RepositoryRecord, String, Set<WorkspaceSearchKind>, Int, Int) async throws -> WorkspaceRepositorySearchPage
  private let loader: Loader
  public init(loader: @escaping Loader = { record, query, kinds, page, size in
    let git = await GitServiceRegistry.shared.service(for: URL(fileURLWithPath: record.path))
    return try await git.workspaceSearch(record: record, query: query, kinds: kinds, page: page, size: size)
  }) { self.loader = loader }
  public nonisolated static func metadata(_ entries: [WorkspaceEntry], query: String) -> [WorkspaceSearchHit] {
    entries.filter { entry in
      let texts = [entry.record.name, entry.record.path, entry.record.group, entry.usable?.branch ?? ""] + (entry.usable?.remoteNames ?? [])
      return query.isEmpty || texts.contains { $0.localizedCaseInsensitiveContains(query) }
    }.map { WorkspaceSearchHit(repositoryID: $0.record.id, kind: .repository, value: $0.record.name, detail: $0.record.path) }
  }
  public func search(records: [RepositoryRecord], query: String, kinds: Set<WorkspaceSearchKind>, page: Int = 0,
                     size: Int = 25) async throws -> WorkspaceSearchPage {
    guard !query.utf8.contains(0), query.utf8.count <= 512, page >= 0, page <= 10000 else {
      throw GitPierError.invalidInput("Search is limited to 512 UTF-8 bytes and valid page numbers.")
    }
    if query.count < 2 || kinds.isDisjoint(with: [.file, .commit]) { return WorkspaceSearchPage() }
    let limit = max(1, min(size, 50)), loader = self.loader
    return try await withThrowingTaskGroup(of: (Int, WorkspaceRepositorySearchPage?, String?).self) { group in
      func enqueue(_ index: Int) {
        let record = records[index]
        group.addTask {
          do {
            let result = try await WorkspaceOperationBudget.shared.perform { try await loader(record, query, kinds, page, limit) }
            return (index, result, nil)
          } catch is CancellationError { throw CancellationError() }
          catch { return (index, nil, String(GitService.redact(error.localizedDescription).prefix(2000))) }
        }
      }
      var next = 0
      for _ in 0..<min(3, records.count) { enqueue(next); next += 1 }
      var results: [(Int, WorkspaceRepositorySearchPage?, String?)] = []
      while let result = try await group.next() {
        try Task.checkCancellation(); results.append(result)
        if next < records.count { enqueue(next); next += 1 }
      }
      var page = WorkspaceSearchPage()
      for (index, result, error) in results.sorted(by: { $0.0 < $1.0 }) {
        if let result { page.hits += result.hits; if result.hasMore { page.moreRepositories.insert(records[index].id) } }
        if let error { page.errors[records[index].id] = error }
      }
      return page
    }
  }
}
