import AppKit
import GitPierCore

enum AppResources {
  static let version =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? releaseConfiguration.version
  static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? releaseConfiguration.build
  static let bundle: Bundle = {
    if let resources = Bundle.main.resourceURL,
      let packaged = Bundle(url: resources.appendingPathComponent("GitPier_GitPier.bundle"))
    {
      return packaged
    }
    return Bundle.module
  }()

  static let releaseConfiguration: ReleaseConfiguration = {
    guard let url = bundle.url(forResource: "ReleaseConfiguration", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let config = try? JSONDecoder().decode(ReleaseConfiguration.self, from: data) else {
      fatalError("Missing release configuration")
    }
    return config
  }()

  /// Sidebar, Dock and About all use the same approved raster, never a cached system icon.
  @MainActor static let applicationIcon: NSImage? = {
    guard let url = bundle.url(forResource: "gitpier-icon-1024", withExtension: "png") else {
      return nil
    }
    return NSImage(contentsOf: url)
  }()

  @MainActor private static let hostingLogos: [String: NSImage] = {
    var images: [String: NSImage] = [:]
    for name in ["hosting-github-light", "hosting-github-dark", "hosting-gitlab", "hosting-gitea"] {
      let ext = name.hasPrefix("hosting-github") ? "pdf" : "svg"
      if let url = bundle.url(forResource: name, withExtension: ext), let image = NSImage(contentsOf: url) { images[name] = image }
    }
    return images
  }()
  @MainActor static func hostingLogo(_ provider: HostingProvider, dark: Bool) -> NSImage? {
    hostingLogos["hosting-" + provider.rawValue + (provider == .github ? (dark ? "-dark" : "-light") : "")]
  }
}
