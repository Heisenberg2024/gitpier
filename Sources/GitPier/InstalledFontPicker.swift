import AppKit
import SwiftUI

/// Build native menu items once instead of thousands of SwiftUI font labels on every form layout.
struct InstalledFontPicker: NSViewRepresentable {
  @Binding var font: String
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSPopUpButton {
    let button = NSPopUpButton(frame: .zero, pullsDown: false)
    button.addItems(withTitles: InstalledFonts.names)
    button.target = context.coordinator
    button.action = #selector(Coordinator.choose(_:))
    button.setAccessibilityLabel("Diff code font")
    return button
  }
  func updateNSView(_ button: NSPopUpButton, context: Context) {
    context.coordinator.parent = self
    if button.titleOfSelectedItem != font { button.selectItem(withTitle: font) }
  }
  @MainActor final class Coordinator: NSObject {
    var parent: InstalledFontPicker
    init(_ parent: InstalledFontPicker) { self.parent = parent }
    @objc func choose(_ sender: NSPopUpButton) {
      if let name = sender.titleOfSelectedItem { parent.font = name }
    }
  }
}
