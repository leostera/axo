import AxoMobileModel
import AxoProtocol
import CryptoKit
import XCTest

final class RequestNotificationActionTests: XCTestCase {
  func testOnlyTheCompleteCurrentDisplayedConfirmationCanBeAnswered() throws {
    let account = UUID(), host = UUID(), session = UUID(), request = UUID()
    let message = "Approve the harmless test?"
    let expiry: Int64 = 200_000
    let digest = SHA256.hash(data: Data(message.utf8)).map { String(format: "%02x", $0) }.joined()
    let route = try XCTUnwrap(RequestNotificationRoute(userInfo: ["axo": ["version": 1,
      "accountId": account.uuidString, "hostId": host.uuidString, "sessionId": session.uuidString, "requestId": request.uuidString]]))
    let action = try XCTUnwrap(RequestNotificationAction(userInfo: ["axoRequest": ["version": 1,
      "digest": digest, "expiresAt": expiry]]))
    let question = Elicitation(id: request.uuidString.lowercased(), sessionId: SessionID(session), message: message,
      createdAt: 0, expiresAt: expiry)
    let now = Date(timeIntervalSince1970: 100)
    XCTAssertTrue(action.matches(question, route: route, displayedMessage: message, now: now))
    XCTAssertFalse(action.matches(question, route: route, displayedMessage: "A different operation", now: now))
    XCTAssertFalse(action.matches(question, route: route, displayedMessage: message, now: Date(timeIntervalSince1970: 200)))
    let changed = Elicitation(id: question.id, sessionId: question.sessionId, message: "Changed operation", createdAt: 0, expiresAt: expiry)
    XCTAssertFalse(action.matches(changed, route: route, displayedMessage: message, now: now))
    let input = Elicitation(id: question.id, sessionId: question.sessionId, kind: .input, message: message, createdAt: 0, expiresAt: expiry)
    XCTAssertFalse(action.matches(input, route: route, displayedMessage: message, now: now))
    let extended = Elicitation(id: question.id, sessionId: question.sessionId, message: message, createdAt: 0, expiresAt: expiry + 1)
    XCTAssertFalse(action.matches(extended, route: route, displayedMessage: message, now: now))
  }

  func testMalformedMetadataHasNoActionAuthority() {
    XCTAssertNil(RequestNotificationAction(userInfo: [:]))
    XCTAssertNil(RequestNotificationAction(userInfo: ["axoRequest": ["version": true, "digest": String(repeating: "a", count: 64), "expiresAt": 1]]))
    XCTAssertNil(RequestNotificationAction(userInfo: ["axoRequest": ["version": 1, "digest": "not-a-hash", "expiresAt": 1]]))
    XCTAssertNil(RequestNotificationAction(userInfo: ["axoRequest": ["version": 1, "digest": String(repeating: "a", count: 64), "expiresAt": 1, "action": "accept"]]))
  }
}
