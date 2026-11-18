import AxoProtocol
import XCTest

@testable import AxoDaemonManager

final class DaemonBuildChangeTests: XCTestCase {
  private let bundled = BuildNumber(87)!

  func testTheSameBuildIsUsedAsItIs() {
    XCTAssertEqual(DaemonBuildChange.between(running: 87, bundled: bundled), .none)
  }

  func testAnOlderRunningAxodIsUpgraded() {
    XCTAssertEqual(DaemonBuildChange.between(running: 86, bundled: bundled), .upgrade)
  }

  func testANewerRunningAxodIsNeverRestartedIntoAnOlderOne() {
    XCTAssertEqual(DaemonBuildChange.between(running: 88, bundled: bundled), .downgrade(running: 88))
  }
}
