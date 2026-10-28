import XCTest

/// Scripted swipes between layers, for scripts/phone-swipe-motion.sh: it records the simulator
/// screen while this runs and follows the magenta stripe the app draws on the conversation's
/// edge (`AXO_PHONE_PREVIEW_MARKERS=1`) frame by frame. Pauses between gestures let the script
/// tell them apart. On its own the test only checks the stack ends where each swipe sent it.
final class AxoPhoneMotionTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testSwipeMotionBetweenLayers() {
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1", "AXO_PHONE_PREVIEW_CHAT": "1", "AXO_PHONE_PREVIEW_MARKERS": "1"]
    app.launchArguments = ["-appearance", "light"]
    app.launch()
    let title = app.staticTexts["conversation-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 15))
    let rest = title.frame.minX

    func point(_ x: CGFloat) -> XCUICoordinate { app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.55)) }
    func pause(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    func drag(from: CGFloat, to: CGFloat, speed: CGFloat, hold: TimeInterval) {
      point(from).press(forDuration: 0.05, thenDragTo: point(to), withVelocity: XCUIGestureVelocity(speed), thenHoldForDuration: hold)
    }

    pause(1.5)
    // A slow drag that stops before letting go: the spring should start where the finger left it.
    drag(from: 0.04, to: 0.6, speed: 500, hold: 0.4)
    pause(1.5)
    XCTAssertGreaterThan(title.frame.minX, rest + 200, "slow drag opened the chats")
    drag(from: 0.92, to: 0.35, speed: 500, hold: 0.4)
    pause(1.5)
    XCTAssertEqual(title.frame.minX, rest, accuracy: 1, "slow drag came back")
    // Flicks: let go while moving fast.
    drag(from: 0.04, to: 0.45, speed: 2500, hold: 0)
    pause(1.5)
    XCTAssertGreaterThan(title.frame.minX, rest + 200, "flick opened the chats")
    drag(from: 0.92, to: 0.5, speed: 2500, hold: 0)
    pause(1.5)
    XCTAssertEqual(title.frame.minX, rest, accuracy: 1, "flick came back")
  }
}
