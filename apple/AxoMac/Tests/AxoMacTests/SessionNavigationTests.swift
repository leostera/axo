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
    for id in 0..<UInt32(RecentSessions.capacity + 10) { recent.remember(.fixture(id)) }
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
      active(4, message: 100, created: 50),
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

  func testPinnedSessionsLeadAndKeepTheirOrderAmongThemselves() {
    let ordered = [active(5), active(4), active(3), active(2), active(1)]
    XCTAssertEqual(SessionPins().pinnedFirst(ordered).map(\.id), [5, 4, 3, 2, 1])
    // Pinned in the order 1, 3: they lead in the list's order, not the order they were pinned.
    let pins = SessionPins([1, 3])
    XCTAssertEqual(pins.pinnedFirst(ordered).map(\.id), [3, 1, 5, 4, 2])
    // A pinned Session that isn't listed (closed, or on a Mac that is offline) does nothing.
    XCTAssertEqual(SessionPins([9, 3]).pinnedFirst(ordered).map(\.id), [3, 5, 4, 2, 1])
  }

  func testPinsToggleDeduplicateParseAndStayBounded() {
    var pins = SessionPins([2, 2, 3])
    XCTAssertEqual(pins.ids, [2, 3])
    pins.toggle(1)
    pins.toggle(2)
    XCTAssertEqual(pins.ids, [3, 1])
    XCTAssertTrue(pins.contains(1))
    XCTAssertFalse(pins.contains(2))

    // Stored values that aren't Session IDs (an older format, a hand edit) are dropped.
    let stored = SessionPins(storedValue: [SessionID(1).rawValue, "7", "", SessionID(4).rawValue])
    XCTAssertEqual(stored.ids, [1, 4])
    XCTAssertEqual(SessionPins(storedValue: stored.storedValue), stored)
    XCTAssertEqual(SessionPins(storedValue: nil).ids, [])

    // The oldest pins go first once there are too many.
    var many = SessionPins()
    for id in 0..<UInt32(SessionPins.capacity + 3) { many.toggle(.fixture(id)) }
    XCTAssertEqual(many.ids.count, SessionPins.capacity)
    XCTAssertEqual(many.ids.first, .fixture(3))
  }

  func testMacStepsCycleThroughThisMacEachOtherMacAndAll() {
    let hosts = ["a", "b"]
    XCTAssertNil(SidebarMacs.thisMac.adjacent(.next, hostIDs: []), "no other Mac, nothing to step")
    XCTAssertEqual(SidebarMacs.thisMac.adjacent(.next, hostIDs: hosts), .mac("a"))
    XCTAssertEqual(SidebarMacs.mac("b").adjacent(.next, hostIDs: hosts), .all)
    XCTAssertEqual(SidebarMacs.all.adjacent(.next, hostIDs: hosts), .thisMac)
    XCTAssertEqual(SidebarMacs.thisMac.adjacent(.previous, hostIDs: hosts), .all)
    // A Mac that went away counts as This Mac.
    XCTAssertEqual(SidebarMacs.mac("gone").adjacent(.next, hostIDs: hosts), .mac("a"))
    XCTAssertEqual(SidebarMacs(hostID: nil), .thisMac)
    XCTAssertEqual(SidebarMacs(hostID: "a"), .mac("a"))
  }

  func testAgesAreShort() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let age = { SessionActivityOrder.age(of: 1_000_000 - $0, now: now) }
    XCTAssertEqual([age(5), age(-30), age(120), age(7_200), age(172_800), age(1_209_600)],
      ["now", "now", "2m", "2h", "2d", "2w"])
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
  func testReopeningAClosedSessionShowsItAndBeepsWorthyWhenNoneAreLeft() async {
    let client = FakeAxodClient()
    client.sessions = [TerminalSession(id: 1, initialPwd: "/", shells: [])]
    client.closedSessions = [
      TerminalSession(id: 7, initialPwd: "/", shells: []),
      TerminalSession(id: 4, initialPwd: "/", shells: []),
    ]
    let model = TerminalSessionsModel(client: client)
    await model.refresh()

    let first = await model.reopenClosedSession()
    XCTAssertEqual(first, .reopened(7))
    XCTAssertEqual(model.selectedSessionID, 7)
    let second = await model.reopenClosedSession()
    XCTAssertEqual(second, .reopened(4))
    XCTAssertEqual(model.selectedSessionID, 4)
    XCTAssertEqual(Set(model.sessions.map(\.id)), [1, 4, 7])

    // Nothing left: not an error, so nothing is reported (the menu command beeps).
    let none = await model.reopenClosedSession()
    XCTAssertEqual(none, .nothingToReopen)
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(model.selectedSessionID, 4)
  }

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
    XCTAssertEqual(model.sidebarMacs, .thisMac)
    XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), [2, 3, 1], "latest activity first")
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
    model.endSessionSteps()
    XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), [1, 2, 3])
    model.showNextSession()
    XCTAssertEqual(model.selectedSessionID, 2)

    model.setSidebarMacs(.all)
    let reopened = TerminalSessionsModel(client: client, selectedSessionDefaults: defaults)
    XCTAssertEqual(reopened.sidebarMacs, .all)
  }

  func testPreviousAndNextSessionStepThroughTheRowsAsShownWhileOtherSessionsMoveUp() async throws {
    let client = FakeAxodClient()
    client.sessions = [
      TerminalSession(id: 1, initialPwd: "/", shells: [], lastMessageAt: 100),
      TerminalSession(id: 2, initialPwd: "/", shells: [], lastMessageAt: 300),
      TerminalSession(id: 3, initialPwd: "/", shells: [], lastMessageAt: 200),
      TerminalSession(id: 4, initialPwd: "/", shells: [], lastMessageAt: 50),
    ]
    let model = TerminalSessionsModel(client: client)
    model.sessionStepHold = .milliseconds(100)
    await model.refresh()
    XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), [2, 3, 1, 4])
    model.showSession(2)
    model.showNextSession()
    XCTAssertEqual(model.selectedSessionID, 3)

    // An agent writes in 1 between presses. The list holds still, so the next press goes to the
    // row after 3 as shown, not to the row after 3's new place.
    client.sessions[0] = TerminalSession(id: 1, initialPwd: "/", shells: [], lastMessageAt: 400)
    await model.refresh()
    XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), [2, 3, 1, 4])
    model.showNextSession()
    XCTAssertEqual(model.selectedSessionID, 1)
    model.showPreviousSession()
    XCTAssertEqual(model.selectedSessionID, 3)

    // A moment after the last press, the rows move to their places.
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), [1, 2, 3, 4])
  }

  func testPinnedSessionsStayOnTopAreRememberedOnThisMacAndSurviveTheirAbsence() async throws {
    let suiteName = "axo-sidebar-pins-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let client = FakeAxodClient()
    client.sessions = [
      TerminalSession(id: 1, initialPwd: "/", shells: [], lastMessageAt: 100),
      TerminalSession(id: 2, initialPwd: "/", shells: [], lastMessageAt: 300),
      TerminalSession(id: 3, initialPwd: "/", shells: [], lastMessageAt: 200),
    ]
    let model = TerminalSessionsModel(client: client, selectedSessionDefaults: defaults)
    await model.refresh()
    XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), [2, 3, 1])

    model.togglePin(1)
    XCTAssertTrue(model.isPinned(1))
    XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), [1, 2, 3], "pinned first")
    // More activity elsewhere doesn't move anything above a pinned Session.
    client.sessions[2] = TerminalSession(id: 3, initialPwd: "/", shells: [], lastMessageAt: 900)
    await model.refresh()
    XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), [1, 3, 2])

    // Pinning under the pointer moves the row up even though the list is held still. Pinned
    // Sessions keep recent activity among themselves: 2 (300) before 1 (100).
    model.holdRecentOrder(true)
    model.togglePin(2)
    XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), [2, 1, 3])
    model.holdRecentOrder(false)
    XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), [2, 1, 3])

    // Previous/Next Session follow the pinned order too.
    model.showSession(1)
    model.showNextSession()
    XCTAssertEqual(model.selectedSessionID, 3)

    // A pinned Session that goes away drops out of the list; the pin stays, harmlessly, and
    // applies again if the Session comes back (reopened, or its Mac back online).
    let closed = client.sessions.remove(at: 0)
    await model.refresh()
    XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), [2, 3])
    XCTAssertTrue(model.isPinned(1))

    // Pins are this Mac's user defaults, read back by the next launch.
    XCTAssertEqual(
      defaults.stringArray(forKey: AxoPreferenceKey.pinnedSessions),
      [SessionID(1).rawValue, SessionID(2).rawValue])
    client.sessions.append(closed)
    let relaunched = TerminalSessionsModel(client: client, selectedSessionDefaults: defaults)
    await relaunched.refresh()
    XCTAssertEqual(relaunched.sidebarOrderedSessions.map(\.id), [2, 1, 3])

    relaunched.togglePin(1)
    XCTAssertFalse(relaunched.isPinned(1))
    XCTAssertEqual(relaunched.sidebarOrderedSessions.map(\.id), [2, 3, 1])
  }

  func testMacShortcutsStepThroughThisMacEachOtherMacThenAllAndThePaletteSearchesEveryMac()
    async throws
  {
    let suiteName = "axo-sidebar-mac-steps-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let client = FakeAxodClient()
    client.methods.append(AxodMethodName.peerSessionsList.rawValue)
    client.sessions = [TerminalSession(id: 1, initialPwd: "/", shells: [], lastMessageAt: 100)]
    let studio = "2e2e7f91-3d8f-4f97-8f71-4fc7d53313c7"
    let air = "8f8f8f8f-0000-4000-8000-000000000009"
    client.peers = PeerSessionList(
      connected: true,
      hosts: [
        PeerHost(hostId: studio, label: "Mac Studio", online: true),
        PeerHost(hostId: air, label: "Air", online: true),
      ],
      sessions: [
        PeerSession(
          hostId: studio,
          session: TerminalSession(id: 9, initialPwd: "/", shells: [], name: "Fix it", lastMessageAt: 200))
      ])
    let model = TerminalSessionsModel(client: client, selectedSessionDefaults: defaults)
    await model.refresh()
    XCTAssertEqual(model.sidebarMacs, .thisMac)

    model.showNextMacs()
    XCTAssertEqual(model.sidebarMacs, .mac(studio))
    model.showNextMacs()
    XCTAssertEqual(model.sidebarMacs, .mac(air))
    model.showNextMacs()
    XCTAssertEqual(model.sidebarMacs, .all)
    model.showNextMacs()
    XCTAssertEqual(model.sidebarMacs, .thisMac, "wraps around")
    model.showPreviousMacs()
    XCTAssertEqual(model.sidebarMacs, .all)

    // The palette lists every Mac's Sessions whatever the sidebar shows, naming other Macs.
    model.setSidebarMacs(.thisMac)
    XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), [1])
    let context = model.commandPaletteContext()
    XCTAssertEqual(context.sessions.map(\.id), [9, 1])
    XCTAssertEqual(context.hostLabels, [9: "Mac Studio"])
    let studioItem = try XCTUnwrap(
      CommandPaletteCatalog.items(context).first { $0.action == .showSession(9) })
    XCTAssertTrue(studioItem.subtitle.hasPrefix("Mac Studio"), studioItem.subtitle)

    // Choosing another Mac's Session lists its Mac, so the selection is in the sidebar.
    model.showSession(9)
    XCTAssertEqual(model.sidebarMacs, .mac(studio))
    XCTAssertEqual(model.selectedSessionID, 9)
    model.showSession(1)
    XCTAssertEqual(model.sidebarMacs, .thisMac)
    // A Session already listed leaves the sidebar alone.
    model.setSidebarMacs(.all)
    model.showSession(9)
    XCTAssertEqual(model.sidebarMacs, .all)
  }

  func testOtherMacsSessionsAreListedByMacAndShowingOneOpensAPaneOnIt() async throws {
    let suiteName = "axo-sidebar-macs-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let client = FakeAxodClient()
    client.methods.append(AxodMethodName.peerSessionsList.rawValue)
    client.sessions = [TerminalSession(id: 1, initialPwd: "/", shells: [], lastMessageAt: 100)]
    let studio = "2e2e7f91-3d8f-4f97-8f71-4fc7d53313c7"
    client.peers = PeerSessionList(
      connected: true, hosts: [PeerHost(hostId: studio, label: "Mac Studio", online: true)],
      sessions: [
        PeerSession(
          hostId: studio,
          session: TerminalSession(id: 9, initialPwd: "/", shells: [], name: "Fix it", lastMessageAt: 200))
      ])
    let model = TerminalSessionsModel(client: client, selectedSessionDefaults: defaults)
    await model.refresh()
    XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), [1], "this Mac's, at first")
    model.setSidebarMacs(.mac(studio))
    XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), [9])
    XCTAssertEqual(model.sidebarMacsTitle, "Mac Studio")
    model.setSidebarMacs(.all)
    XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), [9, 1])
    XCTAssertEqual(model.hostLabel(for: 9), "Mac Studio")
    XCTAssertNil(model.hostLabel(for: 1))

    // Shown, it gets a pane on this Mac, which selects and attaches like any.
    model.showSession(9)
    for _ in 0..<100 where model.session(for: 9)?.shells.isEmpty != false {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(client.openedPeers, [9])
    XCTAssertEqual(model.session(for: 9)?.shells.map(\.id), [client.pane.id])
    XCTAssertEqual(model.selectedSessionID, 9)

    // It is not this Mac's to rename or archive: closing it closes only the pane here.
    do {
      try await model.renameSession(9, to: "Mine")
      XCTFail("another Mac's Session was renamed here")
    } catch {}
    await model.requestCloseSession(9)
    XCTAssertEqual(client.closedPeers, [9])

    // A list that no longer has the Mac shown goes back to this Mac.
    client.peers = PeerSessionList(
      connected: true, hosts: [PeerHost(hostId: "8f8f8f8f-0000-4000-8000-000000000009", label: "Air", online: false)],
      sessions: [])
    model.setSidebarMacs(.mac(studio))
    _ = await model.apply(.peerSessionsChanged)
    XCTAssertEqual(model.sidebarMacs, .thisMac)
    XCTAssertNil(model.session(for: 9))
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
