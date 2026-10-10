import Darwin
import Foundation
import GitPierCore

enum SSHLauncher {
  /// Respects SSH host aliases but binds the selected identity to the profile's resolved host.
  static func run() -> Never {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--ssh-profile"), args.count > index + 2,
      let id = UUID(uuidString: args[index + 1]),
      let configuration = try? ConfigurationStore(
        url: ProcessInfo.processInfo.environment["GITPIER_CONFIGURATION"].map {
          URL(fileURLWithPath: $0)
        }
      ).load(),
      let profile = configuration.credentials.first(where: { $0.id == id && $0.kind == .ssh })
    else { exit(1) }
    let sshArgs = Array(args.dropFirst(index + 2))
    var target: String?
    var cursor = 0
    let parameterOptions: Set<String> = [
      "-p", "-o", "-F", "-i", "-l", "-J", "-S", "-b", "-c", "-D", "-E", "-e", "-L", "-m", "-O",
      "-Q", "-R", "-W", "-w",
    ]
    while cursor < sshArgs.count {
      let value = sshArgs[cursor]
      if value == "--" {
        cursor += 1
        if cursor < sshArgs.count { target = sshArgs[cursor] }
        break
      }
      if !value.hasPrefix("-") {
        target = value
        break
      }
      cursor += parameterOptions.contains(value) ? 2 : 1
    }
    guard let target else { exit(1) }
    let inspection = Process()
    inspection.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    inspection.arguments = ["-G", target]
    let out = Pipe()
    let err = Pipe()
    inspection.standardOutput = out
    inspection.standardError = err
    do { try inspection.run() } catch { exit(1) }
    let configurationData = out.fileHandleForReading.readDataToEndOfFile()
    inspection.waitUntilExit()
    let host = String(decoding: configurationData, as: UTF8.self).split(separator: "\n").first {
      $0.hasPrefix("hostname ")
    }.map { String($0.dropFirst(9)).lowercased() }
    // An explicit profile is never silently applied to a different server.
    guard inspection.terminationStatus == 0,
      host == profile.host.lowercased().split(separator: ":").first.map(String.init)
    else {
      FileHandle.standardError.write(
        Data("GitPier: SSH profile host does not match the resolved remote host.\n".utf8))
      exit(1)
    }
    let invocation =
      ["/usr/bin/ssh", "-i", profile.identityPath, "-o", "IdentitiesOnly=yes"] + sshArgs
    let pointers = invocation.map { strdup($0) } + [nil]
    pointers.withUnsafeBufferPointer { _ = execv("/usr/bin/ssh", $0.baseAddress!) }
    for pointer in pointers { free(pointer) }
    exit(1)
  }
}
