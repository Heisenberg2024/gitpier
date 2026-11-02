import AppKit
import GitPierCore
import SwiftUI

struct OperationRecoveryControls: View {
  let record: WorkflowOperationRecord
  @ObservedObject var center: OperationsCenter
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      if let branch = record.localBranch {
        Text(branch + (record.pushCheckpoint.map { " → " + $0.remote + " / " + String($0.remoteReference.dropFirst(11)) } ?? ""))
          .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
          .accessibilityLabel(store.text("Branch and Push target", "分支及推送目标"))
      }
      if record.localCommitUnverified {
        Text(store.text("Inspect History or Reflog before committing again. The local result has not been confirmed.", "再次提交前请检查历史或引用日志，本地结果尚未确认。"))
          .font(.caption).foregroundStyle(.secondary)
      }
      HStack(spacing: 10) {
        if let hash = record.localCommit {
          Button(store.text("Copy Commit Hash", "复制提交 Hash")) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(hash, forType: .string)
          }.help(hash).accessibilityIdentifier("gitpier.operation.copy." + record.id.uuidString)
        }
        if record.localCommit != nil || record.localCommitUnverified {
          Button(store.text("Open History", "打开历史")) {
            dismiss(); Task { await store.openOperationHistory(record) }
          }.accessibilityIdentifier("gitpier.operation.history." + record.id.uuidString)
        }
        if record.pushCheckpoint != nil, record.state == .resultUnknown {
          Button(store.text(center.verifyingPush.contains(record.id) ? "Checking…" : "Verify Remote", center.verifyingPush.contains(record.id) ? "核实中…" : "核实远端")) {
            Task { await center.verifyPush(record, store: store) }
          }.disabled(center.verifyingPush.contains(record.id))
            .accessibilityIdentifier("gitpier.operation.verify." + record.id.uuidString)
          Button(store.text("Review Retry Push…", "审查重试推送…")) {
            dismiss(); Task {
              await store.openOperation(record)
              if let checkpoint = record.pushCheckpoint, let model = store.current,
                model.record.id == record.repositoryID { model.confirmCheckpointPush(checkpoint) }
            }
          }.disabled(center.verifyingPush.contains(record.id))
            .accessibilityIdentifier("gitpier.operation.retry." + record.id.uuidString)
        }
      }.controlSize(.small)
      if let date = record.verifiedAt {
        HStack(spacing: 4) {
          Label(store.text("Remote reference verified", "远端引用已核实"), systemImage: "checkmark.shield")
          Text(date, style: .time)
        }.font(.caption).foregroundStyle(.green)
      } else if record.state == .resultUnknown, record.kind != .review, record.pushCheckpoint == nil {
        Text(store.text("No single Push target was captured. Inspect the original remote configuration and server history before retrying.", "未捕获单一推送目标。重试前请检查原远端配置和服务器历史。"))
          .font(.caption).foregroundStyle(.secondary)
      }
      if let message = center.verificationMessages[record.id] {
        Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          .accessibilityIdentifier("gitpier.operation.verification." + record.id.uuidString)
      }
    }
  }
}

func operationKindSymbol(_ kind: WorkflowOperationKind) -> String {
  switch kind {
  case .commit, .commitAndPush: "checkmark.circle"
  case .push: "arrow.up.circle"
  case .fetch, .batchFetch, .automaticFetch: "arrow.down.circle"
  case .pull: "arrow.down.to.line"
  case .merge, .mergeAndPush: "arrow.triangle.merge"
  case .rebase: "arrow.triangle.branch"
  case .clone: "square.and.arrow.down"
  case .createWorktree, .removeWorktree: "square.stack.3d.up"
  case .review, .reviewTask: "text.bubble"
  case .agentSession: "terminal"
  case .createTask, .openTask, .archiveTask: "checklist"
  case .git: "gearshape"
  }
}
