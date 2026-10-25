// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "AxoRPC",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "AxoRPC", targets: ["AxoRPC"])
  ],
  dependencies: [
    .package(url: "https://github.com/ChimeHQ/JSONRPC.git", from: "0.9.2"),
    .package(path: "../AxoProtocol"),
  ],
  targets: [
    .target(
      name: "AxoRPC",
      dependencies: [
        .product(name: "JSONRPC", package: "JSONRPC"),
        .product(name: "AxoProtocol", package: "AxoProtocol"),
      ]
    ),
    .testTarget(
      name: "AxoRPCTests",
      dependencies: ["AxoRPC", .product(name: "AxoProtocol", package: "AxoProtocol")]),
  ],
  swiftLanguageVersions: [.v5]
)
