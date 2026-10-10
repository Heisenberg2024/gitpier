import AppKit
import GitPierCore
import SwiftUI

/// Exercises the actual application against a throwaway repository; no fixture is loaded by normal launches.
@MainActor enum UIAcceptance {
  static func run() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    Task {
      let store = AppStore.shared
      let args = CommandLine.arguments
      guard let outputIndex = args.firstIndex(of: "--output"), args.count > outputIndex + 1,
        let rootIndex = args.firstIndex(of: "--repository"), args.count > rootIndex + 1,
        ProcessInfo.processInfo.environment["GITPIER_WORKSPACE_FILE"] != nil
      else {
        FileHandle.standardError.write(
          Data("Acceptance requires isolated workspace, repository and output paths.\n".utf8))
        exit(1)
      }
      let output = URL(fileURLWithPath: args[outputIndex + 1])
      let root = URL(fileURLWithPath: args[rootIndex + 1])
      do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        await store.addRepository(root)
        await store.current?.activate()
        guard let model = store.current, model.available else {
          throw GitPierError.invalidInput(store.error ?? "Cannot open acceptance repository")
        }
        model.record.name = "Acceptance Fixture"
        store.update(model.record)
        model.editDraft(
          "feat(workspace): connect repository status\n\nReview only the selected Index content.\nKeep every repository's draft and terminal isolated."
        )
        if let file = model.status.files.first(where: { $0.path == "Sources/workspace.swift" }) {
          model.select(file, permanent: true)
        }
        var appearanceSettings = store.settings
        appearanceSettings.appearance = .dark
        store.updateSettings(appearanceSettings)
        let content = RootView().environmentObject(store).modifier(AppAppearance(store: store))
          .frame(
            minWidth: 960, minHeight: 640)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        host.autoresizingMask = [.width, .height]
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "GitPier Acceptance"
        window.contentView = host
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.setFrameOrigin(NSPoint(x: -2000, y: -2000))
        window.orderFront(nil)
        try await settle()
        try await waitFor { !model.refreshing && !model.diffLoading }
        let progressProbe = OperationProgress()
        let oldTicket = progressProbe.begin("Previous")
        let staleReceiver = progressProbe.receiver()
        progressProbe.advance("Refresh")
        staleReceiver(GitTransferProgress(phase: .receiving, fraction: 0.5))
        try await Task.sleep(for: .milliseconds(10))
        guard progressProbe.state?.transfer == nil else {
          throw GitPierError.invalidInput("Old transfer updated a later progress phase")
        }
        _ = progressProbe.begin("Current")
        progressProbe.finish(.succeeded, ticket: oldTicket)
        guard progressProbe.state?.result == .running else {
          throw GitPierError.invalidInput("Old operation completed a new progress bar")
        }
        model.run(label: "Status-bar acceptance") { _ in
          try await Task.sleep(for: .milliseconds(300))
        }
        try await Task.sleep(for: .milliseconds(50))
        guard model.busy, model.activity.state?.result == .running,
          descendants(host).compactMap({ $0 as? NSProgressIndicator }).contains(where: {
            $0.style == .bar && $0.isIndeterminate
          })
        else {
          throw GitPierError.invalidInput(
            "Running operation did not show an indeterminate footer bar")
        }
        try await settle()
        try await waitFor { !model.busy }
        guard
          descendants(host).compactMap({ $0 as? NSProgressIndicator }).contains(where: {
            $0.style == .bar
          }),
          model.activity.state?.result == .succeeded
        else {
          throw GitPierError.invalidInput("Status bar did not display native operation progress")
        }
        let idleCount = model.refreshCount
        try await Task.sleep(for: .seconds(2))
        guard model.refreshCount == idleCount else {
          throw GitPierError.invalidInput("Idle repository continuously refreshed")
        }
        let tracked = model.status.tracked
        let untracked = model.status.untracked
        let indexBeforeSelection = try await model.git().snapshot()
        let selectionStart = ContinuousClock.now
        for _ in 0..<100 {
          model.toggleIncluded(tracked)
          model.toggleIncluded(untracked)
        }
        let selectionDuration = selectionStart.duration(to: .now)
        let indexAfterSelection = try await model.git().snapshot()
        guard model.refreshCount == idleCount, !model.busy, !model.refreshing,
          indexBeforeSelection == indexAfterSelection,
          model.status.untracked == untracked, selectionDuration < .milliseconds(150)
        else {
          throw GitPierError.invalidInput("Checkbox selection mutated Git or was not immediate")
        }
        if let first = model.selectedFile,
          let second = model.status.files.first(where: { $0.path == "README.md" })
        {
          model.select(second)
          try await waitFor { !model.diffLoading }
          model.select(first)
          try await waitFor { !model.diffLoading }
          let reads = model.diffReadCount
          let switchStart = ContinuousClock.now
          for _ in 0..<100 {
            model.select(second)
            guard !model.diffLoading else {
              throw GitPierError.invalidInput("Cached Diff showed a loader")
            }
            model.select(first)
            guard !model.diffLoading else {
              throw GitPierError.invalidInput("Cached Diff showed a loader")
            }
          }
          guard model.diffReadCount == reads, switchStart.duration(to: .now) < .milliseconds(150)
          else {
            throw GitPierError.invalidInput("Cached file switching ran Git or was not immediate")
          }
          // Exercise the actual event path, not just the fast RepositoryModel.select method.
          try await settle()
          guard
            let target = descendants(host).compactMap({ $0 as? FileMouseDownView })
              .first(where: { $0.path == second.path })
          else {
            throw GitPierError.invalidInput("Missing native immediate file hit target")
          }
          let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
          @MainActor func pointerEvent(
            _ type: NSEvent.EventType, clicks: Int, modifiers: NSEvent.ModifierFlags = []
          ) -> NSEvent {
            NSEvent.mouseEvent(
              with: type, location: point, modifierFlags: modifiers,
              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
              context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
          }
          let beforeReads = model.diffReadCount
          let mouseStart = ContinuousClock.now
          NSApp.postEvent(pointerEvent(.leftMouseDown, clicks: 1), atStart: false)
          try await waitFor { model.selectedPath == second.path }
          guard model.selectedPath == second.path, model.selectedPaths == [second.path],
            !model.diffLoading, model.diffReadCount == beforeReads,
            model.diff.raw.contains("Review the Index")
          else {
            throw GitPierError.invalidInput(
              "First mouse-down did not immediately select and display the cached file: target=\(target.bounds), selected=\(model.selectedPath ?? "nil"), loading=\(model.diffLoading), reads=\(model.diffReadCount - beforeReads)"
            )
          }
          let mouseDuration = mouseStart.duration(to: .now)
          print(
            "Native first mouse-down dispatch: \(target.lastDispatchDuration * 1000) ms; asserted before mouse-up (\(mouseDuration))"
          )
          NSApp.postEvent(pointerEvent(.leftMouseUp, clicks: 1), atStart: false)
          let revision = model.diff.revision
          NSApp.postEvent(pointerEvent(.leftMouseDown, clicks: 2), atStart: false)
          try await waitFor {
            model.tabs.first(where: { $0.path == second.path })?.preview == false
          }
          guard model.tabs.first(where: { $0.path == second.path })?.preview == false,
            model.diff.revision == revision, model.diffReadCount == beforeReads
          else {
            throw GitPierError.invalidInput(
              "Second mouse-down must only promote the existing Diff tab")
          }
          NSApp.postEvent(pointerEvent(.leftMouseUp, clicks: 2), atStart: false)
          let down = NSEvent.keyEvent(
            with: .keyDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
            isARepeat: false, keyCode: 125)!
          // The offscreen fixture has no global key window; route through its real responder chain.
          window.sendEvent(down)
          do {
            try await waitFor {
              model.selectedPath == first.path
                && (window.firstResponder as? FileMouseDownView)?.path == first.path
            }
          } catch {
            throw GitPierError.invalidInput(
              "Keyboard navigation: selected=\(model.selectedPath ?? "nil"), responder=\(String(describing: window.firstResponder)), expected=\(first.path)"
            )
          }
          guard (window.firstResponder as? FileMouseDownView)?.path == first.path,
            !model.diffLoading, model.diffReadCount == beforeReads
          else {
            throw GitPierError.invalidInput(
              "Mouse selection did not retain keyboard navigation and cached Diff")
          }
          NSApp.postEvent(
            pointerEvent(.leftMouseDown, clicks: 1, modifiers: .command), atStart: false)
          do { try await waitFor { model.selectedPaths == [first.path, second.path] } } catch {
            throw GitPierError.invalidInput("Command selection: selected=\(model.selectedPaths)")
          }
          NSApp.postEvent(
            pointerEvent(.leftMouseUp, clicks: 1, modifiers: .command), atStart: false)
          let selectedBeforeCheckbox = model.selectedPaths
          let documentBeforeCheckbox = model.diff.revision
          guard
            let checkbox = descendants(host).compactMap({ $0 as? NSButton }).first(where: {
              $0.allowsMixedState
            })
          else {
            throw GitPierError.invalidInput("Missing independent commit checkbox")
          }
          checkbox.performClick(nil)
          guard !model.includedPaths.isEmpty, model.selectedPaths == selectedBeforeCheckbox,
            model.diff.revision == documentBeforeCheckbox, model.diffReadCount == beforeReads
          else {
            throw GitPierError.invalidInput("Checkbox changed file focus or reloaded Diff")
          }
          checkbox.performClick(nil)
          // Context selection must happen before native menu handling, including the row gutter.
          let inclusionBeforeContext = model.includedPaths
          let escape = NSEvent.keyEvent(
            with: .keyDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53)!
          var contextCases = [(second, false)]
          if let untrackedFile = model.status.untracked.first {
            model.select(untrackedFile)
            try await waitFor { !model.diffLoading }
            contextCases.append((untrackedFile, false))
          }
          contextCases += [(first, false), (second, true), (first, true)]
          model.select(first)
          let contextReads = model.diffReadCount
          for (file, controlClick) in contextCases {
            if model.selectedPath == file.path {
              model.select(file.path == first.path ? second : first)
            }
            try await settle()
            guard
              let row = descendants(host).compactMap({ $0 as? FileMouseDownView })
                .first(where: { $0.path == file.path })
            else {
              throw GitPierError.invalidInput("Missing context-click row: " + file.path)
            }
            let location =
              row.convert(
                NSPoint(
                  x: controlClick ? row.bounds.minX - 25 : row.bounds.midX,
                  y: row.bounds.midY), to: nil)
            let contextEvent = NSEvent.mouseEvent(
              with: controlClick ? .leftMouseDown : .rightMouseDown, location: location,
              modifierFlags: controlClick ? .control : [],
              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
              context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
            NSApp.postEvent(contextEvent, atStart: false)
            NSApp.postEvent(escape, atStart: false)
            try await waitFor { model.selectedPath == file.path }
            guard model.selectedPaths == [file.path], !model.diffLoading,
              model.diffReadCount == contextReads, model.includedPaths == inclusionBeforeContext
            else {
              throw GitPierError.invalidInput(
                "Context click did not immediately select the correct row independently of commit inclusion: "
                  + file.path
              )
            }
            NSApp.postEvent(
              NSEvent.mouseEvent(
                with: controlClick ? .leftMouseUp : .rightMouseUp, location: location,
                modifierFlags: controlClick ? .control : [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!, atStart: false)
          }
          print(
            "Native context selection: repeated tracked/untracked right-click and Control-click gutter selected before menu handling; no Git read or checkbox mutation"
          )
          // Return to the source used by the remaining manual-refresh regression.
          model.select(first, permanent: true)
        }
        let oldDiff = model.diff.raw
        let oldStatus = model.status
        let selectedURL = root.appendingPathComponent("Sources/workspace.swift")
        let originalContents = try Data(contentsOf: selectedURL)
        var editedContents = originalContents
        editedContents.append(Data("\n// GITPIER_MANUAL_REFRESH_CONTENT\n".utf8))
        try editedContents.write(to: selectedURL)
        await model.refresh()
        try await waitFor {
          model.diff.raw.contains("GITPIER_MANUAL_REFRESH_CONTENT")
        }
        guard model.status == oldStatus else {
          throw GitPierError.invalidInput("Manual-refresh regression fixture changed status flags")
        }
        try originalContents.write(to: selectedURL)
        await model.refresh()
        try await waitFor { model.diff.raw == oldDiff }
        let themeRefreshCount = model.refreshCount
        appearanceSettings.appearance = .light
        store.updateSettings(appearanceSettings)
        try await settle()
        guard model.refreshCount == themeRefreshCount, model.diff.raw == oldDiff else {
          throw GitPierError.invalidInput("Appearance changes reloaded Git or Diff")
        }
        appearanceSettings.appearance = .dark
        store.updateSettings(appearanceSettings)
        try await settle()
        if let code = descendants(host).compactMap({ $0 as? DiffCell }).first?.code {
          let font = code.font
          let inset = code.textContainerInset
          window.makeFirstResponder(code)
          code.setSelectedRange(NSRange(location: 0, length: min(3, code.string.utf16.count)))
          guard code.font == font, code.textContainerInset == inset, !code.isEditable else {
            throw GitPierError.invalidInput("Selecting Diff code changed typography")
          }
        } else {
          throw GitPierError.invalidInput("No native Diff code view")
        }
        if let second = model.status.files.first(where: { $0.path == "README.md" }) {
          model.select(second, permanent: true)
          let count = model.tabs.count
          guard ShortcutRouter.closeTab(store: store, responder: window.firstResponder),
            model.tabs.count == count - 1
          else { throw GitPierError.invalidInput("Commit Cmd+W routing did not close a tab") }
        }
        try await waitFor { !model.diffLoading }
        try capture(host, to: output.appendingPathComponent("commit-dark.png"))
        let previousApplicationAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        store.updateSystemAppearance()
        appearanceSettings.appearance = .light
        store.updateSettings(appearanceSettings)
        appearanceSettings.appearance = .system
        store.updateSettings(appearanceSettings)
        try await settle()
        guard store.resolvedColorScheme == .dark, window.appearance == nil else {
          throw GitPierError.invalidInput("Follow-system appearance did not reset all content")
        }
        NSApp.appearance = previousApplicationAppearance
        store.updateSystemAppearance()
        appearanceSettings.appearance = .light
        store.updateSettings(appearanceSettings)
        host.rootView = RootView().environmentObject(store).modifier(AppAppearance(store: store))
          .frame(
            minWidth: 960, minHeight: 640)
        window.appearance = NSAppearance(named: .aqua)
        try await settle()
        try capture(host, to: output.appendingPathComponent("commit-light.png"))
        host.rootView = RootView().environmentObject(store).modifier(AppAppearance(store: store))
          .frame(
            minWidth: 960, minHeight: 640)
        appearanceSettings.appearance = .dark
        store.updateSettings(appearanceSettings)
        var layout = model.record.layout
        layout.terminalVisible = true
        model.editLayout(layout)
        model.terminal.add(settings: store.settings)
        guard let session = model.terminal.selected else {
          throw GitPierError.invalidInput("Terminal was not created")
        }
        var bytes = Data()
        session.view.acceptanceOutput = { chunk in
          if bytes.count < 1024 * 1024 { bytes.append(chunk) }
        }
        try await settle()
        let fontApplications = session.fontApplyCount
        let terminalSuperview = session.view.superview
        let savedLayout = store.repositories.first { $0.id == model.record.id }!.layout
        guard let nativeDiff = descendants(host).compactMap({ $0 as? DiffSplitContainer }).first
        else {
          throw GitPierError.invalidInput("No persistent native Diff table")
        }
        let reloads = nativeDiff.reloadCount
        let invalidations = nativeDiff.heightInvalidationCount
        let documentRevision = model.diff.revision
        for height in [220.0, 240.0, 280.0, 260.0, 230.0, 260.0] {
          var dragged = model.panels.layout
          dragged.terminalHeight = height
          dragged.changesWidth = height + 80
          model.editLayout(dragged, persist: false)
          try await Task.sleep(for: .milliseconds(50))
        }
        guard session.fontApplyCount == fontApplications,
          session.view.superview === terminalSuperview, session.view.process.running,
          store.repositories.first(where: { $0.id == model.record.id })!.layout == savedLayout,
          model.record.layout == savedLayout, model.diff.revision == documentRevision,
          nativeDiff.reloadCount == reloads, nativeDiff.heightInvalidationCount == invalidations,
          descendants(host).contains(where: { $0 === nativeDiff })
        else {
          throw GitPierError.invalidInput(
            "Terminal resize recreated its view, reapplied fonts or persisted each frame")
        }
        model.persistLayout()
        var wrapping = store.settings
        wrapping.wrapDiff = true
        store.updateSettings(wrapping)
        try await settle()
        let wrappedReloads = nativeDiff.reloadCount
        let wrappedInvalidations = nativeDiff.heightInvalidationCount
        for width in [310.0, 330.0, 360.0, 320.0, 340.0, 310.0] {
          var dragged = model.panels.layout
          dragged.changesWidth = width
          model.editLayout(dragged, persist: false)
          try await Task.sleep(for: .milliseconds(30))
        }
        try await settle()
        guard nativeDiff.reloadCount == wrappedReloads,
          nativeDiff.heightInvalidationCount - wrappedInvalidations <= 2
        else {
          throw GitPierError.invalidInput(
            "Wrapped resize reloaded rows or invalidated all heights every frame")
        }
        wrapping.wrapDiff = false
        store.updateSettings(wrapping)
        model.persistLayout()
        var restored = model.panels.layout
        restored.changesWidth = savedLayout.changesWidth
        model.editLayout(restored)
        // Code typography must not alter UI or repository labels.
        let normalUI = uiFont(size: 12)
        let normalRepository = repositoryFont()
        var typography = store.settings
        typography.diffFont = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular).fontName
        typography.diffFontSize = 18
        store.updateSettings(typography)
        try await settle()
        guard uiFont(size: 12) == normalUI, repositoryFont() == normalRepository,
          descendants(host).compactMap({ $0 as? DiffCell }).first?.code.font?.pointSize == 18
        else { throw GitPierError.invalidInput("Diff typography affected other interface regions") }
        typography.diffFont = appearanceSettings.diffFont
        typography.diffFontSize = appearanceSettings.diffFontSize
        store.updateSettings(typography)
        session.view.send(
          txt:
            "printf '\\033[34mGitPier PTY acceptance — 中文 ✓\\033[0m\\n'; pwd; stty size; git status --short\n"
        )
        do {
          try await waitFor {
            String(decoding: bytes, as: UTF8.self).contains("GitPier PTY acceptance — 中文")
              && String(decoding: bytes, as: UTF8.self).contains(model.record.path)
          }
        } catch {
          try capture(host, to: output.appendingPathComponent("terminal-failure.png"))
          throw GitPierError.invalidInput(
            "PTY acceptance timed out (running=\(session.view.process.running), expected directory=\(model.record.path)). Captured fixture output: "
              + String(decoding: bytes.suffix(1000), as: UTF8.self))
        }
        try await settle()
        try capture(host, to: output.appendingPathComponent("workspace-terminal-dark.png"))
        // A hidden terminal must remain alive, as must sessions belonging to another repository.
        layout.terminalVisible = false
        model.editLayout(layout)
        session.view.send(txt: "printf 'GITPIER_HIDDEN_SESSION_OK\\n'\n")
        try await waitFor {
          String(decoding: bytes, as: UTF8.self).contains("\r\nGITPIER_HIDDEN_SESSION_OK\r\n")
        }
        guard session.view.process.running else {
          throw GitPierError.invalidInput("Hidden terminal exited")
        }
        layout.terminalVisible = true
        layout.terminalMaximized = true
        model.editLayout(layout)
        try await settle()
        try capture(host, to: output.appendingPathComponent("terminal-dark.png"))
        session.view.send(txt: "sleep 30\n")
        try await Task.sleep(for: .milliseconds(200))
        session.view.send(data: [3][...])
        session.view.send(txt: "printf 'GITPIER_INTERRUPT_OK\\n'\n")
        try await waitFor {
          String(decoding: bytes, as: UTF8.self).contains("\r\nGITPIER_INTERRUPT_OK\r\n")
        }
        session.view.send(txt: "vim -Nu NONE -n README.md\n")
        try await waitFor { String(decoding: bytes, as: UTF8.self).contains("\u{1B}[?1049h") }
        session.view.send(txt: ":q!\r")
        try await waitFor { String(decoding: bytes, as: UTF8.self).contains("\u{1B}[?1049l") }
        session.view.send(
          txt:
            "git --version; ssh -V; command -v node >/dev/null && node --version; command -v docker >/dev/null && docker --version; printf 'GITPIER_CLI_TOOLS_OK\\n'\n"
        )
        try await waitFor {
          String(decoding: bytes, as: UTF8.self).contains("\r\nGITPIER_CLI_TOOLS_OK\r\n")
        }
        session.view.send(txt: "git add -- README.md; printf 'GITPIER_STAGE_DONE\\n'\n")
        try await waitFor {
          String(decoding: bytes, as: UTF8.self).contains("\r\nGITPIER_STAGE_DONE\r\n")
        }
        await model.refresh()
        try await waitFor { model.status.files.first { $0.path == "README.md" }?.isStaged == true }
        layout.terminalMaximized = false
        model.editLayout(layout)
        model.setPage("history")
        await model.loadHistory(reset: true)
        try await settle()
        try capture(host, to: output.appendingPathComponent("history-dark.png"))
        model.setPage("branches")
        try await settle()
        try capture(host, to: output.appendingPathComponent("branches-dark.png"))
        model.setPage("commit")
        host.rootView = RootView().environmentObject(store).modifier(AppAppearance(store: store))
          .frame(
            minWidth: 960, minHeight: 640)
        appearanceSettings.appearance = .light
        store.updateSettings(appearanceSettings)
        window.setContentSize(NSSize(width: 960, height: 640))
        try await settle()
        try capture(host, to: output.appendingPathComponent("workspace-light-960.png"))
        var settings = store.settings
        settings.language = .simplifiedChinese
        store.updateSettings(settings)
        try await settle()
        try capture(host, to: output.appendingPathComponent("workspace-chinese-light.png"))
        let organization = try store.createOrganization("Acceptance Project")
        try store.moveRepositories([model.record.id], to: organization.id)
        try store.renameOrganization(organization.id, name: "Renamed Project")
        guard model.record.group == "Renamed Project",
          model.record.draft.contains("feat(workspace)")
        else { throw GitPierError.invalidInput("Organization management lost repository state") }
        store.removeOrganization(organization.id)
        guard model.record.group.isEmpty else {
          throw GitPierError.invalidInput(
            "Organization removal did not preserve ungrouped repository")
        }
        session.view.acceptanceOutput = nil
        store.shutdown()
        window.close()
        try
          "Immediate native first mouse-down selection and cached Diff before mouse-up, second-click tab promotion without reload, right-click and Control-click gutter selection before menu handling without changing commit inclusion, immediate checkbox selection without Index changes, cached Diff switching without Git reads, native resize without table reload/row-height invalidation, code-only typography, manual-refresh idle stability, changed file contents with unchanged status flags, theme-only changes, follow-system reset, native Diff selection typography, Cmd+W tab routing, stable terminal resize and organization state preservation passed. Native UI captured in dark/light at 1440×900 and 960×640, plus Simplified Chinese. Real PTY: working directory, ANSI, Unicode, size reporting, hidden-session survival, Ctrl+C, Vim alternate-screen entry/exit, installed CLI version probes and manual Index refresh passed.\n"
          .write(
            to: output.appendingPathComponent("acceptance.txt"), atomically: true, encoding: .utf8)
        print("Native UI and PTY acceptance passed. Screenshots: \(output.path)")
        exit(0)
      } catch {
        store.shutdown()
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
      }
    }
    NSApp.run()
  }
  static func descendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants($0) }
  }
  static func settle() async throws { try await Task.sleep(for: .milliseconds(650)) }
  static func waitFor(_ condition: () -> Bool) async throws {
    let until = Date().addingTimeInterval(8)
    while !condition() {
      if Date() > until { throw GitPierError.invalidInput("Acceptance condition timed out") }
      try await Task.sleep(for: .milliseconds(100))
    }
  }
  static func capture(_ view: NSView, to url: URL) throws {
    func refreshLayers(_ node: NSView) {
      node.needsDisplay = true
      node.displayIfNeeded()
      node.layer?.displayIfNeeded()
      node.subviews.forEach(refreshLayers)
    }
    refreshLayers(view)
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw GitPierError.invalidInput(
        "Unable to render native view (bounds=\(view.bounds), window=\(String(describing: view.window?.frame)))"
      )
    }
    view.cacheDisplay(in: view.bounds, to: image)
    // SwiftTerm uses a layer background and transparent default cells. Compose its native layer too.
    if let layer = view.layer, let context = NSGraphicsContext(bitmapImageRep: image)?.cgContext {
      context.saveGState()
      context.translateBy(x: 0, y: view.bounds.height)
      context.scaleBy(x: 1, y: -1)
      layer.render(in: context)
      context.restoreGState()
    }
    // Compose a separate native terminal bitmap; its default cells use a transparent backing store.
    func composeTerminal(_ node: NSView) {
      if let terminal = node as? SafeTerminalView, terminal.bounds.width > 0,
        terminal.bounds.height > 0,
        let terminalImage = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: Int(terminal.bounds.width * 2),
          pixelsHigh: Int(terminal.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
          bitsPerPixel: 0),
        let rootContext = NSGraphicsContext(bitmapImageRep: image)
      {
        terminalImage.size = terminal.bounds.size
        NSGraphicsContext.saveGraphicsState()
        let terminalContext = NSGraphicsContext(bitmapImageRep: terminalImage)!
        NSGraphicsContext.current = terminalContext
        terminal.draw(terminal.bounds)
        terminalContext.cgContext.setBlendMode(.destinationOver)
        terminal.nativeBackgroundColor.setFill()
        terminal.bounds.fill()
        NSGraphicsContext.current = rootContext
        let sourceRect = terminal.convert(terminal.bounds, to: view)
        let targetRect = NSRect(
          x: sourceRect.minX, y: view.bounds.height - sourceRect.maxY, width: sourceRect.width,
          height: sourceRect.height)
        let nativeImage = NSImage(size: terminal.bounds.size)
        nativeImage.addRepresentation(terminalImage)
        nativeImage.draw(in: targetRect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
      }
      node.subviews.forEach(composeTerminal)
    }
    composeTerminal(view)
    guard let png = image.representation(using: .png, properties: [:]) else {
      throw GitPierError.invalidInput("Unable to encode screenshot")
    }
    try png.write(to: url)
  }
}
