// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "AxoClient",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .library(name: "AxoClient", targets: ["AxoClient"])
  ],
  dependencies: [
    .package(path: "../AxoProtocol")
  ],
  targets: [
    .target(
      name: "AxoClient",
      dependencies: [.product(name: "AxoProtocol", package: "AxoProtocol")]
    ),
    .testTarget(
      name: "AxoClientTests",
      dependencies: ["AxoClient", .product(name: "AxoProtocol", package: "AxoProtocol")]),
  ],
  swiftLanguageVersions: [.v5]
)
