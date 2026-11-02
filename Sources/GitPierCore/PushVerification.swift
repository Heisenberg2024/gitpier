import Foundation

/// Session-only identity for one ordinary branch Push. No URL, credentials,
/// command text or mutable Git snapshot is retained in operation history.
public struct PushCheckpoint: Equatable, Sendable {
  public let gitExecutable: String
  public let workingTree: String
  public let gitDirectory: String
  public let commonDirectory: String
  public let localReference: String
  public let localHead: String
  public let remote: String
  public let remoteReference: String
  let directoryIdentities: [TaskDirectoryIdentity]
  let configurationIdentity: Data
  let destinationIdentity: String
  let explicitTarget: Bool
}

/// Constructed by GitService after a bounded read-only query and identity
/// revalidation. A different or absent tip never establishes Push failure.
public struct PushVerificationObservation: Equatable, Sendable {
  public let checkpoint: PushCheckpoint
  public let remoteHead: String?
  public let checkedAt: Date
  public var confirmed: Bool { remoteHead == checkpoint.localHead }
}
