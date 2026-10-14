import XCTest

@testable import AxoMac

final class TerminalLayoutTests: XCTestCase {
  func testInsertAddsSiblingPaneInRequestedDirection() throws {
    let original = TerminalLayout.pane(17)

    let updated = try XCTUnwrap(
      original.inserting(sessionID: 23, direction: .down, beside: 17)
    )

    guard case .split(_, let direction, let first, let second) = updated else {
      return XCTFail("inserting a pane should create a split")
    }
    XCTAssertEqual(direction, .down)
    XCTAssertEqual(first, .pane(17))
    XCTAssertEqual(second, .pane(23))
  }

  func testRemovingPaneCollapsesEmptySplit() {
    let layout = TerminalLayout.split(
      id: UUID(),
      direction: .right,
      first: .pane(17),
      second: .pane(23)
    )

    XCTAssertEqual(layout.removing(sessionID: 17), .pane(23))
  }

  func testPruningClosedSessionsCollapsesNestedSplit() {
    let layout = TerminalLayout.split(
      id: UUID(),
      direction: .right,
      first: .pane(17),
      second: .split(
        id: UUID(),
        direction: .down,
        first: .pane(23),
        second: .pane(42)
      )
    )

    XCTAssertEqual(layout.pruned(to: [42]), .pane(42))
  }
}
