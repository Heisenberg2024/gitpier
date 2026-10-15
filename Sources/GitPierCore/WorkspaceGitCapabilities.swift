import Foundation

/// Old Git ignores GIT_NO_LAZY_FETCH. Refuse partial-clone workspace reads there,
/// without changing the owner's config or restricting ordinary repositories.
actor WorkspaceGitCapabilities {
  static let shared = WorkspaceGitCapabilities()
  private var tasks: [String: Task<Bool, Error>] = [:]
  func supportsLocalPartialClone(executable: String, query: @escaping @Sendable () async throws -> String) async throws -> Bool {
    let attributes = try? FileManager.default.attributesOfItem(atPath: executable)
    let key = executable + ":\(attributes?[.systemFileNumber] ?? ""):\(attributes?[.modificationDate] ?? "")"
    if let task = tasks[key] { return try await task.value }
    let task = Task {
      let text = try await query()
      let parts = text.split(separator: " ")
      guard parts.count >= 3 else { return false }
      let numbers = parts[2].split(separator: ".")
      guard numbers.count >= 2, let major = Int(numbers[0]), let minor = Int(numbers[1]) else { return false }
      return major > 2 || major == 2 && minor >= 43
    }
    tasks[key] = task
    do { return try await task.value } catch { tasks[key] = nil; throw error }
  }
}
