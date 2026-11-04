import AppKit
import SwiftUI

/// Decoration used for an existing favorite. Parents can expose the state alongside their title.
struct RepositoryFavoriteMark: View {
  var body: some View {
    Image(systemName: "star.fill")
      .symbolRenderingMode(.monochrome)
      .foregroundStyle(Color(nsColor: .systemYellow))
      .accessibilityHidden(true)
  }
}

extension NSColor {
  convenience init(hex: UInt32) {
    self.init(
      srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
      blue: Double(hex & 255) / 255, alpha: 1)
  }
}
enum Theme {
  static var editorColor: NSColor { .textBackgroundColor }
  static func panel(_: ColorScheme) -> Color { Color(nsColor: .windowBackgroundColor) }
  static func editor(_: ColorScheme) -> Color { Color(nsColor: editorColor) }
  static func sidebar(_: ColorScheme) -> Color { Color(nsColor: .underPageBackgroundColor) }
  static var separator: Color { Color(nsColor: .separatorColor) }
  static let controlRadius: CGFloat = 6
  static let panelRadius: CGFloat = 10
  static let iconTarget: CGFloat = 25

  static func selection(increasedContrast: Bool) -> Color {
    Color.accentColor.opacity(increasedContrast ? 0.24 : 0.14)
  }

  static func panelShape(radius: CGFloat) -> AnyShape {
    #if compiler(>=6.4)
    if #available(macOS 27, *) {
      return AnyShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(radius))))
    }
    #endif
    return AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
  }
}

enum WorkspaceHeading {
  case section, page, sheet
  var font: Font {
    switch self {
    case .section: .headline
    case .page: .title3.weight(.semibold)
    case .sheet: .title2.weight(.semibold)
    }
  }
}

extension View {
  func workspaceHeading(_ level: WorkspaceHeading = .section) -> some View {
    font(level.font).accessibilityAddTraits(.isHeader)
  }
  func workspacePanel(_ fill: Color, radius: CGFloat = Theme.panelRadius) -> some View {
    modifier(WorkspacePanelSurface(fill: fill, radius: radius))
  }
}

private struct WorkspacePanelSurface: ViewModifier {
  @Environment(\.colorSchemeContrast) private var contrast
  let fill: Color
  let radius: CGFloat
  func body(content: Content) -> some View {
    let shape = Theme.panelShape(radius: radius)
    content.background(fill, in: shape).overlay {
      shape.stroke(Theme.separator.opacity(contrast == .increased ? 1 : 0.65))
        .allowsHitTesting(false)
    }
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
      Image(systemName: symbol).font(.system(size: 12)).frame(width: Theme.iconTarget, height: Theme.iconTarget).contentShape(
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
      Text(title).workspaceHeading(.page)
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
  @Environment(\.isFocused) private var focused
  @Environment(\.colorSchemeContrast) private var contrast
  @State private var hovering = false
  var body: some View {
    content().background {
      RoundedRectangle(cornerRadius: Theme.controlRadius).fill(
        enabled
          ? (pressed
            ? Theme.selection(increasedContrast: true) : hovering ? Color.primary.opacity(contrast == .increased ? 0.15 : 0.08) : .clear)
          : .clear)
    }
    .overlay {
      RoundedRectangle(cornerRadius: Theme.controlRadius).stroke(
        enabled && focused ? Color.accentColor : enabled && pressed ? Color.accentColor.opacity(0.55) : .clear,
        lineWidth: focused && contrast == .increased ? 2 : 1).allowsHitTesting(false)
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
