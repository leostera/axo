import AxoRPC
import Observation
import XCTest

@testable import AxoMac

final class SessionNavigationTests: XCTestCase {
  private func session(_ id: SessionID, workspace: String? = nil) -> TerminalSession {
    TerminalSession(id: id, initialPwd: "/", shells: [], workspaceId: workspace)
  }

  func testRecentSessionsAreNewestFirstUniqueAndBounded() {
    var recent = RecentSessions()
    recent.remember(1)
    recent.remember(2)
    recent.remember(1)
    XCTAssertEqual(recent.ids, [1, 2])
    recent.forget(1)
    XCTAssertEqual(recent.ids, [2])
    for id in 0..<Int64(RecentSessions.capacity + 10) { recent.remember(SessionID(rawValue: id)) }
    XCTAssertEqual(recent.ids.count, RecentSessions.capacity)
  }

  func testSidebarOrderGroupsByWorkspaceOrderThenStandalone() {
    let workspaces = [
      WorkspaceRecord(workspaceId: "b", name: "B", directoryPath: "/"),
      WorkspaceRecord(workspaceId: "a", name: "A", directoryPath: "/"),
    ]
    let sessions = [session(1), session(2, workspace: "a"), session(3, workspace: "b")]
    let sections = SidebarSections(sessions: sessions, workspaces: workspaces)
    XCTAssertEqual(sections.ordered.map(\.id), [3, 2, 1])
    XCTAssertEqual(sections.sessions(in: "a").map(\.id), [2])
    XCTAssertEqual(sections.ungrouped.map(\.id), [1])
  }

  func testSidebarListsSessionsOfUnlistedWorkspacesWithTheStandaloneOnes() {
    let workspaces = [WorkspaceRecord(workspaceId: "a", name: "A", directoryPath: "/")]
    let sessions = [session(1, workspace: "gone"), session(2, workspace: "a"), session(3)]
    let sections = SidebarSections(sessions: sessions, workspaces: workspaces)
    XCTAssertEqual(sections.ordered.map(\.id), [2, 1, 3])
    XCTAssertEqual(sections.ungrouped.map(\.id), [1, 3])
    XCTAssertEqual(sections.sessions(in: "gone").map(\.id), [])
  }

  func testAdjacentIndexWrapsAndStartsAtEnds() {
    XCTAssertEqual(SessionNavigation.adjacentIndex(from: 2, count: 3, direction: .next), 0)
    XCTAssertEqual(SessionNavigation.adjacentIndex(from: 0, count: 3, direction: .previous), 2)
    XCTAssertEqual(SessionNavigation.adjacentIndex(from: nil, count: 3, direction: .next), 0)
    XCTAssertEqual(SessionNavigation.adjacentIndex(from: nil, count: 3, direction: .previous), 2)
    XCTAssertNil(SessionNavigation.adjacentIndex(from: nil, count: 0, direction: .next))
  }

  func testSuccessorPrefersRecentSiblingThenReplacementThenWorkspaceThenAny() {
    let closed = session(1, workspace: "w")
    let sessions = [closed, session(2, workspace: "w"), session(3, workspace: "w"), session(4)]
    var recent = RecentSessions()
    recent.remember(4)
    recent.remember(3)
    recent.remember(1)
    XCTAssertEqual(
      SessionNavigation.successor(afterClosing: closed, in: sessions, recent: recent), 3)
    XCTAssertEqual(
      SessionNavigation.successor(
        afterClosing: closed, in: sessions, recent: RecentSessions(),
        replacement: session(3, workspace: "w")), 3)
    XCTAssertEqual(
      SessionNavigation.successor(afterClosing: closed, in: sessions, recent: RecentSessions()), 2)
    XCTAssertEqual(
      SessionNavigation.successor(
        afterClosing: closed, in: [closed, session(4)], recent: RecentSessions()), 4)
  }

  func testDefaultLayoutPlacesPanesInCreationOrder() {
    XCTAssertNil(TerminalLayout.defaultLayout(for: []))
    XCTAssertEqual(TerminalLayout.defaultLayout(for: [7, 8, 9])?.orderedShellIDs, [7, 8, 9])
  }
}

@MainActor
final class TerminalSessionsModelPublishingTests: XCTestCase {
  func testUnchangedCatalogEventDoesNotRepublish() async {
    let client = FakeAxodClient()
    let shell = TerminalShell(
      id: 10, processId: 1, initialPwd: "/", ptyDevice: "/dev/null", attachSocketPath: "/tmp/s")
    let session = TerminalSession(id: 1, initialPwd: "/", shells: [shell])
    client.sessions = [session]
    let model = TerminalSessionsModel(client: client)
    await model.refresh()

    let changed = await observesChange(of: {
      _ = (model.sessions, model.workspaces, model.selectedSessionID, model.focusedShellID,
        model.layout, model.errorMessage)
    }) {
      await model.apply(.sessionSnapshot(model.sessions[0]))
      await model.refresh()
    }

    XCTAssertFalse(changed, "re-applying identical state must not re-render the workbench")
  }

  func testUnavailablePiPaneIsFocusedSoCloseCanTargetIt() async {
    let client = FakeAxodClient()
    let shell = TerminalShell(
      id: 10, processId: 1, initialPwd: "/", ptyDevice: "/dev/null", attachSocketPath: "/tmp/s",
      role: .pi, availability: .unavailable(reason: "Pi exited."))
    client.sessions = [TerminalSession(id: 1, initialPwd: "/", shells: [shell])]
    let model = TerminalSessionsModel(client: client)
    await model.refresh()

    XCTAssertEqual(model.selectedSessionID, 1)
    XCTAssertEqual(model.focusedShellID, 10, "⌘W is disabled without a focused pane")
    model.focus(10)
    XCTAssertEqual(model.focusedShellID, 10)
  }

  func testUnsupportedCommandReportsUserFacingError() async {
    let client = FakeAxodClient()
    client.methods = AxodCapabilities.requiredMethods.map(\.rawValue)
    let model = TerminalSessionsModel(client: client)
    do {
      try await model.renameSession(1, to: "x")
      XCTFail("rename must require axo.session.rename")
    } catch {
      XCTAssertEqual(
        error as? SessionCommandError,
        SessionCommandError(
          "This action requires a newer Axod. Your Sessions and Workspace are unchanged."))
    }
  }
}
