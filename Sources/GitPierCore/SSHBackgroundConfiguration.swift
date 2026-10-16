import Foundation

/// OpenSSH forwards -F to ProxyJump's ssh child. Put noninteractive options before
/// Includes so the same restrictions cover both the destination and jump hosts.
public struct SSHBackgroundConfiguration: Sendable {
  public let directory: URL
  public var path: String { directory.appendingPathComponent("config").path }
  public init(userConfiguration: String? = nil) throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-ssh-background-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let user = userConfiguration ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config").path
    // OpenSSH config uses double-quoted paths; no shell expansion or command evaluation.
    let quoted = user.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let config = """
    Host *
      BatchMode yes
      StrictHostKeyChecking yes
      NumberOfPasswordPrompts 0
      IgnoreUnknown UseKeychain
      UseKeychain no
    Include "\(quoted)"
    Include /etc/ssh/ssh_config

    """
    do {
      try Data(config.utf8).write(to: URL(fileURLWithPath: path))
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    } catch { remove(); throw error }
  }
  public func remove() { try? FileManager.default.removeItem(at: directory) }
}
