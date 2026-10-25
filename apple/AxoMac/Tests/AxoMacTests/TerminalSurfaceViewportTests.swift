import AppKit
import XCTest

@testable import AxoMac

@MainActor
final class TerminalSurfaceViewportTests: XCTestCase {
  func testTerminalHostClipsSurfaceToItsViewport() {
    XCTAssertTrue(GhosttySurfaceHostNSView().wantsDefaultClipping)
  }

  func testInitialSurfaceSizePrefersThePanesLayoutSizeThenTheProposalThenANonzeroSeed() {
    let pane = CGSize(width: 640, height: 900)
    let proposal = CGSize(width: 420, height: 280)
    XCTAssertEqual(GhosttyRuntime.seededSurfaceSize(paneSize: pane, proposedSize: proposal), pane)
    XCTAssertEqual(GhosttyRuntime.seededSurfaceSize(paneSize: pane, proposedSize: .zero), pane)
    XCTAssertEqual(GhosttyRuntime.seededSurfaceSize(paneSize: nil, proposedSize: proposal), proposal)
    XCTAssertEqual(
      GhosttyRuntime.seededSurfaceSize(paneSize: .zero, proposedSize: .zero),
      CGSize(width: 800, height: 600))
  }

  func testNativeFrameResizeReplacesTheCachedSplitSize() {
    let runtime = GhosttyRuntime(initializeGhostty: false)
    let view = GhosttySurfaceNSView(
      runtime: runtime, shellID: 1, initialFrameSize: CGSize(width: 400, height: 300), onFocus: {})
    view.syncSurfaceSize()
    view.setFrameSize(CGSize(width: 1000, height: 600))
    XCTAssertEqual(view.contentSize, view.bounds.size)
    XCTAssertEqual(view.contentSize, CGSize(width: 1000, height: 600))
    view.setBoundsSize(CGSize(width: 900, height: 500))
    XCTAssertEqual(view.contentSize, view.bounds.size)
    XCTAssertEqual(view.contentSize?.width ?? 0, 900, accuracy: 0.001)
    XCTAssertEqual(view.contentSize?.height ?? 0, 500, accuracy: 0.001)
  }

  func testSurvivingPaneUsesExpandedHostAfterHorizontalOrVerticalClose() {
    let runtime = GhosttyRuntime(initializeGhostty: false)
    for splitSize in [CGSize(width: 400, height: 600), CGSize(width: 1000, height: 300)] {
      let view = GhosttySurfaceNSView(
        runtime: runtime, shellID: 1, initialFrameSize: splitSize, onFocus: {})
      let oldHost = GhosttySurfaceHostNSView(frame: CGRect(origin: .zero, size: splitSize))
      oldHost.attachSurface(view)
      oldHost.layout()
      XCTAssertEqual(view.contentSize, splitSize)

      let expanded = CGSize(width: 1000, height: 600)
      let newHost = GhosttySurfaceHostNSView(frame: CGRect(origin: .zero, size: expanded))
      newHost.attachSurface(view)
      newHost.layout()
      XCTAssertTrue(view.superview === newHost)
      XCTAssertEqual(view.contentSize, expanded)
      oldHost.layout()
      XCTAssertEqual(view.contentSize, expanded, "the released host cannot restore the old split size")
    }
  }

  func testTransientEmptyViewportPreservesLastValidSizeUntilRelayout() {
    let runtime = GhosttyRuntime(initializeGhostty: false)
    let initial = CGSize(width: 400, height: 300)
    let view = GhosttySurfaceNSView(
      runtime: runtime, shellID: 1, initialFrameSize: initial, onFocus: {})
    view.syncSurfaceSize()
    view.setFrameSize(.zero)
    view.layout()
    XCTAssertEqual(view.contentSize, initial)
    view.setFrameSize(CGSize(width: 1000, height: 600))
    view.layout()
    XCTAssertEqual(view.contentSize, CGSize(width: 1000, height: 600))
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
