import AppKit
import AxoDaemonManager
import SwiftUI
import XCTest

@testable import AxoMac

final class AppUpgradePresentationTests: XCTestCase {
  @MainActor
  func testDownloadPresentationUsesTheCapturedSemanticVersionNotTheBuildNumber() throws {
    let commit = String(repeating: "a", count: 40)
    let release = try PublishedBuild(build: 329, axodBuild: 80, commit: commit, version: "0.58",
      artifacts: ["aarch64-apple-darwin": "axo-0.58-aaaaaaaaaaaa-aarch64-apple-darwin.zip"])
    let view = AppUpgradeDownloadProgress(release: release)
    XCTAssertEqual(view.title, "Downloading Axo 0.58")
    XCTAssertNotEqual(view.title, "Downloading Axo 329")

    // Render only the fixture view, never launch or restart the person’s running Axo.
    let hosting = NSHostingView(rootView: view.background(.background))
    let size = hosting.fittingSize
    XCTAssertEqual(size.width, 340)
    XCTAssertGreaterThan(size.height, 100)
    hosting.frame = NSRect(origin: .zero, size: size)
    let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let directory = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"]
      ?? FileManager.default.temporaryDirectory.path
    let path = URL(fileURLWithPath: directory).appendingPathComponent("axo-upgrade-progress.png")
    try png.write(to: path)
    print("Upgrade progress screenshot: \(path.path)")
  }
}
