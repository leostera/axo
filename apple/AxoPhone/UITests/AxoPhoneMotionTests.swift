import XCTest

/// Scripted swipes between layers (gentle pushes, slow drags held before letting go, flicks),
/// checking each ends where it should and moves smoothly getting there. The app notes where the
/// conversation layer is at every frame (`AXO_PHONE_PREVIEW_MOTION`); a snap is the layer's speed
/// changing all at once, as a canned jump on release does. Run it after touching `LayerStack`.
final class AxoPhoneMotionTests: XCTestCase {
  /// The largest change of speed from one frame to the next, in points a second. A spring, a
  /// finger, or a push easing back changes speed a little every frame; a snap, hundreds of points.
  static let jump = 2500.0

  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testSwipeMotionBetweenLayers() throws {
    let outputs = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"] ?? NSTemporaryDirectory()
    let log = URL(fileURLWithPath: outputs).appendingPathComponent("motion.txt")
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1", "AXO_PHONE_PREVIEW_CHAT": "1", "AXO_PHONE_PREVIEW_MOTION": log.path]
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
    // Gentle pushes, let go while moving: not enough momentum to carry the stack halfway, so it
    // eases back from where the finger left it. (A rule that took any 300 pt/s for a flick opened
    // the chats on these.)
    drag(from: 0.04, to: 0.2, speed: 300, hold: 0)
    pause(1.5)
    XCTAssertEqual(title.frame.minX, rest, accuracy: 1, "a gentle push eased back")
    drag(from: 0.04, to: 0.25, speed: 700, hold: 0)
    pause(1.5)
    XCTAssertEqual(title.frame.minX, rest, accuracy: 1, "a quicker push, still short, eased back")
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

    let frames = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").compactMap(Frame.init)
    let movements = Movement.split(frames)
    for (n, movement) in movements.enumerated() { print("MOTION \(n + 1): \(movement)") }
    // At least one a swipe (a drag held before letting go is two: the finger's, then the spring's).
    XCTAssertGreaterThanOrEqual(movements.count, 6, "the layer's frames were noted")
    let snaps = movements.filter { $0.largestChangeOfSpeed > Self.jump }
    XCTAssertTrue(snaps.isEmpty, "these snap, changing speed by over \(Int(Self.jump)) pt/s in a frame:\n" + snaps.map(\.description).joined(separator: "\n"))
  }
}

/// Where the layer was, and when.
private struct Frame {
  let time: Double
  let x: Double

  init?(_ line: Substring) {
    let fields = line.split(separator: " ")
    guard fields.count == 2, let time = Double(fields[0]), let x = Double(fields[1]) else { return nil }
    self.time = time
    self.x = x
  }
}

/// A run of frames in which the layer moves, between rests.
private struct Movement: CustomStringConvertible {
  let frames: [Frame]

  /// Frames are noted only when the layer moves, so a rest shows as a gap.
  static func split(_ frames: [Frame]) -> [Movement] {
    var movements: [Movement] = []
    var current: [Frame] = []
    for (previous, frame) in zip(frames, frames.dropFirst()) {
      let afterRest = frame.time - previous.time > 0.3
      if !current.isEmpty && afterRest {
        movements.append(Movement(frames: current))
        current = []
      }
      if abs(frame.x - previous.x) > 0.25 {
        // A movement starts from the frame before it, unless that was before a rest: then the
        // layer's first step is unknown, not slow.
        if current.isEmpty && !afterRest { current = [previous] }
        current.append(frame)
      }
    }
    if !current.isEmpty { movements.append(Movement(frames: current)) }
    return movements
  }

  /// Points a second between consecutive frames (taking at least a 120 Hz frame between them).
  var speeds: [Double] {
    zip(frames, frames.dropFirst()).map { a, b in (b.x - a.x) / max(b.time - a.time, 1.0 / 120) }
  }

  var largestChangeOfSpeed: Double {
    let speeds = speeds
    return zip(speeds, speeds.dropFirst()).map { abs($1 - $0) }.max() ?? 0
  }

  var description: String {
    let duration = (frames.last!.time - frames.first!.time) * 1000
    let top = speeds.map(abs).max() ?? 0
    return String(
      format: "%.1f -> %.1f pt in %.0f ms, %d frames, top speed %.0f pt/s, largest change of speed %.0f pt/s",
      frames.first!.x, frames.last!.x, duration, frames.count, top, largestChangeOfSpeed)
  }
}
