import AxoDaemonManager
import XCTest

@testable import AxoMac

final class LaunchSplashGateTests: XCTestCase {
  func testWaitsUntilReadyHoweverLongItTakes() {
    XCTAssertFalse(LaunchSplashGate.shouldReveal(ready: false, elapsed: .seconds(3)))
    XCTAssertFalse(LaunchSplashGate.shouldReveal(ready: false, elapsed: .seconds(600)))
    XCTAssertTrue(LaunchSplashGate.shouldReveal(ready: true, elapsed: .seconds(3)))
  }

  func testDoesNotFlashWhenAlreadyReady() {
    XCTAssertFalse(LaunchSplashGate.shouldReveal(ready: true, elapsed: .milliseconds(200)))
  }

  func testAsksThePersonOnlyWhenAxodCannotStartWithoutThem() {
    XCTAssertEqual(LaunchSplashGate.attention(for: .requiresApproval), .approveInLoginItems)
    XCTAssertEqual(LaunchSplashGate.attention(for: .disabled), .turnOn)
    XCTAssertEqual(LaunchSplashGate.attention(for: .failed("boom")), .retry(reason: "boom"))
    XCTAssertNil(LaunchSplashGate.attention(for: .starting))
    XCTAssertNil(LaunchSplashGate.attention(for: .updating))
  }

  func testProgressFollowsTheLaunchSteps() {
    XCTAssertEqual(LaunchSplashGate.progress(daemonRunning: false, catalogLive: false), 0.25)
    XCTAssertEqual(LaunchSplashGate.progress(daemonRunning: true, catalogLive: false), 0.65)
    XCTAssertEqual(LaunchSplashGate.progress(daemonRunning: true, catalogLive: true), 1)
    // A live catalog without a running daemon is stale, not done.
    XCTAssertEqual(LaunchSplashGate.progress(daemonRunning: false, catalogLive: true), 0.25)
  }
}
