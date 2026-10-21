import Foundation

/// A private write-ahead record, never a receipt inferred from a path or marker.
public struct TaskWorkspaceCreation: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let name: String
  public let savedDescription: String?
  public let repositoryID: UUID
  public let repositoryRoot: String
  public let path: String
  public let branch: String
  public let baseCommit: String
  public let repositoryIdentity: TaskDirectoryIdentity
  public let commonDirectory: String
  public let commonIdentity: TaskDirectoryIdentity
  public let createdAt: Date
  public var workspace: TaskWorkspace?
  func validate() throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 240,
      !name.utf8.contains(0), savedDescription.map({ $0.utf8.count <= 4096 && !$0.utf8.contains(0) }) ?? true,
      [repositoryRoot, path, commonDirectory].allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.utf8.contains(0) && URL(fileURLWithPath: $0).standardizedFileURL.path == $0 }),
      branch.hasPrefix("refs/heads/"), branch.utf8.count <= 1024, !branch.utf8.contains(0),
      [40, 64].contains(baseCommit.count), baseCommit.allSatisfy(\.isHexDigit), createdAt.timeIntervalSince1970.isFinite
    else { throw TaskWorkspaceError.invalid }
    if let workspace {
      try workspace.validate()
      guard workspace.id == id, workspace.name == name, workspace.savedDescription == savedDescription,
        workspace.repositoryID == repositoryID, workspace.repositoryRoot == repositoryRoot,
        workspace.path == path, workspace.branch == branch, workspace.baseCommit == baseCommit,
        workspace.commonDirectory == commonDirectory, workspace.binding.commonIdentity == commonIdentity,
        workspace.binding.managed, workspace.agent == nil, workspace.review == nil, !workspace.archived,
        workspace.createdAt == createdAt else { throw TaskWorkspaceError.invalid }
    }
  }
}

public struct WorktreeCreationFailure: Error, LocalizedError, Sendable {
  public enum Stage: Sendable { case gitCommand, ownershipMarker, taskRegistration }
  public let path: String
  public let stage: Stage
  public let reason: String
  public init(path: String, stage: Stage, reason: String) {
    self.path = path; self.stage = stage; self.reason = reason
  }
  public var errorDescription: String? {
    let outcome = stage == .gitCommand ? "Git worktree creation did not finish; a directory or branch may remain." : "The worktree was created, but registration did not finish."
    return outcome + "\n" + path + "\n" + reason + "\nOpen Worktrees to inspect it. Resume a saved creation record when available, or associate the existing worktree without granting ownership. Files and branches have been preserved."
  }
}
