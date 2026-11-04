import AppKit
import QuartzCore
import SwiftUI

struct NativeOperationBar: NSViewRepresentable {
  @EnvironmentObject var store: AppStore
  let value: Double?
  let animates: Bool
  let increasedContrast: Bool
  func makeNSView(context: Context) -> OperationProgressTrackView {
    OperationProgressTrackView(frame: NSRect(x: 0, y: 0, width: 100, height: 12))
  }
  func updateNSView(_ view: OperationProgressTrackView, context: Context) {
    view.update(value: value, animates: animates, increasedContrast: increasedContrast,
      label: store.text("Git operation progress", "Git 操作进度"))
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: OperationProgressTrackView, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 100, height: 12)
  }
}

/// One AppKit track, with either a reversing accent fill or a measured fill anchored at the left.
final class OperationProgressTrackView: NSView {
  private let track = CALayer()
  private let fill = CAGradientLayer()
  private var fraction: Double?
  private var animates = true
  private var increasedContrast = false
  private var renderedSize = CGSize.zero
  var isIndeterminate: Bool { fraction == nil }
  var doubleValue: Double { fraction ?? 0 }
  override var intrinsicContentSize: NSSize { NSSize(width: 100, height: 12) }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    track.name = "operation.track"; track.masksToBounds = true
    fill.name = "operation.fill"; fill.anchorPoint = CGPoint(x: 0, y: 0.5)
    fill.startPoint = CGPoint(x: 0, y: 0.5); fill.endPoint = CGPoint(x: 1, y: 0.5)
    layer?.addSublayer(track); track.addSublayer(fill)
    setAccessibilityElement(true); setAccessibilityRole(.progressIndicator)
    setAccessibilityMinValue(0); setAccessibilityMaxValue(1)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  func update(value: Double?, animates: Bool, increasedContrast: Bool, label: String) {
    let previous = fraction
    fraction = value.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
    self.animates = animates; self.increasedContrast = increasedContrast
    setAccessibilityLabel(label)
    setAccessibilityValue(fraction.map { NSNumber(value: $0) })
    render(animateFill: animates && previous != nil && fraction != nil && doubleValue > previous!,
      valueChanged: previous != fraction)
  }
  override func layout() { super.layout(); render() }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); render() }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); render() }

  private func render(animateFill: Bool = false, valueChanged: Bool = false) {
    let width = max(0, bounds.width), height: CGFloat = 6
    let oldWidth = fill.presentation()?.bounds.width ?? fill.bounds.width
    let sizeChanged = renderedSize != bounds.size
    renderedSize = bounds.size
    CATransaction.begin(); CATransaction.setDisableActions(true)
    track.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: width, height: height)
    track.cornerRadius = height / 2; track.borderWidth = increasedContrast ? 1 : 0.5
    fill.cornerRadius = height / 2
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let accent = NSColor.controlAccentColor
      track.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(increasedContrast ? 0.24 : 0.13).cgColor
      track.borderColor = NSColor.separatorColor.cgColor
      fill.colors = [accent.cgColor, (isIndeterminate ? accent.withAlphaComponent(0.20) : accent).cgColor]
    }
    if isIndeterminate {
      fill.removeAnimation(forKey: "fill")
      let length = min(36, width)
      fill.bounds = CGRect(x: 0, y: 0, width: length, height: height)
      fill.position = CGPoint(x: animates && window != nil ? 0 : (width - length) / 2, y: height / 2)
      if animates, window != nil, width > length {
        if fill.animation(forKey: "bounce") == nil || sizeChanged {
          let animation = CABasicAnimation(keyPath: "position.x")
          animation.fromValue = 0; animation.toValue = width - length
          animation.duration = 0.9; animation.autoreverses = true; animation.repeatCount = .infinity
          animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
          fill.add(animation, forKey: "bounce")
        }
      } else { fill.removeAnimation(forKey: "bounce") }
    } else {
      fill.removeAnimation(forKey: "bounce")
      if valueChanged { fill.removeAnimation(forKey: "fill") }
      let target = width * doubleValue
      fill.bounds = CGRect(x: 0, y: 0, width: target, height: height)
      fill.position = CGPoint(x: 0, y: height / 2)
      if animateFill, window != nil, target > oldWidth {
        let animation = CABasicAnimation(keyPath: "bounds.size.width")
        animation.fromValue = oldWidth; animation.toValue = target; animation.duration = 0.15
        fill.add(animation, forKey: "fill")
      }
    }
    CATransaction.commit()
  }
}
