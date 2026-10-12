// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "GitPier",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "GitPierCore", targets: ["GitPierCore"]),
    .executable(name: "GitPier", targets: ["GitPier"]),
  ],
  dependencies: [
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
  ],
  targets: [
    .target(name: "GitPierCore", dependencies: ["PTYSupport"]),
    .target(name: "PTYSupport"),
    .executableTarget(
      name: "GitPier",
      dependencies: [
        "GitPierCore", "PTYSupport", .product(name: "SwiftTerm", package: "SwiftTerm"),
        .product(name: "Sparkle", package: "Sparkle"),
      ], resources: [.process("Resources")],
      linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    .testTarget(name: "GitPierCoreTests", dependencies: ["GitPierCore"]),
  ]
)
