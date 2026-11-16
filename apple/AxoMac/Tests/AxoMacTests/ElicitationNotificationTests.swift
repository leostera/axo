import AxoProtocol
import UserNotifications
import XCTest

@testable import AxoMac

@MainActor
final class ElicitationNotificationTests: XCTestCase {
  private func question(_ id: String) -> Elicitation {
    Elicitation(id: id, sessionId: 1, kind: .confirm, askedBy: .agent,
      message: "Private question text never belongs in a notification.", createdAt: 1_000, expiresAt: 10_000)
  }
  private func until(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    XCTAssertTrue(condition())
  }

  func testEachRequestHasOnePrivateNativeNoticeAndResolutionWithdrawsIt() async {
    var delivered: [UNNotificationRequest] = []
    var removed: [String] = []
    let service = ElicitationNotifications(authorized: { true },
      deliver: { delivered.append($0) }, remove: { removed += $0 },
      now: { Date(timeIntervalSince1970: 1) })
    service.update([question("a"), question("b")])
    await until { delivered.count == 2 }
    service.update([question("a"), question("b")])
    await Task.yield()
    XCTAssertEqual(Set(delivered.map(\.identifier)), Set(["a", "b"].map(ElicitationNotifications.identifier)))
    XCTAssertTrue(delivered.allSatisfy { $0.content.body.contains("Open Axo") && !$0.content.body.contains("Private question") })
    service.update([question("b")])
    XCTAssertTrue(removed.contains(ElicitationNotifications.identifier("a")))
    service.update([question("a"), question("b")]) // stale/reconnect replay cannot create another banner
    await Task.yield()
    XCTAssertEqual(delivered.count, 2)
    service.update([])
  }

  func testNoPermissionMeansNoNativeNoticeAndNeverAnAuthorizationPrompt() async {
    var checked = 0
    var delivered = 0
    let service = ElicitationNotifications(authorized: { checked += 1; return false },
      deliver: { _ in delivered += 1 }, remove: { _ in }, now: { Date(timeIntervalSince1970: 1) })
    service.update([question("a")])
    await until { checked == 1 }
    await Task.yield()
    XCTAssertEqual(delivered, 0)
    service.update([])
  }

  func testResolutionWhileNativeDeliveryIsPendingRetractsAgainAfterCompletion() async {
    var gate: CheckedContinuation<Void, Never>?
    var removed: [String] = []
    let service = ElicitationNotifications(authorized: { true },
      deliver: { _ in await withCheckedContinuation { gate = $0 } }, remove: { removed += $0 },
      now: { Date(timeIntervalSince1970: 1) })
    service.update([question("a")])
    await until { gate != nil }
    service.update([])
    XCTAssertEqual(removed, [ElicitationNotifications.identifier("a")])
    gate?.resume()
    await until { removed.count == 2 }
    XCTAssertEqual(Set(removed), [ElicitationNotifications.identifier("a")])
  }

  func testReconnectRestoresDeliveryAfterACancelledPermissionCheckActuallyRetires() async {
    var gate: CheckedContinuation<Bool, Never>?
    var checked = 0
    var delivered = 0
    let service = ElicitationNotifications(
      authorized: {
        checked += 1
        if checked == 1 { return await withCheckedContinuation { gate = $0 } }
        return true
      },
      deliver: { _ in delivered += 1 }, remove: { _ in }, now: { Date(timeIntervalSince1970: 1) })
    service.update([question("a")])
    await until { gate != nil }
    service.update([])
    service.update([question("a")])
    XCTAssertEqual(checked, 1, "do not overlap the old authorization operation")
    gate?.resume(returning: true)
    await until { delivered == 1 }
    XCTAssertEqual(checked, 2)
    service.update([])
  }

  func testExpiryWithdrawsTheNoticeAndAnExpiredQuestionIsNeverDelivered() async {
    var now = Date(timeIntervalSince1970: 1)
    var delivered = 0
    var removed: [String] = []
    let service = ElicitationNotifications(authorized: { true }, deliver: { _ in delivered += 1 },
      remove: { removed += $0 }, now: { now })
    service.update([question("a")])
    await until { delivered == 1 }
    now = Date(timeIntervalSince1970: 11)
    service.update([question("a"), question("b")])
    await Task.yield()
    XCTAssertEqual(delivered, 1)
    XCTAssertTrue(removed.contains(ElicitationNotifications.identifier("a")))
    service.update([])
  }
}
