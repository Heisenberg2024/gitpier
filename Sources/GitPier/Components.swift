import AppKit
import SwiftUI

extension NSColor {
  convenience init(hex: UInt32) {
    self.init(
      srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
      blue: Double(hex & 255) / 255, alpha: 1)
  }
}
enum Theme {
  static func panel(_ scheme: ColorScheme) -> Color {
    Color(nsColor: NSColor(hex: scheme == .dark ? 0x23262D : 0xF0F2F5))
  }
  static func editor(_ scheme: ColorScheme) -> Color {
    Color(nsColor: NSColor(hex: scheme == .dark ? 0x191B1F : 0xFAFBFC))
  }
  static func sidebar(_ scheme: ColorScheme) -> Color {
    Color(nsColor: NSColor(hex: scheme == .dark ? 0x202229 : 0xF4F5F7))
  }
}
@MainActor func uiFont(
  size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default
) -> Font {
  .system(size: size, weight: weight, design: design)
}
struct IconButton: View {
  let symbol: String
  let help: String
  var action: () -> Void
  init(_ symbol: String, help: String, action: @escaping () -> Void) {
    self.symbol = symbol
    self.help = help
    self.action = action
  }
  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 12)).frame(width: 23, height: 23).contentShape(
        Rectangle())
    }.buttonStyle(.workspace).help(help).foregroundStyle(.secondary).accessibilityLabel(help)
  }
}
struct EmptyState: View {
  let symbol: String
  let title: String
  let detail: String
  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
      Text(title).font(.title3.weight(.medium))
      Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(
        maxWidth: 460)
    }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
struct ResizeHandle: View {
  var vertical: Bool
  var onDrag: (CGFloat) -> Void
  var onEnd: () -> Void = {}
  @State private var previous: CGFloat = 0
  @State private var latest: CGFloat = 0
  @State private var lastDelivery: TimeInterval = 0
  var body: some View {
    Rectangle().fill(Color.primary.opacity(0.08)).frame(
      width: vertical ? 5 : nil, height: vertical ? nil : 5
    )
    .contentShape(Rectangle())
    .onHover { hover in
      if hover {
        (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
      } else {
        NSCursor.pop()
      }
    }
    .gesture(
      DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged { value in
        let offset = vertical ? value.translation.width : value.translation.height
        latest = offset
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDelivery >= 1.0 / 60 {
          var transaction = Transaction()
          transaction.disablesAnimations = true
          withTransaction(transaction) { onDrag(offset - previous) }
          previous = offset
          lastDelivery = now
        }
      }.onEnded { _ in
        if latest != previous {
          var transaction = Transaction()
          transaction.disablesAnimations = true
          withTransaction(transaction) { onDrag(latest - previous) }
        }
        previous = 0
        latest = 0
        lastDelivery = 0
        onEnd()
      })
  }
}

struct WorkspaceButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    FeedbackSurface(pressed: configuration.isPressed) { configuration.label }
  }
}
extension ButtonStyle where Self == WorkspaceButtonStyle {
  static var workspace: WorkspaceButtonStyle { WorkspaceButtonStyle() }
}
struct FeedbackSurface<Content: View>: View {
  let pressed: Bool
  @ViewBuilder var content: () -> Content
  @Environment(\.isEnabled) private var enabled
  @State private var hovering = false
  var body: some View {
    content().background {
      RoundedRectangle(cornerRadius: 5).fill(
        enabled
          ? (pressed
            ? Color.accentColor.opacity(0.27) : hovering ? Color.primary.opacity(0.08) : .clear)
          : .clear)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 5).stroke(
        enabled && pressed ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1)
    }
    .opacity(enabled ? 1 : 0.45).contentShape(Rectangle()).onHover { hovering = $0 }
  }
}
@MainActor func repositoryFont(sizeOffset: CGFloat = 0, weight: Font.Weight = .regular) -> Font {
  .system(size: 12 + sizeOffset, weight: weight)
}
struct Badge: View {
  var text: String
  var color: Color = .secondary
  var body: some View {
    Text(text).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(color)
      .padding(.horizontal, 5).padding(.vertical, 2).background(color.opacity(0.12)).clipShape(
        RoundedRectangle(cornerRadius: 3))
  }
}
