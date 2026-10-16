import Foundation
import Darwin

/// Capability describes a local credential source, never proof that a server accepted it.
public enum BackgroundAuthenticationState: String, Codable, Sendable {
  case ready, requiresForegroundAuthorization, credentialMissing, unsupportedHelper
  case sshAgentUnavailable, sshIdentityNotLoaded, accessDenied, serverRejected
  case hostVerificationFailed, networkFailure, configurationInvalid
}

public struct AuthenticationFailure: Error, LocalizedError, Sendable {
  public let state: BackgroundAuthenticationState
  public var source: String?
  public init(_ state: BackgroundAuthenticationState, source: String? = nil) { self.state = state; self.source = source }
  public var helperDiagnostic: String { "GitPier authentication: " + state.rawValue }
  public var errorDescription: String? {
    switch state {
    case .ready: return "Background credentials are available."
    case .requiresForegroundAuthorization: return "Background Keychain access needs foreground authorization."
    case .credentialMissing: return "No matching saved credential is available."
    case .unsupportedHelper: return "The configured credential helper has no supported noninteractive interface."
    case .sshAgentUnavailable: return "SSH Agent is unavailable. Prepare SSH authentication."
    case .sshIdentityNotLoaded: return "The configured SSH identity is not loaded. Prepare SSH authentication."
    case .accessDenied: return "Credential authorization was denied or cancelled."
    case .serverRejected: return "The server rejected the saved credential or SSH identity."
    case .hostVerificationFailed: return "SSH host verification failed. Review known hosts before retrying."
    case .networkFailure: return "The remote network check failed."
    case .configurationInvalid: return "Authentication configuration changed or is unsupported. Review the remote settings."
    }
  }
  public static func classify(_ error: Error) -> BackgroundAuthenticationState {
    if let failure = error as? AuthenticationFailure { return failure.state }
    let message = error.localizedDescription.lowercased()
    // Helpers return only a fixed marker. Never persist a helper's credential protocol output.
    for state in [BackgroundAuthenticationState.requiresForegroundAuthorization, .accessDenied, .credentialMissing] {
      if message.contains("gitpier authentication: " + state.rawValue.lowercased()) { return state }
    }
    if message.contains("host key verification failed") || message.contains("remote host identification has changed") { return .hostVerificationFailed }
    if ["authentication failed", "invalid username or token", "permission denied (publickey", "http basic: access denied"].contains(where: message.contains) { return .serverRejected }
    if ["could not read username", "could not read password", "terminal prompts disabled", "could not get password", "unable to get password"].contains(where: message.contains) { return .credentialMissing }
    if message.contains("keychain lookup failed") { return .requiresForegroundAuthorization }
    if message.contains("ssh identity is not readable") || message.contains("authentication could not be configured") { return .configurationInvalid }
    return .networkFailure
  }
  public var blocksAutomaticRetry: Bool {
    state != .networkFailure && state != .hostVerificationFailed
  }
}

public struct BackgroundAuthentication: Equatable, Sendable {
  public static func transport(for url: String) -> String {
    if url.hasPrefix("https://") { return "HTTPS" }
    if url.hasPrefix("http://") { return "HTTP" }
    if url.hasPrefix("ssh://") || !url.contains("://") && !url.hasPrefix("/") && url.contains(":") { return "SSH" }
    if url.hasPrefix("git://") { return "Git" }
    if let scheme = URLComponents(string: url)?.scheme { return scheme.uppercased() }
    return "Local"
  }
  public var transport: String
  public var source: String
  public var state: BackgroundAuthenticationState
  public var remote: String
  public var verifiedByFetch = false
  public var identityFiles: [String] = []
  public init(transport: String, source: String, state: BackgroundAuthenticationState, remote: String) {
    self.transport = transport; self.source = source; self.state = state; self.remote = remote
  }
}

/// Delegate configured helpers as native Git does; literal recognition is only for display.
public enum SafeCredentialHelper {
  /// Git's documented helper command transformation, with only get delegated.
  /// Preserve shell snippets, options, partial responses and native helper identities.
  public static func getOnly(_ value: String, source: String) -> String {
    let command = value.hasPrefix("!") ? String(value.dropFirst())
      : value.hasPrefix("/") ? value : "git credential-" + value
    return "!f() { if test \"$1\" = get; then if test \"$GITPIER_AUTH_PROBE\" = 1; then echo gitpier-source:" + source
      + " >&2; fi; /bin/sh -c " + InputValidation.shellQuote(command + " get") + "; fi; }; f"
  }
  /// gh setup-git installs a shell-form helper. Accept exactly that command, never
  /// a general shell fragment or extra flags/subcommands.
  public static func githubCLI(_ value: String) -> String? {
    let shellForm = value.hasPrefix("!")
    guard let parts = words(shellForm ? String(value.dropFirst()) : value), parts.count == 3,
      parts[1] == "auth", parts[2] == "git-credential",
      parts[0] == "gh" && shellForm || parts[0].hasPrefix("/") && URL(fileURLWithPath: parts[0]).lastPathComponent == "gh"
    else { return nil }
    return parts[0]
  }
  public static func words(_ value: String) -> [String]? {
    var words: [String] = [], word = "", quote: Character?, escaped = false, started = false
    for ch in value {
      if escaped { word.append(ch); escaped = false; started = true; continue }
      if ch == "\\" && quote != "'" { escaped = true; continue }
      if let current = quote {
        if ch == current { quote = nil }
        else {
          if current == "\"" && (ch == "$" || ch == "`") { return nil }
          word.append(ch)
        }
      } else if ch == "'" || ch == "\"" { quote = ch; started = true }
      else if ch == " " || ch == "\t" {
        if started { words.append(word); word = ""; started = false }
      } else {
        if "\n\r\0;$`|&<>()".contains(ch) { return nil }
        word.append(ch); started = true
      }
    }
    guard quote == nil, !escaped else { return nil }
    if started { words.append(word) }
    return words
  }
  public static func supported(_ value: String) -> [String]? {
    guard let words = words(value), let name = words.first, ["store", "cache", "osxkeychain"].contains(name) else { return nil }
    if name == "osxkeychain" { return words.count == 1 ? words : nil }
    let options = name == "store" ? ["--file"] : ["--socket", "--timeout"]
    var index = 1
    while index < words.count {
      let word = words[index]
      if options.contains(word) {
        index += 1
        guard index < words.count, !words[index].isEmpty, !words[index].hasPrefix("-") else { return nil }
      } else if !options.contains(where: { word.hasPrefix($0 + "=") && word.count > $0.count + 1 }) { return nil }
      index += 1
    }
    return words
  }
}

public struct SSHAuthenticationConfiguration: Sendable {
  public var values: [String: [String]] = [:]
  public init(_ output: String) {
    for line in output.split(separator: "\n") {
      let pair = line.split(separator: " ", maxSplits: 1)
      if pair.count == 2 { values[String(pair[0]), default: []].append(String(pair[1])) }
    }
  }
  public func first(_ key: String) -> String? { values[key]?.first }
  public var identityFiles: [String] { values["identityfile"] ?? [] }
  public func agentSocket(environment: [String: String]) -> String? {
    guard let socket = first("identityagent"), socket != "SSH_AUTH_SOCK" else { return environment["SSH_AUTH_SOCK"] }
    if socket == "none" { return nil }
    return (socket as NSString).expandingTildeInPath
  }
}

/// `ssh -G` evaluates Match exec, even in BatchMode. Check all static Includes before
/// launching it; dynamic includes and external conditions have no silent contract.
public enum SSHConfigurationSafety {
  private static var refusal: AuthenticationFailure { AuthenticationFailure(.configurationInvalid, source: "sshConfig") }
  public static func validate(userConfiguration: String? = nil,
    systemConfiguration: String? = "/etc/ssh/ssh_config", userDirectory: String? = nil) throws {
    let userDirectory = userDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh").path
    var visited: Set<String> = []
    func withoutComment(_ line: String) -> String {
      var result = "", quote: Character?, escaped = false
      for ch in line {
        if escaped { result.append(ch); escaped = false; continue }
        if ch == "\\" { result.append(ch); escaped = true; continue }
        if ch == "\"" || ch == "'" { if quote == ch { quote = nil } else if quote == nil { quote = ch } }
        if ch == "#", quote == nil { break }
        result.append(ch)
      }
      return result.trimmingCharacters(in: .whitespaces)
    }
    func expand(_ pattern: String, base: String) throws -> [String] {
      guard !pattern.contains("$"), !pattern.contains("%"), !pattern.contains("\0") else { throw refusal }
      let expanded = (pattern as NSString).expandingTildeInPath
      let absolute = expanded.hasPrefix("/") ? expanded : base + "/" + expanded
      var matches = glob_t()
      let status = absolute.withCString { Darwin.glob($0, 0, nil, &matches) }
      defer { globfree(&matches) }
      if status == GLOB_NOMATCH { return [] }
      guard status == 0, matches.gl_pathc <= 128 else { throw refusal }
      return (0..<Int(matches.gl_pathc)).compactMap { index in
        matches.gl_pathv[index].map { String(cString: $0) }
      }
    }
    func visit(_ file: String, base: String, depth: Int) throws {
      guard FileManager.default.fileExists(atPath: file) else { return }
      let path = URL(fileURLWithPath: file).resolvingSymlinksInPath().path
      if visited.contains(path) { return }
      let attributes = try FileManager.default.attributesOfItem(atPath: path)
      guard depth < 16, visited.count < 128, attributes[.type] as? FileAttributeType == .typeRegular,
        let size = attributes[.size] as? NSNumber,
        size.intValue <= 1024 * 1024 else { throw refusal }
      visited.insert(path)
      let text: String
      do { text = try String(contentsOfFile: path, encoding: .utf8) }
      catch { throw refusal }
      for raw in text.split(separator: "\n") {
        let line = withoutComment(String(raw))
        guard !line.isEmpty else { continue }
        guard !line.hasSuffix("\\") else { throw refusal }
        let key = String(line.prefix { !$0.isWhitespace && $0 != "=" }).lowercased()
        let external = ["proxycommand", "localcommand", "knownhostscommand", "pkcs11provider", "securitykeyprovider"].contains(key)
        guard key == "include" || key == "match" || external else { continue }
        let rest = line.dropFirst(key.count).drop { $0.isWhitespace || $0 == "=" }
        guard let words = SafeCredentialHelper.words(String(rest)) else { throw refusal }
        if external {
          guard words == ["none"] || key == "securitykeyprovider" && words == ["internal"] else { throw refusal }
          continue
        }
        if key == "include" {
          for word in words { for included in try expand(word, base: base) { try visit(included, base: base, depth: depth + 1) } }
        } else {
          var index = 0
          while index < words.count {
            let condition = words[index].trimmingCharacters(in: CharacterSet(charactersIn: "!")).lowercased()
            if ["all", "canonical", "final"].contains(condition) { index += 1; continue }
            guard ["host", "originalhost", "user", "localuser", "command", "tagged", "localnetwork", "version"].contains(condition), index + 1 < words.count else {
              throw refusal
            }
            index += 2
          }
        }
      }
    }
    do {
      try visit(userConfiguration ?? userDirectory + "/config", base: userDirectory, depth: 0)
      if let systemConfiguration { try visit(systemConfiguration, base: "/etc/ssh", depth: 0) }
    } catch { throw refusal }
  }
}
