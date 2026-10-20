import XCTest

@testable import AxoMac

@MainActor
final class TerminalSurfaceViewportTests: XCTestCase {
  func testTerminalHostClipsSurfaceToItsViewport() {
    XCTAssertTrue(GhosttySurfaceHostNSView().wantsDefaultClipping)
  }
}
