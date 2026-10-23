import AppKit
import XCTest

@testable import AxoMac

@MainActor
final class TerminalSurfaceViewportTests: XCTestCase {
  func testTerminalHostClipsSurfaceToItsViewport() {
    XCTAssertTrue(GhosttySurfaceHostNSView().wantsDefaultClipping)
  }

  func testWindowStateObserverReportsOcclusionAndKeyChangesForItsWindowOnly() {
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered,
      defer: true)
    let other = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered,
      defer: true)
    let observer = TerminalWindowStateObserver()
    var occlusion = 0
    var key = 0
    observer.observe(window, onOcclusionChange: { occlusion += 1 }, onKeyChange: { key += 1 })
    let center = NotificationCenter.default

    center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    center.post(name: NSWindow.didBecomeKeyNotification, object: window)
    center.post(name: NSWindow.didResignKeyNotification, object: window)
    center.post(name: NSWindow.didChangeOcclusionStateNotification, object: other)
    XCTAssertEqual(occlusion, 1)
    XCTAssertEqual(key, 2)

    observer.observe(window, onOcclusionChange: { occlusion += 10 }, onKeyChange: {})
    center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    XCTAssertEqual(occlusion, 2, "re-observing the same window must not duplicate observers")

    observer.observe(nil, onOcclusionChange: {}, onKeyChange: {})
    center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    XCTAssertEqual(occlusion, 2)
    XCTAssertNil(observer.observedWindow)
  }
}
