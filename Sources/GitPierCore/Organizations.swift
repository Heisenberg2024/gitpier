import Foundation

public struct RepositoryOrganization: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var name: String
  public init(id: UUID = UUID(), name: String) {
    self.id = id
    self.name = name
  }
}

extension WorkspaceConfiguration {
  /// Registers existing free-text groups without changing repository identity, paths or drafts.
  public mutating func reconcileOrganizations() {
    for repository in repositories where !repository.group.isEmpty {
      if !organizations.contains(where: { $0.name == repository.group }) {
        organizations.append(RepositoryOrganization(name: repository.group))
      }
    }
  }
  @discardableResult public mutating func createOrganization(_ name: String) throws
    -> RepositoryOrganization
  {
    let clean = try validatedOrganizationName(name)
    let organization = RepositoryOrganization(name: clean)
    organizations.append(organization)
    return organization
  }
  public mutating func renameOrganization(_ id: UUID, to name: String) throws {
    guard let index = organizations.firstIndex(where: { $0.id == id }) else {
      throw GitPierError.invalidInput("Organization no longer exists.")
    }
    let clean = try validatedOrganizationName(name, excluding: id)
    let old = organizations[index].name
    organizations[index].name = clean
    for i in repositories.indices where repositories[i].group == old {
      repositories[i].group = clean
    }
  }
  public mutating func moveRepositories(_ ids: Set<UUID>, to organizationID: UUID?) throws {
    let name: String
    if let organizationID {
      guard let organization = organizations.first(where: { $0.id == organizationID }) else {
        throw GitPierError.invalidInput("Organization no longer exists.")
      }
      name = organization.name
    } else {
      name = ""
    }
    for i in repositories.indices where ids.contains(repositories[i].id) {
      repositories[i].group = name
    }
  }
  public mutating func removeOrganization(_ id: UUID) {
    guard let organization = organizations.first(where: { $0.id == id }) else { return }
    for i in repositories.indices where repositories[i].group == organization.name {
      repositories[i].group = ""
    }
    organizations.removeAll { $0.id == id }
  }
  private func validatedOrganizationName(_ name: String, excluding id: UUID? = nil) throws -> String
  {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, !clean.contains("\n"), !clean.contains("\r"), !clean.utf8.contains(0)
    else { throw GitPierError.invalidInput("Enter a non-empty organization name on one line.") }
    guard
      !organizations.contains(where: {
        $0.id != id && $0.name.localizedCaseInsensitiveCompare(clean) == .orderedSame
      })
    else { throw GitPierError.invalidInput("An organization with this name already exists.") }
    return clean
  }
}
