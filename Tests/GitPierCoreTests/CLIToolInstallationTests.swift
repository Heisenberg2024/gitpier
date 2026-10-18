import XCTest
@testable import GitPierCore

final class CLIToolInstallationTests: XCTestCase {
  var root: URL!, app: URL!, source: URL!, installation: CLIToolInstallation!
  override func setUpWithError() throws {
    root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("GitPier-cli-" + UUID().uuidString)
    app = root.appendingPathComponent("GitPier.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": "com.example.gitpier.fixture", "CFBundleExecutable": "GitPier", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
    source = app.appendingPathComponent("Contents/MacOS/GitPier")
    try Data("fixture launcher bytes".utf8).write(to: source)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
    installation = CLIToolInstallation(directory: root.appendingPathComponent("bin"))
  }
  override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
  func install() throws { try installation.install(source: source, application: app, bundleIdentifier: "com.example.gitpier.fixture") }
  func testInstallVerifyUninstallAndPermissions() throws {
    try install(); let receipt = try installation.receipt()
    XCTAssertEqual(try receipt.application().path, app.path)
    let mode = try FileManager.default.attributesOfItem(atPath: installation.executable.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(mode?.intValue, 0o700)
    try installation.uninstall(); XCTAssertFalse(FileManager.default.fileExists(atPath: installation.executable.path))
  }
  func testNeverOverwritesAnExistingUserScript() throws {
    try FileManager.default.createDirectory(at: installation.directory, withIntermediateDirectories: true)
    let original = Data("user script".utf8); try original.write(to: installation.executable)
    XCTAssertThrowsError(try install()); XCTAssertEqual(try Data(contentsOf: installation.executable), original)
  }
  func testNeverOverwritesAnExistingOwnedInstallation() throws {
    try install(); XCTAssertThrowsError(try install()); XCTAssertNoThrow(try installation.receipt())
  }
  func testSymlinkTargetIsPreserved() throws {
    try FileManager.default.createDirectory(at: installation.directory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: installation.executable, withDestinationURL: source)
    let before = try Data(contentsOf: source)
    XCTAssertThrowsError(try install()); XCTAssertThrowsError(try installation.uninstall())
    XCTAssertEqual(try Data(contentsOf: source), before)
  }
  func testSymlinkParentIsRefused() throws {
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: installation.directory, withDestinationURL: outside)
    XCTAssertThrowsError(try install()); XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }
  func testTamperedLauncherCannotBeUninstalled() throws {
    try install(); try Data("another user's file".utf8).write(to: installation.executable)
    XCTAssertThrowsError(try installation.uninstall()); XCTAssertTrue(FileManager.default.fileExists(atPath: installation.executable.path))
  }
  func testReceiptSymlinkCannotClaimOwnership() throws {
    try install(); let receipt = installation.directory.appendingPathComponent(CLIToolInstallation.receiptName)
    let other = root.appendingPathComponent("receipt")
    try FileManager.default.moveItem(at: receipt, to: other)
    try FileManager.default.createSymbolicLink(at: receipt, withDestinationURL: other)
    XCTAssertThrowsError(try installation.receipt()); XCTAssertThrowsError(try installation.uninstall())
  }
  func testHardLinkedLauncherIsRefused() throws {
    try install(); try FileManager.default.linkItem(at: installation.executable, to: root.appendingPathComponent("other"))
    XCTAssertThrowsError(try installation.uninstall())
  }
  func testWorldWritableDirectoryIsRefused() throws {
    try FileManager.default.createDirectory(at: installation.directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: installation.directory.path)
    XCTAssertThrowsError(try install())
  }
  func testMissingLauncherKeepsReceiptForManualRepair() throws {
    try install(); try FileManager.default.removeItem(at: installation.executable)
    XCTAssertThrowsError(try installation.uninstall()); XCTAssertThrowsError(try install())
    XCTAssertTrue(FileManager.default.fileExists(atPath: installation.directory.appendingPathComponent(CLIToolInstallation.receiptName).path))
  }
  func testSamePathAppReplacementKeepsSelectedApp() throws {
    try install(); let receipt = try installation.receipt()
    try Data("updated app binary".utf8).write(to: source)
    XCTAssertEqual(try receipt.application().path, app.path)
  }
  func testMovedAppKeepsBookmarkSelection() throws {
    try install(); let receipt = try installation.receipt()
    let moved = root.appendingPathComponent("Moved GitPier.app")
    try FileManager.default.moveItem(at: app, to: moved)
    XCTAssertEqual(try receipt.application().path, moved.path)
  }
  func testUnknownReceiptVersionPreservesLauncher() throws {
    try install()
    let receipt = installation.directory.appendingPathComponent(CLIToolInstallation.receiptName)
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
    json["version"] = 2
    try JSONSerialization.data(withJSONObject: json).write(to: receipt)
    XCTAssertThrowsError(try installation.receipt()); XCTAssertThrowsError(try installation.uninstall())
    XCTAssertTrue(FileManager.default.fileExists(atPath: installation.executable.path))
  }
  func testFullAppReplacementPrefersNewInstallationOverMovedOldBookmark() throws {
    try install(); let receipt = try installation.receipt()
    let old = root.appendingPathComponent("old GitPier.app")
    try FileManager.default.moveItem(at: app, to: old)
    try FileManager.default.copyItem(at: old, to: app)
    XCTAssertEqual(try receipt.application().path, app.path)
  }
  func testFreshInstallerInstanceReopensAnExistingCanonicalDirectory() throws {
    try install()
    let reopened = CLIToolInstallation(directory: installation.directory)
    XCTAssertEqual(try reopened.receipt().application().path, app.path)
    try reopened.uninstall()
    XCTAssertFalse(FileManager.default.fileExists(atPath: installation.executable.path))
  }
  func testWrongAppIdentityIsRejected() throws {
    XCTAssertThrowsError(try installation.install(source: source, application: app, bundleIdentifier: "com.another.app"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: installation.executable.path))
  }
}
