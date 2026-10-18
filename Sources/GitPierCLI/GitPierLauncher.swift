import AppKit
import Foundation
import Darwin
import GitPierCore

@main struct GitPierLauncher {
  @MainActor static func main() async {
    do {
      let command = try GitPierCLICommand.parse(Array(CommandLine.arguments.dropFirst()),
        directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
      switch command {
      case .help:
        print("""
        GitPier command line tool — navigation only
        Usage: gitpier --help | --version
               gitpier open [path] [--page commit|history|branches|worktrees|compare]
        Opens a local repository or worktree in the GitPier app selected during installation.
        No Git write is executed. Shell configuration and credentials are never changed.
        """)
      case .version:
        if let app = try? selectedApplication(), let bundle = Bundle(url: app),
          let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
          print("gitpier " + version + " (navigation protocol 1)")
        } else { print("gitpier CLI 1 (navigation protocol 1)") }
      case .open(let request):
        try request.validateAccess()
        // Validate with System Git before waking the GUI; the receiver independently repeats this.
        let git = GitService(root: request.directory)
        _ = try await git.validate()
        _ = try await git.commonDirectory()
        let app = try selectedApplication()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        let running: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
          NSWorkspace.shared.open([request.url], withApplicationAt: app, configuration: configuration) { running, error in
            if let error { continuation.resume(throwing: error) }
            else if let running { continuation.resume(returning: running) }
            else { continuation.resume(throwing: NavigationRequest.invalid) }
          }
        }
        // Activate the exact instance returned by Launch Services, including an
        // already-running selected copy. Window readiness is handled by the app.
        _ = running.activate(options: [.activateIgnoringOtherApps])
      }
    } catch {
      // Do not echo raw arguments, URLs, paths, Git stderr or credentials.
      FileHandle.standardError.write(Data("gitpier: Invalid request, inaccessible repository, or selected app unavailable. See --help; reinstall from GitPier Settings if needed.\n".utf8))
      exit(1)
    }
  }
  static func selectedApplication() throws -> URL {
    var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(getpid(), &pathBuffer, UInt32(pathBuffer.count)) > 0 else { throw NavigationRequest.invalid }
    let executable = URL(fileURLWithPath: String(cString: pathBuffer))
    let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if executable.deletingLastPathComponent().lastPathComponent == "Helpers", app.pathExtension == "app",
      let bundle = Bundle(url: app), let id = bundle.bundleIdentifier,
      id == "com.heisenberg2024.gitpier" || id.hasPrefix("com.heisenberg2024.gitpier.") { return app }
    return try CLIToolInstallation(directory: executable.deletingLastPathComponent()).receipt().application()
  }
}
