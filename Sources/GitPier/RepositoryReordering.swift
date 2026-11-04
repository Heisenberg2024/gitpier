import GitPierCore
import SwiftUI

/// All repository lists share one persisted order and accept only known repository drag IDs.
struct RepositoryReordering: ViewModifier {
  @EnvironmentObject var store: AppStore
  let record: RepositoryRecord
  var reordered: () -> Void = {}
  func body(content: Content) -> some View {
    content
      .repositoryDragSource(record)
      .repositoryDropTarget { id in
        guard store.reorderRepository(id, relativeTo: record.id) else { return false }
        reordered()
        return true
      }
  }
}

private let repositoryDragPrefix = "gitpier-repository:"

private func repositoryDraggedID(_ items: [String]) -> UUID? {
  guard items.count == 1, let item = items.first, item.hasPrefix(repositoryDragPrefix) else { return nil }
  return UUID(uuidString: String(item.dropFirst(repositoryDragPrefix.count)))
}

extension DynamicViewContent {
  func repositoryInsertionTarget(_ receive: @escaping (UUID, Int) -> Void) -> some DynamicViewContent {
    dropDestination(for: String.self) { (items: [String], offset: Int) in
      guard let id = repositoryDraggedID(items) else { return }
      receive(id, offset)
    }
  }
}

extension View {
  func repositoryDragSource(_ record: RepositoryRecord) -> some View {
    draggable(repositoryDragPrefix + record.id.uuidString)
  }
  func repositoryDropTarget(_ receive: @escaping (UUID) -> Bool) -> some View {
    dropDestination(for: String.self) { items, _ in
      guard let id = repositoryDraggedID(items) else { return false }
      return receive(id)
    }
  }
  func repositoryReordering(_ record: RepositoryRecord, reordered: @escaping () -> Void = {})
    -> some View
  {
    modifier(RepositoryReordering(record: record, reordered: reordered))
  }
}
