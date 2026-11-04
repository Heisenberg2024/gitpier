import AppKit
import CoreImage
import SwiftUI

/// Presentation metadata only: paths may describe deleted, untracked or remote files.
enum FileIconKind: String, CaseIterable {
  case generic, ignore, swift, python, typescript, javascript, react, docker, markdown, json, yaml, toml
  case reactTypescript = "react_ts"
  case xml, html, css, sass, less, vue, svelte, astro, angular, java, kotlin, go, rust, c, cpp, h, hpp, csharp
  case objectiveC = "objective-c", objectiveCpp = "objective-cpp"
  case ruby, php, dart, elixir, erlang, scala, lua, r, julia, perl, haskell, zig, terraform
  case shell = "console", powershell, windows = "command", makefile, cmake, gradle
  case npm, yarn, pnpm, nodejs, git, gitlab, editorconfig, settings, document, image, svg, pdf
  case githubActions = "github-actions-workflow"
  case font, zip, database, video, audio, lock, certificate, key

  var systemSymbol: String? {
    switch self {
    case .generic: "doc.text"
    case .ignore: "nosign"
    default: nil
    }
  }

  static func resolve(_ path: String) -> Self {
    let name = (path as NSString).lastPathComponent.lowercased()
    // Ignore formats share one visual identity, including per-Dockerfile ignore files.
    if name.hasSuffix("ignore") { return .ignore }
    if name == "exclude" {
      let parent = (path as NSString).deletingLastPathComponent.lowercased()
      if parent == ".git/info" || parent.hasSuffix("/.git/info") { return .ignore }
    }
    if let kind = filenames[name] { return kind }
    let ext = (name as NSString).pathExtension
    if name.hasPrefix("dockerfile.") || name.hasSuffix(".dockerfile") { return .docker }
    if ["yml", "yaml"].contains(ext) {
      if name.hasPrefix("docker-compose.") || name.hasPrefix("compose.") { return .docker }
      let parent = (path as NSString).deletingLastPathComponent.lowercased()
      if parent == ".github/workflows" || parent.hasSuffix("/.github/workflows") { return .githubActions }
    }
    if name.hasPrefix(".env.") { return .settings }
    if ext == "json", name.hasPrefix("tsconfig.") { return .typescript }
    if ext == "json", name.hasPrefix("jsconfig.") { return .javascript }
    if name.hasSuffix(".d.ts") || name.hasSuffix(".d.mts") || name.hasSuffix(".d.cts") { return .typescript }
    return extensions[ext] ?? .generic
  }

  private static let filenames: [String: Self] = [
    "dockerfile": .docker, "containerfile": .docker,
    "docker-compose.yml": .docker, "docker-compose.yaml": .docker,
    "compose.yml": .docker, "compose.yaml": .docker,
    "makefile": .makefile, "gnumakefile": .makefile, "bsdmakefile": .makefile,
    "cmakelists.txt": .cmake, "cmakecache.txt": .cmake,
    ".gitignore_global": .ignore, "gitignore_global": .ignore,
    ".gitattributes": .git, ".gitmodules": .git, ".gitkeep": .git,
    ".gitconfig": .git, ".gitmessage": .git, ".gitlab-ci.yml": .gitlab,
    "package.json": .npm, "package-lock.json": .npm, "npm-shrinkwrap.json": .npm, ".npmrc": .npm,
    "yarn.lock": .yarn, ".yarnrc": .yarn, ".yarnrc.yml": .yarn,
    "pnpm-lock.yaml": .pnpm, "pnpm-workspace.yaml": .pnpm, ".pnpmfile.cjs": .pnpm,
    "tsconfig.json": .typescript, "jsconfig.json": .javascript,
    "angular.json": .angular, ".angular-cli.json": .angular, ".nvmrc": .nodejs, ".node-version": .nodejs,
    "cargo.toml": .rust, "cargo.lock": .rust, "go.mod": .go, "go.sum": .go,
    "gemfile": .ruby, "gemfile.lock": .ruby, "rakefile": .ruby,
    "gradlew": .gradle, "gradlew.bat": .gradle,
    ".editorconfig": .editorconfig, ".env": .settings, ".prettierrc": .settings, ".eslintrc": .settings,
    ".bashrc": .shell, ".bash_profile": .shell, ".zshrc": .shell, ".zprofile": .shell,
    ".profile": .shell, ".zshenv": .shell, "brewfile": .ruby,
    "readme": .markdown, "license": .document, "licence": .document, "copying": .document,
    "notice": .document, "authors": .document, "changelog": .document,
  ]
  private static let extensions: [String: Self] = [
    "swift": .swift, "py": .python, "pyi": .python, "pyw": .python, "ipynb": .python,
    "ts": .typescript, "mts": .typescript, "cts": .typescript, "tsx": .reactTypescript,
    "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .react,
    "md": .markdown, "markdown": .markdown, "mdown": .markdown, "mdx": .markdown,
    "json": .json, "jsonc": .json, "json5": .json, "jsonl": .json, "ndjson": .json,
    "yaml": .yaml, "yml": .yaml, "toml": .toml, "xml": .xml, "plist": .xml, "xsd": .xml,
    "html": .html, "htm": .html, "xhtml": .html, "css": .css, "scss": .sass, "sass": .sass,
    "less": .less, "vue": .vue, "svelte": .svelte, "astro": .astro,
    "java": .java, "kt": .kotlin, "kts": .kotlin, "go": .go, "rs": .rust,
    "c": .c, "h": .h, "cc": .cpp, "cpp": .cpp, "cxx": .cpp, "c++": .cpp,
    "hpp": .hpp, "hh": .hpp, "hxx": .hpp, "cs": .csharp, "csx": .csharp,
    "m": .objectiveC, "mm": .objectiveCpp, "rb": .ruby, "gemspec": .ruby, "php": .php,
    "dart": .dart, "ex": .elixir, "exs": .elixir, "erl": .erlang, "hrl": .erlang,
    "scala": .scala, "sc": .scala, "lua": .lua, "r": .r, "rmd": .r, "jl": .julia,
    "pl": .perl, "pm": .perl, "hs": .haskell, "lhs": .haskell, "zig": .zig,
    "tf": .terraform, "tfvars": .terraform, "hcl": .terraform,
    "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell,
    "ps1": .powershell, "psm1": .powershell, "psd1": .powershell, "bat": .windows, "cmd": .windows,
    "mk": .makefile, "cmake": .cmake, "gradle": .gradle, "lock": .lock,
    "ini": .settings, "cfg": .settings, "conf": .settings, "config": .settings,
    "properties": .settings, "env": .settings, "strings": .settings, "stringsdict": .xml,
    "txt": .document, "text": .document, "rst": .document, "rtf": .document,
    "csv": .database, "tsv": .database, "sql": .database, "db": .database, "sqlite": .database, "sqlite3": .database,
    "png": .image, "jpg": .image, "jpeg": .image, "gif": .image, "webp": .image, "heic": .image,
    "avif": .image, "bmp": .image, "tif": .image, "tiff": .image, "ico": .image, "icns": .image,
    "svg": .svg, "pdf": .pdf, "ttf": .font, "otf": .font, "woff": .font, "woff2": .font,
    "zip": .zip, "tar": .zip, "gz": .zip, "bz2": .zip, "xz": .zip, "7z": .zip, "rar": .zip, "tgz": .zip,
    "mp4": .video, "mov": .video, "mkv": .video, "webm": .video, "avi": .video,
    "mp3": .audio, "wav": .audio, "flac": .audio, "aac": .audio, "m4a": .audio, "ogg": .audio,
    "pem": .certificate, "crt": .certificate, "cer": .certificate, "p12": .certificate, "pfx": .certificate,
    "key": .key, "pub": .key,
  ]
}

/// One bounded cache for native rows and SwiftUI. No repository I/O or Launch Services lookups.
@MainActor enum FileTypeIcons {
  private struct Key: Hashable {
    let kind: FileIconKind
    let colored: Bool
    let dark: Bool
  }
  private static var images: [Key: NSImage] = [:]
  private static let context = CIContext(options: [.useSoftwareRenderer: true])

  static func image(path: String, colored: Bool, dark: Bool) -> NSImage {
    image(kind: FileIconKind.resolve(path), colored: colored, dark: dark)
  }
  static func image(kind: FileIconKind, colored: Bool, dark: Bool) -> NSImage {
    let key = Key(kind: kind, colored: colored, dark: dark)
    if let cached = images[key] { return cached }
    let suffix = !dark && [.toml, .pnpm].contains(kind) ? "_light" : ""
    let image: NSImage
    if kind.systemSymbol == nil,
      let url = AppResources.bundle.url(forResource: "filetype-" + kind.rawValue + suffix, withExtension: "svg"),
      let original = NSImage(contentsOf: url) {
      original.size = NSSize(width: 16, height: 16)
      original.isTemplate = false
      image = colored ? original : monochrome(original)
    } else {
      image = NSImage(systemSymbolName: kind.systemSymbol ?? "doc.text", accessibilityDescription: nil)
        ?? NSImage(size: NSSize(width: 16, height: 16))
      image.isTemplate = true
    }
    images[key] = image
    return image
  }

  /// Preserve white lettering and internal detail that an alpha-only template would erase.
  private static func monochrome(_ original: NSImage) -> NSImage {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return original }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.cgContext.clear(CGRect(x: 0, y: 0, width: 64, height: 64))
    original.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
    NSGraphicsContext.restoreGraphicsState()
    guard let input = CIImage(bitmapImageRep: bitmap) else { return original }
    let filtered = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
    guard let cgImage = context.createCGImage(filtered, from: filtered.extent) else { return original }
    return NSImage(cgImage: cgImage, size: NSSize(width: 16, height: 16))
  }
}

struct FileTypeIcon: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.colorScheme) private var scheme
  let path: String
  var size: CGFloat = 16
  var body: some View {
    let image = FileTypeIcons.image(path: path, colored: store.settings.coloredFileIcons, dark: scheme == .dark)
    Image(nsImage: image).renderingMode(image.isTemplate ? .template : .original)
      .resizable().interpolation(.high).scaledToFit().frame(width: size, height: size)
      .foregroundStyle(.secondary).allowsHitTesting(false).accessibilityHidden(true)
  }
}
