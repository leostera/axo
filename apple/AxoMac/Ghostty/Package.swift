// swift-tools-version: 6.0
import PackageDescription

// Test the same source files compiled into Axo, without launching the real application.
let package = Package(
    name: "GhosttyLayout",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "GhosttyLayout", path: ".", exclude: ["Package.swift", "Tests", "README.md", "LICENSE.txt"]),
        .testTarget(name: "GhosttyLayoutTests", dependencies: ["GhosttyLayout"], path: "Tests"),
    ],
    swiftLanguageModes: [.v5]
)
