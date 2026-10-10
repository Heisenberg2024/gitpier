import AppKit

enum AppResources {
  static let bundle: Bundle = {
    if let resources = Bundle.main.resourceURL,
      let packaged = Bundle(url: resources.appendingPathComponent("GitPier_GitPier.bundle"))
    {
      return packaged
    }
    return Bundle.module
  }()

  /// Sidebar, Dock and About all use the same approved raster, never a cached system icon.
  @MainActor static let applicationIcon: NSImage? = {
    guard let url = bundle.url(forResource: "gitpier-icon-1024", withExtension: "png") else {
      return nil
    }
    return NSImage(contentsOf: url)
  }()
}
