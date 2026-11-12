import AxoPhoneModel
import AxoWatchModel
import XCTest

final class WatchHistoryPagingTests: XCTestCase {
  func testOpeningAtTheBottomNeverFetchesHistoryByItself() {
    var paging = WatchHistoryPaging()
    XCTAssertFalse(paging.begin(history: .loaded(records: 50, hasOlder: true), hasScrolled: false, nearTop: true))
    XCTAssertFalse(paging.begin(history: .loaded(records: 50, hasOlder: true), hasScrolled: true, nearTop: false))
    XCTAssertTrue(paging.begin(history: .loaded(records: 50, hasOlder: true), hasScrolled: true, nearTop: true))
  }

  func testItPagesAgainAfterProgressButDoesNotSpinOnFailureOrDuplicateGeometry() {
    var paging = WatchHistoryPaging()
    XCTAssertTrue(paging.begin(history: .loaded(records: 50, hasOlder: true), hasScrolled: true, nearTop: true))
    XCTAssertFalse(paging.begin(history: .loadingOlder(records: 50), hasScrolled: true, nearTop: true))
    XCTAssertFalse(paging.begin(history: .loaded(records: 50, hasOlder: true), hasScrolled: true, nearTop: true))
    XCTAssertTrue(paging.begin(history: .loaded(records: 100, hasOlder: true), hasScrolled: true, nearTop: true))
    XCTAssertFalse(paging.begin(history: .loaded(records: 150, hasOlder: false), hasScrolled: true, nearTop: true))
  }

  func testToolOnlyPagesCannotTriggerAnUnboundedAutomaticScan() {
    var paging = WatchHistoryPaging()
    for records in [50, 100, 150] {
      XCTAssertTrue(paging.begin(history: .loaded(records: records, hasOlder: true), hasScrolled: true, nearTop: true))
    }
    XCTAssertFalse(paging.begin(history: .loaded(records: 200, hasOlder: true), hasScrolled: true, nearTop: true))
    paging.interactionBegan()
    XCTAssertTrue(paging.begin(history: .loaded(records: 200, hasOlder: true), hasScrolled: true, nearTop: true))
  }

  func testASecondScrollGestureCanRetryAFailedPage() {
    var paging = WatchHistoryPaging()
    XCTAssertTrue(paging.begin(history: .loaded(records: 50, hasOlder: true), hasScrolled: true, nearTop: true))
    XCTAssertFalse(paging.begin(history: .loaded(records: 50, hasOlder: true), hasScrolled: true, nearTop: true))
    paging.interactionBegan()
    XCTAssertTrue(paging.begin(history: .loaded(records: 50, hasOlder: true), hasScrolled: true, nearTop: true))
  }

  func testAnExplicitRetryAndChangingSessionsAreAllowed() {
    var paging = WatchHistoryPaging()
    XCTAssertTrue(paging.begin(history: .loaded(records: 50, hasOlder: true), hasScrolled: true, nearTop: true))
    XCTAssertTrue(paging.begin(history: .loaded(records: 50, hasOlder: true), hasScrolled: false, nearTop: false, explicit: true))
    paging.reset()
    XCTAssertTrue(paging.begin(history: .loaded(records: 50, hasOlder: true), hasScrolled: true, nearTop: true))
  }
}
