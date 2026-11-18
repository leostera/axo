import AxoMobileModel
import XCTest

final class RequestNotificationCleanupTests: XCTestCase {
  func testALaggingSnapshotCannotEraseANewBanner() {
    let received = Date(timeIntervalSince1970: 100)
    for age in [-1.0, 0, 1, 9.999] {
      XCTAssertFalse(RequestNotificationCleanup.shouldRemove(receivedAt: received,
        belongsToCurrentAccount: true, isPending: false, now: received.addingTimeInterval(age)))
    }
    XCTAssertTrue(RequestNotificationCleanup.shouldRemove(receivedAt: received,
      belongsToCurrentAccount: true, isPending: false, now: received.addingTimeInterval(10)))
  }

  func testPendingAlertsStayButOtherAccountAlertsGoImmediately() {
    let received = Date(timeIntervalSince1970: 100)
    XCTAssertFalse(RequestNotificationCleanup.shouldRemove(receivedAt: received,
      belongsToCurrentAccount: true, isPending: true, now: received.addingTimeInterval(100)))
    XCTAssertTrue(RequestNotificationCleanup.shouldRemove(receivedAt: received,
      belongsToCurrentAccount: false, isPending: true, now: received))
  }
}
