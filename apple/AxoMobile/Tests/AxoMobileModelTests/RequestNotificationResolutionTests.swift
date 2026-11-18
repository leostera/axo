import Foundation
import XCTest
@testable import AxoMobileModel

final class RequestNotificationResolutionTests: XCTestCase {
  private var route: [String: Any] {
    ["version": 1, "accountId": "11111111-1111-4111-8111-111111111111",
      "hostId": "22222222-2222-4222-8222-222222222222",
      "sessionId": "33333333-3333-4333-8333-333333333333",
      "requestId": "44444444-4444-4444-8444-444444444444"]
  }

  func testOnlyTheExactRequestCanBeRemovedNeverInformationOrAnotherRoute() throws {
    let resolution = try XCTUnwrap(RequestNotificationResolution(userInfo: [
      "axo": route, "axoResolution": ["version": 1],
    ]))
    XCTAssertTrue(resolution.matches(["axo": route]))
    XCTAssertFalse(resolution.matches(["axo": route, "axoNotice": ["version": 1, "kind": "information"]]))
    for field in ["accountId", "hostId", "sessionId", "requestId"] {
      var other = route
      other[field] = "55555555-5555-4555-8555-555555555555"
      XCTAssertFalse(resolution.matches(["axo": other]), field)
    }
  }

  func testMalformedOrOrdinaryPushesAreNotRetractions() {
    XCTAssertNil(RequestNotificationResolution(userInfo: ["axo": route]))
    XCTAssertNil(RequestNotificationResolution(userInfo: ["axo": route, "axoResolution": ["version": 2]]))
    XCTAssertNil(RequestNotificationResolution(userInfo: ["axo": route, "axoResolution": ["version": 1, "action": "accept"]]))
    XCTAssertNil(RequestNotificationResolution(userInfo: ["axoResolution": ["version": 1]]))
  }
}
