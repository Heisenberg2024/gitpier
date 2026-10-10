// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "GitPier",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "GitPierCore", targets: ["GitPierCore"]),
    .executable(name: "GitPier", targets: ["GitPier"]),
  ],
  dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")],
  targets: [
    .target(name: "GitPierCore", dependencies: ["PTYSupport"]),
    .target(name: "PTYSupport"),
    .executableTarget(
      name: "GitPier",
      dependencies: [
        "GitPierCore", "PTYSupport", .product(name: "SwiftTerm", package: "SwiftTerm"),
      ], resources: [.process("Resources")]),
    .testTarget(name: "GitPierCoreTests", dependencies: ["GitPierCore"]),
  ]
)
