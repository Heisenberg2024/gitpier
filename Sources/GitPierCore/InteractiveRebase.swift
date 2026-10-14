import Foundation

public enum RebaseAction: String, CaseIterable, Codable, Sendable {
  case pick, reword, squash, fixup, drop
}

public struct RebaseStep: Identifiable, Sendable {
  public var id: String { commit.hash }
  public let commit: CommitRecord
  public var action: RebaseAction
  public var message: String
  public init(commit: CommitRecord, action: RebaseAction = .pick, message: String? = nil) {
    self.commit = commit; self.action = action
    self.message = message ?? commit.subject + (commit.body.isEmpty ? "" : "\n\n" + commit.body)
  }
}

public struct InteractiveRebaseCandidate: Sendable {
  public let review: GitOperationReview
  public let upstream: String
  public let commits: [CommitRecord]
  /// Local remote-tracking refs are evidence, never proof that other commits are private.
  public let sharedCommits: Set<String>
}

public struct InteractiveRebasePlan: Sendable {
  public let candidate: InteractiveRebaseCandidate
  public var steps: [RebaseStep]
  public init(candidate: InteractiveRebaseCandidate, steps: [RebaseStep]? = nil) {
    self.candidate = candidate; self.steps = steps ?? candidate.commits.map { RebaseStep(commit: $0) }
  }
  public func validate() throws {
    let original = candidate.commits.map(\.hash)
    guard !original.isEmpty, original.count <= 200, steps.count == original.count,
      Set(steps.map(\.id)) == Set(original), Set(original).count == original.count else {
      throw GitPierError.invalidInput("The rebase plan must include each reviewed commit exactly once.")
    }
    var preceding = false
    for step in steps {
      guard [40, 64].contains(step.id.count), step.id.allSatisfy(\.isHexDigit) else {
        throw GitPierError.invalidInput("Invalid rebase commit.")
      }
      if step.action == .squash || step.action == .fixup {
        guard preceding else { throw GitPierError.invalidInput("Squash and Fixup require a preceding kept commit.") }
      } else if step.action != .drop { preceding = true }
      if step.action == .reword || step.action == .squash {
        guard !step.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !step.message.utf8.contains(0), step.message.utf8.count <= 64 * 1024 else {
          throw GitPierError.invalidInput("Enter a nonempty commit message within 64 KiB.")
        }
      }
    }
  }
  public func todo() throws -> String {
    try validate()
    return steps.map { $0.action.rawValue + " " + $0.id }.joined(separator: "\n") + "\n"
  }
  /// Git edits a squash chain's message at the final squash/fixup, including trailing fixups.
  func messages() throws -> [String: String] {
    try validate()
    let kept = steps.filter { $0.action != .drop }
    var result: [String: String] = [:]
    var groupEnd: String?
    var combined: String?
    for step in kept {
      if step.action != .squash && step.action != .fixup {
        if let groupEnd, let combined { result[groupEnd] = combined }
        combined = nil
        if step.action == .reword { result[step.id] = step.message }
      } else if step.action == .squash { combined = step.message }
      groupEnd = step.id
    }
    if let groupEnd, let combined { result[groupEnd] = combined }
    return result
  }
}

public enum RebaseControl: String, Sendable { case `continue`, skip, abort }
public struct RebaseState: Sendable {
  public let review: GitOperationReview
  public let workingFingerprint: Data
  public let branch: String
  public let originalHead: String
  public let upstream: String
  public let done: String
  public let todo: String
  public let message: String
  public let current: Int
  public let total: Int
  public let interactive: Bool
}

/// Only data persists in Git metadata. Fixed helper scripts are recreated for each invocation.
struct RebaseMessagePlan: Codable {
  let format: String
  let branch: String
  let head: String
  let upstream: String
  let messages: [String: String]
  init(_ plan: InteractiveRebasePlan) throws {
    format = "GitPierInteractiveRebase1"; branch = "refs/heads/" + plan.candidate.review.branch
    head = plan.candidate.review.head ?? ""; upstream = plan.candidate.upstream
    messages = try plan.messages()
  }
  func validate() throws {
    guard format == "GitPierInteractiveRebase1", messages.count <= 200,
      [head, upstream].allSatisfy({ [40, 64].contains($0.count) && $0.allSatisfy(\.isHexDigit) }),
      messages.allSatisfy({ [40, 64].contains($0.key.count) && $0.key.allSatisfy(\.isHexDigit)
        && $0.value.utf8.count <= 64 * 1024 && !$0.value.utf8.contains(0) }) else {
      throw GitPierError.invalidInput("The saved rebase message plan is invalid. Preserve the Git state and use the terminal to inspect it.")
    }
  }
}

struct RebaseEditorFiles {
  let directory: URL
  let environment: [String: String]
  init(todo: String? = nil, messages: [String: String] = [:], state: URL,
       overrideMessage: String? = nil) throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitPier-rebase-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    do {
      let messagesURL = directory.appendingPathComponent("messages")
      try FileManager.default.createDirectory(at: messagesURL, withIntermediateDirectories: false,
                                             attributes: [.posixPermissions: 0o700])
      for (hash, message) in messages { try Self.write(message, to: messagesURL.appendingPathComponent(hash)) }
      if let overrideMessage { try Self.write(overrideMessage, to: directory.appendingPathComponent("override")) }
      let sequence = directory.appendingPathComponent("sequence.sh")
      let editor = directory.appendingPathComponent("editor.sh")
      if let todo { try Self.write(todo, to: directory.appendingPathComponent("todo")) }
      try Self.write("#!/bin/sh\nset -eu\n/bin/cat \"$GITPIER_REBASE_FILES/todo\" > \"$1\"\n", to: sequence, mode: 0o700)
      try Self.write("""
        #!/bin/sh
        set -eu
        if [ -f "$GITPIER_REBASE_FILES/override" ]; then
          /bin/cat "$GITPIER_REBASE_FILES/override" > "$1"
          /bin/mv "$GITPIER_REBASE_FILES/override" "$GITPIER_REBASE_FILES/used-override"
          exit 0
        fi
        [ -f "$GITPIER_REBASE_STATE/done" ] || exit 0
        object=$(/usr/bin/awk '{ object=$2 } END { print object }' "$GITPIER_REBASE_STATE/done")
        case "$object" in ''|*[!0-9a-fA-F]*) exit 1;; esac
        if [ -f "$GITPIER_REBASE_FILES/messages/$object" ]; then
          /bin/cat "$GITPIER_REBASE_FILES/messages/$object" > "$1"
        fi
        """ + "\n", to: editor, mode: 0o700)
      environment = ["GIT_SEQUENCE_EDITOR": InputValidation.shellQuote(sequence.path),
                     "GIT_EDITOR": InputValidation.shellQuote(editor.path),
                     "GITPIER_REBASE_FILES": directory.path, "GITPIER_REBASE_STATE": state.path]
    } catch { try? FileManager.default.removeItem(at: directory); throw error }
  }
  func remove() { try? FileManager.default.removeItem(at: directory) }
  static func write(_ text: String, to url: URL, mode: Int = 0o600) throws {
    try Data(text.utf8).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
  }
}
