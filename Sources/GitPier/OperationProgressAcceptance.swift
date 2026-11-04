#if DEBUG
import AppKit
import GitPierCore
import SwiftUI

extension UIAcceptance {
  /// Native geometry catches both segmented controls and state-dependent footer movement.
  static func verifyOperationProgress(store: AppStore, model: RepositoryModel, window: NSWindow, output: URL) async throws {
    guard let host = window.contentView,
      URL(fileURLWithPath: model.record.path).deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui.")
    else { throw GitPierError.invalidInput("Progress acceptance requires the disposable workspace") }
    var settings = store.settings
    settings.automaticFetch = false; settings.automaticRefresh = false; settings.completionNotifications = false
    store.updateSettings(settings); store.workspace.shutdown()
    NSApp.setActivationPolicy(.regular)
    window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    var observations: [String] = []
    defer {
      try? observations.joined(separator: "\n").write(to: output.appendingPathComponent("indicator-frames.txt"), atomically: true, encoding: .utf8)
      model.busy = false; model.refreshing = false; store.cloning = false
    }
    func bars(_ content: NSView) -> [NSView] {
      descendants(content).filter { $0 is OperationProgressTrackView || ($0 as? NSProgressIndicator)?.style == .bar }
    }
    func elementFrame(_ id: String, in content: NSView) throws -> NSRect {
      guard let element = assistantFind(content, id: id), element.responds(to: NSSelectorFromString("accessibilityFrame")),
        let rect = element.value(forKey: "accessibilityFrame") as? NSValue else {
        throw GitPierError.invalidInput("Missing footer geometry: " + id)
      }
      return content.convert(window.convertFromScreen(rect.rectValue), from: nil)
    }
    func fillLayer(_ bar: OperationProgressTrackView) throws -> CALayer {
      guard let track = bar.layer?.sublayers?.first(where: { $0.name == "operation.track" }),
        let fill = track.sublayers?.first(where: { $0.name == "operation.fill" }) else {
        throw GitPierError.invalidInput("Missing rendered operation track")
      }
      return fill
    }
    @discardableResult func check(_ name: String, in content: NSView, matches expected: NSRect? = nil,
      value: Double? = nil, indeterminate: Bool = false, width: CGFloat? = 100) async throws -> NSRect {
      try await settle()
      let indicators = bars(content)
      try await captureHostingWindow(window, to: output.appendingPathComponent(name + ".png"))
      guard indicators.count == 1, let indicator = indicators.first else {
        try workflowAccessibilityText(content).write(to: output.appendingPathComponent(name + "-accessibility.txt"), atomically: true, encoding: .utf8)
        throw GitPierError.invalidInput("\(name): expected one native progress bar, got \(indicators.count)")
      }
      let frame = indicator.convert(indicator.bounds, to: content)
      let isIndeterminate = (indicator as? NSProgressIndicator)?.isIndeterminate
        ?? (indicator as? OperationProgressTrackView)?.isIndeterminate ?? false
      let actualValue = (indicator as? NSProgressIndicator)?.doubleValue
        ?? (indicator as? OperationProgressTrackView)?.doubleValue ?? 0
      observations.append("\(name): \(NSStringFromRect(frame)); indeterminate=\(isIndeterminate); value=\(actualValue)")
      let expectedWidth = expected?.width ?? width
      guard abs(frame.height - 12) < 0.5,
        expectedWidth.map({ abs(frame.width - $0) < 0.5 }) ?? (frame.width >= 100 && frame.width < 210) else {
        throw GitPierError.invalidInput("\(name): unexpected native progress size: \(NSStringFromRect(frame))")
      }
      if let expected {
        guard abs(frame.minX - expected.minX) < 0.5, abs(frame.minY - expected.minY) < 0.5,
          abs(frame.width - expected.width) < 0.5, abs(frame.height - expected.height) < 0.5 else {
          throw GitPierError.invalidInput("\(name): progress moved or resized: \(NSStringFromRect(expected)) → \(NSStringFromRect(frame))")
        }
      }
      guard isIndeterminate == indeterminate else {
        throw GitPierError.invalidInput("\(name): unexpected progress animation state")
      }
      if let value, abs(actualValue - value) > 0.001 {
        throw GitPierError.invalidInput("\(name): expected progress \(value), got \(actualValue)")
      }
      if let value {
        guard let measured = indicator as? OperationProgressTrackView else {
          throw GitPierError.invalidInput("Measured progress changed its existing renderer")
        }
        let fill = try fillLayer(measured)
        let rendered = fill.presentation() ?? fill
        guard abs(rendered.bounds.width - value * frame.width) < 0.75,
          abs(rendered.frame.minX) < 0.5, fill.animation(forKey: "bounce") == nil else {
          throw GitPierError.invalidInput("\(name): rendered fill does not match the measured left-to-right progress")
        }
      }
      return frame
    }
    func checkCompletedRefresh(_ name: String, summaryX: CGFloat) async throws {
      try await settle()
      try await captureHostingWindow(window, to: output.appendingPathComponent(name + ".png"))
      guard model.activity.state?.presentation == .waiting, model.activity.state?.result == .succeeded,
        bars(host).isEmpty else {
        throw GitPierError.invalidInput("Completed repository refresh must hide its progress track while retaining its summary")
      }
      let summary = try elementFrame("gitpier.operation.summary", in: host)
      guard abs(summary.minX - summaryX) < 0.5 else {
        throw GitPierError.invalidInput("Hiding completed refresh progress collapsed its reserved slot")
      }
      observations.append("\(name): no progress control; summary=\(NSStringFromRect(summary))")
    }
    for (language, appearance, size, suffix) in [
      (AppLanguage.english, AppearanceMode.light, NSSize(width: 1440, height: 900), "en-light-wide"),
      (.simplifiedChinese, .dark, NSSize(width: 960, height: 640), "zh-dark-compact")
    ] {
      settings.language = language; settings.appearance = appearance; store.updateSettings(settings)
      window.setContentSize(size); window.center()
      store.showDashboard = false; model.setPage("commit")
      try await settle()
      try await waitFor { !model.refreshing && !model.diffLoading }
      model.refreshing = true
      let refresh = model.activity.begin(store.text("Refreshing", "刷新仓库"), cancellable: false,
        observed: false, presentation: .waiting)
      let fixed = try await check("refresh-running-" + suffix, in: host, indeterminate: true,
        width: size.width > 1000 ? 210 : nil)
      guard bars(host).first is NSProgressIndicator else {
        throw GitPierError.invalidInput("Refresh must use the v2.0.0 NSProgressIndicator animation")
      }
      let statusFrame = try elementFrame("gitpier.repository.status", in: host)
      let countsFrame = try elementFrame("gitpier.repository.change-counts", in: host)
      let summaryFrame = try elementFrame("gitpier.operation.summary", in: host)
      observations.append("footer-\(suffix): status=\(NSStringFromRect(statusFrame)); counts=\(NSStringFromRect(countsFrame))")
      guard abs(fixed.minX - statusFrame.minX - 222) < 1,
        countsFrame.minX >= statusFrame.minX - 0.5, countsFrame.minX <= statusFrame.minX + 12.5 else {
        throw GitPierError.invalidInput("Footer must retain left counts and the fixed 222 pt progress anchor")
      }
      if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let bar = bars(host).first {
        var samples = Set<Data>()
        for index in 0..<5 {
          try await Task.sleep(for: .milliseconds(180))
          let capture = output.appendingPathComponent("refresh-native-\(index)-\(suffix).png")
          try await captureHostingWindow(window, to: capture)
          guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: capture)), let cg = bitmap.cgImage else {
            throw GitPierError.invalidInput("Missing native refresh screenshot")
          }
          let base = bar.convert(bar.bounds, to: nil)
          let scale = CGFloat(bitmap.pixelsWide) / window.frame.width
          let crop = CGRect(x: base.minX * scale, y: CGFloat(bitmap.pixelsHigh) - base.maxY * scale,
            width: base.width * scale, height: base.height * scale).integral
          guard let clipped = cg.cropping(to: crop) else { throw GitPierError.invalidInput("Invalid native animation bounds") }
          let pixels = NSBitmapImageRep(cgImage: clipped)
          guard let bytes = pixels.bitmapData else { throw GitPierError.invalidInput("Missing native animation pixels") }
          let data = Data(bytes: bytes, count: pixels.bytesPerRow * pixels.pixelsHigh)
          samples.insert(data)
          try data.write(to: output.appendingPathComponent("native-track-\(index)-\(suffix).rgba"))
        }
        guard samples.count >= 3 else {
          throw GitPierError.invalidInput("v2.0.0 refresh animation did not change its rendered pixels")
        }
        observations.append("native-animation-\(suffix): \(samples.count) distinct rendered tracks")
      }
      model.refreshing = false
      model.activity.finish(.succeeded, ticket: refresh)
      try await checkCompletedRefresh("refresh-completed-" + suffix, summaryX: summaryFrame.minX)
      // Exercise the actual refresh entry point too; a synthetic waiting operation alone can miss a caller regression.
      await model.refresh()
      try await checkCompletedRefresh("real-refresh-completed-" + suffix, summaryX: summaryFrame.minX)
      model.busy = true
      let push = model.activity.begin(store.text("Commit & Push", "提交并推送"), kind: .commitAndPush, observed: false)
      try await check("commit-preparing-" + suffix, in: host, matches: fixed, value: 0)
      model.activity.advance(store.text("Committing", "正在提交"), cancellable: false, step: .commit)
      try await check("committing-" + suffix, in: host, matches: fixed, value: 0)
      model.activity.advance(store.text("Checking the reviewed remote and branch before pushing the saved local commit", "推送已保存的本地提交之前，检查已审查的远端和目标分支"), cancellable: true, step: .pushTarget)
      try await check("push-target-" + suffix, in: host, matches: fixed, value: 0)
      model.activity.advance(store.text("Pushing", "正在推送"), step: .push)
      let receive = model.activity.receiver()
      receive(.init(phase: .counting, fraction: 1))
      try await check("push-counting-" + suffix, in: host, matches: fixed, value: 0)
      receive(.init(phase: .compressing, fraction: 1))
      try await check("push-compressing-" + suffix, in: host, matches: fixed, value: 0)
      receive(.init(phase: .writing, fraction: 0.42))
      try await check("push-transfer-" + suffix, in: host, matches: fixed, value: 0.42)
      receive(.init(phase: .writing, fraction: 1))
      try await check("push-transfer-finished-" + suffix, in: host, matches: fixed, value: 0.99)
      receive(.init(phase: .resolving, fraction: 0.05))
      try await check("push-resolving-" + suffix, in: host, matches: fixed, value: 0.99)
      guard model.activity.state?.result == .running else { throw GitPierError.invalidInput("Transfer completion incorrectly completed the operation") }
      model.activity.advance(store.text("Refreshing", "刷新仓库"), cancellable: false, phase: .refreshing)
      try await check("push-refreshing-" + suffix, in: host, matches: fixed, value: 0.99)
      model.busy = false
      model.activity.finish(.succeeded, ticket: push)
      try await check("push-completed-" + suffix, in: host, matches: fixed, value: 1)
      for (name, result) in [("failed", OperationResult.failed), ("cancelled", .cancelled), ("attention", .needsAttention), ("unknown", .resultUnknown)] {
        let ticket = model.activity.begin(store.text("Push", "推送"), kind: .push, observed: false)
        model.activity.markExecuting()
        model.activity.finish(result, ticket: ticket)
        try await check(name + "-" + suffix, in: host, matches: fixed, value: 0)
      }
      let label = workflowAccessibilityText(host)
      guard !label.contains("Step "), !label.contains("第 1/"), !label.contains("steps completed") else {
        throw GitPierError.invalidInput("Progress still exposes a segmented step counter")
      }
      let originalLayout = model.panels.layout
      var movedLayout = originalLayout; movedLayout.changesWidth += 40
      model.editLayout(movedLayout, persist: false)
      try await check("pane-moved-" + suffix, in: host, matches: fixed, value: 0)
      let movedCounts = try elementFrame("gitpier.repository.change-counts", in: host)
      guard abs(movedCounts.minX - countsFrame.minX) < 0.5 else {
        throw GitPierError.invalidInput("Dragging the pane divider moved the changes/staging information")
      }
      model.editLayout(originalLayout, persist: false)
      try await check("pane-restored-" + suffix, in: host, matches: fixed, value: 0)
      window.setContentSize(NSSize(width: size.width > 1000 ? 960 : 1440, height: size.height))
      let resized = try await check("window-resized-" + suffix, in: host, value: 0,
        width: size.width > 1000 ? nil : 210)
      let resizedFooter = try elementFrame("gitpier.repository.status", in: host)
      guard abs(resized.minX - resizedFooter.minX - 222) < 1,
        (size.width > 1000 ? resized.width < fixed.width : resized.width > fixed.width) else {
        throw GitPierError.invalidInput("Window resizing must adapt only the progress length, retaining its fixed footer anchor")
      }
      window.setContentSize(size)
      try await check("window-restored-" + suffix, in: host, matches: fixed, value: 0)

      store.showDashboard = true; store.cloning = true
      let clone = store.cloneActivity.begin(store.text("Cloning", "正在克隆"), kind: .clone, observed: false)
      let dashboard = try await check("dashboard-running-" + suffix, in: host, value: 0)
      store.cloning = false; store.cloneActivity.finish(.succeeded, ticket: clone)
      try await check("dashboard-completed-" + suffix, in: host, matches: dashboard, value: 1)
    }
    // A separate native root exercises the Clone sheet's fixed row and the Center's non-workflow bar.
    let originalContent = window.contentView
    defer { window.contentView = originalContent }
    let cloneHost = NSHostingView(rootView: CloneSheet().environmentObject(store).modifier(AppAppearance(store: store)))
    cloneHost.sizingOptions = []; window.contentView = cloneHost
    window.setContentSize(NSSize(width: 560, height: 340)); window.center()
    store.cloning = true
    let clone = store.cloneActivity.begin("Clone", kind: .clone, observed: false)
    let cloneFrame = try await check("clone-running", in: cloneHost, value: 0)
    store.cloning = false; store.cloneActivity.finish(.succeeded, ticket: clone)
    try await check("clone-completed", in: cloneHost, matches: cloneFrame, value: 1)

    let center = OperationsCenter()
    let operation = OperationProgress(); operation.center = center
    let task = operation.begin("Fetch", kind: .fetch)
    operation.markExecuting()
    let centerHost = NSHostingView(rootView: OperationsCenterView(center: center).environmentObject(store))
    centerHost.sizingOptions = []; window.contentView = centerHost
    window.setContentSize(NSSize(width: 760, height: 580)); window.center()
    try await check("center-workflow", in: centerHost, value: 0)
    operation.finish(.succeeded, ticket: task)
    try await check("center-completed", in: centerHost, value: 1)
    let plainCenter = OperationsCenter(), plainID = UUID()
    plainCenter.begin(id: plainID, kind: .batchFetch, repositoryID: nil, state: .running)
    let plainHost = NSHostingView(rootView: OperationsCenterView(center: plainCenter).environmentObject(store))
    plainHost.sizingOptions = []; window.contentView = plainHost
    let batchFrame = try await check("center-batch", in: plainHost, value: 0)
    plainCenter.update(plainID, transfer: .init(phase: .receiving, fraction: 0.64))
    try await check("center-batch-transfer", in: plainHost, matches: batchFrame, value: 0.64)
    plainCenter.update(plainID, state: .succeeded)
    try await check("center-batch-completed", in: plainHost, value: 1)

    let background = model.activity.begin("Background Fetch", kind: .fetch)
    model.activity.markExecuting()
    let empty = OperationProgress()
    let backgroundHost = NSHostingView(rootView: HStack {
      Spacer()
      OperationProgressView(progress: empty) {}
    }.environmentObject(store).modifier(AppAppearance(store: store)))
    backgroundHost.sizingOptions = []; window.contentView = backgroundHost
    window.setContentSize(NSSize(width: 760, height: 80)); window.center()
    let backgroundFrame = try await check("other-repository", in: backgroundHost, value: 0)
    model.activity.receiver()(.init(phase: .receiving, fraction: 0.37))
    try await check("other-repository-transfer", in: backgroundHost, matches: backgroundFrame, value: 0.37)
    guard let entry = assistantFind(backgroundHost, id: "gitpier.operation.background") else {
      throw GitPierError.invalidInput("Background progress lost its Operations Center action")
    }
    try assistantPress(entry)
    guard store.showOperationsCenter else { throw GitPierError.invalidInput("Background progress did not open Operations Center") }
    store.showOperationsCenter = false
    model.activity.finish(.succeeded, ticket: background)

    let staticHost = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 12))
    let staticBar = OperationProgressTrackView(frame: staticHost.bounds)
    staticHost.addSubview(staticBar); window.contentView = staticHost
    window.setContentSize(staticHost.bounds.size)
    staticBar.update(value: nil, animates: false, increasedContrast: false, label: "Static waiting progress")
    try await check("reduce-motion-waiting", in: staticHost, indeterminate: true)
    guard try fillLayer(staticBar).animation(forKey: "bounce") == nil else {
      throw GitPierError.invalidInput("Static waiting progress did not disable its bounce")
    }
    try Data("v2.0.0 native waiting animation, hidden completed refresh, unchanged measured fill, responsive length and fixed status-bar anchor passed.\n".utf8)
      .write(to: output.appendingPathComponent("progress-results.txt"))
  }
}
#endif
