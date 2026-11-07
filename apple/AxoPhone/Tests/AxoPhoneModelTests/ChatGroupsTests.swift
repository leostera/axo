import AxoProtocol
import XCTest

@testable import AxoPhoneModel

/// The chat list's Pinned, Active and Earlier groups, as the Mac's sidebar and the web app have them.
final class ChatGroupsTests: XCTestCase {
  private let now: Int64 = 1_800_000_000
  private let hostID = UUID()

  private func entry(_ id: UInt32, name: String? = nil, ago: Int64, status: String = "ready", createdAgo: Int64? = nil)
    -> ChatMenuEntry
  {
    let created = now - (createdAgo ?? ago)
    let session = try! JSONDecoder().decode(RemoteSession.self, from: Data("""
      {"hostId":"\(hostID.uuidString)","sessionId":"\(SessionID.fixture(id))","name":"\(name ?? "S\(id)")",
      "hasAgent":true,"status":"\(status)","shells":[],"layout":null,"updatedAt":"2026-01-01T00:00:00Z",
      "lastMessageAt":\(now - ago),"createdAt":\(created)}
      """.utf8))
    let host = RemoteHost(ClientHost(hostId: hostID, hostGeneration: UUID(), label: "Studio", online: true), sessions: [session])
    return ChatMenuEntry(host: host, session: session)
  }

  private func names(_ sections: [ChatGroupSection]) -> [String: [String]] {
    Dictionary(uniqueKeysWithValues: sections.map { ($0.group.title, $0.chats.map(\.session.displayName)) })
  }

  func testTheDefaultsAreTheMacs() {
    let settings = ChatGroupingSettings()
    XCTAssertEqual(settings.activeWindowMinutes, 3)
    XCTAssertEqual(settings.regroupIntervalSeconds, 30)
    XCTAssertTrue(settings.unseenStayActive)
    XCTAssertEqual(settings.unseenMarker, .dotAndBold)
    XCTAssertEqual(settings.pinnedOrder, .pinned)
    XCTAssertEqual(settings.activeOrder, .name)
    XCTAssertEqual(settings.earlierOrder, .activity)
    XCTAssertTrue(settings.showsGroupTitles)
    XCTAssertFalse(settings.earlierCollapsed)
    XCTAssertNil(settings.earlierLimit)
  }

  func testStoredSettingsLoadWhateverIsMissingOrOutOfRange() {
    let stored = Data(#"{"activeWindowMinutes":0,"activeOrder":"pinned","earlierLimit":10,"unseenMarker":"sparkles","future":1}"#.utf8)
    let settings = ChatGroupingSettings(storedValue: stored)
    XCTAssertEqual(settings.activeWindowMinutes, 1, "clamped")
    XCTAssertEqual(settings.activeOrder, .name, "pin order is only for Pinned")
    XCTAssertEqual(settings.unseenMarker, .dotAndBold, "an unknown marker takes the default")
    XCTAssertEqual(settings.earlierLimit, 10)
    XCTAssertEqual(ChatGroupingSettings(storedValue: Data("nonsense".utf8)), ChatGroupingSettings())
    XCTAssertEqual(ChatGroupingSettings(storedValue: settings.storedValue), settings, "round trips")
  }

  func testPinnedThenActiveAToZThenEarlierByLatestActivity() {
    let entries = [
      entry(1, name: "zeta", ago: 30),
      entry(2, name: "alpha", ago: 60),
      entry(3, name: "old", ago: 86_400),
      entry(4, name: "older", ago: 7 * 86_400),
      entry(5, name: "busy", ago: 86_400, status: "working"),
      entry(6, name: "asking", ago: 86_400, status: "needsAttention"),
      entry(7, name: "pinned old", ago: 30 * 86_400),
    ]
    let pins = ChatPins([7])
    // Everything was seen after its last message, so only time and status decide.
    let seen = ChatSeen(baseline: now)
    let sections = ChatGrouping.sections(entries, pins: pins, seen: seen, now: now)
    XCTAssertEqual(sections.map(\.group), [.pinned, .active, .earlier])
    XCTAssertEqual(names(sections)["Pinned"], ["pinned old"])
    XCTAssertEqual(names(sections)["Active"], ["alpha", "asking", "busy", "zeta"])
    XCTAssertEqual(names(sections)["Earlier"], ["old", "older"])
  }

  func testUnseenActivityStaysActiveUntilSeen() {
    let old = entry(1, name: "news", ago: 3_600)
    var seen = ChatSeen(baseline: now - 7_200)
    XCTAssertEqual(ChatGrouping.group(of: old, pins: ChatPins(), seen: seen, now: now), .active)
    var settings = ChatGroupingSettings()
    settings.unseenStayActive = false
    XCTAssertEqual(ChatGrouping.group(of: old, pins: ChatPins(), seen: seen, now: now, settings: settings), .earlier)
    XCTAssertTrue(seen.markSeen(old.session, now: now))
    XCTAssertFalse(seen.markSeen(old.session, now: now + 1), "already seen")
    XCTAssertEqual(ChatGrouping.group(of: old, pins: ChatPins(), seen: seen, now: now), .earlier)
  }

  func testPinsAreCappedOldestFirstAndKeptForChatsNotListed() {
    var pins = ChatPins((1...UInt32(ChatPins.capacity)).map { SessionID.fixture($0) })
    pins.toggle(.fixture(9_999))
    XCTAssertEqual(pins.ids.count, ChatPins.capacity)
    XCTAssertFalse(pins.contains(.fixture(1)), "the oldest pin goes")
    XCTAssertTrue(pins.contains(.fixture(9_999)))
    pins.toggle(.fixture(9_999))
    XCTAssertFalse(pins.contains(.fixture(9_999)))
    XCTAssertEqual(ChatPins(storedValue: ["nope", SessionID.fixture(3).rawValue]).ids, [.fixture(3)])
    // A pin for a chat not listed does nothing, and stays.
    let sections = ChatGrouping.sections([entry(5, ago: 30)], pins: ChatPins([.fixture(77), .fixture(5)]),
      seen: ChatSeen(baseline: now), now: now)
    XCTAssertEqual(sections.map(\.group), [.pinned])
  }

  func testTheHeldListKeepsRowsInPlaceButPinsApplyAtOnce() {
    let seen = ChatSeen(baseline: now)
    let a = entry(1, name: "a", ago: 30)
    let b = entry(2, name: "b", ago: 86_400)
    let held = ChatGrouping.sections([a, b], pins: ChatPins(), seen: seen, now: now)
    // b gets a message: live, it is Active; held, it stays in Earlier. A new chat leads Active.
    let bNow = entry(2, name: "b", ago: 5)
    let c = entry(3, name: "c", ago: 1)
    let live = ChatGrouping.sections([a, bNow, c], pins: ChatPins(), seen: ChatSeen(baseline: now + 10), now: now)
    XCTAssertEqual(names(ChatGrouping.holding(held, live: live)), ["Active": ["c", "a"], "Earlier": ["b"]])
    XCTAssertEqual(ChatGrouping.holding(held, live: live).last?.chats.first?.session, bNow.session, "with live data")
    let pinned = ChatGrouping.sections([a, bNow, c], pins: ChatPins([2]), seen: seen, now: now)
    XCTAssertEqual(names(ChatGrouping.holding(held, live: pinned)), ["Pinned": ["b"], "Active": ["c", "a"]])
  }

  @MainActor
  func testPreferencesAreKeptUnderTheMacsKeys() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "ChatGroupsTests-\(UUID())"))
    let prefs = ChatListPreferences(defaults: defaults, now: Date(timeIntervalSince1970: TimeInterval(now)))
    prefs.togglePin(.fixture(4))
    prefs.settings.earlierCollapsed = true
    prefs.markSeen(entry(4, ago: -60).session, now: Date(timeIntervalSince1970: TimeInterval(now)))
    XCTAssertEqual(defaults.stringArray(forKey: "sidebar.pinnedSessions.v1"), [SessionID.fixture(4).rawValue])
    XCTAssertEqual(defaults.object(forKey: "sidebar.seenSessionsBaseline.v1") as? Int64, now)
    XCTAssertEqual(defaults.dictionary(forKey: "sidebar.seenSessions.v1")?[SessionID.fixture(4).rawValue] as? Int64, now + 60)
    let again = ChatListPreferences(defaults: defaults)
    XCTAssertTrue(again.pins.contains(.fixture(4)))
    XCTAssertTrue(again.settings.earlierCollapsed)
    XCTAssertEqual(again.seen.baseline, now)
  }
}
