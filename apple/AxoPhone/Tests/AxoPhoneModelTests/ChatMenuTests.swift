import AxoProtocol
import XCTest

@testable import AxoPhoneModel

final class ChatMenuTests: XCTestCase {
  private func session(_ id: Int, on host: UUID, workspace: String, at time: String, agent: Bool = true) -> RemoteSession {
    try! JSONDecoder().decode(RemoteSession.self, from: Data("""
      {"hostId":"\(host.uuidString)","sessionId":\(id),"name":"S\(id)","workspaceName":"\(workspace)",
      "hasAgent":\(agent),"shells":[],"layout":null,"updatedAt":"\(time)"}
      """.utf8))
  }

  private func workspace(_ name: String) -> RemoteWorkspace {
    try! JSONDecoder().decode(RemoteWorkspace.self, from: Data(#"{"workspaceId":"\#(UUID().uuidString)","name":"\#(name)"}"#.utf8))
  }

  private func host(_ label: String, _ sessions: [RemoteSession], id: UUID) -> RemoteHost {
    let list = sessions.map { "{\"hostId\":\"\(id.uuidString)\",\"sessionId\":\($0.sessionId),\"shells\":[],\"updatedAt\":\"\($0.updatedAt)\"}" }
    return try! JSONDecoder().decode(RemoteHost.self, from: Data("""
      {"hostId":"\(id.uuidString)","hostGeneration":"\(UUID().uuidString)","label":"\(label)","hostKind":"macos",
      "status":"online","stale":false,"lastSeenAt":"2026-10-16T00:00:00Z","sessions":[\(list.joined(separator: ","))]}
      """.utf8))
  }

  func testChatsAndWorkspacesAreListedMostRecentlyActiveFirst() {
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
      workspace("Axo"), workspace("Notes"),
    ])
    XCTAssertEqual(menu.map(\.title), ["Website", "Axo", "Notes"], "by the newest chat in each; an empty one last")
    XCTAssertEqual(menu[1].chats.map(\.session.sessionId), [3, 4, 1], "newest activity first; a bare terminal is not a chat")
    XCTAssertEqual(menu[2].chats, [])
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
}
