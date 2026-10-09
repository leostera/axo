// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AxoProtocol",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AxoProtocol", targets: ["AxoProtocol"]),
    ],
    targets: [
        .target(name: "AxoProtocol"),
        .testTarget(
            name: "AxoProtocolTests",
            dependencies: ["AxoProtocol"],
            path: "tests/AxoProtocolTests"
        ),
    ]
)
