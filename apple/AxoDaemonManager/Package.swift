// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "AxoDaemonManager",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "AxoDaemonManager", targets: ["AxoDaemonManager"])
  ],
  dependencies: [
    .package(path: "../AxoRPC")
  ],
  targets: [
    .target(
      name: "AxoDaemonManager",
      dependencies: [.product(name: "AxoRPC", package: "AxoRPC")]
    ),
    .testTarget(name: "AxoDaemonManagerTests", dependencies: ["AxoDaemonManager"]),
  ],
  swiftLanguageVersions: [.v5]
)
