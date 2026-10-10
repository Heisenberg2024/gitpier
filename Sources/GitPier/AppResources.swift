import Foundation

enum AppResources {
  static let bundle: Bundle = {
    if let resources = Bundle.main.resourceURL,
      let packaged = Bundle(url: resources.appendingPathComponent("GitPier_GitPier.bundle"))
    {
      return packaged
    }
    return Bundle.module
  }()
}
