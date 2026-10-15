import Foundation

/// One local Dashboard projection. Never queries Git or changes selection.
public struct WorkspaceListing: Sendable {
  public struct Row: Identifiable, Sendable {
    public var id: UUID { entry.record.id }
    public let entry: WorkspaceEntry
    public let familyKey: String?
    public let relatedCount: Int
    public let isChild: Bool
    public let canCollapse: Bool
  }
  public let scoped: [WorkspaceEntry]
  public let summary: WorkspaceSummary
  public let matching: [WorkspaceEntry]
  public let rows: [Row]
  public var matchingIDs: Set<UUID> { Set(matching.map { $0.record.id }) }
  public var hiddenCount: Int { matching.count - rows.count }
  public var scanning: Int { scoped.filter { $0.state == .collecting || $0.state == .queued }.count }

  public init(records: [RepositoryRecord], entries: [UUID: WorkspaceEntry], organization: String? = nil,
              search: String = "", filters: Set<WorkspaceFilter> = [], sort: String = "manual",
              collapsed: Set<String> = []) {
    scoped = records.filter { organization == nil || $0.group == organization }.map { record in
      var entry = entries[record.id] ?? WorkspaceEntry(record: record)
      entry.record = record
      return entry
    }
    summary = WorkspaceSummary(scoped)
    let matches = scoped.filter { entry in
      let record = entry.record
      let metadata = [record.name, record.path, record.group, entry.usable?.branch ?? ""]
        + (entry.usable?.remoteNames ?? [])
      return (search.isEmpty || metadata.contains { $0.localizedCaseInsensitiveContains(search) })
        && filters.allSatisfy { $0.matches(entry) }
    }
    matching = matches.enumerated().sorted { lhs, rhs in
      switch sort {
      case "name", "path":
        let a = sort == "name" ? lhs.element.record.name : lhs.element.record.path
        let b = sort == "name" ? rhs.element.record.name : rhs.element.record.path
        let order = a.localizedStandardCompare(b)
        return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
      case "recent":
        let a = lhs.element.record.lastOpened, b = rhs.element.record.lastOpened
        return a == b ? lhs.offset < rhs.offset : a > b
      default: return lhs.offset < rhs.offset
      }
    }.map(\.element)
    let families = Dictionary(grouping: scoped.filter { $0.usable != nil }) { $0.usable!.commonDirectory }
    let matchedFamilies = Dictionary(grouping: matching.filter { $0.usable != nil }) { $0.usable!.commonDirectory }
    rows = matching.compactMap { entry in
      let key = entry.usable?.commonDirectory
      let family = key.flatMap { families[$0] } ?? []
      let matched = key.flatMap { matchedFamilies[$0] } ?? []
      let leader = (matched.first { $0.usable?.isWorktree == false } ?? matched.first)?.record.id
      let child = matched.count > 1 && leader != entry.record.id
      if child, let key, collapsed.contains(key) { return nil }
      return Row(entry: entry, familyKey: key, relatedCount: family.count, isChild: child,
        canCollapse: matched.count > 1 && leader == entry.record.id)
    }
  }
}
