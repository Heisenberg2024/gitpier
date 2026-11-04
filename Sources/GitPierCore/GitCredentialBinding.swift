import Foundation

/// Resolved Git transport selection. Hosting API accounts are deliberately absent.
public struct GitCredentialBinding: Equatable, Sendable {
  public enum Source: Equatable, Sendable { case system, workspaceDefault, repository }
  public let source: Source
  public let profileID: UUID?
  public let profile: CredentialProfile?
  public var missingProfile: Bool { profileID != nil && profile == nil }

  public init(record: RepositoryRecord, settings: AppSettings, profiles: [CredentialProfile]) {
    if let id = record.credentialID {
      source = .repository; profileID = id
    } else if record.useDefaultCredential {
      source = .workspaceDefault; profileID = settings.defaultCredentialID
    } else {
      source = .system; profileID = nil
    }
    let requestedID = profileID
    profile = profiles.first { $0.id == requestedID }
  }

  public func context(executable: String, configurationPath: String) throws -> AuthenticationContext {
    guard !missingProfile else { throw AuthenticationFailure(.configurationInvalid) }
    return try AuthenticationContext.make(profile: profile, executable: executable, configurationPath: configurationPath)
  }
}
