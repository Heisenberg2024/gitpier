#if DEBUG
import AppKit
import GitPierCore
import SwiftUI

extension UIAcceptance {
  static func verifyQualityPresentation(store: AppStore, model: RepositoryModel, root: URL, output: URL) async throws {
    let git = await model.git()
    for index in 0..<4 {
      let name = "quality-history.txt"
      try Data("history \(index)\n".utf8).write(to: root.appendingPathComponent(name))
      try await git.perform(["add", "--", name])
      try await git.perform(["commit", "-m", "Quality history \(index)"])
    }
    var settings = store.settings
    settings.automaticRefresh = false; settings.completionNotifications = false
    store.updateSettings(settings); store.notice = nil
    await model.refresh()
    model.setPage("history"); await model.loadHistory(reset: true)
    let host = NSHostingView(rootView: RootView().environmentObject(store).modifier(AppAppearance(store: store)))
    host.autoresizingMask = [.width, .height]
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    window.title = "GitPier Quality · Disposable Fixture"
    NSApp.setActivationPolicy(.regular); window.center(); window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    defer { window.close() }
    let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let handled = MainActor.assumeIsolated {
        ShortcutRouter.handleKeyDown(event, store: store, window: event.window)
      }
      return handled ? nil : event
    }
    defer { if let monitor { NSEvent.removeMonitor(monitor) } }
    try await settle()
    guard accessibleButton(host, title: store.text("Clear Selection", "清除选择"), enabled: false) != nil else {
      throw GitPierError.invalidInput("History has no accessible Clear Selection control")
    }
    if ProcessInfo.processInfo.environment["GITPIER_QUALITY_KEYBOARD_ONLY"] == "1" {
      try await verifyQualityHistoryKeyboard(store: store, model: model, host: host, window: window, output: output)
      return
    }
    let identity = OperationRepositoryIdentity(workingTree: root.path, commonDirectory: root.appendingPathComponent(".git").path)
    let states = WorkflowOperationState.allCases.filter { $0 != .waitingForUser } + [.waitingForUser]
    for state in states {
      let id = UUID()
      let kind: WorkflowOperationKind = state == .failed ? .commitAndPush : state == .agentExited ? .agentSession : .push
      store.operations.begin(id: id, kind: kind,
        repositoryID: model.record.id, identity: identity, cancel: state.active ? {} : nil)
      let detail = state == .failed ? "Local commit succeeded; controlled Push failure.\n" + String(repeating: "Controlled diagnostic line with horizontal overflow " + String(repeating: "x", count: 120) + "\n", count: 24) : nil
      store.operations.update(id, state: state, localCommit: state == .failed ? model.history.first?.hash : nil, detail: detail)
    }
    var captures: [String] = []
    var assertions = 1
    for language in AppLanguage.allCases {
      for appearance in [AppearanceMode.light, .dark] {
        settings = store.settings; settings.language = language; settings.appearance = appearance
        store.updateSettings(settings); store.notice = nil
        for width in [960, 1440] {
          window.setContentSize(NSSize(width: width, height: width == 960 ? 640 : 900)); window.center()
          store.showDashboard = false; model.setPage("history")
          try await settle()
          guard let first = model.history.first,
            let checkbox = dashboardElement(host, label: store.text("Select commit", "选择提交") + " " + first.subject, role: "AXCheckBox") else {
            throw GitPierError.invalidInput("Missing real history selection checkbox")
          }
          try dashboardPress(checkbox)
          try await waitFor { accessibleButton(host, title: store.text("Clear Selection", "清除选择"), enabled: true) != nil }
          assertions += 1
          let suffix = language.rawValue + "-" + appearance.rawValue + "-" + String(width)
          let history = "history-" + suffix
          try await captureHostingWindow(window, to: output.appendingPathComponent(history + ".png")); captures.append(history)
          try pressNativeButton(host, title: store.text("Clear Selection", "清除选择"))
          try await waitFor { accessibleButton(host, title: store.text("Clear Selection", "清除选择"), enabled: false) != nil }
          assertions += 1
          for page in ["commit", "branches", "worktrees"] {
            model.setPage(page); try await settle()
            let name = page + "-" + suffix
            try await captureHostingWindow(window, to: output.appendingPathComponent(name + ".png")); captures.append(name)
          }
          if let control = descendants(host).compactMap({ $0 as? NSSegmentedControl }).first(where: { control in
            (0..<control.segmentCount).contains { control.label(forSegment: $0) == store.text("Tasks", "任务") }
          }), let index = (0..<control.segmentCount).first(where: { control.label(forSegment: $0) == store.text("Tasks", "任务") }) {
            // NSAccessibilitySegment's in-process Pick/Press both returned false
            // on the test OS. Exercise the actual native segment with mouse events.
            let width = control.bounds.width / CGFloat(control.segmentCount)
            let point = control.convert(NSPoint(x: width * (CGFloat(index) + 0.5), y: control.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
              guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw GitPierError.invalidInput("Cannot create native Task segment mouse event")
              }
              NSApp.postEvent(event, atStart: false)
            }
            try await waitFor { control.selectedSegment == index }
            try await settle()
            guard accessibleButton(host, title: store.text("New Task…", "新建任务…"), enabled: true) != nil else {
              throw GitPierError.invalidInput("Native Task segment did not display Task Workspaces")
            }
            assertions += 1
            let name = "tasks-" + suffix
            try await captureHostingWindow(window, to: output.appendingPathComponent(name + ".png")); captures.append(name)
          } else {
            try accessibilityLabels(host).write(to: output.appendingPathComponent("task-segment-accessibility.txt"), atomically: true, encoding: .utf8)
            throw GitPierError.invalidInput("Task Workspace segment is not keyboard/accessibility reachable")
          }
          store.showDashboard = true; try await settle()
          let dashboard = "dashboard-" + suffix
          try await captureHostingWindow(window, to: output.appendingPathComponent(dashboard + ".png")); captures.append(dashboard)
          store.showOperationsCenter = true
          try await waitFor { window.attachedSheet != nil }
          guard let sheet = window.attachedSheet, let content = sheet.contentView else { throw GitPierError.invalidInput("Missing Operations Center sheet") }
          try await settle()
          let indicators = descendants(content).compactMap { $0 as? NSProgressIndicator }
          guard !indicators.isEmpty, indicators.allSatisfy({ $0.accessibilityLabel() == store.text("Git operation progress", "Git 操作进度") }) else {
            throw GitPierError.invalidInput("Operation progress has missing or untranslated accessibility labels")
          }
          guard accessibleButton(content, title: store.text("Close", "关闭"), enabled: true) != nil else {
            throw GitPierError.invalidInput("Operations Center close action is clipped")
          }
          let detailsTitle = store.text("Details", "详情")
          guard let disclosure = dashboardElement(content, label: detailsTitle, role: "AXDisclosureTriangle")
            ?? dashboardElement(content, label: detailsTitle, role: "AXButton") else {
            try accessibilityLabels(content).write(to: output.appendingPathComponent("operations-accessibility.txt"), atomically: true, encoding: .utf8)
            throw GitPierError.invalidInput("Operation diagnostic disclosure is not accessible")
          }
          try dashboardPress(disclosure); try await settle()
          let thumbs = descendants(content).compactMap { $0 as? OverlayScrollThumb }.filter { !$0.isHidden }
          guard thumbs.contains(where: \.horizontal), thumbs.contains(where: { !$0.horizontal }) else {
            throw GitPierError.invalidInput("Operation diagnostics did not install both shared overlay scrollbar axes")
          }
          assertions += 2
          let operations = "operations-" + suffix
          try await captureHostingWindow(sheet, to: output.appendingPathComponent(operations + ".png")); captures.append(operations)
          try pressNativeButton(content, title: store.text("Close", "关闭"))
          try await waitFor { window.attachedSheet == nil }
        }
      }
    }
    settings = store.settings; settings.language = .english; settings.appearance = .dark
    store.updateSettings(settings); store.notice = nil; store.showDashboard = false
    model.setPage("history"); try await settle()
    try await verifyQualityHistoryKeyboard(store: store, model: model, host: host, window: window, output: output)
    assertions += 2
    for name in [NSAppearance.Name.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
      settings.appearance = name == .accessibilityHighContrastAqua ? .light : .dark
      store.updateSettings(settings); store.notice = nil; try await settle()
      window.appearance = NSAppearance(named: name)
      try await settle()
      let image = "history-" + name.rawValue
      try await captureHostingWindow(window, to: output.appendingPathComponent(image + ".png")); captures.append(image)
    }
    let report: [String: Any] = ["assertions": assertions, "systemWindowCaptures": captures,
      "keyboard": "actual history row press, Down and Escape events in the native window",
      "contrast": "AppKit high-contrast Aqua/Dark Aqua window appearances; system preference left unchanged",
      "systemIncreaseContrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
      "voiceOver": "labels/checkbox/disclosure actions checked; Task segment exercised with native mouse events after in-process AX actions were unsupported; full spoken VoiceOver workflow not performed"]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("presentation-results.json"))
    if ProcessInfo.processInfo.environment["GITPIER_QUALITY_PRESENTATION_HOLD"] == "1" {
      try Data("ready\n".utf8).write(to: output.appendingPathComponent("inspection-ready"))
      for _ in 0..<180 {
        if FileManager.default.fileExists(atPath: output.appendingPathComponent("inspection-finished").path) { break }
        try await Task.sleep(for: .seconds(1))
      }
    }
  }
  private static func verifyQualityHistoryKeyboard(store: AppStore, model: RepositoryModel, host: NSView,
    window: NSWindow, output: URL) async throws {
    guard let first = model.history.first, let second = model.history.dropFirst().first else {
      throw GitPierError.invalidInput("History fixture needs two commits")
    }
    var phase = "row-press"
    var beforeResponder = ""
    do {
      window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
      try pressNativeButton(host, title: first.subject)
      try await waitFor { model.selectedHistoryCommit?.hash == first.hash }
      beforeResponder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
      phase = "down"
      guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
        characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125) else {
        throw GitPierError.invalidInput("Cannot create history navigation event")
      }
      NSApp.postEvent(down, atStart: false)
      try await waitFor { model.selectedHistoryCommit?.hash == second.hash }
      phase = "escape"
      try sendWorkspaceKey(53, window: window)
      try await waitFor { model.selectedHistoryCommit == nil }
      try Data("Native row press, Down selection and Escape detail closure passed.\n".utf8).write(to: output.appendingPathComponent("keyboard-results.txt"))
    } catch {
      let report: [String: Any] = ["phase": phase, "beforeResponder": beforeResponder,
        "afterResponder": window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil",
        "isActive": NSApp.isActive, "isKeyWindow": window.isKeyWindow,
        "managedWindow": store.managedWindows.contains(ObjectIdentifier(window)),
        "selected": model.selectedHistoryCommit?.hash ?? "nil", "first": first.hash, "second": second.hash]
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("keyboard-failure.json"))
      try await captureHostingWindow(window, to: output.appendingPathComponent("keyboard-failure.png"))
      if ProcessInfo.processInfo.environment["GITPIER_QUALITY_PRESENTATION_HOLD"] == "1" {
        try Data("ready\n".utf8).write(to: output.appendingPathComponent("inspection-ready"))
        for _ in 0..<180 {
          if FileManager.default.fileExists(atPath: output.appendingPathComponent("inspection-finished").path) { break }
          try await Task.sleep(for: .seconds(1))
        }
      }
      throw error
    }
  }
}
#endif
