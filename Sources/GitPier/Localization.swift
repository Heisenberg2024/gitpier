import Foundation

@MainActor func localizedUI(_ english: String) -> String {
  guard AppStore.shared.settings.language == .simplifiedChinese else { return english }
  return UILocalization.chinese[english] ?? english.components(separatedBy: "\n").map { UILocalization.chinese[$0] ?? $0 }.joined(separator: "\n")
}

enum UILocalization {
  static let chinese: [String: String] = {
    guard let url = AppResources.bundle.url(forResource: "zh-Hans", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let strings = try? JSONDecoder().decode([String: String].self, from: data)
    else { return [:] }
    return strings
  }()
}
