import AxoProtocol
import XCTest

@testable import AxoMac

/// `WorkbenchSelection` is pure, so its rules are tested without a model, daemon or views.
final class WorkbenchSelectionTests: XCTestCase {
  private func shell(_ id: ShellID) -> TerminalShell {
    TerminalShell(
      id: id, processId: 1, initialPwd: "/", ptyDevice: "/dev/null", attachSocketPath: "/tmp/s")
  }

  private func session(
    _ id: SessionID, _ shells: [ShellID], layout: SessionLayout? = nil, workspace: String? = nil
  ) -> TerminalSession {
    TerminalSession(
      id: id, initialPwd: "/", shells: shells.map(shell), layout: layout, workspaceId: workspace)
  }

  private func selection(_ sessions: [TerminalSession]) -> WorkbenchSelection {
    var selection = WorkbenchSelection()
    selection.applyCatalog(sessions, previous: [], focusing: nil)
    return selection
  }

  func testTheFirstCatalogShowsTheFirstSessionFocusedOnItsNewestPane() {
    var selection = selection([session(1, [10, 11]), session(2, [20])])
    XCTAssertEqual(selection.selectedSessionID, 1)
    XCTAssertEqual(selection.focusedShellID, 11)
    XCTAssertEqual(selection.layout?.orderedShellIDs, [10, 11])
    // Neither had a stored layout, so both normalized layouts are saved.
    XCTAssertEqual(Set(selection.takePendingWrites().keys), [1, 2])
    XCTAssertTrue(selection.pendingWrites.isEmpty)
  }

  func testAStoredLayoutThatMatchesIsNotSavedAgain() {
    var selection = WorkbenchSelection()
    selection.applyCatalog([session(1, [10], layout: .pane(shellID: 10))], previous: [], focusing: nil)
    XCTAssertEqual(selection.takePendingWrites(), [:])
  }

  func testANewPaneInTheShownSessionTakesFocus() {
    let before = [session(1, [10])]
    var selection = selection(before)
    let after = [session(1, [10, 12])]
    selection.applyCatalog(after, previous: before, focusing: nil)
    XCTAssertEqual(selection.focusedShellID, 12)
    XCTAssertEqual(selection.layout?.orderedShellIDs, [10, 12])
  }

  func testAFocusedPaneThatClosesHandsFocusToItsLayoutNeighbour() {
    let before = [session(1, [10, 11, 12])]
    var selection = selection(before)
    selection.focus(11, in: before)
    let after = [session(1, [10, 12])]
    selection.applyCatalog(after, previous: before, focusing: nil)
    XCTAssertEqual(selection.layout?.orderedShellIDs, [10, 12])
    XCTAssertNotNil(selection.focusedShellID)
    XCTAssertNotEqual(selection.focusedShellID, 11)
  }

  func testRemovingTheShownSessionSelectsItsSuccessorInTheSameWorkspace() {
    let before = [
      session(1, [10], workspace: "a"), session(2, [20], workspace: "b"),
      session(3, [30], workspace: "a"),
    ]
    var selection = selection(before)
    selection.select(3, in: before)
    let after = before.filter { $0.id != 3 }
    selection.applyCatalog(after, previous: before, focusing: nil)
    XCTAssertEqual(selection.selectedSessionID, 1)
    XCTAssertNil(selection.layouts[3])
  }

  func testAResumeRequestWinsOverTheCurrentSelection() {
    let sessions = [session(1, [10]), session(2, [20])]
    var selection = selection(sessions)
    selection.applyCatalog(sessions, previous: sessions, focusing: 2)
    XCTAssertEqual(selection.selectedSessionID, 2)
    XCTAssertEqual(selection.focusedShellID, 20)
  }

  func testPlacingASplitFocusesTheNewPaneOnlyInTheShownSession() {
    let sessions = [session(1, [10]), session(2, [20])]
    var selection = selection(sessions)
    _ = selection.takePendingWrites()
    XCTAssertEqual(selection.splitAnchor(in: 1), 10)

    selection.place(11, in: sessions[0], direction: .down, beside: 10, ratio: 0.3)
    XCTAssertEqual(selection.focusedShellID, 11)
    XCTAssertEqual(selection.layout?.orderedShellIDs, [10, 11])

    selection.place(21, in: sessions[1], direction: .right, beside: 20, ratio: 0.5)
    XCTAssertEqual(selection.focusedShellID, 11, "a hidden Session's new pane does not take focus")
    XCTAssertEqual(Set(selection.takePendingWrites().keys), [1, 2])
  }

  func testResizingClampsTheRatioAndIgnoresUnknownOrInvalidSplits() throws {
    var selection = selection([session(1, [10, 11])])
    _ = selection.takePendingWrites()
    guard case .split(let splitID, _, _, _, _) = try XCTUnwrap(selection.layout) else {
      return XCTFail("expected a split")
    }
    selection.resizeSplit(UUID(), to: 0.3)
    selection.resizeSplit(splitID, to: .nan)
    XCTAssertEqual(selection.takePendingWrites(), [:])

    selection.resizeSplit(splitID, to: 5)
    guard case .split(_, _, let ratio, _, _) = try XCTUnwrap(selection.layout) else {
      return XCTFail("expected a split")
    }
    XCTAssertEqual(ratio, 0.99)
    XCTAssertEqual(Set(selection.takePendingWrites().keys), [1])
  }

  func testClosingAPaneDecidesFocusFromTheLayoutBeforeTheClose() {
    let open = session(1, [10, 11, 12])
    var selection = selection([open])
    selection.focus(12, in: [open])
    let layoutBefore = selection.currentLayout(of: open)
    let preferred = selection.focusAfterClosing(12, in: open)
    XCTAssertEqual(preferred, 11)

    selection.paneClosed(
      12, in: 1, remaining: [10, 11], layoutBeforeClose: layoutBefore, preferredFocus: preferred)
    XCTAssertEqual(selection.focusedShellID, 11)
    XCTAssertEqual(selection.layout?.orderedShellIDs, [10, 11])
  }

  func testPaneNavigationWrapsOverOpenPanesInLayoutOrder() {
    let open = session(1, [10, 11, 12])
    var selection = selection([open])
    selection.focus(12, in: [open])
    XCTAssertEqual(selection.adjacentPane(.next, among: [10, 11, 12]), 10)
    XCTAssertEqual(selection.adjacentPane(.previous, among: [10, 11, 12]), 11)
    XCTAssertEqual(selection.adjacentPane(.next, among: [10, 12]), 10)
  }
}
