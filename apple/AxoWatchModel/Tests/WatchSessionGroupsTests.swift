import AxoPhoneModel
import AxoProtocol
import XCTest
@testable import AxoWatchModel

final class WatchSessionGroupsTests: XCTestCase {
  func testActiveAndEarlierCombineSessionsAcrossMachinesUsingSharedRules() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let a = UUID(), b = UUID()
    let working = RemoteSession(hostId: a, sessionId: SessionID(UUID()), name: "Zeta working", status: .working, hasAgent: true, lastMessageAt: 1)
    let recent = RemoteSession(hostId: b, sessionId: SessionID(UUID()), name: "Alpha recent", status: .ready, hasAgent: true, lastMessageAt: 9_999)
    let earlierA = RemoteSession(hostId: a, sessionId: SessionID(UUID()), name: "Old A", status: .ready, hasAgent: true, lastMessageAt: 100)
    let earlierB = RemoteSession(hostId: b, sessionId: SessionID(UUID()), name: "Old B", status: .ready, hasAgent: true, lastMessageAt: 200)
    let terminal = RemoteSession(hostId: a, sessionId: SessionID(UUID()), name: "Not an agent", hasAgent: false)
    let hosts = [
      RemoteHost(hostId: a, hostGeneration: UUID(), label: "Many sessions Mac", status: .online, sessions: [working, earlierA, terminal]),
      RemoteHost(hostId: b, hostGeneration: UUID(), label: "Other Mac", status: .offline, sessions: [recent, earlierB]),
    ]
    let sections = WatchSessionGroups.sections(hosts: hosts, sessionsOf: { $0.sessions }, seen: ChatSeen(baseline: 10_000), now: now)
    XCTAssertEqual(sections.map(\.group), [.active, .earlier])
    XCTAssertEqual(sections[0].chats.map(\.session.displayName), ["Alpha recent", "Zeta working"], "active rows use the phone's name order, not host order")
    XCTAssertEqual(sections[1].chats.map(\.session.displayName), ["Old B", "Old A"], "earlier rows use latest activity across all Macs")
    XCTAssertEqual(Set(sections[0].chats.map(\.host.hostId)), Set([a, b]))
    XCTAssertEqual(Set(sections[1].chats.map(\.host.hostId)), Set([a, b]))
    XCTAssertEqual(sections.flatMap(\.chats).count, 4)
  }

  func testAttentionAndUnseenSessionsStayActiveAndRowIdentityIncludesHost() {
    let a = UUID(), b = UUID(), sharedID = SessionID(UUID())
    let attention = RemoteSession(hostId: a, sessionId: sharedID, name: "Needs you", status: .needsAttention, hasAgent: true, lastMessageAt: 1)
    let unseen = RemoteSession(hostId: b, sessionId: sharedID, name: "Unseen", hasAgent: true, lastMessageAt: 500)
    let hosts = [
      RemoteHost(hostId: a, hostGeneration: UUID(), label: "A", status: .online, sessions: [attention]),
      RemoteHost(hostId: b, hostGeneration: UUID(), label: "B", status: .online, sessions: [unseen]),
    ]
    let groups = WatchSessionGroups.sections(hosts: hosts, sessionsOf: { $0.sessions }, seen: ChatSeen(baseline: 100), now: Date(timeIntervalSince1970: 10_000))
    XCTAssertEqual(groups.map(\.group), [.active])
    XCTAssertEqual(Set(groups[0].chats.map(\.key)).count, 2, "same session id on different hosts must not collapse a row")
  }

  func testNoMachinesProducesNoMisleadingMachineSections() {
    XCTAssertTrue(WatchSessionGroups.sections(hosts: [], sessionsOf: { $0.sessions }, seen: ChatSeen(baseline: 0)).isEmpty)
  }
}
