import AxoProtocol
import Foundation
import Observation
import XCTest

@testable import AxoMac

final class SessionNavigationTests: XCTestCase {
  private func session(_ id: SessionID, folder: String = "/") -> TerminalSession {
    TerminalSession(id: id, folder: folder, shells: [])
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
    TerminalSession(id: id, folder: "/", shells: [], lastMessageAt: message, createdAt: created)
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

  func testSidebarGroupsArePinnedThenActiveAToZThenEarlierByActivity() {
    let now: Int64 = 10_000
    let seen = SessionSeen(baseline: 5_000)
    let sessions = [
      TerminalSession(id: 1, folder: "/", shells: [], name: "zeta", lastMessageAt: now - 10),
      TerminalSession(id: 2, folder: "/", shells: [], name: "alpha", lastMessageAt: now - 5),
      TerminalSession(id: 3, folder: "/", shells: [], name: "old", lastMessageAt: 1_000),
      TerminalSession(id: 4, folder: "/", shells: [], name: "older", lastMessageAt: 900),
      // Quiet for an hour but finished after this Mac last looked: still Active.
      TerminalSession(id: 5, folder: "/", shells: [], name: "mid", lastMessageAt: now - 3_600),
      // Quiet but still working: Active.
      TerminalSession(
        id: 6, folder: "/", shells: [], name: "busy", lastMessageAt: 800, status: .working),
      TerminalSession(id: 7, folder: "/", shells: [], name: "pinned", lastMessageAt: 100),
    ]
    let sections = SessionGrouping.sections(sessions, pins: SessionPins([7]), seen: seen, now: now)
    XCTAssertEqual(sections.map(\.group), [.pinned, .active, .earlier])
    XCTAssertEqual(sections.map { $0.sessions.map(\.id) }, [[7], [2, 6, 5, 1], [3, 4]])

    // More activity in an Active Session moves nothing: A to Z doesn't care.
    var busier = sessions
    busier[0] = TerminalSession(id: 1, folder: "/", shells: [], name: "zeta", lastMessageAt: now)
    XCTAssertEqual(
      SessionGrouping.sections(busier, pins: SessionPins([7]), seen: seen, now: now)[1].sessions.map(\.id),
      [2, 6, 5, 1])

    // Seen and quiet for the window, a Session falls to Earlier.
    var looked = seen
    looked.markSeen(sessions[4], now: now)
    looked.markSeen(sessions[1], now: now)
    let later = SessionGrouping.sections(
      sessions, pins: SessionPins([7]), seen: looked, now: now + SidebarGroupingSettings().activeWindow)
    XCTAssertEqual(later.map { $0.sessions.map(\.id) }, [[7], [6, 1], [2, 5, 3, 4]])
  }

  func testGroupingSettingsChangeTheWindowUnseenRuleAndOrders() {
    let now: Int64 = 10_000
    let seen = SessionSeen(baseline: 5_000)
    let sessions = [
      TerminalSession(
        id: 1, folder: "/", shells: [], name: "b", lastMessageAt: now - 600, createdAt: 10),
      TerminalSession(
        id: 2, folder: "/", shells: [], name: "a", lastMessageAt: now - 30, createdAt: 20),
      TerminalSession(
        id: 3, folder: "/", shells: [], name: "c", lastMessageAt: 1_000, createdAt: 30),
    ]
    var settings = SidebarGroupingSettings()
    let ids = { (settings: SidebarGroupingSettings) in
      SessionGrouping.sections(sessions, pins: SessionPins(), seen: seen, now: now, settings: settings)
        .map { $0.sessions.map(\.id) }
    }
    XCTAssertEqual(ids(settings), [[2, 1], [3]], "1 is unseen, so Active")
    settings.unseenStayActive = false
    XCTAssertEqual(ids(settings), [[2], [1, 3]])
    settings.activeWindowMinutes = 15
    XCTAssertEqual(ids(settings), [[2, 1], [3]], "1 is within 15 minutes")
    settings.activeOrder = .activity
    XCTAssertEqual(ids(settings), [[2, 1]] + [[3]])
    settings.activeOrder = .created
    XCTAssertEqual(ids(settings), [[2, 1], [3]])
    settings.activeOrder = .name
    settings.activeWindowMinutes = 60
    settings.earlierOrder = .name
    XCTAssertEqual(ids(settings), [[2, 1], [3]])
  }

  func testGroupingSettingsLoadWhateverIsStored() throws {
    XCTAssertEqual(SidebarGroupingSettings(storedValue: nil), SidebarGroupingSettings())
    XCTAssertEqual(SidebarGroupingSettings(storedValue: Data("junk".utf8)), SidebarGroupingSettings())
    // Missing, unknown and out-of-range values take their defaults or are clamped.
    let stored = Data(
      #"{"activeWindowMinutes":0,"activeOrder":"sideways","unseenMarker":"dot","future":1}"#.utf8)
    let settings = SidebarGroupingSettings(storedValue: stored)
    XCTAssertEqual(settings.activeWindowMinutes, 1)
    XCTAssertEqual(settings.activeOrder, .name)
    XCTAssertEqual(settings.unseenMarker, .dot)
    XCTAssertEqual(settings.regroupIntervalSeconds, 30)
    var changed = SidebarGroupingSettings()
    changed.earlierOrder = .created
    changed.showsGroupTitles = false
    XCTAssertEqual(SidebarGroupingSettings(storedValue: changed.storedValue), changed)
  }

  func testAHeldSidebarKeepsEachRowInItsGroupAndPlace() {
    let session = { (id: SessionID, name: String, at: Int64) in
      TerminalSession(id: id, folder: "/", shells: [], name: name, lastMessageAt: at)
    }
    let held = [
      SidebarSection(group: .active, sessions: [session(1, "a", 0), session(2, "b", 0)]),
      SidebarSection(group: .earlier, sessions: [session(3, "c", 0)]),
    ]
    // Live, 2 fell to Earlier and 4 is new; held, 2 stays put and 4 goes first in its group.
    let live = [
      SidebarSection(group: .active, sessions: [session(1, "a", 0), session(4, "d", 0)]),
      SidebarSection(group: .earlier, sessions: [session(2, "b", 0), session(3, "c", 0)]),
    ]
    let shown = SessionGrouping.holding(held, live: live, pins: SessionPins())
    XCTAssertEqual(shown.map { $0.sessions.map(\.id) }, [[4, 1, 2], [3]])
    // Pinned under the pointer, a row moves up at once.
    let pinnedLive = [
      SidebarSection(group: .pinned, sessions: [session(3, "c", 0)]),
      SidebarSection(group: .active, sessions: [session(1, "a", 0), session(4, "d", 0)]),
      SidebarSection(group: .earlier, sessions: [session(2, "b", 0)]),
    ]
    let pinned = SessionGrouping.holding(held, live: pinnedLive, pins: SessionPins([3]))
    XCTAssertEqual(pinned.map(\.group), [.pinned, .active])
    XCTAssertEqual(pinned.map { $0.sessions.map(\.id) }, [[3], [4, 1, 2]])
  }

  @MainActor func testShowingASessionToThePersonWakesItsDormantPiOnce() async throws {
    let suiteName = "axo-dormant-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let dormantPi = TerminalShell(
      id: 21, processId: 0, initialPwd: "/", ptyDevice: "", attachSocketPath: "/tmp/s", role: .pi,
      availability: .dormant)
    let client = FakeAxodClient()
    client.methods.append(AxodMethodName.piRestartAuto.rawValue)
    client.restartsPi = true
    client.sessions = [
      TerminalSession(id: 1, folder: "/", shells: [dormantPi]),
      TerminalSession(id: 2, folder: "/", shells: []),
    ]
    defaults.set(SessionID(2).rawValue, forKey: AxoPreferenceKey.selectedSession)
    let model = TerminalSessionsModel(client: client, selectedSessionDefaults: defaults)
    var looking = false
    model.isLookingAtSelection = { looking }
    await model.refresh()
    XCTAssertEqual(model.selectedSessionID, 2)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(client.restartedPis.isEmpty, "not shown, so left dormant")

    // Selected while the person is in another app: it waits for them to come back.
    model.showSession(1)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(client.restartedPis.isEmpty, "nobody is looking")
    looking = true
    model.appBecameActive()
    for _ in 0..<100 where model.shell(for: 21)?.isAvailable != true {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(client.restartedPis.map(\.shellID), [21])
    XCTAssertEqual(client.restartedPis.map(\.automatically), [true])
    XCTAssertTrue(try XCTUnwrap(model.shell(for: 21)).isAvailable)
    model.showSession(2)
    model.showSession(1)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(client.restartedPis.count, 1, "awake now, so not woken again")
  }

  @MainActor func testSessionsSeenOnThisMacAreRememberedAndOnlyNewActivityIsUnseen() async throws {
    let suiteName = "axo-sidebar-seen-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let now = Int64(Date.now.timeIntervalSince1970)
    let client = FakeAxodClient()
    client.sessions = [
      TerminalSession(id: 1, folder: "/", shells: [], name: "old", lastMessageAt: now - 7_200),
      TerminalSession(id: 2, folder: "/", shells: [], name: "other", lastMessageAt: now - 7_200),
    ]
    let model = TerminalSessionsModel(client: client, selectedSessionDefaults: defaults)
    var looking = false
    model.isLookingAtSelection = { looking }
    await model.refresh()
    // Activity from before this Mac kept track isn't news.
    XCTAssertEqual(model.sidebarSections.map(\.group), [.earlier])

    // New activity while nobody looks: unseen, so Active, and it stays Active past the window.
    client.sessions[1] = TerminalSession(
      id: 2, folder: "/", shells: [], name: "other", lastMessageAt: now + 5)
    await model.refresh()
    model.advanceSidebarClock(to: .now.addingTimeInterval(3_600))
    XCTAssertTrue(model.isUnseen(try XCTUnwrap(model.session(for: 2))))
    XCTAssertEqual(model.sidebarSections.map { $0.sessions.map(\.id) }, [[2], [1]])

    // Selected while Axo is in the background, it isn't seen; in front, it is.
    model.showSession(2)
    XCTAssertTrue(model.isUnseen(try XCTUnwrap(model.session(for: 2))))
    looking = true
    model.markSelectionSeen()
    XCTAssertFalse(model.isUnseen(try XCTUnwrap(model.session(for: 2))))
    XCTAssertEqual(model.sidebarSections.map { $0.sessions.map(\.id) }, [[2, 1]])

    // Remembered by the next launch, as are the grouping settings.
    var grouping = SidebarGroupingSettings()
    grouping.earlierOrder = .name
    model.setSidebarGrouping(grouping)
    model.advanceSidebarClock(to: .now.addingTimeInterval(3_600))
    XCTAssertEqual(model.sidebarSections.map { $0.sessions.map(\.id) }, [[1, 2]], "old before other")
    let relaunched = TerminalSessionsModel(client: client, selectedSessionDefaults: defaults)
    await relaunched.refresh()
    XCTAssertFalse(relaunched.isUnseen(try XCTUnwrap(relaunched.session(for: 2))))
    XCTAssertEqual(relaunched.sidebarGrouping, grouping)
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

  func testSuccessorPrefersRecentSiblingThenTheSameFolderThenAny() {
    let closed = session(1, folder: "/w")
    let sessions = [closed, session(2, folder: "/w"), session(3, folder: "/w"), session(4)]
    var recent = RecentSessions()
    recent.remember(4)
    recent.remember(3)
    recent.remember(1)
    XCTAssertEqual(
      SessionNavigation.successor(afterClosing: closed, in: sessions, recent: recent), 3)
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
    client.sessions = [TerminalSession(id: 1, folder: "/", shells: [])]
    client.closedSessions = [
      TerminalSession(id: 7, folder: "/", shells: []),
      TerminalSession(id: 4, folder: "/", shells: []),
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
    client.sessions = [
      TerminalSession(id: 1, folder: "/a", shells: [], lastMessageAt: 100),
      TerminalSession(id: 2, folder: "/a", shells: [], lastMessageAt: 300),
      TerminalSession(id: 3, folder: "/", shells: [], lastMessageAt: 200),
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
      id: 1, folder: "/a", shells: [], lastMessageAt: 400)
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
      TerminalSession(id: 1, folder: "/", shells: [], lastMessageAt: 100),
      TerminalSession(id: 2, folder: "/", shells: [], lastMessageAt: 300),
      TerminalSession(id: 3, folder: "/", shells: [], lastMessageAt: 200),
      TerminalSession(id: 4, folder: "/", shells: [], lastMessageAt: 50),
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
    client.sessions[0] = TerminalSession(id: 1, folder: "/", shells: [], lastMessageAt: 400)
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
      TerminalSession(id: 1, folder: "/", shells: [], lastMessageAt: 100),
      TerminalSession(id: 2, folder: "/", shells: [], lastMessageAt: 300),
      TerminalSession(id: 3, folder: "/", shells: [], lastMessageAt: 200),
    ]
    let model = TerminalSessionsModel(client: client, selectedSessionDefaults: defaults)
    await model.refresh()
    XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), [2, 3, 1])

    model.togglePin(1)
    XCTAssertTrue(model.isPinned(1))
    XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), [1, 2, 3], "pinned first")
    // More activity elsewhere doesn't move anything above a pinned Session.
    client.sessions[2] = TerminalSession(id: 3, folder: "/", shells: [], lastMessageAt: 900)
    await model.refresh()
    XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), [1, 3, 2])

    // Pinning under the pointer moves the row up even though the list is held still. Pinned
    // Sessions keep the order they were pinned in, whatever their activity.
    model.holdRecentOrder(true)
    model.togglePin(2)
    XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), [1, 2, 3])
    model.holdRecentOrder(false)
    XCTAssertEqual(model.sidebarOrderedSessions.map(\.id), [1, 2, 3])

    // Previous/Next Session follow the pinned order too.
    model.showSession(1)
    model.showNextSession()
    XCTAssertEqual(model.selectedSessionID, 2)

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
    XCTAssertEqual(relaunched.sidebarOrderedSessions.map(\.id), [1, 2, 3])

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
    client.sessions = [TerminalSession(id: 1, folder: "/", shells: [], lastMessageAt: 100)]
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
          session: TerminalSession(id: 9, folder: "/", shells: [], name: "Fix it", lastMessageAt: 200))
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
    client.sessions = [TerminalSession(id: 1, folder: "/", shells: [], lastMessageAt: 100)]
    let studio = "2e2e7f91-3d8f-4f97-8f71-4fc7d53313c7"
    client.peers = PeerSessionList(
      connected: true, hosts: [PeerHost(hostId: studio, label: "Mac Studio", online: true)],
      sessions: [
        PeerSession(
          hostId: studio,
          session: TerminalSession(id: 9, folder: "/", shells: [], name: "Fix it", lastMessageAt: 200))
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
    let session = TerminalSession(id: 1, folder: "/", shells: [shell])
    client.sessions = [session]
    let model = TerminalSessionsModel(client: client)
    await model.refresh()

    let changed = await observesChange(of: {
      _ = (model.sessions, model.selectedSessionID, model.focusedShellID,
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
    client.sessions = [TerminalSession(id: 1, folder: "/", shells: [shell])]
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
          "This action requires a newer Axod. Your Sessions are unchanged."))
    }
  }
}
