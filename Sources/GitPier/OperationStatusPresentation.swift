import GitPierCore
import SwiftUI

/// Operation outcomes share symbols across the progress strip and Operations Center.
/// Branch synchronization and merge ancestry keep their independent presentation.
struct OperationStatusPresentation {
  let state: WorkflowOperationState
  init(_ state: WorkflowOperationState) { self.state = state }
  init(_ result: OperationResult) {
    switch result {
    case .running: state = .running
    case .succeeded: state = .succeeded
    case .needsAttention: state = .needsAttention
    case .failed: state = .failed
    case .cancelled: state = .cancelled
    }
  }
  var symbol: String {
    switch state {
    case .queued: "clock"
    case .running: "arrow.triangle.2.circlepath"
    case .waitingForUser: "hand.raised"
    case .succeeded: "checkmark.circle.fill"
    case .failed: "xmark.octagon.fill"
    case .cancelled: "stop.circle"
    case .needsAttention: "exclamationmark.triangle.fill"
    case .resultUnknown: "questionmark.circle"
    case .agentExited: "terminal"
    }
  }
  var color: Color {
    switch state {
    case .succeeded: .green
    case .failed: .red
    case .running: .blue
    case .waitingForUser, .needsAttention: .orange
    case .queued, .cancelled, .resultUnknown: .secondary
    case .agentExited: .primary
    }
  }
}

struct OperationDiagnosticView: View {
  @EnvironmentObject var store: AppStore
  let detail: String
  var body: some View {
    DisclosureGroup(store.text("Details", "详情")) {
      ScrollView([.horizontal, .vertical]) {
        Text(detail).font(uiFont(size: 11, design: .monospaced)).textSelection(.enabled).padding(8)
      }.frame(height: min(160, max(52, CGFloat(detail.components(separatedBy: "\n").count) * 15)))
    }.font(.caption)
  }
}
