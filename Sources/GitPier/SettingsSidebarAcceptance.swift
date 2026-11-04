import AppKit
import GitPierCore
import SwiftUI

@MainActor extension UIAcceptance {
  static func verifySettingsSidebars(store: AppStore, root: URL, window: NSWindow,
    output: URL) async throws {
    guard root.deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui.") else {
      throw GitPierError.invalidInput("Settings sidebar acceptance requires a disposable repository")
    }
    var settings = store.settings
    settings.automaticFetch = false
    settings.automaticRefresh = false
    settings.appearance = .light
    settings.language = .english
    store.updateSettings(settings)
    let organization = try store.createOrganization("Alpha")
    var grouped = RepositoryRecord(path: root.appendingPathComponent("grouped-fixture").path,
      name: "Grouped Fixture")
    grouped.group = organization.name
    store.configuration.repositories.append(grouped)
    store.configuration.credentials = (1...40).map {
      CredentialProfile(name: String(format: "Account %02d", $0), host: "example.invalid",
        username: "fixture-\($0)")
    }
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    host.sizingOptions = []
    host.autoresizingMask = [.width, .height]
    window.contentView = host
    window.toolbar = nil
    window.setContentSize(NSSize(width: 780, height: 600))
    window.center()
    NSApp.setActivationPolicy(.regular)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    var checks: [String] = []
    func require(_ condition: Bool, _ message: String) throws {
      guard condition else { throw GitPierError.invalidInput("Settings sidebars: " + message) }
      checks.append(message)
      try checks.joined(separator: "\n").write(
        to: output.appendingPathComponent("settings-sidebar-results.txt"), atomically: true,
        encoding: .utf8)
    }
    func tables() -> [NSTableView] {
      descendants(host).compactMap { $0 as? NSTableView }
        .filter { !$0.isHiddenOrHasHiddenAncestor }
        .sorted { $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX }
    }
    func click(_ row: Int, in table: NSTableView) async throws {
      table.scrollRowToVisible(row)
      try await settle()
      let rect = table.rect(ofRow: row)
      let point = table.convert(NSPoint(x: rect.minX + 50, y: rect.midY), to: nil)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
          throw GitPierError.invalidInput("Cannot construct settings row click")
        }
        NSApp.postEvent(event, atStart: false)
      }
      try await settle()
    }
    func show(_ view: some View, name: String) async throws {
      host.rootView = AnyView(view.id(name).environmentObject(store)
        .modifier(AppAppearance(store: store)))
      try await settle()
      try await captureHostingWindow(window, to: output.appendingPathComponent(name + ".png"))
      let diagnostic = descendants(host).compactMap { view -> String? in
        if let split = view as? NSSplitView {
          return "split frame=\(split.convert(split.bounds, to: host)) divider=\(split.dividerThickness)"
        }
        if let scroll = view as? NSScrollView {
          return "scroll frame=\(scroll.convert(scroll.bounds, to: host)) border=\(scroll.borderType.rawValue) native=\(scroll.hasVerticalScroller)/\(scroll.hasHorizontalScroller)"
        }
        return nil
      }.joined(separator: "\n")
      try diagnostic.write(to: output.appendingPathComponent(name + "-geometry.txt"),
        atomically: true, encoding: .utf8)
      if let scroll = tables().first?.enclosingScrollView {
        let frame = scroll.convert(scroll.bounds, to: nil)
        let geometry: [String: Double] = ["x": frame.minX,
          "y": window.frame.height - frame.maxY, "width": frame.width,
          "height": frame.height, "windowWidth": window.frame.width]
        try JSONSerialization.data(withJSONObject: geometry, options: [.sortedKeys])
          .write(to: output.appendingPathComponent(name + "-sidebar.json"))
      }
    }
    try await show(CredentialsView(), name: "credentials-before-selection")
    try await show(OrganizationsView(), name: "organizations-initial")
    try require(tables().count == 2 && tables()[1].numberOfRows == 1,
      "Opening Organizations shows the ungrouped repository")
    try await click(1, in: tables()[0])
    try require(tables()[0].selectedRow == 1 && tables()[1].numberOfRows == 1,
      "Clicking Alpha selects the organization and its repository")
    try await click(0, in: tables()[0])
    try await captureHostingWindow(window, to: output.appendingPathComponent("organizations-return-ungrouped.png"))
    try require(tables()[0].selectedRow == 0,
      "Clicking Ungrouped after another organization selects the Ungrouped row")
    let labels = assistantElements(tables()[1]).map {
      assistantString($0, "accessibilityLabel") + assistantString($0, "accessibilityValue")
    }.joined(separator: "\n")
    try require(labels.contains("Acceptance Fixture") && !labels.contains("Grouped Fixture"),
      "Returning to Ungrouped restores its repository list")
    try await click(1, in: tables()[0])
    try await click(0, in: tables()[0])
    try require(tables()[0].selectedRow == 0,
      "Repeated organization and Ungrouped switching remains clickable")

    for index in 1...35 { _ = try store.createOrganization(String(format: "Group %02d", index)) }
    let matrix: [(AppLanguage, AppearanceMode, NSSize)] = [
      (.english, .light, NSSize(width: 1060, height: 720)),
      (.simplifiedChinese, .light, NSSize(width: 780, height: 600)),
      (.english, .dark, NSSize(width: 780, height: 600)),
      (.simplifiedChinese, .dark, NSSize(width: 1060, height: 720)),
    ]
    for (language, appearance, size) in matrix {
      settings.language = language
      settings.appearance = appearance
      store.updateSettings(settings)
      window.setContentSize(size)
      for (tab, page) in [(5, "organizations"), (6, "credentials")] {
        let name = "\(page)-\(language.rawValue)-\(appearance.rawValue)"
        try await show(SettingsView(initialTab: tab), name: name)
        guard let sidebar = tables().first, let scroll = sidebar.enclosingScrollView,
          let overlay = scroll.subviews.compactMap({ $0 as? OverlayScrollbars }).first else {
          throw GitPierError.invalidInput("Missing native settings sidebar or shared scrollbar")
        }
        try require(!scroll.hasVerticalScroller && !scroll.hasHorizontalScroller
          && scroll.subviews.filter({ $0 is OverlayScrollbars }).count == 1,
          "\(name): one shared overlay and no native scrollbar gutter")
        try require(descendants(host).allSatisfy { !($0 is NSSplitView) },
          "\(name): no native split divider beside or below the rounded sidebar")
        try await click(sidebar.numberOfRows - 1, in: sidebar)
        try require(sidebar.selectedRow == sidebar.numberOfRows - 1,
          "\(name): the last sidebar row remains clickable")
        if tab == 6 {
          let text = assistantElements(host).map {
            assistantString($0, "accessibilityLabel") + assistantString($0, "accessibilityValue")
          }.joined(separator: "\n")
          try require(text.contains("Account 40") && text.contains("fixture-40"),
            "\(name): selecting an account updates its details")
        }
        sidebar.scrollRowToVisible(0)
        try await settle()
        try dragThumb(overlay.verticalThumb, in: window)
        try await settle()
        try require(sidebar.rows(in: scroll.contentView.bounds).contains(sidebar.numberOfRows - 1),
          "\(name): the shared scrollbar thumb reaches the last row")
        try await click(0, in: sidebar)
        try require(sidebar.selectedRow == 0,
          "\(name): scrolling back restores first-row hit testing")
        if tab == 5 {
          let memberTable = tables()[1]
          let text = assistantElements(memberTable).map {
            assistantString($0, "accessibilityLabel") + assistantString($0, "accessibilityValue")
          }.joined(separator: "\n")
          try require(text.contains("Acceptance Fixture"),
            "\(name): Ungrouped restores its repository after scrolling")
        }
      }
    }
    store.configuration.credentials = []
    try await show(SettingsView(initialTab: 6), name: "credentials-empty")
    try require(tables().first?.numberOfRows == 0,
      "An empty credential list retains its rounded sidebar")
  }
}
