import XCTest

@testable import GitPierCore

final class LayoutMigrationTests: XCTestCase {
  func testOldLayoutPreservesExistingSizesAndDefaultsHistoryPanes() throws {
    let old = Data(
      #"{"changesWidth":351,"messageHeight":207,"terminalHeight":181,"terminalVisible":true,"terminalMaximized":false}"#
        .utf8)
    let layout = try JSONDecoder().decode(PanelLayout.self, from: old)
    XCTAssertEqual(layout.changesWidth, 351)
    XCTAssertEqual(layout.messageHeight, 207)
    XCTAssertEqual(layout.terminalHeight, 181)
    XCTAssertTrue(layout.terminalVisible)
    XCTAssertEqual(layout.historyDetailHeight, 320)
    XCTAssertEqual(layout.historyFilesWidth, 280)
  }

  func testRepositoryHistoryLayoutsAndCustomEditorRoundTripIndependently() throws {
    var configuration = WorkspaceConfiguration()
    var first = RepositoryRecord(path: "/fixture/first")
    first.layout.historyDetailHeight = 415
    first.layout.historyFilesWidth = 305
    let second = RepositoryRecord(path: "/fixture/second")
    configuration.repositories = [first, second]
    configuration.settings.editorPath = "/fixture/Custom Editor.app"
    configuration.settings.customEditorPaths = [
      "/fixture/Custom Editor.app", "/fixture/Second.app",
    ]
    let restored = try JSONDecoder().decode(
      WorkspaceConfiguration.self,
      from: JSONEncoder().encode(configuration))
    XCTAssertEqual(restored.repositories[0].layout, first.layout)
    XCTAssertEqual(restored.repositories[1].layout, second.layout)
    XCTAssertEqual(restored.settings.editorPath, "/fixture/Custom Editor.app")
    XCTAssertEqual(restored.settings.customEditorPaths, configuration.settings.customEditorPaths)
    let oldSettings = try JSONDecoder().decode(
      AppSettings.self,
      from: Data(#"{"editorPath":"/fixture/Existing.app"}"#.utf8))
    XCTAssertEqual(oldSettings.editorPath, "/fixture/Existing.app")
    XCTAssertTrue(oldSettings.customEditorPaths.isEmpty)
  }
  func testLegacyRepositoryPageIsIgnoredAndNoLongerSaved() throws {
    let record = RepositoryRecord(path: "/fixture/repository")
    var legacy =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
    legacy["page"] = "history"
    let restored = try JSONDecoder().decode(
      RepositoryRecord.self,
      from: JSONSerialization.data(withJSONObject: legacy))
    XCTAssertEqual(restored, record)
    let saved =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as! [String: Any]
    XCTAssertNil(saved["page"])
  }
}
