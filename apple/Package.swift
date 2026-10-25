// swift-tools-version: 6.0
// The one manifest Bazel reads external Swift dependencies from
// (`swift_deps.from_package` in MODULE.bazel accepts a single manifest).
// Every remote package any Axo Swift package uses must be listed here and pinned in
// Package.resolved; each package's own Package.swift still lists what it uses for SwiftPM.
import PackageDescription

let package = Package(
  name: "AxoDependencies",
  dependencies: [
    .package(url: "https://github.com/ChimeHQ/JSONRPC.git", from: "0.9.2"),
    .package(url: "https://github.com/ordo-one/FuzzyMatch.git", from: "1.4.0"),
  ]
)
