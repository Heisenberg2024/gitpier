import GitPierCore
import SwiftUI

/// All repository lists share one persisted order and accept only known repository drag IDs.
struct RepositoryReordering: ViewModifier {
  @EnvironmentObject var store: AppStore
  let record: RepositoryRecord
  var reordered: () -> Void = {}
  func body(content: Content) -> some View {
    content
      .draggable("gitpier-repository:" + record.id.uuidString)
      .dropDestination(for: String.self) { items, _ in
        guard items.count == 1, let item = items.first,
          item.hasPrefix("gitpier-repository:"),
          let id = UUID(uuidString: String(item.dropFirst("gitpier-repository:".count))),
          store.reorderRepository(id, relativeTo: record.id)
        else { return false }
        reordered()
        return true
      }
  }
}

extension View {
  func repositoryReordering(_ record: RepositoryRecord, reordered: @escaping () -> Void = {})
    -> some View
  {
    modifier(RepositoryReordering(record: record, reordered: reordered))
  }
}
