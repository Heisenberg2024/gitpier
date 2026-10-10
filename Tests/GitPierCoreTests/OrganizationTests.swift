import XCTest

@testable import GitPierCore

final class OrganizationTests: XCTestCase {
  func testFirstReleaseConfigurationMigratesGroupsAndManualRefresh() throws {
    var old = WorkspaceConfiguration()
    var a = RepositoryRecord(path: "/project/client")
    a.group = "Project A"
    a.draft = "draft A"
    a.credentialID = UUID()
    var b = RepositoryRecord(path: "/project/server")
    b.group = "Project A"
    b.draft = "draft B"
    old.repositories = [a, b]
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
    json["organizations"] = nil
    json["version"] = 1
    var settings = json["settings"] as! [String: Any]
    settings["refreshPolicyVersion"] = nil
    settings["automaticRefresh"] = true
    json["settings"] = settings
    let migrated = try JSONDecoder().decode(
      WorkspaceConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertEqual(migrated.organizations.map(\.name), ["Project A"])
    XCTAssertEqual(migrated.repositories, [a, b])
    XCTAssertFalse(migrated.settings.automaticRefresh)
    XCTAssertEqual(migrated.version, 2)
  }
  func testRenameMoveAndRemovePreserveRepositoryOwnershipAndDrafts() throws {
    var config = WorkspaceConfiguration()
    var repository = RepositoryRecord(path: "/real/repository")
    repository.draft = "keep this"
    repository.credentialID = UUID()
    repository.favorite = true
    config.repositories = [repository]
    let first = try config.createOrganization("First")
    let second = try config.createOrganization("Second")
    try config.moveRepositories([repository.id], to: first.id)
    try config.renameOrganization(first.id, to: "Renamed")
    XCTAssertEqual(config.repositories[0].group, "Renamed")
    XCTAssertEqual(config.organizations[0].id, first.id)
    try config.moveRepositories([repository.id], to: second.id)
    config.removeOrganization(second.id)
    XCTAssertEqual(config.repositories[0], repository)
    XCTAssertEqual(config.repositories.count, 1)
  }
  func testEmptyOrganizationsPersistAndDuplicateNamesAreRejected() throws {
    var config = WorkspaceConfiguration()
    let empty = try config.createOrganization("  Shared Project  ")
    XCTAssertThrowsError(try config.createOrganization("shared project"))
    XCTAssertThrowsError(try config.createOrganization("\n"))
    let restored = try JSONDecoder().decode(
      WorkspaceConfiguration.self, from: JSONEncoder().encode(config))
    XCTAssertEqual(restored.organizations, [empty])
    XCTAssertTrue(restored.repositories.isEmpty)
  }
  func testNewRefreshPreferenceAndRepositoryFontRoundTrip() throws {
    var settings = AppSettings()
    settings.automaticRefresh = true
    settings.repositoryFont = "Menlo"
    settings.repositoryFontSize = 16
    let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertTrue(restored.automaticRefresh)
    XCTAssertEqual(restored.repositoryFont, "Menlo")
    XCTAssertEqual(restored.repositoryFontSize, 16)
  }
}
