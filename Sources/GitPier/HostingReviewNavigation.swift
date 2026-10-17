import AppKit
import GitPierCore

extension AppStore {
  /// Explicit inbox navigation reuses an existing binding. It never creates a binding,
  /// scans/fetches Git or guesses repository ownership from an account's login.
  func openHostingReviewInboxItem(_ item: HostingReviewDashboardItem) {
    guard let account = hosting.account(item.accountID), account.instance == item.instance,
      let binding = hosting.metadata.bindings.first(where: { $0.accountID == item.accountID && $0.repository == item.repository && models[$0.repositoryID] != nil }) else {
      NSWorkspace.shared.open(item.webURL); return
    }
    hostingReviewDestination = item; selectedID = binding.repositoryID; showDashboard = false
    models[binding.repositoryID]?.setPage("hosting")
  }
}
