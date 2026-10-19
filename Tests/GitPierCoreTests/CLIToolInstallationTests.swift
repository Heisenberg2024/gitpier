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
  func testReceiptReplacementAfterIdentityCheckPreservesReplacementAndRestoresTool() throws {
    try install()
    let receipt = installation.directory.appendingPathComponent(CLIToolInstallation.receiptName)
    let replacement = Data("another installer's receipt".utf8)
    let originalTool = try Data(contentsOf: installation.executable)
    installation.fileBoundary = { event in
      if case .takingCustody(let name) = event, name == CLIToolInstallation.receiptName {
        try replacement.write(to: receipt, options: .atomic)
      }
    }
    XCTAssertThrowsError(try installation.uninstall())
    XCTAssertEqual(try Data(contentsOf: receipt), replacement)
    XCTAssertEqual(try Data(contentsOf: installation.executable), originalTool)
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: installation.directory.path).contains { $0.hasPrefix(".gitpier-removing-") })
  }
  func testNewInstallationAtPublicNamesDuringDeletionIsPreserved() throws {
    try install()
    let receipt = installation.directory.appendingPathComponent(CLIToolInstallation.receiptName)
    let tool = installation.executable
    let newReceipt = Data("new receipt after custody".utf8), newTool = Data("new launcher after custody".utf8)
    installation.fileBoundary = { event in
      if case .deletingOwnedFile(let name) = event, name == CLIToolInstallation.receiptName {
        try newReceipt.write(to: receipt, options: .withoutOverwriting)
        try newTool.write(to: tool, options: .withoutOverwriting)
      }
    }
    try installation.uninstall()
    XCTAssertEqual(try Data(contentsOf: receipt), newReceipt)
    XCTAssertEqual(try Data(contentsOf: tool), newTool)
  }
  func testFailedInstallCleanupPreservesFilesCreatedBeforeOwnedDeletion() throws {
    let receipt = installation.directory.appendingPathComponent(CLIToolInstallation.receiptName)
    let tool = installation.executable
    let newReceipt = Data("replacement receipt".utf8), newTool = Data("replacement launcher".utf8)
    installation.fileBoundary = { event in
      switch event {
      case .filesReserved: throw CocoaError(.fileWriteUnknown)
      case .deletingOwnedFile(let name):
        if name == CLIToolInstallation.receiptName { try newReceipt.write(to: receipt, options: .withoutOverwriting) }
        if name == "gitpier" { try newTool.write(to: tool, options: .withoutOverwriting) }
      default: break
      }
    }
    XCTAssertThrowsError(try install())
    XCTAssertEqual(try Data(contentsOf: receipt), newReceipt)
    XCTAssertEqual(try Data(contentsOf: tool), newTool)
  }
  func testReceiptSymlinkReplacementAtCustodyBoundaryPreservesLinkAndTarget() throws {
    try install()
    let receipt = installation.directory.appendingPathComponent(CLIToolInstallation.receiptName)
    let target = root.appendingPathComponent("other-receipt")
    let original = Data("foreign target".utf8)
    try original.write(to: target)
    installation.fileBoundary = { event in
      if case .takingCustody(let name) = event, name == CLIToolInstallation.receiptName {
        try FileManager.default.removeItem(at: receipt)
        try FileManager.default.createSymbolicLink(at: receipt, withDestinationURL: target)
      }
    }
    XCTAssertThrowsError(try installation.uninstall())
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: receipt.path), target.path)
    XCTAssertEqual(try Data(contentsOf: target), original)
    XCTAssertTrue(FileManager.default.fileExists(atPath: installation.executable.path))
  }
  func testRestorationNeverOverwritesAConcurrentLauncherAndRetainsOwnedFile() throws {
    try install()
    let directory = installation.directory
    let receipt = directory.appendingPathComponent(CLIToolInstallation.receiptName)
    let tool = installation.executable
    let original = try Data(contentsOf: tool), replacement = Data("concurrent launcher".utf8)
    installation.fileBoundary = { event in
      if case .takingCustody(let name) = event, name == CLIToolInstallation.receiptName {
        try Data("concurrent receipt".utf8).write(to: receipt, options: .atomic)
        try replacement.write(to: tool, options: .withoutOverwriting)
      }
    }
    XCTAssertThrowsError(try installation.uninstall())
    XCTAssertEqual(try Data(contentsOf: tool), replacement)
    let quarantine = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".gitpier-removing-") })
    XCTAssertEqual(try Data(contentsOf: quarantine.appendingPathComponent("gitpier")), original)
    let mode = try FileManager.default.attributesOfItem(atPath: quarantine.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(mode?.intValue, 0o700)
  }
}
