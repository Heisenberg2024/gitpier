import AppKit
import GitPierCore
import SwiftUI
import UniformTypeIdentifiers

struct InstalledEditor: Identifiable {
  var id: String { url.path }
  let name: String
  let url: URL
  @MainActor var icon: NSImage {
    let image = NSWorkspace.shared.icon(forFile: url.path).copy() as! NSImage
    image.size = NSSize(width: 16, height: 16)
    return image
  }
}

@MainActor enum ExternalEditors {
  static let preferredApplications: [(String, String)] = [
    ("VS Code", "com.microsoft.VSCode"),
    ("Cursor", "com.todesktop.230313mzl4w4u92"),
    ("Zed", "dev.zed.Zed"),
    ("Sublime Text", "com.sublimetext.4"),
    ("Nova", "com.panic.Nova"),
    ("BBEdit", "com.barebones.bbedit"),
    ("IntelliJ IDEA", "com.jetbrains.intellij"),
    ("IntelliJ IDEA CE", "com.jetbrains.intellij.ce"),
    ("WebStorm", "com.jetbrains.WebStorm"),
    ("GoLand", "com.jetbrains.goland"),
    ("PyCharm", "com.jetbrains.pycharm"),
    ("PyCharm CE", "com.jetbrains.pycharm.ce"),
    ("CLion", "com.jetbrains.CLion"),
    ("Android Studio", "com.google.android.studio"),
    ("Xcode", "com.apple.dt.Xcode"),
    ("TextMate", "com.macromates.TextMate"),
    ("CotEditor", "com.coteditor.CotEditor"),
  ]
  static func installed() -> [InstalledEditor] {
    var paths = Set<String>()
    return preferredApplications.compactMap { name, identifier in
      guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
        let editor = editor(at: url, name: name), paths.insert(editor.id).inserted
      else { return nil }
      return editor
    }
  }
  static func editor(at url: URL, name: String? = nil) -> InstalledEditor? {
    let canonical = url.resolvingSymlinksInPath().standardizedFileURL
    guard canonical.pathExtension.lowercased() == "app",
      FileManager.default.fileExists(atPath: canonical.path),
      Bundle(url: canonical)?.executableURL != nil
    else { return nil }
    let displayName = FileManager.default.displayName(atPath: canonical.path)
    return InstalledEditor(
      name: name
        ?? (displayName.hasSuffix(".app")
          ? String(displayName.dropLast(4)) : displayName),
      url: canonical)
  }
  static func available(settings: AppSettings) -> [InstalledEditor] {
    var editors = installed()
    var paths = Set(editors.map(\.id))
    for path in settings.customEditorPaths + [settings.editorPath] where !path.isEmpty {
      if let editor = editor(at: URL(fileURLWithPath: path)), paths.insert(editor.id).inserted {
        editors.append(editor)
      }
    }
    return editors
  }
  static func application(settings: AppSettings, override: URL? = nil) -> URL? {
    if let override { return override }
    if !settings.editorPath.isEmpty,
      let editor = editor(at: URL(fileURLWithPath: settings.editorPath))
    {
      return editor.url
    }
    return installed().first?.url
  }
  static func setIcon(_ editor: InstalledEditor, on item: NSMenuItem) {
    item.image = editor.icon
    // macOS 27 may hide menu images automatically. Use its runtime setter so older
    // SDKs remain supported; ImageVisibility.visible has the raw value 1.
    if item.responds(to: NSSelectorFromString("setPreferredImageVisibility:")) {
      item.setValue(NSNumber(value: 1), forKey: "preferredImageVisibility")
    }
  }
  static func chooseApplication() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.applicationBundle]
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.message = AppStore.shared.text(
      "Choose an application to open repositories and files", "选择用于打开仓库和文件的应用")
    guard panel.runModal() == .OK, let url = panel.url, let editor = editor(at: url) else {
      return nil
    }
    return editor.url
  }
}

struct ExternalEditorPicker: View {
  @EnvironmentObject var store: AppStore
  @State private var editors: [InstalledEditor] = []
  var selectedPath: String {
    let canonical = URL(fileURLWithPath: store.settings.editorPath).resolvingSymlinksInPath().path
    return editors.first { $0.id == canonical }?.id ?? editors.first?.id ?? ""
  }
  var body: some View {
    LabeledContent(store.text("External Editor", "外部编辑器")) {
      EditorApplicationPicker(
        editors: editors, selectedPath: selectedPath,
        chooseTitle: store.text("Choose Application…", "选择应用…"),
        label: store.text("External Editor", "外部编辑器")
      ) { path in
        if let path {
          var settings = store.settings
          settings.editorPath = path
          store.updateSettings(settings)
        } else if let url = ExternalEditors.chooseApplication() {
          var settings = store.settings
          if !settings.customEditorPaths.contains(url.path) {
            settings.customEditorPaths.append(url.path)
          }
          settings.editorPath = url.path
          store.updateSettings(settings)
        }
        editors = ExternalEditors.available(settings: store.settings)
      }.fixedSize()
    }
    .onAppear { editors = ExternalEditors.available(settings: store.settings) }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      editors = ExternalEditors.available(settings: store.settings)
    }
  }
}

/// Native application icons appear in both the selected item and its menu.
struct EditorApplicationPicker: NSViewRepresentable {
  let editors: [InstalledEditor]
  let selectedPath: String
  let chooseTitle: String
  let label: String
  let select: (String?) -> Void
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSPopUpButton {
    let button = NSPopUpButton(frame: .zero, pullsDown: false)
    button.target = context.coordinator
    button.action = #selector(Coordinator.choose(_:))
    button.menu?.autoenablesItems = false
    button.setAccessibilityIdentifier("external-editor-picker")
    return button
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView button: NSPopUpButton, context: Context)
    -> CGSize?
  {
    let font = button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let textWidth = (button.titleOfSelectedItem ?? chooseTitle).size(withAttributes: [.font: font])
      .width
    let iconWidth = button.selectedItem?.image?.size.width ?? 0
    return CGSize(
      width: min(280, max(90, ceil(textWidth + iconWidth + 40))),
      height: max(24, button.intrinsicContentSize.height))
  }
  func updateNSView(_ button: NSPopUpButton, context: Context) {
    let coordinator = context.coordinator
    coordinator.parent = self
    let identity = editors.map { $0.id + "\0" + $0.name } + [chooseTitle]
    if coordinator.identity != identity {
      coordinator.identity = identity
      button.removeAllItems()
      for editor in editors {
        let item = NSMenuItem(title: editor.name, action: nil, keyEquivalent: "")
        item.representedObject = editor.id
        ExternalEditors.setIcon(editor, on: item)
        button.menu?.addItem(item)
      }
      if !editors.isEmpty { button.menu?.addItem(.separator()) }
      button.menu?.addItem(NSMenuItem(title: chooseTitle, action: nil, keyEquivalent: ""))
    }
    button.selectItem(at: editors.firstIndex { $0.id == selectedPath } ?? 0)
    button.setAccessibilityLabel(label)
  }
  @MainActor final class Coordinator: NSObject {
    var parent: EditorApplicationPicker
    var identity: [String] = []
    init(_ parent: EditorApplicationPicker) { self.parent = parent }
    @objc func choose(_ sender: NSPopUpButton) {
      let path = sender.selectedItem?.representedObject as? String
      if let path {
        parent.select(path)
      } else {
        // End native menu tracking before opening a panel. Otherwise the popup can overwrite
        // the restored selection when its tracking loop finishes after a cancelled panel.
        DispatchQueue.main.async { [weak self, weak sender] in
          guard let self, let sender else { return }
          sender.selectItem(
            at: self.parent.editors.firstIndex { $0.id == self.parent.selectedPath } ?? 0)
          self.parent.select(nil)
        }
      }
    }
  }
}

struct EditorLaunchMenu: View {
  @ObservedObject var model: RepositoryModel
  var path: String? = nil
  @EnvironmentObject var store: AppStore
  var body: some View {
    Menu(store.text("Open in Editor", "在编辑器中打开")) {
      ForEach(ExternalEditors.available(settings: store.settings)) { editor in
        Button {
          model.openEditor(path, application: editor.url)
        } label: {
          Label {
            Text(editor.name)
          } icon: {
            Image(nsImage: editor.icon).renderingMode(.original)
          }
          .labelStyle(.titleAndIcon)
        }
      }
    } primaryAction: {
      model.openEditor(path)
    }
  }
}
