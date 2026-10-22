import Foundation

/// A fixed merge object and its ordered parents, bound to the reviewed working tree.
public struct MergeRevertReview: Sendable {
  public let workingTree: String
  let executable: String
  public let operation: GitOperationReview
  public let commit: CommitRecord
  public let parents: [CommitRecord]
}
