import XCTest

@testable import AxoProtocol

/// `axo.daemon.health`, from axods old and new.
final class DaemonHealthTests: XCTestCase {
  private func decode(_ json: String) throws -> DaemonHealth {
    try JSONDecoder().decode(DaemonHealth.self, from: Data(json.utf8))
  }

  func testAnAxodSaysWhetherItMayRunAsADeveloperTool() throws {
    let health = try decode(#"{"version":"0.1.0","buildNumber":26,"status":"running","developerTools":"notAsked"}"#)
    XCTAssertEqual(health.developerTools, .notAsked)
    XCTAssertEqual(health.buildNumber, 26)
  }

  func testAnOlderAxodOrAStateThisBuildDoesNotKnowSaysNothing() throws {
    XCTAssertNil(try decode(#"{"version":"0.1.0","buildNumber":25,"status":"running"}"#).developerTools)
    XCTAssertNil(try decode(#"{"buildNumber":27,"status":"running","developerTools":"restricted"}"#).developerTools)
  }
}
