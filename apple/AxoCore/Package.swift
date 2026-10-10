// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AxoCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "AxoCore", targets: ["AxoCore"])],
    dependencies: [
        .package(path: "../../protocol"),
    ],
    targets: [
        .target(name: "AxoCore", dependencies: [
            .product(name: "AxoProtocol", package: "protocol"),
        ]),
        .testTarget(name: "AxoCoreTests", dependencies: [
            "AxoCore",
            .product(name: "AxoProtocol", package: "protocol"),
        ]),
    ]
)
