import AxoRPC
import Foundation
import GhosttyKit
import XCTest

@testable import AxoMac

/// Axod sizes panes no surface shows yet from the padding Axo reports, so it must be the padding
/// libghostty will draw: Axo's default, or the user's Ghostty config when it overrides it.
@MainActor
final class TerminalWindowPaddingTests: XCTestCase {
  override class func setUp() {
    super.setUp()
    _ = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
  }

  private func resolvedPadding(userConfig: String?) throws -> ClientViewport.Padding {
    let config = try XCTUnwrap(ghostty_config_new())
    defer { ghostty_config_free(config) }
    XCTAssertNil(GhosttyRuntime.loadAxoConfigDefaults(into: config))
    if let userConfig {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("axo-padding-test-\(UUID().uuidString).ghostty")
      try (userConfig + "\n").write(to: url, atomically: true, encoding: .utf8)
      defer { try? FileManager.default.removeItem(at: url) }
      url.path.withCString { ghostty_config_load_file(config, $0) }
    }
    ghostty_config_finalize(config)
    return GhosttyRuntime.windowPadding(from: config)
  }

  func testWithoutAnOverrideAxosDefaultPaddingApplies() throws {
    XCTAssertEqual(try resolvedPadding(userConfig: nil), GhosttyRuntime.axoWindowPadding)
  }

  func testAUserGhosttyConfigOverridesTheDefault() throws {
    XCTAssertEqual(
      try resolvedPadding(userConfig: "window-padding-x = 0\nwindow-padding-y = 3,5"),
      ClientViewport.Padding(top: 3, bottom: 5, left: 0, right: 0))
  }
}
