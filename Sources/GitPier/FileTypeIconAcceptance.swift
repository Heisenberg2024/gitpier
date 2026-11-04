import AppKit
import GitPierCore
import SwiftUI

@MainActor extension UIAcceptance {
  static func verifyFileTypeIcons(store: AppStore, model: RepositoryModel, root: URL,
    window: NSWindow, output: URL) async throws {
    guard root.deletingLastPathComponent().lastPathComponent.hasPrefix("GitPier-ui.") else {
      throw GitPierError.invalidInput("File icon acceptance requires a disposable repository")
    }
    let paths = ["App.swift", "agent.py", "client.ts", "README.md", "Dockerfile"]
    let cell = ChangesListCell(frame: NSRect(x: 0, y: 0, width: 480, height: 24))
    var images = Set<Data>()
    for path in paths {
      let file = FileChange(path: path, index: ".", worktree: "M", kind: .modified)
      cell.configure(.file(file, depth: 0), model: model, coloredIcons: true, tree: false)
      guard let data = cell.icon.image?.tiffRepresentation else {
        throw GitPierError.invalidInput("Missing file icon: \(path)")
      }
      images.insert(data)
    }
    guard images.count == paths.count else {
      throw GitPierError.invalidInput("Different file types still share the same icon (\(images.count)/\(paths.count))")
    }
    var checks = ["Different native file types render distinct icons"]
    func require(_ condition: Bool, _ message: String) throws {
      guard condition else { throw GitPierError.invalidInput("File type icons: " + message) }
      checks.append(message)
    }
    let ignorePaths = [".gitignore", ".dockerignore", ".npmignore", ".eslintignore", ".prettierignore",
      ".stylelintignore", ".hgignore", ".bzrignore", ".ignore", ".rgignore", ".fdignore",
      ".helmignore", ".vercelignore", ".gcloudignore", ".vscodeignore", ".p4ignore",
      "docker/build.Dockerfile.dockerignore", "templates/custom.ignore", "nested/.GITIGNORE",
      ".gitignore_global", "gitignore_global", ".git/info/exclude"]
    guard let prohibition = NSImage(systemSymbolName: "nosign", accessibilityDescription: nil) else {
      throw GitPierError.invalidInput("Missing prohibition symbol")
    }
    prohibition.isTemplate = true
    for dark in [false, true] {
      cell.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      for colored in [false, true] {
        for path in ignorePaths {
          let file = FileChange(path: path, index: ".", worktree: "M", kind: .modified)
          cell.configure(.file(file, depth: 0), model: model, coloredIcons: colored, tree: false)
          try require(cell.icon.image?.tiffRepresentation == prohibition.tiffRepresentation
            && cell.icon.image?.isTemplate == true && cell.icon.contentTintColor == .secondaryLabelColor,
            "Ignore uses a neutral prohibition icon: \(path), dark=\(dark), colored=\(colored)")
        }
      }
    }
    let cases: [(String, FileIconKind)] = [
      ("Sources/Appearance.swift", .swift), ("删除的文件/旧版.SWIFT", .swift),
      ("src/agent.py", .python), ("types/model.pyi", .python), ("notebook.ipynb", .python),
      ("client.test.ts", .typescript), ("types.d.ts", .typescript), ("types.d.mts", .typescript),
      ("ui/Index.TSX", .reactTypescript), ("ui/index.jsx", .react), ("runtime.mjs", .javascript),
      ("README.zh-CN.md", .markdown), ("README", .markdown), ("locales/en.json", .json),
      ("tsconfig.json", .typescript), ("tsconfig.build.json", .typescript), ("jsconfig.json", .javascript),
      ("package.json", .npm), ("package-lock.json", .npm), ("pnpm-lock.yaml", .pnpm), ("yarn.lock", .yarn),
      ("Dockerfile", .docker), ("docker/Dockerfile.prod", .docker), ("api.dockerfile", .docker),
      (".dockerignore", .ignore), ("docker-compose.override.yml", .docker), ("compose.dev.yaml", .docker),
      (".gitignore", .ignore), (".gitattributes", .git), (".gitmodules", .git), (".gitlab-ci.yml", .gitlab),
      (".github/workflows/ci.yml", .githubActions), ("nested/.github/workflows/build.yaml", .githubActions),
      ("workflows/ci.yml", .yaml), (".env", .settings), (".env.production", .settings),
      (".editorconfig", .editorconfig), ("Makefile", .makefile), ("CMakeLists.txt", .cmake),
      ("install.sh", .shell), (".zshrc", .shell), ("install.ps1", .powershell), ("install.bat", .windows),
      ("pyproject.toml", .toml), ("Cargo.toml", .rust), ("go.mod", .go), ("Gemfile.lock", .ruby),
      ("angular.json", .angular), (".nvmrc", .nodejs), ("app.vue", .vue), ("app.svelte", .svelte),
      ("styles.scss", .sass), ("asset.PnG", .image), ("logo.svg", .svg), ("data.sqlite3", .database),
      ("archive.tar.gz", .zip), ("LICENSE", .document), ("report.pdf", .pdf),
      ("ignore.swift", .swift), (".gitignore.md", .markdown), ("do-not-ignore.txt", .document),
      ("exclude", .generic), ("data/exclude", .generic), (".git/info/exclude.txt", .document),
      ("folder.swift/opaque", .generic), ("", .generic), ("无扩展名", .generic), ("unknown.blob", .generic),
    ]
    for (path, kind) in cases {
      try require(FileIconKind.resolve(path) == kind, "Filename association: \(path)")
    }
    for dark in [false, true] {
      for kind in FileIconKind.allCases where kind.systemSymbol == nil {
        let original = FileTypeIcons.image(kind: kind, colored: true, dark: dark)
        let neutral = FileTypeIcons.image(kind: kind, colored: false, dark: dark)
        let rendered = try iconPixels(original)
        try require(!original.isTemplate && rendered.visible > 0,
          "Bundled vector renders: \(kind.rawValue), dark=\(dark)")
        let pixels = try iconPixels(neutral)
        try require(pixels.visible > 0 && !pixels.chromatic,
          "Monochrome preserves visible detail: \(kind.rawValue), dark=\(dark)")
      }
    }
    try require(FileTypeIcons.image(path: "A.swift", colored: true, dark: false)
      === FileTypeIcons.image(path: "another/B.SWIFT", colored: true, dark: false),
      "Same type shares the cached image across unrelated paths")
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      cell.appearance = NSAppearance(named: appearance)
      let dark = appearance == .darkAqua
      for (path, kind) in [("project.toml", FileIconKind.toml), ("A.swift", .swift), ("pnpm-lock.yaml", .pnpm)] {
        let file = FileChange(path: path, index: ".", worktree: "M", kind: .modified)
        cell.configure(.file(file, depth: 1), model: model, coloredIcons: true, tree: true)
        try require(cell.icon.image === FileTypeIcons.image(kind: kind, colored: true, dark: dark)
          && cell.icon.contentTintColor == nil, "Reused cell resets image/tint in \(appearance.rawValue): \(path)")
      }
    }
    let conflicted = FileChange(path: "conflict.swift", index: "U", worktree: "U", kind: .conflicted)
    cell.configure(.file(conflicted, depth: 0), model: model, coloredIcons: true, tree: false)
    try require(!cell.check.isEnabled && cell.icon.contentTintColor == .systemOrange,
      "Conflict warning and disabled commit checkbox remain")
    let submodule = FileChange(path: "vendor", index: ".", worktree: "M", submodule: "S.M.", kind: .modified)
    cell.configure(.file(submodule, depth: 0), model: model, coloredIcons: true, tree: false)
    try require(cell.icon.image != nil && cell.icon.contentTintColor != nil, "Submodule keeps its package indicator")
    let deleted = FileChange(path: "gone.swift", index: "D", worktree: ".", kind: .deleted)
    cell.configure(.file(deleted, depth: 0), model: model, coloredIcons: true, tree: false)
    try require(cell.name.textColor == .systemRed && cell.icon.contentTintColor == nil
      && cell.icon.image === FileTypeIcons.image(path: "gone.swift", colored: true, dark: true),
      "Deleted path retains its type without reading a local file; status remains red")
    let renamed = FileChange(path: "renamed.py", originalPath: "before.swift", index: "R", worktree: ".", kind: .renamed)
    cell.configure(.file(renamed, depth: 0), model: model, coloredIcons: false, tree: false)
    try require(cell.icon.image === FileTypeIcons.image(path: "renamed.py", colored: false, dark: true)
      && cell.toolTip == "before.swift → renamed.py", "Rename uses the destination type and keeps its source tooltip")
    cell.configure(.directory(path: "folder", depth: 0, expanded: true), model: model, coloredIcons: true, tree: true)
    try require(cell.icon.contentTintColor == .secondaryLabelColor && cell.check.isHidden,
      "Directory row clears the previous file state")

    let git = await model.git()
    let before = try await git.snapshot()
    let samples = ["App.swift", "agent.py", "client.ts", "index.tsx", "README.zh-CN.md", "Dockerfile",
      ".dockerignore", ".gitignore", ".npmignore", "install.sh", "install.ps1", "pyproject.toml", "settings.json", "package.json",
      "styles.css", "logo.svg", "unknown.blob"]
    for path in samples {
      let url = root.appendingPathComponent("FileIconSamples").appendingPathComponent(path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("File icon acceptance fixture\n".utf8).write(to: url)
    }
    await model.refresh(); try await settle()
    guard let selected = model.status.files.first(where: { $0.path == "FileIconSamples/App.swift" }),
      let host = window.contentView else { throw GitPierError.invalidInput("Missing icon fixture") }
    model.select(selected, permanent: true)
    try await waitFor { !model.diffLoading }
    let included = model.includedPaths, selection = model.selectedPaths
    window.setFrameOrigin(NSPoint(x: 60, y: 60))
    var screenshots = 0
    for dark in [false, true] {
      for colored in [true, false] {
        for tree in [false, true] {
          var settings = store.settings
          settings.appearance = dark ? .dark : .light
          settings.language = tree ? .simplifiedChinese : .english
          settings.coloredFileIcons = colored
          store.updateSettings(settings)
          model.treeMode = tree; model.expandedDirectories = ["FileIconSamples", "Sources"]
          window.setContentSize(NSSize(width: tree ? 960 : 1440, height: 900))
          try await settle()
          guard let table = descendants(host).compactMap({ $0 as? ChangesTableView }).first,
            let native = descendants(table).compactMap({ $0 as? ChangesListCell })
              .first(where: { $0.hit.path == selected.path }) else {
            throw GitPierError.invalidInput("Selected file row missing from icon fixture")
          }
          try require(native.icon.image === FileTypeIcons.image(path: selected.path, colored: colored, dark: dark),
            "Live native row follows theme/color/layout: \(dark)/\(colored)/\(tree)")
          try require(model.includedPaths == included && model.selectedPaths == selection,
            "Icon changes preserve commit inclusion and selection: \(dark)/\(colored)/\(tree)")
          let prefix = "\(dark ? "dark" : "light")-\(colored ? "color" : "mono")-\(tree ? "tree-zh" : "flat-en")"
          try await captureHostingWindow(window, to: output.appendingPathComponent(prefix + ".png"))
          screenshots += 1
        }
      }
    }
    let after = try await git.snapshot()
    try require(after.identity == before.identity, "HEAD and Index remain unchanged")
    let summary: [String: Any] = ["checks": checks.count, "screenshots": screenshots,
      "bundledKinds": FileIconKind.allCases.filter { $0.systemSymbol == nil }.count,
      "systemKinds": FileIconKind.allCases.filter { $0.systemSymbol != nil && $0 != .generic }.count,
      "results": checks]
    try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("file-type-icons-summary.json"))
    try checks.joined(separator: "\n").write(
      to: output.appendingPathComponent("file-type-icons-results.txt"), atomically: true, encoding: .utf8)
  }

  private static func iconPixels(_ image: NSImage) throws -> (visible: Int, chromatic: Bool) {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
      throw GitPierError.invalidInput("Cannot rasterize file icon")
    }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
    graphics.cgContext.clear(CGRect(x: 0, y: 0, width: 32, height: 32))
    image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
    NSGraphicsContext.restoreGraphicsState()
    var visible = 0, chromatic = false
    for y in 0..<32 { for x in 0..<32 {
      guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.1 else { continue }
      visible += 1
      chromatic = chromatic || max(abs(color.redComponent - color.greenComponent), abs(color.blueComponent - color.greenComponent)) > 0.035
    } }
    return (visible, chromatic)
  }
}
