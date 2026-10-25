// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "AxoProtocol",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "AxoProtocol", targets: ["AxoProtocol"])
  ],
  targets: [
    .target(name: "AxoProtocol"),
    .testTarget(name: "AxoProtocolTests", dependencies: ["AxoProtocol"]),
  ],
  swiftLanguageVersions: [.v5]
)
