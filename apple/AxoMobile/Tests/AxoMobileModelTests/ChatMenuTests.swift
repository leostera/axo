import AxoProtocol
import XCTest

@testable import AxoMobileModel

final class ChatMenuTests: XCTestCase {
  private func session(
    _ id: Int, on host: UUID, folder: String, at time: String, agent: Bool = true, status: String = "ready",
    lastMessageAt: Int64? = nil, createdAt: Int64? = nil
  ) -> RemoteSession {
    let times = [lastMessageAt.map { ",\"lastMessageAt\":\($0)" }, createdAt.map { ",\"createdAt\":\($0)" }]
      .compactMap { $0 }.joined()
    return try! JSONDecoder().decode(RemoteSession.self, from: Data("""
      {"hostId":"\(host.uuidString)","sessionId":"\(SessionID.fixture(UInt32(id)))","name":"S\(id)","folderName":"\(folder)",
      "hasAgent":\(agent),"status":"\(status)","shells":[],"layout":null,"updatedAt":"\(time)"\(times)}
      """.utf8))
  }

  private func host(_ label: String, _ sessions: [RemoteSession], id: UUID) -> RemoteHost {
    RemoteHost(ClientHost(hostId: id, hostGeneration: UUID(), label: label, online: true), sessions: sessions)
  }

  // MARK: - Recent activity

  /// What every snapshot from one Mac says: when it was sent, not when a chat was active.
  private let sent = "2026-10-27T12:00:00Z"
  private func at(_ iso: String) -> Int64 { Int64(try! Date(iso, strategy: .iso8601).timeIntervalSince1970) }

  func testAChatsActivityIsItsLatestFinishedMessageOrItsCreationNotTheSnapshotsTime() {
    let id = UUID()
    let messaged = session(1, on: id, folder: "Axo", at: sent, lastMessageAt: at("2026-10-27T09:00:00Z"), createdAt: at("2026-10-26T00:00:00Z"))
    let fresh = session(2, on: id, folder: "Axo", at: sent, createdAt: at("2026-10-27T11:00:00Z"))
    let unknown = session(3, on: id, folder: "Axo", at: sent)
    XCTAssertEqual(ChatMenu.activity(messaged), try! Date("2026-10-27T09:00:00Z", strategy: .iso8601))
    XCTAssertEqual(ChatMenu.activity(fresh), try! Date("2026-10-27T11:00:00Z", strategy: .iso8601), "no messages yet: its creation")
    XCTAssertEqual(ChatMenu.activity(unknown), try! Date(sent, strategy: .iso8601), "a Mac that reports neither")
  }

  func testTheRecentListPutsEveryChatOnEveryMacInOneListMostRecentlyActiveFirst() {
    let (studioID, laptopID) = (UUID(), UUID())
    let studioSessions = [
      session(1, on: studioID, folder: "Axo", at: sent, lastMessageAt: at("2026-10-27T08:00:00Z")),
      session(2, on: studioID, folder: "Website", at: sent, lastMessageAt: at("2026-10-27T11:00:00Z")),
      session(3, on: studioID, folder: "Home", at: sent, agent: false, lastMessageAt: at("2026-10-27T11:59:00Z")),
      session(4, on: studioID, folder: "Home", at: sent, createdAt: at("2026-10-27T10:00:00Z")),
    ]
    let laptopSessions = [session(9, on: laptopID, folder: "Axo", at: sent, lastMessageAt: at("2026-10-27T10:30:00Z"))]
    let studio = host("Studio", studioSessions, id: studioID)
    let laptop = host("Laptop", laptopSessions, id: laptopID)
    let list = ChatMenu.recent(hosts: [studio, laptop]) { $0.hostId == studioID ? studioSessions : laptopSessions }
    XCTAssertEqual(list.map(\.session.sessionId), [2, 9, 4, 1], "across folders and Macs; no bare terminals")
  }

  func testHeldRowsKeepTheirOrderChatsNewSinceGoFirstAndClosedOnesDropOut() {
    let id = UUID()
    let sessions = [
      session(1, on: id, folder: "Axo", at: sent, lastMessageAt: at("2026-10-27T11:00:00Z")),
      session(2, on: id, folder: "Axo", at: sent, lastMessageAt: at("2026-10-27T11:30:00Z")),
      session(3, on: id, folder: "Axo", at: sent, lastMessageAt: at("2026-10-27T11:45:00Z")),
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
