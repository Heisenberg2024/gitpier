import GitPierCore
import UserNotifications

enum CompletionNotifications {
  static func request(id: UUID, kind: WorkflowOperationKind, result: OperationResult,
    operation: String, repository: String, localCommit: String? = nil, settings: AppSettings,
    foreground: Bool) -> UNNotificationRequest? {
    guard settings.completionNotifications, !foreground, kind != .automaticFetch, result != .running else { return nil }
    let chinese = settings.language == .simplifiedChinese
    let outcome: String
    switch result {
    case .running: return nil
    case .succeeded: outcome = chinese ? "已完成" : "Completed"
    case .failed, .needsAttention, .cancelled, .resultUnknown:
      if localCommit != nil && (kind == .commitAndPush || kind == .mergeAndPush) {
        switch result {
        case .resultUnknown: outcome = chinese ? "本地提交已保存，推送结果未知" : "Local commit saved; Push result unknown"
        case .failed: outcome = chinese ? "本地提交已保存，推送失败" : "Local commit saved; Push failed"
        case .cancelled: outcome = chinese ? "本地提交已保存，后续操作已取消" : "Local commit saved; remaining work cancelled"
        default: outcome = chinese ? "本地提交已保存，需要处理" : "Local commit saved; needs attention"
        }
      } else {
        switch result {
        case .resultUnknown: outcome = chinese ? "结果未知" : "Result unknown"
        case .failed: outcome = chinese ? "失败" : "Failed"
        case .cancelled: outcome = chinese ? "已取消" : "Cancelled"
        default: outcome = chinese ? "需要处理" : "Needs attention"
        }
      }
    }
    let content = UNMutableNotificationContent()
    content.title = "GitPier"
    content.subtitle = "\(operation) · \(outcome)"
    // System banners can appear on a locked screen. Keep command output in Operations Center.
    content.body = repository + (localCommit.map { " · \($0.prefix(8))" } ?? "")
    content.sound = settings.completionNotificationSound ? .default : nil
    return UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil)
  }
}
