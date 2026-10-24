import AxoRPC
import XCTest

@testable import AxoMac

final class TerminalLayoutTests: XCTestCase {
  func testSessionLayoutBridgePreservesBothSplitDirections() {
    for direction in [SessionSplitDirection.right, .down] {
      let sessionLayout = SessionLayout.split(
        id: UUID(),
        direction: direction,
        ratio: 0.5,
        first: .pane(shellID: 17),
        second: .pane(shellID: 23)
      )

      XCTAssertEqual(TerminalLayout(sessionLayout).sessionLayout, sessionLayout)
    }
  }

  func testPendingSplitPreviewInsertsAViewOnlyLeafBesideCapturedAnchor() throws {
    let original = TerminalLayout.split(
      id: UUID(),
      direction: .right,
      ratio: 0.6,
      first: .pane(17),
      second: .pane(23)
    )
    let pending = PendingTerminalSplit(
      id: UUID(),
      sessionID: 9,
      anchorShellID: 23,
      direction: .down,
      ratio: 0.4,
      status: .creating
    )

    let preview = try XCTUnwrap(TerminalLayoutPresentation(original).inserting(pending))
    let insertedPending = try XCTUnwrap(pendingLeaf(in: preview))
    let insertedSplit = try XCTUnwrap(pendingSplit(in: preview))

    XCTAssertEqual(insertedPending, pending)
    XCTAssertEqual(insertedSplit.direction, .down)
    XCTAssertEqual(insertedSplit.ratio, 0.4)
    XCTAssertEqual(original.shellIDs, [17, 23], "The preview must not mutate persisted layout.")
    XCTAssertNotEqual(preview.structuralIdentity, TerminalLayoutPresentation(original).structuralIdentity)
  }

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

  func testPlacingAnAlreadyObservedShellRepositionsItWithoutDuplicates() throws {
    let existing = TerminalLayout.split(
      id: UUID(),
      direction: .right,
      ratio: 0.5,
      first: .pane(17),
      second: .pane(23)
    )

    let placed = existing.placing(shellID: 23, direction: .down, beside: 17, ratio: 0.35)

    XCTAssertEqual(placed.shellIDs, [17, 23])
    guard case .split(_, .down, let ratio, .pane(17), .pane(23)) = placed else {
      return XCTFail("the observed shell should be placed beside its captured anchor")
    }
    XCTAssertEqual(ratio, 0.35)
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

  private func pendingLeaf(in layout: TerminalLayoutPresentation) -> PendingTerminalSplit? {
    switch layout {
    case .pane:
      return nil
    case .pending(let pending):
      return pending
    case .split(_, _, _, _, let first, let second):
      return pendingLeaf(in: first) ?? pendingLeaf(in: second)
    }
  }

  private func pendingSplit(
    in layout: TerminalLayoutPresentation
  ) -> (direction: TerminalSplitDirection, ratio: Double)? {
    switch layout {
    case .pane:
      return nil
    case .pending:
      return nil
    case .split(_, let direction, let ratio, let isPending, let first, let second):
      if isPending { return (direction, ratio) }
      return pendingSplit(in: first) ?? pendingSplit(in: second)
    }
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
