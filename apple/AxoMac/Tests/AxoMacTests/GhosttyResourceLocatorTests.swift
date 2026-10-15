import Foundation
import XCTest

@testable import AxoMac

final class GhosttyResourceLocatorTests: XCTestCase {
  func testPrefersInstalledGhosttyResourcesWhenThemesExist() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let appURL = root.appendingPathComponent("Ghostty.app", isDirectory: true)
    let resourcesURL = appURL.appendingPathComponent(
      "Contents/Resources/ghostty", isDirectory: true)
    let themesURL = resourcesURL.appendingPathComponent("themes", isDirectory: true)
    try FileManager.default.createDirectory(at: themesURL, withIntermediateDirectories: true)

    let bundledResourcesURL = root.appendingPathComponent("bundled", isDirectory: true)
    let resolved = GhosttyResourceLocator.resolve(
      installedGhosttyAppURL: appURL,
      bundledResourcesURL: bundledResourcesURL
    )

    XCTAssertEqual(resolved, resourcesURL)
  }

  func testFallsBackToBundledResourcesWithoutInstalledThemeDirectory() {
    let appURL = URL(fileURLWithPath: "/Ghostty.app", isDirectory: true)
    let bundledResourcesURL = URL(fileURLWithPath: "/Axo/ghostty-resources", isDirectory: true)

    XCTAssertEqual(
      GhosttyResourceLocator.resolve(
        installedGhosttyAppURL: appURL,
        bundledResourcesURL: bundledResourcesURL
      ),
      bundledResourcesURL
    )
  }

  func testUsesBundledResourcesWhenGhosttyIsNotInstalled() {
    let bundledResourcesURL = URL(fileURLWithPath: "/Axo/ghostty-resources", isDirectory: true)

    XCTAssertEqual(
      GhosttyResourceLocator.resolve(
        installedGhosttyAppURL: nil,
        bundledResourcesURL: bundledResourcesURL
      ),
      bundledResourcesURL
    )
  }
}
