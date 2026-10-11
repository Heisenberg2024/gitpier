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
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.setFrameOrigin(NSPoint(x: -2000, y: -2000))
        window.orderFront(nil)
        try await settle()
        try await waitFor { !model.refreshing && !model.diffLoading }
        if ProcessInfo.processInfo.environment["GITPIER_UI_ACCEPTANCE_SCOPE"] == "version102" {
          model.terminal.add(settings: store.settings)
          try await verifyVersion102(
            store: store, model: model, host: host, window: window, output: output)
          store.shutdown()
          window.close()
          print("Native 1.0.2 UI acceptance passed.")
          exit(0)
        }
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
        try await verifyWorkspaceImprovements(
          store: store, model: model, root: root, host: host, window: window, output: output)
        try await verifyVersion102(
          store: store, model: model, host: host, window: window, output: output)
        try await verifyDiffScrollBounds(settings: store.settings, output: output)
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
  static func verifyVersion102(
    store: AppStore, model: RepositoryModel, host: NSView, window: NSWindow, output: URL
  ) async throws {
    FileHandle.standardError.write(Data("1.0.2 acceptance: history selection and layout\n".utf8))
    var layout = model.panels.layout
    layout.terminalVisible = false
    model.editLayout(layout)
    model.setPage("history")
    store.select(model.record.id)
    guard model.page == "commit" else {
      throw GitPierError.invalidInput("Opening a repository did not default to Commit")
    }
    let reopened = RepositoryModel(record: model.record, store: store)
    guard reopened.page == "commit" else {
      throw GitPierError.invalidInput("New repository session restored an old page")
    }
    await model.activate()
    model.setPage("history")
    await model.loadHistory(reset: true)
    model.selectedHistoryCommit = nil
    window.setContentSize(NSSize(width: 1440, height: 900))
    try await settle()
    guard let commit = model.history.last else {
      throw GitPierError.invalidInput("Missing history fixture")
    }
    model.selectedHistoryCommit = commit
    try await waitFor { descendants(host).compactMap { $0 as? DiffSplitContainer }.first != nil }
    guard let diff = descendants(host).compactMap({ $0 as? DiffSplitContainer }).first,
      diff.afterOnly, diff.scrolls[0].isHidden, diff.scrolls[1].frame.width == diff.bounds.width
    else { throw GitPierError.invalidInput("History addition did not hide its empty old side") }
    layout = model.panels.layout
    layout.historyDetailHeight = 385
    layout.historyFilesWidth = 315
    model.editLayout(layout, persist: false)
    model.persistLayout()
    guard
      try store.persistence.load().repositories.first(where: { $0.id == model.record.id })?.layout
        == layout
    else { throw GitPierError.invalidInput("History layout was not persisted") }
    try await settle()
    try capture(host, to: output.appendingPathComponent("history-detail-102.png"))
    model.setPage("commit")
    try await settle()
    model.setPage("history")
    try await settle()
    guard model.panels.layout == layout else {
      throw GitPierError.invalidInput("Page switch reset history layout")
    }
    let escape = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false,
      keyCode: 53)!
    guard
      !ShortcutRouter.closeHistory(store: store, responder: model.terminal.sessions.first?.view),
      ShortcutRouter.handleKeyDown(escape, store: store, window: window),
      model.selectedHistoryCommit == nil
    else { throw GitPierError.invalidInput("History Esc routing failed or consumed terminal Esc") }
    try await settle()
    guard descendants(host).compactMap({ $0 as? DiffSplitContainer }).isEmpty else {
      throw GitPierError.invalidInput("Closing history did not remove the native Diff")
    }
    let installed = ExternalEditors.installed()
    var preferences = AppSettings()
    guard Set(installed.map(\.id)).count == installed.count,
      ExternalEditors.application(settings: preferences) == installed.first?.url
    else {
      throw GitPierError.invalidInput("Editor automatic priority or deduplication failed")
    }
    if let selected = installed.last {
      preferences.editorPath = selected.id
      preferences.customEditorPaths = [selected.id, selected.id]
      guard ExternalEditors.application(settings: preferences) == selected.url,
        Set(ExternalEditors.available(settings: preferences).map(\.id)).count == installed.count
      else { throw GitPierError.invalidInput("Editor selection or custom deduplication failed") }
      let override = installed.first!.url
      guard ExternalEditors.application(settings: preferences, override: override) == override,
        preferences.editorPath == selected.id
      else {
        throw GitPierError.invalidInput("One-time editor choice changed the default")
      }
    }
    let settingsHost = NSHostingView(
      rootView: AnyView(
        SettingsView().environmentObject(store).modifier(AppAppearance(store: store))))
    let settingsWindow = NSWindow(
      contentRect: NSRect(x: -2400, y: -2400, width: 760, height: 580),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    settingsWindow.isReleasedWhenClosed = false
    settingsWindow.contentView = settingsHost
    settingsWindow.orderFront(nil)
    defer { settingsWindow.close() }
    FileHandle.standardError.write(Data("1.0.2 acceptance: Settings tabs and offline Help\n".utf8))
    for language in [AppLanguage.english, .simplifiedChinese] {
      var settings = store.settings
      settings.language = language
      store.updateSettings(settings)
      try await settle()
      for index in 0...7 {
        settingsHost.rootView = AnyView(
          SettingsView(initialTab: index).id(index)
            .environmentObject(store).modifier(AppAppearance(store: store)))
        try await settle()
        if index == 0 {
          guard
            let picker = descendants(settingsHost).compactMap({ $0 as? NSPopUpButton })
              .first(where: { $0.accessibilityIdentifier() == "external-editor-picker" }),
            picker.itemArray.last?.title == store.text("Choose Application…", "选择应用…"),
            picker.itemArray.filter({ $0.representedObject is String }).allSatisfy({
              $0.image != nil
            }),
            !picker.itemArray.contains(where: {
              $0.title.contains("Automatic") || $0.title.contains("自动选择")
            })
          else {
            throw GitPierError.invalidInput("Editor popup icons or compact menu layout failed")
          }
        }
        try capture(
          settingsHost,
          to: output.appendingPathComponent("settings-102-\(language.rawValue)-\(index).png"))
      }
      settingsHost.rootView = AnyView(
        HelpView().environmentObject(store).modifier(AppAppearance(store: store)))
      try await settle()
      try capture(
        settingsHost, to: output.appendingPathComponent("help-102-\(language.rawValue).png"))
      settingsHost.rootView = AnyView(
        SettingsView().environmentObject(store).modifier(AppAppearance(store: store)))
    }
    try
      "History layout serialization and page switch, full-width added-file native Diff, Esc routing with terminal exclusion, editor default/custom/one-time selection, native popup application icons and compact menu, all eight Settings initial pages and offline Help rendering passed. Real Settings tab clicks and history pointer/key events require the separate isolated GUI check. Installed editor order: \(installed.map(\.name).joined(separator: ", ")).\n"
      .write(
        to: output.appendingPathComponent("version-102.txt"), atomically: true, encoding: .utf8)
  }
  static func verifyWorkspaceImprovements(
    store: AppStore, model: RepositoryModel, root: URL, host: NSView, window: NSWindow,
    output: URL
  ) async throws {
    let organization = try store.createOrganization("Ordering Acceptance")
    for name in ["ordered-one", "ordered-two", "ordered-three"] {
      await store.addRepository(
        root.deletingLastPathComponent().appendingPathComponent(name),
        group: organization.name)
    }
    let members = store.repositories.filter { $0.group == organization.name }
    guard members.count == 3 else {
      throw GitPierError.invalidInput("Organization-scoped open did not assign new repositories")
    }
    let memberOrder = members.map(\.id)
    store.select(memberOrder[0])
    try await waitFor { store.current?.available == true && store.current?.refreshing == false }
    guard store.repositories.filter({ $0.group == organization.name }).map(\.id) == memberOrder,
      store.reorderRepository(memberOrder[0], relativeTo: memberOrder[2]),
      store.repositories.filter({ $0.group == organization.name }).map(\.id)
        == [memberOrder[1], memberOrder[2], memberOrder[0]],
      try store.persistence.load().repositories.map(\.id) == store.repositories.map(\.id)
    else {
      throw GitPierError.invalidInput("Click order changed or manual reorder was not persisted")
    }
    await store.addRepository(root, group: organization.name)
    guard model.record.group == organization.name, store.selectedID == model.record.id else {
      throw GitPierError.invalidInput(
        "Organization-scoped open did not move the existing repository")
    }
    try await waitFor { !model.refreshing }
    let beforeClick = model.refreshCount
    store.select(model.record.id)
    try await waitFor { model.refreshCount > beforeClick && !model.refreshing }
    let path = "Sources/workspace.swift"
    guard let file = model.status.files.first(where: { $0.path == path }) else {
      throw GitPierError.invalidInput("Missing active-refresh fixture")
    }
    model.select(file)
    try await waitFor { !model.diffLoading }
    let contents = try Data(contentsOf: root.appendingPathComponent(path))
    var edited = contents
    edited.append(Data("\n// GITPIER_FOREGROUND_REFRESH\n".utf8))
    try edited.write(to: root.appendingPathComponent(path))
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    try await waitFor { !model.refreshing && model.diff.raw.contains("GITPIER_FOREGROUND_REFRESH") }
    try contents.write(to: root.appendingPathComponent(path))
    await model.refresh()
    try await waitFor { !model.diffLoading }
    let beforeWrite = model.refreshCount
    model.run(label: "Busy refresh acceptance") { _ in
      try await Task.sleep(for: .milliseconds(450))
    }
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    try await Task.sleep(for: .milliseconds(150))
    guard model.busy, model.refreshCount == beforeWrite else {
      throw GitPierError.invalidInput("Foreground refresh raced an active write")
    }
    try await waitFor { !model.busy }
    guard model.refreshCount > beforeWrite, model.output?.contains("已完成") == true else {
      throw GitPierError.invalidInput("Silent Git operations did not report their final completion")
    }
    let probePath = "scroll-probe.swift"
    let probe =
      (0..<260).map {
        "// line \($0): " + String(repeating: "long-content ", count: 28)
      }.joined(separator: "\n") + "\n"
    try probe.write(to: root.appendingPathComponent(probePath), atomically: true, encoding: .utf8)
    await model.refresh()
    guard let probeFile = model.status.files.first(where: { $0.path == probePath }) else {
      throw GitPierError.invalidInput("Missing scroll fixture")
    }
    model.comparison = .unstaged
    model.select(probeFile)
    var settings = store.settings
    settings.appearance = .dark
    settings.wrapDiff = false
    settings.unifiedDiff = false
    store.updateSettings(settings)
    try await settle()
    try await waitFor { !model.diffLoading }
    guard let diff = descendants(host).compactMap({ $0 as? DiffSplitContainer }).first,
      diff.afterOnly, diff.scrolls[0].isHidden, !diff.scrolls[1].isHidden,
      abs(diff.scrolls[1].frame.width - diff.bounds.width) < 1
    else { throw GitPierError.invalidInput("Empty Index did not give the working tree full width") }
    let scroll = diff.scrolls[1]
    guard !scroll.horizontalThumb.isHidden, !scroll.verticalThumb.isHidden,
      scroll.horizontalThumb.knobRect.width == 56, scroll.horizontalThumb.knobRect.height == 6,
      scroll.verticalThumb.knobRect.width == 6
    else {
      throw GitPierError.invalidInput("Diff scrollbar geometry does not match the compact design")
    }
    guard
      let wheel = CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
        wheel1: -180, wheel2: -260, wheel3: 0
      ).flatMap({ NSEvent(cgEvent: $0) })
    else {
      throw GitPierError.invalidInput("Cannot construct native scrolling event")
    }
    scroll.scrollWheel(with: wheel)
    try await Task.sleep(for: .milliseconds(180))
    guard scroll.contentView.bounds.minY > 0, scroll.contentView.bounds.minX > 0,
      scroll.horizontalThumb.knobOpacity > 0.35, scroll.verticalThumb.knobOpacity > 0.35
    else {
      throw GitPierError.invalidInput("Native wheel scrolling or active thumb visibility failed")
    }
    try capture(host, to: output.appendingPathComponent("diff-scroll-active-dark.png"))
    try await Task.sleep(for: .milliseconds(1100))
    guard scroll.horizontalThumb.knobOpacity < 0.25, scroll.verticalThumb.knobOpacity < 0.25 else {
      throw GitPierError.invalidInput("Diff scrollbars did not fade after scrolling stopped")
    }
    try capture(host, to: output.appendingPathComponent("diff-scroll-idle-dark.png"))
    let thumb = scroll.horizontalThumb
    let start = thumb.convert(NSPoint(x: thumb.knobRect.midX, y: thumb.knobRect.midY), to: nil)
    let end = NSPoint(x: start.x + 70, y: start.y)
    let oldX = scroll.contentView.bounds.minX
    func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 3, clickCount: 1, pressure: 1)!
    }
    thumb.mouseDown(with: mouse(.leftMouseDown, at: start))
    thumb.mouseDragged(with: mouse(.leftMouseDragged, at: end))
    thumb.mouseUp(with: mouse(.leftMouseUp, at: end))
    guard scroll.contentView.bounds.minX > oldX, thumb.knobRect.width == 56 else {
      throw GitPierError.invalidInput("Fixed-width horizontal thumb dragging did not scroll")
    }
    settings.appearance = .light
    store.updateSettings(settings)
    try await settle()
    try capture(host, to: output.appendingPathComponent("diff-empty-index-light.png"))
    model.comparison = .staged
    model.loadDiff()
    try await settle()
    guard !diff.afterOnly, !diff.scrolls[0].isHidden, !diff.scrolls[1].isHidden else {
      throw GitPierError.invalidInput("Staged comparison lost its two-sided layout")
    }
    model.comparison = .unstaged
    model.loadDiff()
    if !model.includedPaths.isEmpty {
      model.toggleIncluded(model.status.files.filter { model.includedPaths.contains($0.path) })
    }
    model.toggleIncluded([probeFile])
    model.editDraft("test: verify final commit and push notice")
    model.requiresIndexReview = false
    model.commit(push: true)
    try await waitFor { !model.busy }
    guard model.lastCommit != nil, model.error == nil,
      model.output?.hasPrefix("提交并推送已完成：") == true,
      model.output?.contains("Counting objects") == false,
      model.output?.contains("Enumerating objects") == false,
      model.output?.contains("%") == false, model.activity.state?.result == .succeeded,
      model.activity.state?.transfer == nil
    else { throw GitPierError.invalidInput("Commit-and-push notice did not show its final result") }
    model.network("fetch")
    try await waitFor { !model.busy }
    guard model.output?.hasPrefix("获取已完成。") == true else {
      throw GitPierError.invalidInput("Fetch did not report final completion")
    }
    model.network("pull")
    try await waitFor { !model.busy }
    guard model.output?.hasPrefix("拉取已完成。") == true else {
      throw GitPierError.invalidInput("Pull did not report final completion")
    }
    model.run(label: "Cancellation acceptance") { _ in
      try await Task.sleep(for: .seconds(2))
    }
    model.cancel()
    try await waitFor { !model.busy }
    guard model.output == "操作已取消。", model.outputResult == .cancelled,
      model.activity.state?.result == .cancelled
    else {
      throw GitPierError.invalidInput("Cancelled operation retained a success notice")
    }
    _ = try await model.git().perform(["branch", "--unset-upstream"])
    try (probe + "// no upstream\n").write(
      to: root.appendingPathComponent(probePath),
      atomically: true, encoding: .utf8)
    await model.refresh()
    guard let pendingFile = model.status.files.first(where: { $0.path == probePath }) else {
      throw GitPierError.invalidInput("Missing pending-push fixture")
    }
    model.toggleIncluded([pendingFile])
    model.editDraft("test: report pending push")
    model.requiresIndexReview = false
    model.commit(push: true)
    try await waitFor { !model.busy }
    guard model.needsUpstream, model.outputResult == .needsAttention,
      model.output?.contains("请选择 Remote 和分支推送") == true,
      model.activity.state?.result == .needsAttention
    else {
      throw GitPierError.invalidInput("Missing upstream was reported as completed push")
    }
    model.needsUpstream = false
    model.network("push", remote: "origin", branch: "main")
    try await waitFor { !model.busy }
    guard model.output?.hasPrefix("推送已完成。") == true, !model.pushFailed else {
      throw GitPierError.invalidInput("Pending local commit could not be pushed")
    }
    _ = try await model.git().perform([
      "remote", "set-url", "origin",
      root.deletingLastPathComponent().appendingPathComponent("missing-remote.git").path,
    ])
    try (probe + "// failed push\n").write(
      to: root.appendingPathComponent(probePath),
      atomically: true, encoding: .utf8)
    await model.refresh()
    model.toggleIncluded([pendingFile])
    model.editDraft("test: preserve commit on failed push")
    model.requiresIndexReview = false
    model.commit(push: true)
    try await waitFor { !model.busy }
    guard model.pushFailed, model.error != nil, model.outputResult == .needsAttention,
      model.output?.hasPrefix("本地提交成功，推送失败：") == true,
      model.lastCommit == model.status.head, model.activity.state?.result == .failed
    else {
      throw GitPierError.invalidInput("Failed push lost its local commit or showed success")
    }
    model.error = nil
    _ = try await model.git().perform([
      "remote", "set-url", "origin",
      root.deletingLastPathComponent().appendingPathComponent("remote.git").path,
    ])
    model.network("push")
    try await waitFor { !model.busy }
    guard !model.pushFailed, model.output?.hasPrefix("推送已完成。") == true else {
      throw GitPierError.invalidInput("Retrying failed push did not report completion")
    }
    store.removeOrganization(organization.id)
    try
      "Final command notifications, commit-and-push over a temporary local remote, explicit fetch/pull results, cancellation, missing-upstream attention, local-commit preservation on failed push and retry, repository click and application foreground refresh, write-safe refresh, persisted repository order, organization-scoped new/existing opens, full-width empty Index, 6pt active/idle scrollbars, 56pt horizontal thumb and native wheel/drag scrolling passed.\n"
      .write(
        to: output.appendingPathComponent("workspace-improvements.txt"), atomically: true,
        encoding: .utf8)
  }

  static func verifyDiffScrollBounds(settings: AppSettings, output: URL) async throws {
    let old = (1...240).map { "-old line \($0) " + String(repeating: "content ", count: 50) }
    let new = (1...240).map { "+new line \($0) " + String(repeating: "content ", count: 50) }
    let patch =
      ([
        "diff --git a/example.swift b/example.swift", "--- a/example.swift",
        "+++ b/example.swift", "@@ -1,240 +1,240 @@",
      ] + old + new).joined(separator: "\n") + "\n"
    let document = DiffParser.parse(Data(patch.utf8))
    var preferences = settings
    preferences.wrapDiff = false
    preferences.unifiedDiff = false
    let view = NSHostingView(
      rootView: DiffTable(
        document: document, path: "example.swift",
        key: "scroll-bounds", settings: preferences, dark: true, selectedHunk: 0,
        indexSide: 0, beforeTitle: "Index", afterTitle: "Working Tree"))
    let window = NSWindow(
      contentRect: NSRect(x: -2400, y: -2400, width: 640, height: 360),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = view
    window.orderFront(nil)
    defer { window.close() }
    try await settle()
    guard let diff = descendants(view).compactMap({ $0 as? DiffSplitContainer }).first else {
      throw GitPierError.invalidInput("Missing native scrollbar layout fixture")
    }
    for size in [
      NSSize(width: 640, height: 360), NSSize(width: 480, height: 120),
      NSSize(width: 820, height: 520),
    ] {
      window.setContentSize(size)
      try await settle()
      for (side, scroll) in diff.scrolls.enumerated() {
        let documentBounds = scroll.documentView!.bounds
        let lastPoint = NSPoint(
          x: max(0, documentBounds.width - scroll.contentView.bounds.width),
          y: max(0, documentBounds.height - scroll.contentView.bounds.height))
        for point in [NSPoint.zero, lastPoint] {
          scroll.contentView.scroll(to: point)
          scroll.reflectScrolledClipView(scroll.contentView)
          let vertical = scroll.verticalThumb
          let horizontal = scroll.horizontalThumb
          let verticalRect = scroll.convert(vertical.bounds, from: vertical)
          let horizontalRect = scroll.convert(horizontal.bounds, from: horizontal)
          guard let overlay = vertical.superview,
            let header = (scroll.documentView as? NSTableView)?.headerView?.superview
          else {
            throw GitPierError.invalidInput("Missing native header or scrollbar overlay")
          }
          let codeRect = scroll.convert(overlay.bounds, from: overlay)
          let headerRect = scroll.convert(header.bounds, from: header)
          guard scroll.bounds.contains(verticalRect), scroll.bounds.contains(horizontalRect),
            codeRect.contains(verticalRect), codeRect.contains(horizontalRect),
            verticalRect.intersection(headerRect).height == 0,
            horizontalRect.intersection(headerRect).height == 0,
            vertical.bounds.contains(vertical.knobRect),
            horizontal.bounds.contains(horizontal.knobRect),
            side == 0 ? verticalRect.minX == codeRect.minX : verticalRect.maxX == codeRect.maxX,
            horizontal.knobRect.width == 56,
            size.height > 200
              ? vertical.knobRect.height == 150
              : vertical.knobRect.height < 150 && vertical.knobRect.height < vertical.bounds.height
          else {
            throw GitPierError.invalidInput(
              "Scrollbar crossed its code viewport/header or fixed length changed: size=\(size), side=\(side), code=\(codeRect), header=\(headerRect), vertical=\(verticalRect), horizontal=\(horizontalRect)"
            )
          }
          let knobPoint = NSPoint(x: vertical.knobRect.midX, y: vertical.knobRect.midY)
          let target = view.superview!.convert(knobPoint, from: vertical)
          guard view.hitTest(target) === vertical else {
            throw GitPierError.invalidInput("Clipped scrollbar cannot receive native mouse events")
          }
          let contentPoint = NSPoint(x: codeRect.midX, y: codeRect.midY)
          let contentTarget = view.superview!.convert(contentPoint, from: scroll)
          guard let hit = view.hitTest(contentTarget), hit !== overlay else {
            throw GitPierError.invalidInput("Scrollbar overlay intercepted native code selection")
          }
        }
      }
      if size.height == 360 {
        try capture(view, to: output.appendingPathComponent("diff-fixed-scrollbars-dark.png"))
      } else if size.height == 120 {
        try capture(view, to: output.appendingPathComponent("diff-scrollbars-small-viewport.png"))
      }
    }
    window.appearance = NSAppearance(named: .aqua)
    view.rootView = DiffTable(
      document: document, path: "example.swift", key: "scroll-bounds",
      settings: preferences, dark: false, selectedHunk: 0, indexSide: 0,
      beforeTitle: "Index", afterTitle: "Working Tree")
    try await settle()
    try capture(view, to: output.appendingPathComponent("diff-fixed-scrollbars-light.png"))
    try
      "Fixed 150pt vertical / 56pt horizontal thumbs, Index-left / working-tree-right placement, header exclusion, viewport clipping, scroll endpoints, compact-window resizing, native thumb hit testing and code-selection pass-through passed.\n"
      .write(
        to: output.appendingPathComponent("diff-scroll-bounds.txt"), atomically: true,
        encoding: .utf8)
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
