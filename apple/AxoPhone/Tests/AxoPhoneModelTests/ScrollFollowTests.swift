import XCTest

@testable import AxoPhoneModel

final class ScrollFollowTests: XCTestCase {
  func testTheFirstPageOpensAtItsEndWithoutAnimating() {
    var follow = ScrollFollow()
    XCTAssertEqual(follow.contentChangedAtEnd(), .jumpToEnd)
    XCTAssertEqual(follow.contentChangedAtEnd(), .followToEnd, "only the first change jumps")
  }

  func testNewContentFollowsAReaderAtTheEnd() {
    var follow = ScrollFollow()
    _ = follow.contentChangedAtEnd()
    follow.readerScrolled(atEnd: true)
    XCTAssertEqual(follow.contentChangedAtEnd(), .followToEnd)
    XCTAssertFalse(follow.hasNew)
  }

  func testAReaderWhoScrolledUpKeepsTheirPlaceAndIsToldAboutNewContent() {
    var follow = ScrollFollow()
    _ = follow.contentChangedAtEnd()
    follow.readerScrolled(atEnd: false)
    XCTAssertEqual(follow.contentChangedAtEnd(), .stay)
    XCTAssertTrue(follow.hasNew)
    follow.readerScrolled(atEnd: false)
    XCTAssertTrue(follow.hasNew, "scrolling elsewhere does not clear it")
    follow.readerScrolled(atEnd: true)
    XCTAssertFalse(follow.hasNew, "reaching the end does")
  }

  func testGoingToTheEndCountsAsBeingThereUntilTheReaderScrollsAway() {
    var follow = ScrollFollow()
    follow.readerScrolled(atEnd: false)  // the list opens at its top before the first jump
    XCTAssertEqual(follow.contentChangedAtEnd(), .jumpToEnd)
    // The jump landed a little short and the list never said so: the next message still follows.
    XCTAssertEqual(follow.contentChangedAtEnd(), .followToEnd)
    follow.readerScrolled(atEnd: false)
    XCTAssertEqual(follow.contentChangedAtEnd(), .stay)
    _ = follow.sent()
    XCTAssertEqual(follow.contentChangedAtEnd(), .followToEnd, "sending took the reader to the end")
  }

  func testSendingOrAskingGoesToTheEndFromAnywhere() {
    var follow = ScrollFollow()
    _ = follow.contentChangedAtEnd()
    follow.readerScrolled(atEnd: false)
    _ = follow.contentChangedAtEnd()
    XCTAssertEqual(follow.sent(), .followToEnd)
    XCTAssertFalse(follow.hasNew)
    _ = follow.contentChangedAtEnd()
    XCTAssertEqual(follow.jumpRequested(), .followToEnd)
    XCTAssertFalse(follow.hasNew)
  }
}
