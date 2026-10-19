import AppKit
import GitPierCore
import SwiftUI

/// Only the native popover's lifetime belongs here. The existing repository
/// model still owns analysis, target review, navigation and confirmed writes.
@MainActor private final class WorkflowPopoverState: ObservableObject {
  @Published var presented = false
  weak var window: NSWindow?
  weak var popoverWindow: NSWindow?
  weak var popover: NSPopover?
  weak var pendingPopover: NSPopover?
  var returnKeyboardFocus = false
  private var handoffID = UUID()
  var handoff: Task<Void, Never>?
  func configurePopover() {
    guard presented, let pendingPopover,
      pendingPopover.contentViewController?.view.window === popoverWindow else { return }
    popover = pendingPopover
    pendingPopover.behavior = .transient
  }
  func close(cancel: Bool = false) {
    presented = false
    returnKeyboardFocus = false
    if cancel { handoffID = UUID(); handoff?.cancel(); handoff = nil }
  }
  func perform(_ action: ContextWorkflowAction, input: ContextWorkflowInput, model: RepositoryModel) {
    close()
    let id = UUID(); handoffID = id
    handoff = Task { [weak self, weak model] in
      guard let model, !Task.isCancelled else { return }
      await model.prepareWorkflow(action, displayed: input)
      if self?.handoffID == id { self?.handoff = nil }
    }
  }
}

struct ContextWorkflowButton: View {
  @ObservedObject var model: RepositoryModel
  @ObservedObject var workspace: WorkspaceModel
  @EnvironmentObject var store: AppStore
  @Environment(\.colorSchemeContrast) private var contrast
  @FocusState private var keyboardFocused: Bool
  @StateObject private var presentation = WorkflowPopoverState()
  private var target: String {
    model.record.id.uuidString + "\0" + model.record.path + "\0" + model.status.branch
      + (model.status.branch == "(detached)" ? (model.status.head ?? "") : "")
  }
  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { timeline in
      let input = model.workflowInput(now: timeline.date)
      let advice = ContextWorkflowAdvice.evaluate(input)
      let status = ContextWorkflowPresentation(advice: advice, input: input, store: store, hasNotice: model.workflowMessage != nil)
      Button(action: togglePresentation) {
        Image(systemName: status.symbol)
          .font(.system(size: 12, weight: status.emphasized ? .semibold : .regular))
          .frame(width: 30, height: 23)
          .background(RoundedRectangle(cornerRadius: 6).fill(status.color.opacity(status.emphasized ? (contrast == .increased ? 0.2 : 0.11) : 0)))
          .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(status.color.opacity(status.emphasized ? (contrast == .increased ? 0.8 : 0.3) : 0), lineWidth: 1))
          .overlay(alignment: .topTrailing) {
            if status.level == .warning || status.level == .blocked {
              Circle().fill(status.color).frame(width: 4, height: 4).padding(2)
            }
          }
          .contentShape(Rectangle())
      }
      .buttonStyle(.workspace).focusable().focused($keyboardFocused).focusEffectDisabled()
      .onKeyPress(keys: [.space, .return], phases: .down) { press in
        guard press.modifiers.isEmpty else { return .ignored }
        togglePresentation()
        return .handled
      }
      .foregroundStyle(status.color)
      .help(presentation.presented ? "" : status.summary)
      .accessibilityLabel(store.text("Context Workflow", "上下文工作流"))
      .accessibilityValue(status.label + ": " + status.summary)
      .accessibilityIdentifier("gitpier.workflow.open")
      .popover(isPresented: $presentation.presented, arrowEdge: .bottom) {
        ContextWorkflowView(model: model, workspace: workspace,
          onAction: { action, input in presentation.perform(action, input: input, model: model) },
          onAbort: { operation, input in
            guard store.current === model, !store.showDashboard, !model.busy,
              model.status == input.status, !model.hasExternalChanges else { return }
            presentation.close()
            model.perform([operation == .cherryPick ? "cherry-pick" : operation.rawValue, "--abort"],
              confirmation: store.text("Abort the operation and restore its starting state?", "中止操作并恢复起始状态？"))
          })
          .environmentObject(store).modifier(AppPopoverAppearance(store: store))
          .background(WorkflowWindowAnchor(presentation: presentation, popover: true).allowsHitTesting(false).accessibilityHidden(true))
          .onExitCommand(perform: dismissAndFocus)
      }
      .background(WorkflowWindowAnchor(presentation: presentation).allowsHitTesting(false).accessibilityHidden(true))
    }
    .fixedSize()
    .onExitCommand(perform: dismissAndFocus)
    .onChange(of: target) { _, _ in presentation.close(cancel: true); model.workflowMessage = nil }
    .onChange(of: store.selectedID) { _, _ in presentation.close(cancel: true) }
    .onChange(of: store.showDashboard) { _, _ in presentation.close(cancel: true) }
    .onReceive(NotificationCenter.default.publisher(for: NSPopover.didShowNotification)) { note in
      if presentation.presented, let popover = note.object as? NSPopover {
        // The native show notification and the SwiftUI window anchor can
        // arrive in either order. Both paths complete the same association.
        presentation.pendingPopover = popover
        presentation.configurePopover()
        DispatchQueue.main.async { presentation.configurePopover() }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { note in
      guard presentation.returnKeyboardFocus,
        let popover = note.object as? NSPopover, popover === presentation.popover else { return }
      // AppKit finishes its key-window teardown after posting didClose. Restore
      // focus on the next main-loop turn, and only for this explicit dismissal.
      DispatchQueue.main.async {
        guard presentation.returnKeyboardFocus, !presentation.presented, NSApp.isActive,
          store.current === model, !store.showDashboard else { return }
        presentation.returnKeyboardFocus = false
        if let window = presentation.window, window.isVisible {
          window.makeKey()
          keyboardFocused = true
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in presentation.close(cancel: true) }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { note in
      if let window = note.object as? NSWindow,
        store.managedWindows.contains(ObjectIdentifier(window)), window !== presentation.window {
        presentation.close(cancel: true)
      }
    }
    .onDisappear { presentation.close(cancel: true) }
  }
  private func togglePresentation() {
    if presentation.presented { dismissAndFocus() } else { presentation.presented = true }
  }
  private func dismissAndFocus() {
    guard presentation.presented else { return }
    keyboardFocused = false
    // Arm before changing the binding: dismissal can synchronously notify.
    presentation.returnKeyboardFocus = true
    presentation.presented = false
  }

}

private struct WorkflowWindowAnchor: NSViewRepresentable {
  let presentation: WorkflowPopoverState
  var popover = false
  func makeNSView(context: Context) -> Anchor { Anchor(presentation, popover: popover) }
  func updateNSView(_ view: Anchor, context: Context) {
    view.presentation = presentation
    view.popover = popover
    view.recordWindow()
  }
  final class Anchor: NSView {
    weak var presentation: WorkflowPopoverState?
    var popover: Bool
    init(_ presentation: WorkflowPopoverState, popover: Bool) { self.presentation = presentation; self.popover = popover; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      recordWindow()
    }
    func recordWindow() {
      // SwiftUI may replace the zero-size probe during a render. A detached
      // old probe must not erase the window just recorded by its replacement.
      guard let window else { return }
      if popover {
        presentation?.popoverWindow = window
        presentation?.configurePopover()
      } else { presentation?.window = window }
    }
  }
}
