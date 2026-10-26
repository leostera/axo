// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AxoPhone",
  platforms: [.macOS(.v14), .iOS(.v18)],
  products: [.library(name: "AxoPhoneModel", targets: ["AxoPhoneModel"])],
  dependencies: [.package(path: "../AxoClient"), .package(path: "../AxoProtocol")],
  targets: [
    .target(
      name: "AxoPhoneModel",
      dependencies: [
        .product(name: "AxoClient", package: "AxoClient"),
        .product(name: "AxoProtocol", package: "AxoProtocol"),
      ]),
    .testTarget(name: "AxoPhoneModelTests", dependencies: ["AxoPhoneModel"]),
  ],
  swiftLanguageVersions: [.v5]
)
