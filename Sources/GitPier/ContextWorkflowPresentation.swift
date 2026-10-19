import GitPierCore
import SwiftUI

/// One presentation vocabulary for the toolbar, popover heading and VoiceOver.
/// No Git reads, animation state or extra refresh path lives here.
@MainActor struct ContextWorkflowPresentation {
  let advice: ContextWorkflowAdvice
  let input: ContextWorkflowInput
  let store: AppStore
  var hasNotice = false
  var level: ContextWorkflowAdvice.DisplayLevel {
    let value = advice.displayLevel(in: input)
    return hasNotice && value.rawValue < ContextWorkflowAdvice.DisplayLevel.attention.rawValue ? .attention : value
  }
  var symbol: String {
    switch level {
    case .normal: return "lightbulb"
    case .suggestion: return "lightbulb.fill"
    case .attention: return "exclamationmark.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .blocked: return "exclamationmark.octagon.fill"
    }
  }
  var color: Color {
    switch level {
    case .normal: return .secondary
    case .suggestion: return .accentColor
    case .attention, .warning: return .orange
    case .blocked: return .red
    }
  }
  var emphasized: Bool { level.rawValue >= ContextWorkflowAdvice.DisplayLevel.attention.rawValue }
  var updating: Bool { [.busy, .refreshing, .checkingRemote].contains(advice.kind) }
  var operationName: String {
    switch input.status.operation {
    case .merge: return store.text("Merge", "合并")
    case .rebase: return store.text("Rebase", "变基")
    case .cherryPick: return store.text("Cherry-pick", "拣选")
    case .revert: return store.text("Revert", "还原")
    case nil: return "Git"
    }
  }
  var label: String {
    switch level {
    case .normal: return store.text("No priority suggestion", "无优先建议")
    case .suggestion: return store.text("Suggestion available", "有操作建议")
    case .attention: return store.text("Needs attention", "需要注意")
    case .warning: return store.text("Warning", "操作风险")
    case .blocked: return input.status.files.contains(where: \.isConflicted) ? store.text("Conflict", "冲突") : store.text("Blocked", "操作待完成")
    }
  }
  var summary: String {
    if updating && emphasized {
      return store.text("Updating analysis; last local snapshot: ", "正在更新分析；上次本地快照：") + label
    }
    if hasNotice && level != .blocked { return store.text("Review the updated context before continuing", "继续前请审查更新后的上下文") }
    switch advice.kind {
    case .conflicts:
      let count = input.status.files.filter(\.isConflicted).count
      return store.text("\(operationName): \(count) conflicted paths; resolve before continuing", "\(operationName)：\(count) 个冲突路径，需先解决")
    case .unfinishedOperation:
      return store.text("\(operationName) in progress; finish or abort first", "\(operationName) 进行中，需先完成或中止")
    case .incoming:
      return store.text("Branch is \(input.status.behind) commits behind its tracking snapshot", "分支落后跟踪快照 \(input.status.behind) 个提交")
    case .diverged:
      return store.text("Tracking snapshot: \(input.status.ahead) ahead, \(input.status.behind) behind; compare histories", "跟踪快照：领先 \(input.status.ahead)、落后 \(input.status.behind)，需先比较分叉")
    case .verifyRemote:
      return store.text("Review Fetch; tracking snapshot ↑\(input.status.ahead) ↓\(input.status.behind) is unconfirmed or outdated", "请审查获取；跟踪快照 ↑\(input.status.ahead) ↓\(input.status.behind) 尚未确认或已过期")
    case .detached: return store.text("Detached HEAD; retain work on a branch", "游离 HEAD，请用分支保留工作")
    case .preserveBeforeSync: return store.text("Preserve local changes before integrating incoming commits", "整合传入提交前需保留本地修改")
    case .authentication: return store.text("Fetch needs repository authentication", "获取需要核查仓库认证")
    case .fetchFailed: return store.text("The last Fetch failed; review before retrying", "上次获取失败，请先审查再重试")
    case .missingUpstream: return store.text("Upstream has no comparable local tracking commit", "上游缺少可比较的本地跟踪提交")
    case .unavailable: return store.text("Working tree is unavailable", "工作树不可用")
    case .stale: return store.text("Local changes detected; refresh analysis", "检测到外部变化，请刷新分析")
    case .busy: return store.text("Git operation in progress", "Git 操作进行中")
    case .refreshing, .checkingRemote: return store.text("Updating workflow analysis", "正在更新工作流分析")
    default:
      return level == .normal ? store.text("No priority workflow action needed", "当前无需优先处理工作流操作")
        : store.text("\(advice.visibleActions(in: input).count) actions available for review", "有 \(advice.visibleActions(in: input).count) 项操作可审查")
    }
  }
}
