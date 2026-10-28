import XCTest

@testable import AxoPhoneModel

final class ScrollFollowTests: XCTestCase {
  func testAConversationOpensFollowingAndKeepsItsEndInViewWithoutAnimating() {
    var follow = ScrollFollow()
    XCTAssertTrue(follow.isFollowing)
    XCTAssertEqual(follow.contentChangedAtEnd(), .keepAtEnd)
    XCTAssertEqual(follow.contentChangedAtEnd(), .keepAtEnd)
    XCTAssertFalse(follow.hasNew)
  }

  func testAReaderWhoScrollsAwayKeepsTheirPlaceAndIsToldAboutNewContent() {
    var follow = ScrollFollow()
    _ = follow.scrollingChanged(to: .byReader, atEnd: true)
    XCTAssertEqual(follow.contentChangedAtEnd(), .stay, "never moved under the finger")
    _ = follow.scrollingChanged(to: .idle, atEnd: false)
    XCTAssertFalse(follow.isFollowing)
    XCTAssertEqual(follow.contentChangedAtEnd(), .stay)
    XCTAssertTrue(follow.hasNew)
  }

  func testComingBackToTheEndFollowsAgain() {
    var follow = ScrollFollow()
    _ = follow.scrollingChanged(to: .byReader, atEnd: true)
    _ = follow.scrollingChanged(to: .idle, atEnd: false)
    _ = follow.contentChangedAtEnd()
    _ = follow.scrollingChanged(to: .byReader, atEnd: false)
    _ = follow.scrollingChanged(to: .idle, atEnd: true)
    XCTAssertTrue(follow.isFollowing)
    XCTAssertFalse(follow.hasNew, "reaching the end clears it")
    XCTAssertEqual(follow.contentChangedAtEnd(), .keepAtEnd)
  }

  func testAJumpKeepsFollowingWhileItIsUnderWayAndCatchesUpIfTheEndMoved() {
    var follow = ScrollFollow()
    _ = follow.scrollingChanged(to: .byReader, atEnd: true)
    _ = follow.scrollingChanged(to: .idle, atEnd: false)
    _ = follow.contentChangedAtEnd()
    XCTAssertEqual(follow.jumpRequested(), .goToEnd)
    XCTAssertFalse(follow.hasNew)
    _ = follow.scrollingChanged(to: .byScreen, atEnd: false)
    // Messages keep arriving while the jump is still on its way: they overtake it.
    XCTAssertEqual(follow.contentChangedAtEnd(), .keepAtEnd)
    XCTAssertEqual(follow.scrollingChanged(to: .idle, atEnd: false), .keepAtEnd, "landed short of the moved end: catch up")
    XCTAssertTrue(follow.isFollowing, "only the reader stops the following")
    XCTAssertEqual(follow.contentChangedAtEnd(), .keepAtEnd)
  }

  func testSendingGoesToTheEndFromAnywhere() {
    var follow = ScrollFollow()
    _ = follow.scrollingChanged(to: .byReader, atEnd: true)
    _ = follow.scrollingChanged(to: .idle, atEnd: false)
    _ = follow.contentChangedAtEnd()
    XCTAssertEqual(follow.sent(), .goToEnd)
    XCTAssertTrue(follow.isFollowing)
    XCTAssertFalse(follow.hasNew)
  }

  func testTheKeyboardRisingKeepsAFollowersEndInView() {
    var follow = ScrollFollow()
    XCTAssertEqual(follow.bottomInsetGrew(), .keepAtEnd)
    _ = follow.scrollingChanged(to: .byReader, atEnd: true)
    _ = follow.scrollingChanged(to: .idle, atEnd: false)
    XCTAssertEqual(follow.bottomInsetGrew(), .stay)
  }
}

extension ScrollFollowTests {
  /// Tapping "Jump to new message" puts a finger on the conversation without scrolling it; the
  /// finger lifts after the jump began, still short of the end.
  func testATapThatScrollsNothingDecidesNothing() {
    var follow = ScrollFollow()
    _ = follow.scrollingChanged(to: .byReader, atEnd: true)
    _ = follow.scrollingChanged(to: .idle, atEnd: false)
    _ = follow.scrollingChanged(to: .touched, atEnd: false)
    _ = follow.jumpRequested()
    _ = follow.scrollingChanged(to: .idle, atEnd: false)
    XCTAssertTrue(follow.isFollowing)
    XCTAssertEqual(follow.contentChangedAtEnd(), .keepAtEnd)
  }
}
