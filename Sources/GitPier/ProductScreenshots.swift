#if DEBUG
import AppKit
import GitPierCore
import SwiftUI

/// Captures existing native views against a marked disposable fixture only.
/// This entry point and all demonstration setup are absent from Release builds.
@MainActor enum ProductScreenshots {
  static func run() -> Never {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    Task {
      do {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--output"), args.count > index + 1 else {
          throw GitPierError.invalidInput("A screenshot output directory is required")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
          .resolvingSymlinksInPath()
        let temporaryRoot = URL(fileURLWithPath:
          ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp")
          .resolvingSymlinksInPath()
        let marker = root.appendingPathComponent(".gitpier-product-fixture")
        let parentMatches = root.deletingLastPathComponent().path == temporaryRoot.path
        let markerMatches = (try? String(contentsOf: marker, encoding: .utf8))
          == "GitPier product fixture\n"
        let configurationMatches = ProcessInfo.processInfo.environment["GITPIER_WORKSPACE_FILE"]
          .map { path in
            let url = URL(fileURLWithPath: path)
            return url.lastPathComponent == "workspace.json"
              && url.deletingLastPathComponent().resolvingSymlinksInPath().path == root.path
              && !FileManager.default.fileExists(atPath: url.path)
          } ?? false
        let shellPath = ProcessInfo.processInfo.environment["ZDOTDIR"].map {
          URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let shellMatches = shellPath == root.appendingPathComponent("shell").standardizedFileURL.path
        guard parentMatches, markerMatches, configurationMatches, shellMatches,
          root.lastPathComponent.hasPrefix("GitPier-product.")
        else {
          throw GitPierError.invalidInput(
            "Screenshots require the isolated product fixture script "
            + "(temporary parent: \(parentMatches), marker: \(markerMatches), "
            + "configuration: \(configurationMatches), shell: \(shellMatches))")
        }
        let output = URL(fileURLWithPath: args[index + 1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var configuration = WorkspaceConfiguration()
        configuration.settings.appearance = .dark
        configuration.settings.language = .english
        configuration.settings.loginShell = false
        configuration.settings.terminalFont = "Menlo"
        configuration.settings.terminalFontSize = 14
        configuration.settings.diffFont = "Menlo"
        configuration.settings.diffFontSize = 14
        configuration.settings.completionNotifications = false
        for name in ["sample-app", "example-api", "demo-dashboard", "sample-library"] {
          let repository = root.appendingPathComponent(name).resolvingSymlinksInPath()
          guard repository.deletingLastPathComponent().path == root.path,
            FileManager.default.fileExists(atPath: repository.appendingPathComponent(".git").path)
          else { throw GitPierError.invalidInput("Missing demonstration repository") }
          // Real relative repository paths keep machine-specific locations out of the UI.
          var record = RepositoryRecord(path: name, name: name)
          record.group = "Demo Projects"
          record.favorite = name == "sample-app"
          record.layout.changesWidth = 340
          record.layout.messageHeight = 225
          record.layout.terminalHeight = 230
          record.draft = "feat: improve repository navigation\n\nKeep project selection clear and make refresh feedback easier to read."
          configuration.repositories.append(record)
        }
        try ConfigurationStore(url: root.appendingPathComponent("workspace.json")).save(configuration)
        let store = AppStore.shared
        for record in store.repositories { await store.models[record.id]?.activate() }
        guard let record = store.repositories.first, let model = store.models[record.id],
          store.models.values.allSatisfy({ $0.available }), store.error == nil
        else { throw GitPierError.invalidInput("Demonstration repositories could not be loaded") }
        store.select(record.id)
        model.expandedDirectories = ["Sources"]
        guard let file = model.status.files.first(where: { $0.path == "Sources/RepositoryView.swift" })
        else { throw GitPierError.invalidInput("Missing demonstration changes") }
        model.select(file, permanent: true)
        model.toggleIncluded(model.status.files.filter {
          ["Sources/RepositoryView.swift", "Sources/NewFeature.swift"].contains($0.path)
        })
        try await UIAcceptance.waitFor { !model.refreshing && !model.diffLoading }
        let host = NSHostingView(rootView:
          RootView().environmentObject(store).modifier(AppAppearance(store: store)))
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        host.autoresizingMask = [.width, .height]
        let window = NSWindow(contentRect: host.frame,
          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "GitPier"
        window.contentView = host
        window.setContentSize(host.frame.size)
        window.setFrameOrigin(NSPoint(x: -2000, y: -2000))
        window.orderFront(nil)
        window.appearance = NSAppearance(named: .darkAqua)
        model.terminal.add(settings: store.settings)
        guard let session = model.terminal.sessions.first else {
          throw GitPierError.invalidInput("Demonstration shell did not start")
        }
        var terminalOutput = Data()
        session.view.acceptanceOutput = { terminalOutput.append($0) }
        var layout = model.panels.layout
        layout.terminalVisible = true
        model.editLayout(layout)
        try await UIAcceptance.settle()
        session.view.send(txt: "clear; git status --short; git branch --show-current\n")
        try await UIAcceptance.waitFor {
          String(decoding: terminalOutput, as: UTF8.self).contains("NewFeature.swift")
        }
        try await UIAcceptance.settle()
        try UIAcceptance.capture(host, to: output.appendingPathComponent("commit-workspace.png"))
        layout.terminalVisible = false
        model.editLayout(layout)
        try await UIAcceptance.settle()
        try UIAcceptance.capture(host, to: output.appendingPathComponent("diff-viewer.png"))
        model.terminal.add(settings: store.settings)
        model.terminal.selectedID = session.id
        layout.terminalVisible = true
        layout.terminalHeight = 420
        model.editLayout(layout)
        terminalOutput.removeAll()
        session.view.send(txt: "clear; git status --short; git branch --show-current; git log --oneline -4\n")
        try await UIAcceptance.waitFor {
          String(decoding: terminalOutput, as: UTF8.self).contains("docs: update installation guide")
        }
        try await UIAcceptance.settle()
        try UIAcceptance.capture(host, to: output.appendingPathComponent("integrated-terminal.png"))
        store.showDashboard = true
        try await UIAcceptance.settle()
        try UIAcceptance.capture(host, to: output.appendingPathComponent("repository-dashboard.png"))
        session.view.acceptanceOutput = nil
        store.shutdown()
        print("Captured four native product screenshots from isolated demonstration repositories")
        exit(0)
      } catch {
        FileHandle.standardError.write(Data("Product capture failed: \(error.localizedDescription)\n".utf8))
        exit(1)
      }
    }
    NSApp.run()
    exit(1)
  }
}
#endif
