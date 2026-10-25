import Foundation
import XCTest

@testable import AxoDaemonManager

final class RestartMethodTests: XCTestCase {
  private let definition = LaunchAgentDefinition(
    bundlePath: "/Applications/Axo.app", plistSHA256: "abc123")

  func testAnUnchangedDefinitionRestartsInPlace() {
    XCTAssertEqual(RestartMethod.decide(registered: definition, current: definition), .kickstart)
  }

  func testAChangedPlistReregisters() {
    var changed = definition
    changed.plistSHA256 = "def456"
    XCTAssertEqual(RestartMethod.decide(registered: definition, current: changed), .reregister)
  }

  func testAMovedAppReregisters() {
    var moved = definition
    moved.bundlePath = "/Users/me/Downloads/Axo.app"
    XCTAssertEqual(RestartMethod.decide(registered: definition, current: moved), .reregister)
  }

  func testAnUnknownOrUnreadableDefinitionReregisters() {
    XCTAssertEqual(RestartMethod.decide(registered: nil, current: definition), .reregister)
    XCTAssertEqual(RestartMethod.decide(registered: definition, current: nil), .reregister)
  }

  func testTheDefinitionFingerprintsTheBundledPlist() throws {
    let bundleURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("axo-definition-\(UUID().uuidString).app")
    let agents = bundleURL.appendingPathComponent("Contents/Library/LaunchAgents")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bundleURL) }
    let plist = agents.appendingPathComponent("agent.plist")
    try Data("one".utf8).write(to: plist)
    let bundle = try XCTUnwrap(Bundle(url: bundleURL))

    let first = try XCTUnwrap(LaunchAgentDefinition.current(bundle: bundle, plistName: "agent.plist"))
    XCTAssertEqual(first.bundlePath, bundleURL.standardizedFileURL.path)
    XCTAssertEqual(
      first.plistSHA256, "7692c3ad3540bb803c020b3aee66cd8887123234ea0c6e7143c0add73ff431ed")
    try Data("two".utf8).write(to: plist)
    let second = try XCTUnwrap(LaunchAgentDefinition.current(bundle: bundle, plistName: "agent.plist"))
    XCTAssertNotEqual(first, second)
    XCTAssertNil(LaunchAgentDefinition.current(bundle: bundle, plistName: "missing.plist"))
  }
}
