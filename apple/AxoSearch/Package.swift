// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AxoSearch",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .library(name: "AxoSearch", targets: ["AxoSearch"])
  ],
  dependencies: [
    .package(url: "https://github.com/ordo-one/FuzzyMatch.git", from: "1.4.0")
  ],
  targets: [
    .target(name: "AxoSearch", dependencies: ["FuzzyMatch"]),
    .testTarget(name: "AxoSearchTests", dependencies: ["AxoSearch"]),
  ],
  swiftLanguageModes: [.v5]
)
