import XCTest

@testable import AxoMac

final class LaunchSplashGateTests: XCTestCase {
  func testWaitsUntilReady() {
    XCTAssertFalse(LaunchSplashGate.shouldReveal(ready: false, needsAttention: false, elapsed: .seconds(3)))
    XCTAssertTrue(LaunchSplashGate.shouldReveal(ready: true, needsAttention: false, elapsed: .seconds(3)))
  }

  func testDoesNotFlashWhenAlreadyReady() {
    XCTAssertFalse(LaunchSplashGate.shouldReveal(ready: true, needsAttention: false, elapsed: .milliseconds(200)))
  }

  func testGivesWayWhenTheDaemonNeedsThePerson() {
    XCTAssertTrue(LaunchSplashGate.shouldReveal(ready: false, needsAttention: true, elapsed: .zero))
  }

  func testGivesWayAfterItsPatienceRunsOut() {
    XCTAssertTrue(LaunchSplashGate.shouldReveal(ready: false, needsAttention: false, elapsed: .seconds(12)))
  }
}
