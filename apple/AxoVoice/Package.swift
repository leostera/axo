// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AxoVoice",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "AxoVoice", targets: ["AxoVoice"])],
    targets: [
        .target(name: "AxoVoice"),
        .testTarget(name: "AxoVoiceTests", dependencies: ["AxoVoice"])
    ]
)
