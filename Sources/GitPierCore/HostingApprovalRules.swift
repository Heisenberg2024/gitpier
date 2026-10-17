import Foundation

public enum HostingApprovalRulesAvailability: String, Sendable {
  case available, permissionRequired, unavailable
}

/// One GitLab rule. Its approval state is the server's rule-level decision, not the
/// current user's approval, reviewer assignment, or permission to merge the MR.
public struct HostingApprovalRule: Identifiable, Sendable, Equatable {
  public let id: String
  public let name: String
  public let ruleType: String
  public let approvalsRequired: Int
  public let approved: Bool
  public let approvedBy: [HostingUser]?
  public let eligibleApprovers: [HostingUser]?
  public let containsHiddenGroups: Bool?
  public let overridden: Bool?
  public init(id: String, name: String, ruleType: String, approvalsRequired: Int, approved: Bool,
    approvedBy: [HostingUser]? = nil, eligibleApprovers: [HostingUser]? = nil, containsHiddenGroups: Bool? = nil, overridden: Bool? = nil) {
    self.id = id; self.name = name; self.ruleType = ruleType; self.approvalsRequired = approvalsRequired; self.approved = approved
    self.approvedBy = approvedBy; self.eligibleApprovers = eligibleApprovers; self.containsHiddenGroups = containsHiddenGroups; self.overridden = overridden
  }
}

public struct HostingApprovalRuleState: Sendable, Equatable {
  public let availability: HostingApprovalRulesAvailability
  public let rules: [HostingApprovalRule]
  public let rulesOverwritten: Bool?
  public init(availability: HostingApprovalRulesAvailability, rules: [HostingApprovalRule] = [], rulesOverwritten: Bool? = nil) {
    self.availability = availability; self.rules = rules; self.rulesOverwritten = rulesOverwritten
  }
}

extension HostingAPIClient {
  /// Independent, read-only and on demand. GitLab's approval_state endpoint may be
  /// unavailable by edition, version or visibility; that is never an empty success.
  public func approvalRules(_ binding: RepositoryHostingBinding, number: Int, account: HostingAccount,
    token: HostingToken) async throws -> HostingApprovalRuleState {
    try account.validateCredentialContext()
    guard binding.accountID == account.id, number > 0 else { throw HostingReviewError.targetChanged }
    guard account.instance.provider == .gitlab else { throw HostingError.unsupported }
    let path = try repositoryPath(binding.repository, provider: .gitlab) + "/merge_requests/\(number)/approval_state"
    let value: HostingJSON
    do { (value, _) = try await json(account, token: token, path: path) }
    catch HostingError.permissionRequired { return HostingApprovalRuleState(availability: .permissionRequired) }
    catch HostingError.notFound { return HostingApprovalRuleState(availability: .unavailable) }
    guard case .array = value["rules"] else { throw HostingError.invalidResponse }
    guard value["rules"].array.count <= 500 else { throw HostingError.responseTooLarge }
    var rules: [HostingApprovalRule] = [], ids: Set<String> = []
    for rule in value["rules"].array {
      guard case .integer(let id) = rule["id"], id > 0,
        case .integer(let required) = rule["approvals_required"], required >= 0, required <= Int64(Int.max),
        case .bool(let approved) = rule["approved"],
        case .string(let name) = rule["name"], !name.isEmpty, name.utf8.count <= 1024,
        case .string(let type) = rule["rule_type"], !type.isEmpty, type.utf8.count <= 128,
        ids.insert(String(id)).inserted else { throw HostingError.invalidResponse }
      rules.append(HostingApprovalRule(id: String(id), name: name, ruleType: type,
        approvalsRequired: Int(required), approved: approved,
        approvedBy: try Self.approvalRuleUsers(rule["approved_by"]), eligibleApprovers: try Self.approvalRuleUsers(rule["eligible_approvers"]),
        containsHiddenGroups: try Self.approvalRuleBoolean(rule["contains_hidden_groups"]), overridden: try Self.approvalRuleBoolean(rule["overridden"])))
    }
    return HostingApprovalRuleState(availability: .available, rules: rules,
      rulesOverwritten: try Self.approvalRuleBoolean(value["approval_rules_overwritten"]))
  }
  private static func approvalRuleBoolean(_ value: HostingJSON) throws -> Bool? {
    if case .null = value { return nil }
    guard case .bool(let value) = value else { throw HostingError.invalidResponse }; return value
  }
  private static func approvalRuleUsers(_ value: HostingJSON) throws -> [HostingUser]? {
    if case .null = value { return nil }
    guard case .array = value else { throw HostingError.invalidResponse }
    guard value.array.count <= 1000 else { throw HostingError.responseTooLarge }
    var users: [HostingUser] = [], ids: Set<String> = []
    for user in value.array {
      guard case .integer(let id) = user["id"], id > 0, case .string(let login) = user["username"], !login.isEmpty else { throw HostingError.invalidResponse }
      if ids.insert(String(id)).inserted { users.append(HostingUser(stableID: String(id), login: login, name: user["name"].string)) }
    }
    return users
  }
}
