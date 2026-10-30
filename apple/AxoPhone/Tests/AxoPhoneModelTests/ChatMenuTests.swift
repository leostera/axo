import AxoProtocol
import XCTest

@testable import AxoPhoneModel

final class ChatMenuTests: XCTestCase {
  private func session(
    _ id: Int, on host: UUID, workspace: String, at time: String, agent: Bool = true, status: String = "ready",
    lastMessageAt: Int64? = nil, createdAt: Int64? = nil
  ) -> RemoteSession {
    let times = [lastMessageAt.map { ",\"lastMessageAt\":\($0)" }, createdAt.map { ",\"createdAt\":\($0)" }]
      .compactMap { $0 }.joined()
    return try! JSONDecoder().decode(RemoteSession.self, from: Data("""
      {"hostId":"\(host.uuidString)","sessionId":"\(SessionID.fixture(UInt32(id)))","name":"S\(id)","workspaceName":"\(workspace)",
      "hasAgent":\(agent),"status":"\(status)","shells":[],"layout":null,"updatedAt":"\(time)"\(times)}
      """.utf8))
  }

  private func workspace(_ name: String) -> RemoteWorkspace {
    try! JSONDecoder().decode(RemoteWorkspace.self, from: Data(#"{"workspaceId":"\#(UUID().uuidString)","name":"\#(name)"}"#.utf8))
  }

  private func host(_ label: String, _ sessions: [RemoteSession], id: UUID) -> RemoteHost {
    let list = sessions.map { "{\"hostId\":\"\(id.uuidString)\",\"sessionId\":\"\($0.sessionId)\",\"shells\":[],\"updatedAt\":\"\($0.updatedAt)\"}" }
    return try! JSONDecoder().decode(RemoteHost.self, from: Data("""
      {"hostId":"\(id.uuidString)","hostGeneration":"\(UUID().uuidString)","label":"\(label)","hostKind":"macos",
      "status":"online","stale":false,"lastSeenAt":"2026-10-16T00:00:00Z","sessions":[\(list.joined(separator: ","))]}
      """.utf8))
  }

  func testWorkspacesStayInAlphabeticalOrderAndTheirChatsAreMostRecentlyActiveFirst() {
    let id = UUID()
    let sessions = [
      session(1, on: id, workspace: "Axo", at: "2026-10-20T10:00:00Z"),
      session(2, on: id, workspace: "Website", at: "2026-10-27T09:00:00Z"),
      session(3, on: id, workspace: "Axo", at: "2026-10-26T10:00:00.250Z"),
      session(4, on: id, workspace: "Axo", at: "2026-10-22T10:00:00Z"),
      session(5, on: id, workspace: "Axo", at: "2026-10-27T08:00:00Z", agent: false),
    ]
    let studio = host("Studio", sessions, id: id)
    let menu = ChatMenu.sections(hosts: [studio], sessionsOf: { _ in sessions }, openHost: studio, workspaces: [
      workspace("Axo"), workspace("notes"),
    ])
    XCTAssertEqual(
      menu.map(\.title), ["Axo", "notes", "Website"],
      "alphabetically, case aside, however recent their chats; an empty one in its place")
    XCTAssertEqual(menu[0].chats.map(\.session.sessionId), [3, 4, 1], "newest activity first; a bare terminal is not a chat")
    XCTAssertEqual(menu[1].chats, [])
  }

  func testProjectsComeFirstAndTheHomeWorkspacesChatsGoUnderThemNewestFirst() throws {
    let id = UUID()
    let sessions = [
      session(1, on: id, workspace: "Axo", at: "2026-10-20T10:00:00Z"),
      session(2, on: id, workspace: "Home", at: "2026-10-27T09:00:00Z"),
      session(3, on: id, workspace: "Home", at: "2026-10-27T11:00:00Z"),
    ]
    let studio = host("Studio", sessions, id: id)
    let home = try JSONDecoder().decode(
      RemoteWorkspace.self,
      from: Data(#"{"workspaceId":"\#(UUID().uuidString)","name":"Home","home":true}"#.utf8))
    XCTAssertTrue(home.isHome)
    let menu = ChatMenu.sections(hosts: [studio], sessionsOf: { _ in sessions }, openHost: studio, workspaces: [
      home, workspace("Axo"), workspace("A first"),
    ])
    XCTAssertEqual(menu.map(\.title), ["A first", "Axo", "Home"], "projects alphabetically, however recent; Home last")
    XCTAssertEqual(menu.map(\.kind), [.project, .project, .home])
    XCTAssertEqual(menu[2].chats.map(\.session.sessionId), [3, 2], "Home's chats newest first")

    let unflagged = ChatMenu.sections(hosts: [studio], sessionsOf: { _ in sessions }, openHost: studio, workspaces: [
      workspace("Home"), workspace("Axo"),
    ])
    XCTAssertEqual(unflagged.map(\.kind), [.project, .project], "a Workspace merely named Home is a project")
    XCTAssertEqual(unflagged.map(\.title), ["Axo", "Home"])
  }

  func testWithSeveralMacsTheWorkspaceNamesItsMacAndTiesKeepTheNewerChatFirst() {
    let (a, b) = (UUID(), UUID())
    let left = [session(1, on: a, workspace: "Axo", at: "2026-10-20T10:00:00Z"), session(2, on: a, workspace: "Axo", at: "2026-10-20T10:00:00Z")]
    let right = [session(9, on: b, workspace: "Axo", at: "2026-10-21T10:00:00Z")]
    let studio = host("Studio", left, id: a)
    let imac = host("iMac", right, id: b)
    let menu = ChatMenu.sections(hosts: [studio, imac], sessionsOf: { $0.hostId == a ? left : right }, openHost: nil, workspaces: [])
    XCTAssertEqual(menu.map(\.title), ["Axo · iMac", "Axo · Studio"])
    XCTAssertEqual(menu[1].chats.map(\.session.sessionId), [2, 1])
  }

  func testASectionListsChatsActiveInTheLastEightHoursBusyOnesAndTheOpenOne() {
    let id = UUID()
    let sessions = [
      session(1, on: id, workspace: "Axo", at: "2026-10-27T11:00:00Z"),
      session(2, on: id, workspace: "Axo", at: "2026-10-27T04:00:01Z"),
      session(3, on: id, workspace: "Axo", at: "2026-10-27T03:59:59Z"),
      session(4, on: id, workspace: "Axo", at: "2026-10-20T00:00:00Z", status: "working"),
      session(5, on: id, workspace: "Axo", at: "2026-10-19T00:00:00Z", status: "needsAttention"),
      session(6, on: id, workspace: "Axo", at: "2026-10-18T00:00:00Z"),
    ]
    let studio = host("Studio", sessions, id: id)
    let section = ChatMenu.sections(hosts: [studio], sessionsOf: { _ in sessions }, openHost: nil, workspaces: [])[0]
    let now = try! Date("2026-10-27T12:00:00Z", strategy: .iso8601)
    XCTAssertEqual(section.recentChats(now: now).map(\.session.sessionId), [1, 2, 4, 5])
    XCTAssertEqual(
      section.recentChats(now: now, keeping: { $0.session.sessionId == 6 }).map(\.session.sessionId), [1, 2, 4, 5, 6])
    XCTAssertTrue(section.isBusy)
  }

  // MARK: - Recent activity

  /// What every snapshot from one Mac says: when it was sent, not when a chat was active.
  private let sent = "2026-10-27T12:00:00Z"
  private func at(_ iso: String) -> Int64 { Int64(try! Date(iso, strategy: .iso8601).timeIntervalSince1970) }

  func testAChatsActivityIsItsLatestFinishedMessageOrItsCreationNotTheSnapshotsTime() {
    let id = UUID()
    let messaged = session(1, on: id, workspace: "Axo", at: sent, lastMessageAt: at("2026-10-27T09:00:00Z"), createdAt: at("2026-10-26T00:00:00Z"))
    let fresh = session(2, on: id, workspace: "Axo", at: sent, createdAt: at("2026-10-27T11:00:00Z"))
    let unknown = session(3, on: id, workspace: "Axo", at: sent)
    XCTAssertEqual(ChatMenu.activity(messaged), try! Date("2026-10-27T09:00:00Z", strategy: .iso8601))
    XCTAssertEqual(ChatMenu.activity(fresh), try! Date("2026-10-27T11:00:00Z", strategy: .iso8601), "no messages yet: its creation")
    XCTAssertEqual(ChatMenu.activity(unknown), try! Date(sent, strategy: .iso8601), "a Mac that reports neither")
  }

  func testTheRecentListPutsEveryChatOnEveryMacInOneListMostRecentlyActiveFirst() {
    let (studioID, laptopID) = (UUID(), UUID())
    let studioSessions = [
      session(1, on: studioID, workspace: "Axo", at: sent, lastMessageAt: at("2026-10-27T08:00:00Z")),
      session(2, on: studioID, workspace: "Website", at: sent, lastMessageAt: at("2026-10-27T11:00:00Z")),
      session(3, on: studioID, workspace: "Home", at: sent, agent: false, lastMessageAt: at("2026-10-27T11:59:00Z")),
      session(4, on: studioID, workspace: "Home", at: sent, createdAt: at("2026-10-27T10:00:00Z")),
    ]
    let laptopSessions = [session(9, on: laptopID, workspace: "Axo", at: sent, lastMessageAt: at("2026-10-27T10:30:00Z"))]
    let studio = host("Studio", studioSessions, id: studioID)
    let laptop = host("Laptop", laptopSessions, id: laptopID)
    let list = ChatMenu.recent(hosts: [studio, laptop]) { $0.hostId == studioID ? studioSessions : laptopSessions }
    XCTAssertEqual(list.map(\.session.sessionId), [2, 9, 4, 1], "across Workspaces and Macs; no bare terminals")
  }

  func testWorkspacesListTheirChatsByRealActivityToo() {
    let id = UUID()
    let sessions = [
      session(1, on: id, workspace: "Axo", at: sent, lastMessageAt: at("2026-10-27T11:00:00Z")),
      session(2, on: id, workspace: "Axo", at: sent, lastMessageAt: at("2026-10-27T01:00:00Z")),
    ]
    let studio = host("Studio", sessions, id: id)
    let section = ChatMenu.sections(hosts: [studio], sessionsOf: { _ in sessions }, openHost: studio, workspaces: [])[0]
    XCTAssertEqual(section.chats.map(\.session.sessionId), [1, 2])
    XCTAssertEqual(
      section.recentChats(now: try! Date(sent, strategy: .iso8601)).map(\.session.sessionId), [1],
      "quiet for 11 hours: behind the button")
  }

  func testHeldRowsKeepTheirOrderChatsNewSinceGoFirstAndClosedOnesDropOut() {
    let id = UUID()
    let sessions = [
      session(1, on: id, workspace: "Axo", at: sent, lastMessageAt: at("2026-10-27T11:00:00Z")),
      session(2, on: id, workspace: "Axo", at: sent, lastMessageAt: at("2026-10-27T11:30:00Z")),
      session(3, on: id, workspace: "Axo", at: sent, lastMessageAt: at("2026-10-27T11:45:00Z")),
    ]
    let studio = host("Studio", sessions, id: id)
    let live = ChatMenu.recent(hosts: [studio]) { _ in sessions }
    let key = { (session: SessionID) in ChatMenuEntry.Key(host: id, session: session) }
    XCTAssertEqual(ChatMenu.holding([key(1), key(4), key(2)], live: live).map(\.session.sessionId), [3, 1, 2])
    XCTAssertEqual(ChatMenu.holding(nil, live: live).map(\.session.sessionId), [3, 2, 1])
  }

  func testAgesAreShortAsOnTheMac() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    XCTAssertEqual(
      [30, 300, 3 * 3_600, 2 * 86_400, 4 * 604_800].map { ChatMenu.age(of: now.addingTimeInterval(-TimeInterval($0)), now: now) },
      ["now", "5m", "3h", "2d", "4w"])
  }
}
