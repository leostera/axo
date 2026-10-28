import XCTest

@testable import AxoPhoneModel

/// The phone's screens: the account (0), the chats (1), the conversation (2, home), and a layer
/// that comes in over the conversation from the right (3).
final class LayerStackGeometryTests: XCTestCase {
  private let stack = LayerStackGeometry(count: 4, home: 2, width: 400)
  private var reveal: Double { stack.reveal }

  func testAtRestTheConversationCoversEverythingBelowAndTheLayerAboveIsOffScreen() {
    let home = 2.0
    XCTAssertEqual(stack.offset(of: 0, at: home), 0)
    XCTAssertEqual(stack.offset(of: 1, at: home), 0)
    XCTAssertEqual(stack.offset(of: 2, at: home), 0)
    XCTAssertEqual(stack.offset(of: 3, at: home), 400, "just off the right edge")
    XCTAssertNil(stack.edgeLayer(showing: 2))
  }

  func testShowingTheChatsPushesTheConversationAsideLeavingItsStrip() {
    XCTAssertEqual(stack.offset(of: 2, at: 1), reveal)
    XCTAssertEqual(stack.offset(of: 1, at: 1), 0)
    XCTAssertEqual(stack.edgeLayer(showing: 1), 2)
    XCTAssertEqual(stack.edgeWidth, 400 - reveal, accuracy: 0.001)
  }

  func testShowingTheAccountPushesTheChatsAsideAndTheConversationOut() {
    XCTAssertEqual(stack.offset(of: 1, at: 0), reveal, "the chats leave the strip now")
    XCTAssertEqual(stack.offset(of: 2, at: 0), 400, "the conversation goes out with them")
    XCTAssertEqual(stack.edgeLayer(showing: 0), 1)
  }

  func testTheLayerAboveTheConversationComesInOverItFromTheRight() {
    XCTAssertEqual(stack.offset(of: 3, at: 3), 400 - reveal, "leaving a strip of the conversation")
    XCTAssertEqual(stack.offset(of: 2, at: 3), 0, "which stays where it is")
    XCTAssertEqual(stack.dimming(of: 2, at: 3), 1, "and dims under it")
    XCTAssertEqual(stack.edgeLayer(showing: 3), 2)
  }

  func testOnlyWhatCanBeSeenIsOnScreen() {
    func onScreen(_ position: Double) -> [Int] { (0..<4).filter { stack.isOnScreen($0, at: position) } }
    XCTAssertEqual(onScreen(2), [2], "the conversation, covering the rest")
    XCTAssertEqual(onScreen(1.5), [1, 2], "the chats coming into view")
    XCTAssertEqual(onScreen(1), [1, 2], "the chats, and the conversation's strip")
    XCTAssertEqual(onScreen(0), [0, 1], "the account, and the chats' strip; the conversation is out")
    XCTAssertEqual(onScreen(3), [2, 3], "the layer above, and the conversation's strip beside it")
  }

  func testEveryLayerFollowsTheFingerTogether() {
    // Halfway from the conversation to the chats, then from the chats to the account.
    let halfToChats = stack.position(showing: 2, dragged: reveal / 2)
    XCTAssertEqual(halfToChats, 1.5, accuracy: 0.001)
    XCTAssertEqual(stack.offset(of: 2, at: halfToChats), reveal / 2, accuracy: 0.001)
    let halfToAccount = stack.position(showing: 1, dragged: reveal / 2)
    XCTAssertEqual(stack.offset(of: 1, at: halfToAccount), reveal / 2, accuracy: 0.001)
    XCTAssertEqual(stack.offset(of: 2, at: halfToAccount), reveal + (400 - reveal) / 2, accuracy: 0.001)
    // No layer ever leaves a gap under the one above it.
    for step in 0...40 {
      let position = Double(step) / 20
      XCTAssertLessThanOrEqual(stack.offset(of: 2, at: position), stack.offset(of: 1, at: position) + 400)
      XCTAssertGreaterThanOrEqual(stack.offset(of: 2, at: position), stack.offset(of: 1, at: position))
    }
  }

  func testPastTheEndsTheStackGivesALittleAndStops() {
    XCTAssertEqual(stack.position(showing: 0, dragged: 1000), -0.1, accuracy: 0.001)
    XCTAssertEqual(stack.position(showing: 3, dragged: -1000), 3.1, accuracy: 0.001)
    let noLayerAbove = LayerStackGeometry(count: 3, home: 2, width: 400)
    XCTAssertGreaterThan(noLayerAbove.position(showing: 2, dragged: -40), 2)
    XCTAssertLessThanOrEqual(noLayerAbove.position(showing: 2, dragged: -40), 2.1)
  }

  func testAFlickGoesOneLayerHoweverShort() {
    XCTAssertEqual(stack.target(showing: 2, dragged: 30, velocity: 900), 1, "right: the chats")
    XCTAssertEqual(stack.target(showing: 1, dragged: 30, velocity: 900), 0, "again: the account")
    XCTAssertEqual(stack.target(showing: 0, dragged: -30, velocity: -900), 1, "left: back to the chats")
    XCTAssertEqual(stack.target(showing: 2, dragged: -30, velocity: -900), 3, "left from home: the layer above")
  }

  func testASlowDragSettlesOnTheNearestLayer() {
    XCTAssertEqual(stack.target(showing: 2, dragged: reveal * 0.4, velocity: 50), 2, "not far enough: back")
    XCTAssertEqual(stack.target(showing: 2, dragged: reveal * 0.6, velocity: 50), 1, "past halfway: on")
  }

  func testOneSwipeMovesOneLayerAtMost() {
    XCTAssertEqual(stack.target(showing: 2, dragged: reveal * 1.8, velocity: 3000), 1)
    XCTAssertEqual(stack.target(showing: 0, dragged: 500, velocity: 3000), 0, "nothing below the bottom")
    XCTAssertEqual(LayerStackGeometry(count: 3, home: 2, width: 400).target(showing: 2, dragged: -50, velocity: -3000), 2,
      "nothing above the top")
  }

  func testAFlickAgainstTheDragIsNotTakenForOne() {
    // Dragged right most of the way, then flicked back left at the end: it stays.
    XCTAssertEqual(stack.target(showing: 2, dragged: reveal * 0.7, velocity: -400), 2)
  }
}

final class LayerStackDragTests: XCTestCase {
  typealias Drag = LayerStackGeometry.Drag

  func testASwipeIsClearlySidewaysAndFarEnough() {
    XCTAssertEqual(Drag.undecided.next(width: 20, height: 0, sidewaysScrolling: false), .undecided, "not far yet")
    XCTAssertEqual(Drag.undecided.next(width: 30, height: 4, sidewaysScrolling: false), .swipe)
    XCTAssertEqual(Drag.undecided.next(width: -30, height: -4, sidewaysScrolling: false), .swipe, "either way")
    XCTAssertEqual(Drag.undecided.next(width: 30, height: 14, sidewaysScrolling: false), .undecided, "a drifting drag waits")
  }

  func testAScrollStaysAScrollWhateverItDoesNext() {
    let scroll = Drag.undecided.next(width: 4, height: 30, sidewaysScrolling: false)
    XCTAssertEqual(scroll, .scroll)
    XCTAssertEqual(scroll.next(width: 300, height: 30, sidewaysScrolling: false), .scroll)
    XCTAssertEqual(Drag.swipe.next(width: 10, height: 200, sidewaysScrolling: false), .swipe, "a swipe stays a swipe")
  }

  func testACodeBlockScrollingSidewaysIsNeverASwipe() {
    XCTAssertEqual(Drag.undecided.next(width: 200, height: 0, sidewaysScrolling: true), .scroll)
  }
}
