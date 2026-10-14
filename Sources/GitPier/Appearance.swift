import AppKit
import GitPierCore
import SwiftUI

struct AppAppearance: ViewModifier {
  @ObservedObject var store: AppStore
  func body(content: Content) -> some View {
    content.environment(\.colorScheme, store.resolvedColorScheme)
      .menuIndicator(.hidden)
      .background(WindowAppearance(mode: store.settings.appearance))
      .background(UnifiedScrollbars())
  }
}
struct WindowAppearance: NSViewRepresentable {
  let mode: AppearanceMode
  func makeNSView(context: Context) -> AppearanceAnchor {
    let view = AppearanceAnchor()
    view.mode = mode
    return view
  }
  func updateNSView(_ view: AppearanceAnchor, context: Context) {
    view.mode = mode
    view.apply()
  }
}
final class AppearanceAnchor: NSView {
  var mode: AppearanceMode = .system
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    apply()
  }
  func apply() {
    let appearance: NSAppearance? =
      mode == .system ? nil : NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
    if window?.appearance != appearance { window?.appearance = appearance }
  }
}
