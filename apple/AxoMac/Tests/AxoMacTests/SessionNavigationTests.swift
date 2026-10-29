import AxoProtocol
import Foundation
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

  private func active(_ id: SessionID, message: Int64? = nil, created: Int64? = nil) -> TerminalSession {
    TerminalSession(id: id, initialPwd: "/", shells: [], lastMessageAt: message, createdAt: created)
  }

  func testRecentActivityPutsTheLatestMessageFirstAndNewSessionsByCreation() {
    let sessions = [
      active(1, message: 100, created: 10),
      active(2, message: 300, created: 20),
      // No message yet: counts from its creation, so a new Session is near the top.
      active(3, created: 250),
      // Equal activity: the newer Session first. Older daemons send no creation time.
      active(4, message: 100),
      active(5),
    ]
    XCTAssertEqual(SessionActivityOrder.sorted(sessions).map(\.id), [2, 3, 4, 1, 5])
  }

  func testAHeldOrderKeepsRowsStillButDropsClosedAndLeadsWithNewSessions() {
    let live = [active(4, message: 400), active(2, message: 300), active(1, message: 100)]
    XCTAssertEqual(SessionActivityOrder.holding(nil, live: live).map(\.id), [4, 2, 1])
    // Held as [1, 2, 3]: 3 closed since, 4 opened since.
    XCTAssertEqual(SessionActivityOrder.holding([1, 2, 3], live: live).map(\.id), [4, 1, 2])
  }

  func testAgesAreShort() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let age = { SessionActivityOrder.age(of: 1_000_000 - $0, now: now) }
    XCTAssertEqual([age(5), age(-30), age(120), age(7_200), age(172_800), age(1_209_600)],
      ["now", "now", "2m", "2h", "2d", "2w"])
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
  func testTheRecentListIsRememberedAndNextSessionFollowsIt() async throws {
    let suiteName = "axo-sidebar-mode-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let client = FakeAxodClient()
    client.workspaces = [WorkspaceRecord(workspaceId: "a", name: "A", directoryPath: "/")]
    client.sessions = [
      TerminalSession(id: 1, initialPwd: "/", shells: [], workspaceId: "a", lastMessageAt: 100),
      TerminalSession(id: 2, initialPwd: "/", shells: [], workspaceId: "a", lastMessageAt: 300),
      TerminalSession(id: 3, initialPwd: "/", shells: [], lastMessageAt: 200),
    ]
    let model = TerminalSessionsModel(client: client, selectedSessionDefaults: defaults)
    await model.refresh()
    XCTAssertEqual(model.sidebarMode, .workspaces)
    XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), [1, 2, 3])

    model.setSidebarMode(.recent)
    XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), [2, 3, 1])
    model.showSession(2)
    model.showNextSession()
    XCTAssertEqual(model.selectedSessionID, 3)

    // While the pointer holds the list still, the shortcuts step through the rows as shown.
    model.holdRecentOrder(true)
    client.sessions[0] = TerminalSession(
      id: 1, initialPwd: "/", shells: [], workspaceId: "a", lastMessageAt: 400)
    await model.refresh()
    model.showNextSession()
    XCTAssertEqual(model.selectedSessionID, 1)
    // Released, the list takes the live order: 1 is now the most recent.
    model.holdRecentOrder(false)
    XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), [1, 2, 3])
    model.showNextSession()
    XCTAssertEqual(model.selectedSessionID, 2)

    let reopened = TerminalSessionsModel(client: client, selectedSessionDefaults: defaults)
    XCTAssertEqual(reopened.sidebarMode, .recent)
  }

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
