import XCTest

@testable import AxoMac

final class TerminalLayoutTests: XCTestCase {
  func testInsertAddsSiblingPaneInRequestedDirection() throws {
    let original = TerminalLayout.pane(17)

    let updated = try XCTUnwrap(
      original.inserting(shellID: 23, direction: .down, beside: 17)
    )

    guard case .split(_, let direction, let ratio, let first, let second) = updated else {
      return XCTFail("inserting a pane should create a split")
    }
    XCTAssertEqual(direction, .down)
    XCTAssertEqual(ratio, 0.5)
    XCTAssertEqual(first, .pane(17))
    XCTAssertEqual(second, .pane(23))
  }

  func testRemovingPaneCollapsesEmptySplit() {
    let layout = TerminalLayout.split(
      id: UUID(),
      direction: .right,
      ratio: 0.5,
      first: .pane(17),
      second: .pane(23)
    )

    XCTAssertEqual(layout.removing(shellID: 17), .pane(23))
  }

  func testClosingPaneFocusesPreviousLeafInTreeOrder() {
    let layout = TerminalLayout.split(
      id: UUID(),
      direction: .right,
      ratio: 0.5,
      first: .pane(17),
      second: .split(
        id: UUID(),
        direction: .down,
        ratio: 0.5,
        first: .pane(23),
        second: .pane(42)
      )
    )

    XCTAssertEqual(
      layout.focusTargetAfterClosing(42, remainingShellIDs: [17, 23]),
      23,
      "Closing a non-leftmost focused pane should focus its previous tree neighbor."
    )
  }

  func testClosingLeftmostPaneFocusesNextLeafInTreeOrder() {
    let layout = TerminalLayout.split(
      id: UUID(),
      direction: .right,
      ratio: 0.5,
      first: .pane(17),
      second: .pane(23)
    )

    XCTAssertEqual(
      layout.focusTargetAfterClosing(17, remainingShellIDs: [23]),
      23,
      "Closing the leftmost pane should focus the next tree neighbor."
    )
  }

  func testResizeChangesOnlyTheTargetSplitRatio() throws {
    let nestedSplitID = UUID()
    let layout = TerminalLayout.split(
      id: UUID(),
      direction: .right,
      ratio: 0.6,
      first: .split(
        id: nestedSplitID,
        direction: .down,
        ratio: 0.4,
        first: .pane(17),
        second: .pane(23)
      ),
      second: .pane(42)
    )

    let resized = try XCTUnwrap(layout.resizing(splitID: nestedSplitID, to: 0.7))

    guard
      case .split(_, .right, let outerRatio, .split(_, .down, let innerRatio, _, _), _) = resized
    else {
      return XCTFail("resizing should preserve the split tree")
    }
    XCTAssertEqual(outerRatio, 0.6)
    XCTAssertEqual(innerRatio, 0.7)
  }

  func testStructuralIdentityIgnoresRatiosButTracksTreeShape() {
    let splitID = UUID()
    let original = TerminalLayout.split(
      id: splitID,
      direction: .right,
      ratio: 0.5,
      first: .pane(17),
      second: .pane(23)
    )
    let resized = TerminalLayout.split(
      id: splitID,
      direction: .right,
      ratio: 0.7,
      first: .pane(17),
      second: .pane(23)
    )
    let changed = TerminalLayout.split(
      id: splitID,
      direction: .down,
      ratio: 0.5,
      first: .pane(17),
      second: .pane(23)
    )

    XCTAssertEqual(original.structuralIdentity, resized.structuralIdentity)
    XCTAssertNotEqual(original.structuralIdentity, changed.structuralIdentity)
  }

  func testOrderedShellIDsFollowSplitTreeOrder() {
    let layout = TerminalLayout.split(
      id: UUID(),
      direction: .right,
      ratio: 0.5,
      first: .pane(17),
      second: .split(
        id: UUID(),
        direction: .down,
        ratio: 0.5,
        first: .pane(23),
        second: .pane(42)
      )
    )

    XCTAssertEqual(layout.orderedShellIDs, [17, 23, 42])
  }

  func testAddingNewShellsPreservesExistingPanesWithoutDuplicates() {
    let layout = TerminalLayout.pane(17)

    let updated = layout.adding([23, 42, 23])

    XCTAssertEqual(updated.shellIDs, [17, 23, 42])
  }

  func testPruningClosedShellsCollapsesNestedSplit() {
    let layout = TerminalLayout.split(
      id: UUID(),
      direction: .right,
      ratio: 0.5,
      first: .pane(17),
      second: .split(
        id: UUID(),
        direction: .down,
        ratio: 0.5,
        first: .pane(23),
        second: .pane(42)
      )
    )

    XCTAssertEqual(layout.pruned(to: [42]), .pane(42))
  }
}
