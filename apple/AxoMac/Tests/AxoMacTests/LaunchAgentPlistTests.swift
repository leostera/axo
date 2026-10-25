import Foundation
import XCTest

/// axod's LaunchAgent: its children are the user's shells and Pi, so launchd must not run them
/// at background priority.
final class LaunchAgentPlistTests: XCTestCase {
  private func launchAgent() throws -> [String: Any] {
    let path = try XCTUnwrap(
      ProcessInfo.processInfo.environment["AXO_LAUNCH_AGENT_PLIST"], "run under Bazel")
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try XCTUnwrap(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
  }

  func testShellsAndPiRunWithInteractivePriority() throws {
    XCTAssertEqual(try launchAgent()["ProcessType"] as? String, "Interactive")
  }
}
