import Foundation

public struct ReleaseConfiguration: Codable, Sendable {
  public let version: String
  public let build: String
  public let bundleIdentifier: String
  public let minimumSystemVersion: String
  public let feedURL: String
  public let publicEDKey: String

  public var hasSigningKey: Bool { Data(base64Encoded: publicEDKey)?.count == 32 }
  public func validate() throws {
    guard version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
      let number = Int(build), number > 0,
      bundleIdentifier == "com.heisenberg2024.gitpier",
      minimumSystemVersion == "14.0",
      feedURL == "https://github.com/Heisenberg2024/gitpier/releases/latest/download/appcast.xml",
      publicEDKey.isEmpty || hasSigningKey
    else {
      throw GitPierError.invalidInput("Invalid release configuration.")
    }
  }
}
