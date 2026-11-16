import AxoProtocol
import Foundation
import XCTest
@testable import AxoPhoneModel

final class ChatSearchTests: XCTestCase {
  func testFuzzyTitleAndFolderSubsequencesAndActivityTies() {
    let hostID = UUID()
    let sessions = [
      RemoteSession(hostId: hostID, sessionId: .fixture(1), folderName: "axo", name: "database migration", lastMessageAt: 10),
      RemoteSession(hostId: hostID, sessionId: .fixture(2), folderName: "axo", name: "database migration", lastMessageAt: 30),
      RemoteSession(hostId: hostID, sessionId: .fixture(3), folderName: "database migration", name: "Other", lastMessageAt: 100),
      RemoteSession(hostId: hostID, sessionId: .fixture(4), name: "database migration", hasAgent: false, lastMessageAt: 200),
    ]
    let host = RemoteHost(ClientHost(hostId: hostID, hostGeneration: UUID(), label: "Studio", online: true), sessions: sessions)
    let matches = ChatSearch.matches("dbmig", hosts: [host], sessionsOf: { _ in sessions })
    XCTAssertEqual(matches.map(\.session.sessionId), [.fixture(2), .fixture(1), .fixture(3)])
    XCTAssertEqual(ChatSearch.matches("", hosts: [host], sessionsOf: { _ in sessions }).map(\.session.sessionId),
                   [.fixture(3), .fixture(2), .fixture(1)])
    XCTAssertTrue(ChatSearch.matches("zzzzzz", hosts: [host], sessionsOf: { _ in sessions }).isEmpty)
  }
}
