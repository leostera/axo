// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AxoMascot",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .library(name: "AxoMascot", targets: ["AxoMascot"])
  ],
  targets: [
    .target(name: "AxoMascot"),
    .testTarget(name: "AxoMascotTests", dependencies: ["AxoMascot"]),
  ],
  swiftLanguageModes: [.v5]
)
