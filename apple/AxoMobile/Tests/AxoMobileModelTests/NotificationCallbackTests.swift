import AxoMobileModel
import Foundation
import XCTest

final class NotificationCallbackTests: XCTestCase {
  @MainActor
  func testCompletionReturnsToMainActorAfterSuspensionExactlyOnce() async {
    let completed = expectation(description: "notification completion")
    completed.expectedFulfillmentCount = 1
    var count = 0
    NotificationCallback.perform(operation: {
      XCTAssertTrue(Thread.isMainThread)
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(5))
      return "finished"
    }, completion: { value in
      XCTAssertTrue(Thread.isMainThread, "UIKit scene-restoration completion must run on the main thread")
      XCTAssertEqual(value, "finished")
      count += 1
      completed.fulfill()
    })
    await fulfillment(of: [completed], timeout: 2)
    XCTAssertEqual(count, 1)
  }

  @MainActor
  func testEarlyReturnStillCompletesOnMainThread() async {
    let completed = expectation(description: "ignored notification completion")
    NotificationCallback.perform(operation: { return }, completion: { _ in
      XCTAssertTrue(Thread.isMainThread)
      completed.fulfill()
    })
    await fulfillment(of: [completed], timeout: 2)
  }
}
