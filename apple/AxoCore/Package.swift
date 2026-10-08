// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AxoCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "AxoCore", targets: ["AxoCore"])],
    targets: [
        .target(name: "AxoCore"),
        .testTarget(name: "AxoCoreTests", dependencies: ["AxoCore"]),
    ]
)
