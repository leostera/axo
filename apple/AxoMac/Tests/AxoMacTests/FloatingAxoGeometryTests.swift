import XCTest

@testable import AxoMac

final class FloatingAxoGeometryTests: XCTestCase {
  func testTheThrowIsHowFastThePointerWasGoingAtTheEnd() {
    var velocity = ThrowVelocity()
    // Slow at first, then 1000 points a second to the right.
    velocity.add(CGPoint(x: 0, y: 0), at: 0)
    velocity.add(CGPoint(x: 5, y: 0), at: 0.5)
    velocity.add(CGPoint(x: 25, y: 0), at: 0.52)
    velocity.add(CGPoint(x: 65, y: 10), at: 0.56)
    let v = velocity.velocity(at: 0.56)
    XCTAssertEqual(v.dx, 1000, accuracy: 1)
    XCTAssertEqual(v.dy, 10 / 0.06, accuracy: 1)
  }

  func testHoldingStillBeforeLettingGoDropsIt() {
    var velocity = ThrowVelocity()
    velocity.add(CGPoint(x: 0, y: 0), at: 0)
    velocity.add(CGPoint(x: 100, y: 0), at: 0.05)
    XCTAssertEqual(velocity.velocity(at: 0.5), .zero)
  }

  func testAWildFlickIsClamped() {
    var velocity = ThrowVelocity()
    velocity.add(CGPoint(x: 0, y: 0), at: 0)
    velocity.add(CGPoint(x: 1000, y: 0), at: 0.01)
    XCTAssertEqual(velocity.velocity(at: 0.01).dx, ThrowVelocity.fastest, accuracy: 0.001)
  }

  func testAWindowInFrontHidesPartOfTheTopEdgeBehindIt() {
    let front = CGRect(x: 100, y: 0, width: 200, height: 500)
    let back = CGRect(x: 0, y: 0, width: 600, height: 400)
    XCTAssertEqual(
      WindowLedges.ledges(of: [front, back]),
      [Ledge(y: 500, minX: 100, maxX: 300), Ledge(y: 400, minX: 0, maxX: 100), Ledge(y: 400, minX: 300, maxX: 600)])
  }

  func testAWindowBelowTheEdgeDoesNotHideIt() {
    let front = CGRect(x: 0, y: 0, width: 600, height: 300)
    let back = CGRect(x: 0, y: 0, width: 600, height: 400)
    XCTAssertEqual(WindowLedges.ledges(of: [front, back]).count, 2)
  }

  func testSlivers() {
    let front = CGRect(x: 10, y: 0, width: 580, height: 500)
    let back = CGRect(x: 0, y: 0, width: 600, height: 400)
    XCTAssertEqual(WindowLedges.ledges(of: [front, back]), [Ledge(y: 500, minX: 10, maxX: 590)])
  }

  func testAPressIsAClickUntilItMoves() {
    XCTAssertFalse(DragThreshold.isDrag(from: .zero, to: CGPoint(x: 2, y: 2)))
    XCTAssertTrue(DragThreshold.isDrag(from: .zero, to: CGPoint(x: 4, y: 0)))
  }
}
