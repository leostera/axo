import AxoProtocol
import XCTest

@testable import AxoMac

final class TerminalPaneGeometryTests: XCTestCase {
  private let a = ShellID(rawValue: 1)
  private let b = ShellID(rawValue: 2)
  private let c = ShellID(rawValue: 3)

  func testSinglePaneFillsTheArea() {
    let sizes = TerminalPaneGeometry.paneSizes(for: .pane(a), in: CGSize(width: 1200, height: 800))
    XCTAssertEqual(sizes, [a: CGSize(width: 1200, height: 800)])
  }

  func testNestedSplitsSubtractDividersAndFollowRatios() {
    let layout = TerminalLayout.split(
      id: UUID(), direction: .right, ratio: 0.25,
      first: .pane(a),
      second: .split(id: UUID(), direction: .down, ratio: 0.5, first: .pane(b), second: .pane(c)))
    let sizes = TerminalPaneGeometry.paneSizes(for: layout, in: CGSize(width: 1001, height: 801))
    XCTAssertEqual(sizes[a], CGSize(width: 250, height: 801))
    XCTAssertEqual(sizes[b], CGSize(width: 750, height: 400))
    XCTAssertEqual(sizes[c], CGSize(width: 750, height: 400))
  }

  func testRatiosAreClampedLikeTheSplitView() {
    let lengths = TerminalPaneGeometry.splitLengths(axisLength: 101, ratio: 0)
    XCTAssertEqual(lengths.first, 1, accuracy: 0.0001)
    XCTAssertEqual(lengths.second, 99, accuracy: 0.0001)
  }

  func testTinyAreaNeverGoesNegative() {
    let lengths = TerminalPaneGeometry.splitLengths(axisLength: 0, ratio: 0.5)
    XCTAssertEqual(lengths.first, 0)
    XCTAssertEqual(lengths.second, 0)
  }
}
