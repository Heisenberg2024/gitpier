import Foundation

public enum ChangeKind: String, Codable, Sendable, CaseIterable {
  case modified, added, deleted, renamed, copied, untracked, conflicted, typeChanged
}

public struct FileChange: Identifiable, Equatable, Sendable {
  public var id: String { path }
  public let path: String
  public let originalPath: String?
  public let index: Character
  public let worktree: Character
  public let submodule: String
  public let kind: ChangeKind
  public var isUntracked: Bool { kind == .untracked }
  public var isConflicted: Bool { kind == .conflicted }
  public var isStaged: Bool { index != "." && index != "?" && !isConflicted }
  public var isUnstaged: Bool { worktree != "." || isUntracked || isConflicted }
  public var isPartial: Bool { isStaged && isUnstaged }
  public var paths: [String] { originalPath.map { [$0, path] } ?? [path] }
  public init(
    path: String, originalPath: String? = nil, index: Character, worktree: Character,
    submodule: String = "N...", kind: ChangeKind
  ) {
    self.path = path
    self.originalPath = originalPath
    self.index = index
    self.worktree = worktree
    self.submodule = submodule
    self.kind = kind
  }
}

public struct RepositoryStatus: Equatable, Sendable {
  public var files: [FileChange] = []
  public var branch = ""
  public var head: String?
  public var upstream: String?
  public var upstreamComparable = false
  public var ahead = 0
  public var behind = 0
  public var operation: GitOperation?
  public var staged: [FileChange] { files.filter(\.isStaged) }
  public var tracked: [FileChange] { files.filter { !$0.isUntracked } }
  public var untracked: [FileChange] { files.filter(\.isUntracked) }
  public init() {}
}

public enum GitOperation: String, Sendable, Codable { case merge, rebase, cherryPick, revert }
public enum DiffComparison: String, CaseIterable, Codable, Sendable { case unstaged, staged }

public struct IndexSnapshot: Equatable, Sendable {
  public let tree: String
  public let head: String?
  public let branch: String
  public let paths: [String]
  public let patch: Data
  public var identity: String { "\(head ?? "unborn"):\(branch):\(tree)" }
}

public struct GitOperationReview: Equatable, Sendable {
  public let head: String?
  public let branch: String
  public let indexFingerprint: Data
  public let operationIdentity: Data
}

public struct ForcePushReview: Sendable {
  public let remote: String
  public let branch: String
  public let localBranch: String
  public let localHead: String
  public let remoteHead: String
  public let destinationIdentity: String
}
public struct RemoteDeletionReview: Sendable {
  public let remote: String
  public let reference: String
  public let expectedHash: String
  public let destinationIdentity: String
}

public struct CommitResult: Sendable {
  public let hash: String
  public let output: String
  public let indexChangedDuringCommit: Bool
}

/// The single current-branch destination actually rejected by Git's porcelain push output.
public struct PushRejection: LocalizedError, Sendable {
  public let localReference: String
  public let localHead: String
  public let remoteURL: String
  public let remoteReference: String
  public let upstreamRemote: String?
  public let diagnostic: String
  public var errorDescription: String? { diagnostic }
}

public enum PushRecoveryPhase: Sendable { case fetching, merging, pushing }

public struct CommitRecord: Identifiable, Sendable {
  public var id: String { hash }
  public let hash: String
  public let parents: [String]
  public let author: String
  public let email: String
  public let date: Date
  public let subject: String
  public let body: String
  public let decorations: String
}

public struct GitBranch: Identifiable, Equatable, Sendable {
  public var id: String { (remote ? "refs/remotes/" : "refs/heads/") + name }
  public let name: String
  public let current: Bool
  public let remote: Bool
  public let upstream: String
  public let tracking: String
  public let hash: String
}

public struct GitRemote: Identifiable, Equatable, Sendable {
  public var id: String { name }
  public let name: String
  public let fetchURL: String
  public let pushURL: String
  public let configuredFetchURLs: [String]
  public let configuredPushURLs: [String]
  public let configurationID: String
}

public struct StashFile: Identifiable, Sendable {
  public var id: String { change.path }
  public let change: FileChange
  public let commit: String
  public let parent: String?
}

public struct GitStash: Identifiable, Equatable, Sendable {
  public var id: String { reference }
  public let reference: String
  public let hash: String
  public let message: String
}

public struct RepositoryRecord: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var path: String
  public var name: String
  public var group: String
  public var favorite: Bool
  public var lastOpened: Date
  public var credentialID: UUID?
  public var useDefaultCredential: Bool
  public var draft: String
  public var layout: PanelLayout
  public init(path: String, name: String? = nil) {
    id = UUID()
    self.path = path
    self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
    group = ""
    favorite = false
    lastOpened = Date()
    credentialID = nil
    useDefaultCredential = false
    draft = ""
    layout = PanelLayout()
  }
}

public struct PanelLayout: Codable, Equatable, Sendable {
  public var changesWidth: Double = 310
  public var messageHeight: Double = 240
  public var terminalHeight: Double = 260
  public var terminalVisible = false
  public var terminalMaximized = false
  public var historyDetailHeight: Double = 320
  public var historyFilesWidth: Double = 280
  public init() {}
  public init(from decoder: Decoder) throws {
    self.init()
    let values = try decoder.container(keyedBy: CodingKeys.self)
    changesWidth = try values.decodeIfPresent(Double.self, forKey: .changesWidth) ?? changesWidth
    messageHeight = try values.decodeIfPresent(Double.self, forKey: .messageHeight) ?? messageHeight
    terminalHeight =
      try values.decodeIfPresent(Double.self, forKey: .terminalHeight) ?? terminalHeight
    terminalVisible =
      try values.decodeIfPresent(Bool.self, forKey: .terminalVisible) ?? terminalVisible
    terminalMaximized =
      try values.decodeIfPresent(Bool.self, forKey: .terminalMaximized) ?? terminalMaximized
    historyDetailHeight =
      try values.decodeIfPresent(Double.self, forKey: .historyDetailHeight) ?? historyDetailHeight
    historyFilesWidth =
      try values.decodeIfPresent(Double.self, forKey: .historyFilesWidth) ?? historyFilesWidth
  }
}

public enum AppearanceMode: String, Codable, CaseIterable, Sendable { case system, dark, light }
public enum AppLanguage: String, Codable, CaseIterable, Sendable { case english, simplifiedChinese }

public struct AppSettings: Codable, Equatable, Sendable {
  public var appearance: AppearanceMode = .system
  public var language: AppLanguage = .english
  public var gitPath = "/usr/bin/git"
  public var shellPath = "/bin/zsh"
  public var loginShell = true
  public var terminalFont = "Menlo"
  public var terminalFontSize: Double = 13
  public var terminalLineSpacing: Double = 1.1
  public var terminalCursor = "blinkBlock"
  public var terminalTheme = "follow"
  public var terminalDirectory = "repository"
  public var terminalCustomDirectory = ""
  public var scrollback = 10000
  public var diffFontSize: Double = 13
  public var diffFont = "Menlo"
  public var wrapDiff = false
  public var showLineNumbers = true
  public var showWhitespace = false
  public var tabSize = 4
  public var ignoreWhitespace = false
  public var unifiedDiff = false
  public var automaticRefresh = false
  public var refreshPolicyVersion = 1
  public var automaticFetch = false
  public var remoteCheckIntervalMinutes = 15
  public var remoteCheckScope = "workspace"
  public var remoteCheckExcludedRepositories: Set<UUID> = []
  public var compactUI = true
  public var uiFont = ""
  public var repositoryFont = ""
  public var repositoryFontSize: Double = 12
  public var coloredFileIcons = true
  public var diffAddedHex = "55B982"
  public var diffRemovedHex = "CF6679"
  public var completionNotifications = false
  public var recentLimit = 20
  public var launchPage = "dashboard"
  public var editorPath = ""
  public var customEditorPaths: [String] = []
  public var pullStrategy = "configured"
  public var defaultCredentialID: UUID?
  public init() {}
  public init(from decoder: Decoder) throws {
    self.init()
    let values = try decoder.container(keyedBy: CodingKeys.self)
    appearance = try values.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? appearance
    language = try values.decodeIfPresent(AppLanguage.self, forKey: .language) ?? language
    gitPath = try values.decodeIfPresent(String.self, forKey: .gitPath) ?? gitPath
    shellPath = try values.decodeIfPresent(String.self, forKey: .shellPath) ?? shellPath
    loginShell = try values.decodeIfPresent(Bool.self, forKey: .loginShell) ?? loginShell
    terminalFont = try values.decodeIfPresent(String.self, forKey: .terminalFont) ?? terminalFont
    terminalFontSize =
      try values.decodeIfPresent(Double.self, forKey: .terminalFontSize) ?? terminalFontSize
    terminalLineSpacing =
      try values.decodeIfPresent(Double.self, forKey: .terminalLineSpacing) ?? terminalLineSpacing
    terminalCursor =
      try values.decodeIfPresent(String.self, forKey: .terminalCursor) ?? terminalCursor
    terminalTheme = try values.decodeIfPresent(String.self, forKey: .terminalTheme) ?? terminalTheme
    terminalDirectory =
      try values.decodeIfPresent(String.self, forKey: .terminalDirectory) ?? terminalDirectory
    terminalCustomDirectory =
      try values.decodeIfPresent(String.self, forKey: .terminalCustomDirectory)
      ?? terminalCustomDirectory
    scrollback = try values.decodeIfPresent(Int.self, forKey: .scrollback) ?? scrollback
    diffFontSize = try values.decodeIfPresent(Double.self, forKey: .diffFontSize) ?? diffFontSize
    diffFont = try values.decodeIfPresent(String.self, forKey: .diffFont) ?? diffFont
    wrapDiff = try values.decodeIfPresent(Bool.self, forKey: .wrapDiff) ?? wrapDiff
    showLineNumbers =
      try values.decodeIfPresent(Bool.self, forKey: .showLineNumbers) ?? showLineNumbers
    showWhitespace =
      try values.decodeIfPresent(Bool.self, forKey: .showWhitespace) ?? showWhitespace
    tabSize = try values.decodeIfPresent(Int.self, forKey: .tabSize) ?? tabSize
    ignoreWhitespace =
      try values.decodeIfPresent(Bool.self, forKey: .ignoreWhitespace) ?? ignoreWhitespace
    unifiedDiff = try values.decodeIfPresent(Bool.self, forKey: .unifiedDiff) ?? unifiedDiff
    // The first release enabled continuous refresh by default. Migrate it to explicit manual refresh.
    if try values.decodeIfPresent(Int.self, forKey: .refreshPolicyVersion) != nil {
      automaticRefresh = try values.decodeIfPresent(Bool.self, forKey: .automaticRefresh) ?? false
    }
    compactUI = try values.decodeIfPresent(Bool.self, forKey: .compactUI) ?? compactUI
    uiFont = try values.decodeIfPresent(String.self, forKey: .uiFont) ?? uiFont
    repositoryFont =
      try values.decodeIfPresent(String.self, forKey: .repositoryFont) ?? repositoryFont
    repositoryFontSize =
      try values.decodeIfPresent(Double.self, forKey: .repositoryFontSize) ?? repositoryFontSize
    coloredFileIcons =
      try values.decodeIfPresent(Bool.self, forKey: .coloredFileIcons) ?? coloredFileIcons
    diffAddedHex = try values.decodeIfPresent(String.self, forKey: .diffAddedHex) ?? diffAddedHex
    diffRemovedHex =
      try values.decodeIfPresent(String.self, forKey: .diffRemovedHex) ?? diffRemovedHex
    completionNotifications =
      try values.decodeIfPresent(Bool.self, forKey: .completionNotifications)
      ?? completionNotifications
    recentLimit = try values.decodeIfPresent(Int.self, forKey: .recentLimit) ?? recentLimit
    launchPage = try values.decodeIfPresent(String.self, forKey: .launchPage) ?? launchPage
    editorPath = try values.decodeIfPresent(String.self, forKey: .editorPath) ?? editorPath
    customEditorPaths = try values.decodeIfPresent([String].self, forKey: .customEditorPaths) ?? []
    pullStrategy = try values.decodeIfPresent(String.self, forKey: .pullStrategy) ?? pullStrategy
    automaticFetch = try values.decodeIfPresent(Bool.self, forKey: .automaticFetch) ?? false
    let minutes = try values.decodeIfPresent(Int.self, forKey: .remoteCheckIntervalMinutes) ?? 15
    remoteCheckIntervalMinutes = RemoteCheckPolicy.intervals.contains(minutes) ? minutes : 15
    let scope = try values.decodeIfPresent(String.self, forKey: .remoteCheckScope) ?? "workspace"
    remoteCheckScope = ["current", "workspace"].contains(scope) ? scope : "current"
    remoteCheckExcludedRepositories = try values.decodeIfPresent(Set<UUID>.self, forKey: .remoteCheckExcludedRepositories) ?? []
    defaultCredentialID = try values.decodeIfPresent(UUID.self, forKey: .defaultCredentialID)
  }
}

public struct CredentialProfile: Codable, Identifiable, Equatable, Sendable {
  public enum Kind: String, Codable, CaseIterable, Sendable { case https, ssh }
  public let id: UUID
  public var name: String
  public var host: String
  public var username: String
  public var kind: Kind
  public var identityPath: String
  public init(
    id: UUID = UUID(), name: String, host: String, username: String = "", kind: Kind = .https,
    identityPath: String = ""
  ) {
    self.id = id
    self.name = name
    self.host = host
    self.username = username
    self.kind = kind
    self.identityPath = identityPath
  }
}

public struct WorkspaceConfiguration: Codable, Sendable {
  public var version = 2
  public var repositories: [RepositoryRecord] = []
  public var ownedWorktrees: [WorktreeOwnership] = []
  public var organizations: [RepositoryOrganization] = []
  public var credentials: [CredentialProfile] = []
  public var settings = AppSettings()
  public var selectedRepository: UUID?
  public init() {}
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    repositories = try values.decodeIfPresent([RepositoryRecord].self, forKey: .repositories) ?? []
    ownedWorktrees = try values.decodeIfPresent([WorktreeOwnership].self, forKey: .ownedWorktrees) ?? []
    organizations =
      try values.decodeIfPresent([RepositoryOrganization].self, forKey: .organizations) ?? []
    credentials = try values.decodeIfPresent([CredentialProfile].self, forKey: .credentials) ?? []
    settings = try values.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
    selectedRepository = try values.decodeIfPresent(UUID.self, forKey: .selectedRepository)
    reconcileOrganizations()
  }
}

public enum GitPierError: LocalizedError, Sendable {
  case command(String, Int32, String)
  case invalidRepository(String)
  case unsafePath(String)
  case invalidInput(String)
  case indexChanged
  case conflictChanged
  case emptyIndex
  case outputLimit
  case timeout
  case configuration(String)
  public var errorDescription: String? {
    switch self {
    case .command(let command, let code, let detail):
      return "\(command) failed (\(code))\n\(detail)"
    case .invalidRepository(let path): return "Not a working Git repository: \(path)"
    case .unsafePath(let path): return "Unsafe repository path: \(path)"
    case .invalidInput(let message), .configuration(let message): return message
    case .indexChanged:
      return
        "The Index or HEAD changed outside this view. Review the refreshed staged changes before committing."
    case .conflictChanged:
      return
        "The conflict, working file or Git operation changed outside this editor. Reload and review before saving."
    case .emptyIndex: return "There are no staged changes to commit."
    case .outputLimit:
      return "Output exceeds the safe loading limit. Open this file in an external editor."
    case .timeout: return "The command timed out."
    }
  }
}
