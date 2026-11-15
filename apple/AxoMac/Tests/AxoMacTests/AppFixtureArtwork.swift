import AppKit
import XCTest

/// Use Axo's real packaged icon in snapshots, not XCTest's generic document icon. No running
/// application's icon, Dock state or settings are changed to render a fixture.
enum AppFixtureArtwork {
  static func icon() throws -> NSImage {
    let environment = ProcessInfo.processInfo.environment
    let relative = try XCTUnwrap(environment["AXO_TEST_APP_ICON"])
    let paths = [relative,
      (environment["TEST_SRCDIR"] ?? "") + "/" + (environment["TEST_WORKSPACE"] ?? "_main") + "/" + relative]
    let path = try XCTUnwrap(paths.first { FileManager.default.fileExists(atPath: $0) })
    return try XCTUnwrap(NSImage(contentsOfFile: path))
  }
}
