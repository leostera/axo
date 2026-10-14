// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "AxoRPC",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "AxoRPC", targets: ["AxoRPC"])
  ],
  dependencies: [
    .package(url: "https://github.com/ChimeHQ/JSONRPC.git", from: "0.9.2")
  ],
  targets: [
    .target(
      name: "AxoRPC",
      dependencies: [.product(name: "JSONRPC", package: "JSONRPC")]
    ),
    .testTarget(name: "AxoRPCTests", dependencies: ["AxoRPC"]),
  ],
  swiftLanguageVersions: [.v5]
)
