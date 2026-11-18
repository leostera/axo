import AxoMobileModel
import XCTest

final class RequestNotificationRouteTests: XCTestCase {
  func testRevisionsSurviveBackupAndClockRollbackWithoutOverflow() {
    let now = Date(timeIntervalSince1970: 1000)
    XCTAssertEqual(RequestNotificationRevision.next(after: nil, now: now), 1_000_001)
    XCTAssertEqual(RequestNotificationRevision.next(after: 1, now: now), 1_000_001)
    XCTAssertEqual(RequestNotificationRevision.next(after: 2_000_000, now: now), 2_000_001)
    XCTAssertNil(RequestNotificationRevision.next(after: .max, now: now))
    XCTAssertNil(RequestNotificationRevision.next(after: -1, now: now))
    XCTAssertNil(RequestNotificationRevision.next(after: nil, now: Date(timeIntervalSince1970: .infinity)))
    XCTAssertNil(RequestNotificationRevision.next(after: nil, now: Date(timeIntervalSince1970: -1)))
  }

  func testOnlyRoutingIdentifiersParseAndThereIsNoAnswerAction() throws {
    let account = UUID(), host = UUID(), session = UUID(), request = UUID()
    let wire: [String: Any] = ["version": 1, "accountId": account.uuidString,
      "hostId": host.uuidString, "sessionId": session.uuidString, "requestId": request.uuidString]
    let parsed = try XCTUnwrap(RequestNotificationRoute(userInfo: ["axo": wire]))
    XCTAssertEqual(parsed.accountID, account)
    XCTAssertEqual(parsed.requestID, request)
    for malformed: [String: Any] in [
      wire.merging(["version": 2]) { _, value in value },
      wire.merging(["version": true]) { _, value in value },
      wire.merging(["requestId": "not-a-uuid"]) { _, value in value },
      wire.merging(["action": "accept"]) { _, value in value },
      wire.merging(["message": "private text"]) { _, value in value },
    ] {
      XCTAssertNil(RequestNotificationRoute(userInfo: ["axo": malformed]))
    }
    XCTAssertNil(RequestNotificationRoute(userInfo: [:]))
  }
}
