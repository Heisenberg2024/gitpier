import Foundation

/// A provider user, identified by the server ID even if a login is later renamed.
/// Team review requests and GitLab approvers are separate concepts and are not selected here.
public struct HostingReviewer: Identifiable, Hashable, Sendable {
  public let id: String
  public let login: String
  public let name: String
  public init(id: String, login: String, name: String = "") { self.id = id; self.login = login; self.name = name }
}

/// Immutable selection shown by the shared remote-write confirmation. The original
/// users are displayed for clarity; execution merges against a fresh server list.
public struct HostingReviewerSelection: Sendable, Equatable {
  public let target: HostingReviewTarget
  public let revision: HostingReviewRevision
  public let reviewers: [HostingReviewer]
  public let existingReviewers: [HostingReviewer]
  public init(context: HostingReviewContext, reviewers: [HostingReviewer], existingReviewers: [HostingReviewer] = []) {
    target = context.target; revision = context.revision; self.reviewers = reviewers; self.existingReviewers = existingReviewers
  }
  public func validate(context: HostingReviewContext) throws {
    guard target == context.target else { throw HostingReviewError.targetChanged }
    guard revision == context.revision else { throw HostingReviewError.revisionChanged }
    guard context.capabilities.contains(.requestReviewers) else { throw HostingReviewError.permissionRequired }
    guard !reviewers.isEmpty, reviewers.count <= 15, Set(reviewers.map(\.id)).count == reviewers.count,
      Set(reviewers.map { $0.login.lowercased() }).count == reviewers.count,
      existingReviewers.count <= 1000, Set(existingReviewers.map(\.id)).count == existingReviewers.count else { throw HostingReviewError.invalidBody }
    for user in reviewers + existingReviewers {
      guard let id = Int64(user.id), id > 0, String(id) == user.id, !user.login.isEmpty, user.login.utf8.count <= 256,
        user.login.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && $0.value >= 33 }),
        !user.login.contains("/"), !user.login.contains("\\"), !user.login.contains("\0") else { throw HostingReviewError.targetChanged }
    }
    guard !reviewers.contains(where: { $0.id == context.authorID }) else { throw HostingReviewError.selfReview }
  }
}
