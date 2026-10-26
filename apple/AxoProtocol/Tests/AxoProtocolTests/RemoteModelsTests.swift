import XCTest

@testable import AxoProtocol

/// What the relay sends, decoded; the JSON is the v1 contract's own fixtures.
final class RemoteModelsTests: XCTestCase {
  private let host = "18355f00-95fd-4c93-8586-a71a8a52bf73"
  private let generation = "c3b6da28-55c0-4bb0-ac04-dd458fd41a2b"

  func testAHostListDecodesWithItsSessions() throws {
    let json = """
      {"hosts":[{"hostId":"\(host)","hostGeneration":"\(generation)","label":"Axo Mac",
      "hostKind":"macos","capabilities":[{"id":"agent.pi","version":1}],"status":"offline",
      "stale":true,"lastSeenAt":"2026-10-16T00:00:00Z","sessions":[{"hostId":"\(host)",
      "sessionId":9,"workspaceId":"7f1918d3-8b6d-4af4-a57e-7e6ae28e89e2","workspaceName":"Axo",
      "name":"Ship it","emoji":"🦀","status":"working","hasAgent":true,"shells":[{"shellId":12}],
      "layout":{"kind":"pane","shellId":12},"updatedAt":"2026-10-15T23:59:00Z"}]}]}
      """
    let list = try JSONDecoder().decode(RemoteHostList.self, from: Data(json.utf8))
    let remote = try XCTUnwrap(list.hosts.first)
    XCTAssertEqual(remote.label, "Axo Mac")
    XCTAssertEqual(remote.status, .offline)
    XCTAssertEqual(remote.reference.hostId.uuidString.lowercased(), host)
    let session = try XCTUnwrap(remote.sessions.first)
    XCTAssertEqual(session.sessionId, 9)
    XCTAssertEqual(session.status, .working)
    XCTAssertEqual(session.shells.map(\.shellId), [12])
    XCTAssertEqual(session.layout, .pane(shellID: 12))
    XCTAssertEqual(session.displayName, "Ship it")
  }

  func testPresenceAndTerminalOutputEventsDecode() throws {
    let presence = """
      {"subscriptionId":"\(UUID().uuidString)","event":{"type":"host.presence","hostId":"\(host)",
      "hostGeneration":"\(generation)","status":"online","observedAt":"2026-10-16T00:00:00Z"}}
      """
    let decoded = try JSONDecoder().decode(RemoteHostNotification.self, from: Data(presence.utf8))
    guard case .presence(let ref, .online) = decoded.event else { return XCTFail("\(decoded)") }
    XCTAssertEqual(ref.hostId.uuidString.lowercased(), host)

    let output = """
      {"subscriptionId":"\(UUID().uuidString)","event":{"type":"host.data","hostId":"\(host)",
      "hostGeneration":"\(generation)","event":{"type":"terminal.output","sessionId":3,
      "shellId":4,"sequence":7,"data":"aGkK"}}}
      """
    let event = try JSONDecoder().decode(RemoteHostNotification.self, from: Data(output.utf8)).event
    guard case .terminalOutput(_, 3, 4, 7, let data) = event else { return XCTFail("\(event)") }
    XCTAssertEqual(String(decoding: data, as: UTF8.self), "hi\n")
  }

  func testPiEventsCarryTheirPayloadAndStoredPagesDecode() throws {
    let stream = UUID().uuidString
    let live = """
      {"subscriptionId":"\(UUID().uuidString)","event":{"type":"host.data","hostId":"\(host)",
      "hostGeneration":"\(generation)","event":{"type":"pi.event","sessionId":2,"piSessionId":"pi-1",
      "streamId":"\(stream)","sequence":5,"name":"message.end",
      "data":{"message":{"role":"user","content":[{"type":"text","text":"hi"}]}}}}}
      """
    let event = try JSONDecoder().decode(RemoteHostNotification.self, from: Data(live.utf8)).event
    guard case .piEvent(_, 2, let record) = event else { return XCTFail("\(event)") }
    XCTAssertEqual(record.name, "message.end")
    XCTAssertEqual(record.sequence, 5)
    XCTAssertEqual(record.data["message"]?["role"]?.stringValue, "user")
    XCTAssertEqual(record.data["message"]?["content"]?.arrayValue?.first?["text"]?.stringValue, "hi")

    let page = """
      {"events":[{"id":7,"hostGeneration":"\(generation)","piSessionId":"pi-1","streamId":"\(stream)",
      "sequence":5,"name":"agent.start","data":null,"receivedAt":1700000000000}],"next":8}
      """
    let decoded = try JSONDecoder().decode(PiEventPage.self, from: Data(page.utf8))
    XCTAssertEqual(decoded.next, 8)
    XCTAssertEqual(decoded.events.first?.record.data, .null)
  }

  func testASnapshotForAnotherHostIsRejected() {
    let json = """
      {"subscriptionId":"\(UUID().uuidString)","event":{"type":"host.data","hostId":"\(host)",
      "hostGeneration":"\(generation)","event":{"type":"session.snapshot","snapshot":
      {"hostId":"\(UUID().uuidString)","sessionId":1,"shells":[],"layout":null,
      "updatedAt":"2026-10-16T00:00:00Z"}}}}
      """
    XCTAssertThrowsError(try JSONDecoder().decode(RemoteHostNotification.self, from: Data(json.utf8)))
  }

  func testUnknownEventsAndNonBase64OutputAreRejectedNotGuessed() {
    for event in [
      #"{"type":"host.data","hostId":"\#(host)","hostGeneration":"\#(generation)","event":{"type":"surprise"}}"#,
      #"{"type":"host.nope","hostId":"\#(host)","hostGeneration":"\#(generation)"}"#,
      #"{"type":"host.data","hostId":"\#(host)","hostGeneration":"\#(generation)","event":{"type":"terminal.output","sessionId":1,"shellId":1,"sequence":0,"data":"***"}}"#,
    ] {
      let json = #"{"subscriptionId":"\#(UUID().uuidString)","event":\#(event)}"#
      XCTAssertThrowsError(
        try JSONDecoder().decode(RemoteHostNotification.self, from: Data(json.utf8)), event)
    }
  }
}
