import AppKit
import Combine
import XCTest

@testable import AxoMac

@MainActor
final class TerminalRenderFeedbackTests: XCTestCase {
  func testRepeatedFocusWithoutAttentionDoesNotPublishViewInvalidations() {
    let runtime = GhosttyRuntime(initializeGhostty: false)
    var invalidations = 0
    let subscription = runtime.objectWillChange.sink { invalidations += 1 }
    for _ in 0..<100 {
      runtime.setFocusedShellID(42)
      runtime.setFocusedShellID(nil)
    }
    XCTAssertEqual(invalidations, 0)
    withExtendedLifetime(subscription) {}
  }

  func testStatusDeliveryIsDeferredAndUsesCurrentCallback() async {
    let runtime = GhosttyRuntime(initializeGhostty: false)
    let view = GhosttySurfaceNSView(
      runtime: runtime, shellID: 42,
      initialFrameSize: CGSize(width: 800, height: 600), onFocus: {})
    var staleDeliveries = 0
    view.onStatusChange = { _ in staleDeliveries += 1 }
    view.status = "Unavailable"
    XCTAssertEqual(staleDeliveries, 0, "A representable update cannot publish state synchronously")
    let delivered = expectation(description: "latest status callback")
    view.onStatusChange = { status in
      XCTAssertEqual(status, "Unavailable")
      delivered.fulfill()
    }
    await fulfillment(of: [delivered], timeout: 2)
    XCTAssertEqual(staleDeliveries, 0)
  }
}
