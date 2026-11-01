import XCTest

@testable import AxoProtocol

/// What the relay sends, decoded: a created Session's snapshot (v1) and the account client's
/// listing and records (RFD0018).
final class RemoteModelsTests: XCTestCase {
  private let host = "18355f00-95fd-4c93-8586-a71a8a52bf73"
  private let generation = "c3b6da28-55c0-4bb0-ac04-dd458fd41a2b"

  func testACreatedSessionsSnapshotDecodes() throws {
    let json = """
      {"hostId":"\(host)","sessionId":"00000009-0000-4000-8000-000000000009","workspaceId":"7f1918d3-8b6d-4af4-a57e-7e6ae28e89e2",
      "workspaceName":"Axo","name":"Ship it","emoji":"🦀","status":"working","hasAgent":true,"shells":[{"shellId":12}],
      "layout":{"kind":"pane","shellId":12},"updatedAt":"2026-10-15T23:59:00Z"}
      """
    let session = try JSONDecoder().decode(RemoteSession.self, from: Data(json.utf8))
    XCTAssertEqual(session.sessionId, 9)
    XCTAssertEqual(session.status, .working)
    XCTAssertEqual(session.shells.map(\.shellId), [12])
    XCTAssertEqual(session.layout, .pane(shellID: 12))
    XCTAssertEqual(session.displayName, "Ship it")
  }

  func testTheAccountListingDecodesAndBecomesHostsAndSessions() throws {
    let json = """
      {"hosts":[{"hostId":"\(host)","hostGeneration":"\(generation)","label":"Axo Mac","hostKind":"macos",
      "online":false,"lastSeenAt":"2026-10-16T00:00:00Z"}],
      "sessions":[{"hostId":"\(host)","sessionId":"00000009-0000-4000-8000-000000000009","epoch":2,"head":40,
      "status":"working","metadata":{"name":"Ship it","emoji":"🦀","workspaceId":"7f1918d3-8b6d-4af4-a57e-7e6ae28e89e2",
      "workspaceName":"Axo","hasAgent":true,"createdAt":1700000000,"lastMessageAt":1700000100,"archived":false}}]}
      """
    let hello = try JSONDecoder().decode(ClientHello.self, from: Data(json.utf8))
    let listed = try XCTUnwrap(hello.sessions.first)
    XCTAssertEqual([listed.epoch, listed.head], [2, 40])
    let session = RemoteSession(listed)
    XCTAssertEqual(session.sessionId, 9)
    XCTAssertEqual(session.workspaceName, "Axo")
    XCTAssertEqual(session.status, .working)
    XCTAssertEqual(session.lastMessageAt, 1_700_000_100)
    XCTAssertEqual(session.shells, [], "terminals stay on the Mac")
    let remote = RemoteHost(try XCTUnwrap(hello.hosts.first), sessions: [session])
    XCTAssertEqual(remote.label, "Axo Mac")
    XCTAssertEqual(remote.status, .offline)
    XCTAssertEqual(remote.reference.hostGeneration.uuidString.lowercased(), generation)
  }

  func testASessionsWorkspaceStateDecodesAndIsAbsentFromOlderMacs() throws {
    let head = String(repeating: "a1", count: 20)
    let json = """
      {"hosts":[],"sessions":[{"hostId":"\(host)","sessionId":"00000009-0000-4000-8000-000000000009","epoch":2,"head":40,
      "status":"ready","metadata":{"name":"Ship it","emoji":null,"workspaceId":null,"workspaceName":"Axo","hasAgent":true,
      "createdAt":1700000000,"lastMessageAt":null,"archived":false,"workspaceState":{"path":"/Users/leo/axo/apple",
      "repoRoot":"/Users/leo/axo","remote":"https://github.com/leostera/axo","branch":"main","head":"\(head)",
      "upstreamHead":null,"dirty":["README.md","apple/BUILD.bazel"],"dirtyMore":3,"at":1700000200}}},
      {"hostId":"\(host)","sessionId":"00000001-0000-4000-8000-000000000001","epoch":null,"head":0,"status":null,
      "metadata":{"name":null,"emoji":null,"workspaceId":null,"workspaceName":null,"hasAgent":true,"createdAt":null,
      "lastMessageAt":null,"archived":false}}]}
      """
    let hello = try JSONDecoder().decode(ClientHello.self, from: Data(json.utf8))
    let state = try XCTUnwrap(RemoteSession(hello.sessions[0]).workspaceState)
    XCTAssertEqual(state.branch, "main")
    XCTAssertEqual(state.head, head)
    XCTAssertEqual(state.changedCount, 5)
    XCTAssertTrue(state.isRepository)
    XCTAssertFalse(state.differsFromUpstream, "an upstream never fetched says nothing")
    XCTAssertNil(RemoteSession(hello.sessions[1]).workspaceState)
  }

  func testRecordsAndProgressDecodeAndAClearedSlotIsNull() throws {
    let open = """
      {"epoch":1,"records":[{"cursor":4,"id":"a1b2","format":"pi/3","line":"{\\"type\\":\\"message\\"}",
      "hash":"sha256:\(String(repeating: "ab", count: 32))"}],"cursor":4,"older":4,
      "progress":[{"slot":"message","snapshot":{"message":{"role":"assistant"}}},{"slot":"question","snapshot":null}]}
      """
    let decoded = try JSONDecoder().decode(ClientOpenResult.self, from: Data(open.utf8))
    XCTAssertEqual(decoded.records.first?.line, #"{"type":"message"}"#)
    XCTAssertEqual(decoded.older, 4)
    XCTAssertEqual(decoded.progress.first?.snapshot["message"]?["role"]?.stringValue, "assistant")
    XCTAssertEqual(decoded.progress.last?.snapshot, .null)
  }

  func testASessionWithoutMetadataIsRejectedNotGuessed() {
    let json = #"{"hosts":[],"sessions":[{"hostId":"\#(host)","sessionId":"00000001-0000-4000-8000-000000000001","epoch":null,"head":0,"status":null}]}"#
    XCTAssertThrowsError(try JSONDecoder().decode(ClientHello.self, from: Data(json.utf8)))
  }
}
