import AxoRPC
import XCTest

@testable import AxoMac

final class ReattachThrottleTests: XCTestCase {
  func testAStreamThatEndsAgainSoonIsReattachedLaterNotDropped() {
    var throttle = ReattachThrottle()
    let start = ContinuousClock.now
    XCTAssertEqual(throttle.decide(for: 1, at: start), .now)
    XCTAssertEqual(throttle.decide(for: 1, at: start + .milliseconds(500)), .after(.milliseconds(1500)))
    // The deferred attempt counts from when it will run, so the next one waits a full window.
    XCTAssertEqual(throttle.decide(for: 1, at: start + .seconds(2)), .after(.seconds(2)))
    XCTAssertEqual(throttle.decide(for: 1, at: start + .seconds(10)), .now)
  }

  func testShellsAreThrottledIndependentlyAndForgettingResets() {
    var throttle = ReattachThrottle()
    let start = ContinuousClock.now
    XCTAssertEqual(throttle.decide(for: 1, at: start), .now)
    XCTAssertEqual(throttle.decide(for: 2, at: start), .now)
    throttle.forget(1)
    XCTAssertEqual(throttle.decide(for: 1, at: start + .milliseconds(1)), .now)
  }
}
