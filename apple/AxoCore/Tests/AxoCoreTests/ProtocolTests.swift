import XCTest
@testable import AxoCore

final class ProtocolTests: XCTestCase {
    func testEndpointRejectsCredentialAndInsecureURLs() throws {
        for url in ["http://example.com", "https://user:password@example.com", "https://example.com/path", "https://example.com?token=secret"] {
            XCTAssertThrowsError(try RelayEndpoint(url))
        }
        let endpoint = try RelayEndpoint("https://api.example.com")
        XCTAssertEqual(endpoint.socketURL.absoluteString, "wss://api.example.com/connect/phone")
        XCTAssertEqual(endpoint.loginURL.absoluteString, "https://api.example.com/login")
    }

    func testDefaultRelayAndPlaceholderMigration() throws {
        XCTAssertEqual(RelayEndpoint.restoredOrigin(nil), RelayEndpoint.defaultOrigin)
        XCTAssertEqual(RelayEndpoint.restoredOrigin("https://api.axo.example.invalid"), RelayEndpoint.defaultOrigin)
        let endpoint = try RelayEndpoint(RelayEndpoint.defaultOrigin)
        XCTAssertEqual(endpoint.loginURL.absoluteString, "https://bridge.axo.leostera.dev/login")
        XCTAssertEqual(endpoint.socketURL.absoluteString, "wss://bridge.axo.leostera.dev/connect/phone")
    }

    func testEndpointMigrationPreservesUserInput() {
        for input in ["https://custom.example.com", "", "not yet a URL"] {
            XCTAssertEqual(RelayEndpoint.restoredOrigin(input), input)
        }
    }

    func testSnapshotMatchesWireFormat() throws {
        let json = #"{"type":"snapshot","sessionId":"s1","state":"running","messages":[{"id":"m1","role":"assistant","text":"Working"}],"activities":[{"id":"tool-1","toolName":"bash","summary":"ls","status":"running","output":"README.md"}],"events":[{"id":"event-1","sequence":1,"timestamp":1000,"category":"tool","name":"tool_execution_start","summary":"bash started","detail":"ls"}],"droppedEvents":0,"liveText":"Partial answer","runId":"run-1","question":null}"#
        guard case .snapshot(let snapshot) = try RelayEvent.decode(Data(json.utf8)) else { return XCTFail("Expected snapshot") }
        XCTAssertEqual(snapshot.sessionId, "s1")
        XCTAssertEqual(snapshot.state, .running)
        XCTAssertEqual(snapshot.activities?.first?.toolName, "bash")
        XCTAssertEqual(snapshot.activities?.first?.output, "README.md")
        XCTAssertEqual(snapshot.events?.first?.name, "tool_execution_start")
        XCTAssertEqual(snapshot.events?.first?.detail, "ls")
        XCTAssertEqual(snapshot.droppedEvents, 0)
        XCTAssertEqual(snapshot.liveText, "Partial answer")
        XCTAssertEqual(snapshot.runId, "run-1")
        XCTAssertEqual(snapshot.messages.count, 1)
    }

    func testTranscriptIncludesThinkingAndToolResults() throws {
        let json = #"{"type":"snapshot","sessionId":"s1","state":"idle","messages":[{"id":"think","role":"thinking","text":"Thinking block · content not shared"},{"id":"tool-ok","role":"tool","toolName":"bash","toolCallId":"call-ok","text":"ls","status":"completed","output":"README.md"},{"id":"tool-error","role":"tool","toolName":"read","toolCallId":"call-error","text":"missing.txt","status":"failed","output":"File not found"}],"question":null}"#
        guard case .snapshot(let snapshot) = try RelayEvent.decode(Data(json.utf8)) else { return XCTFail("Expected snapshot") }
        XCTAssertEqual(snapshot.messages.map(\.role), ["thinking", "tool", "tool"])
        XCTAssertEqual(snapshot.messages[1].status, .completed)
        XCTAssertEqual(snapshot.messages[1].toolCallId, "call-ok")
        XCTAssertEqual(snapshot.messages[2].status, .failed)
        XCTAssertEqual(snapshot.messages[2].output, "File not found")
    }

    func testSnapshotsRemainCompatibleWithoutActivities() throws {
        let json = #"{"type":"snapshot","sessionId":"s1","state":"idle","messages":[],"question":null}"#
        guard case .snapshot(let snapshot) = try RelayEvent.decode(Data(json.utf8)) else { return XCTFail("Expected snapshot") }
        XCTAssertNil(snapshot.activities)
        XCTAssertNil(snapshot.events)
        XCTAssertNil(snapshot.droppedEvents)
    }

    func testMalformedAndOversizedFramesFail() {
        XCTAssertThrowsError(try RelayEvent.decode(Data(#"{"type":"presence"}"#.utf8)))
        XCTAssertThrowsError(try RelayEvent.decode(Data(#"{"type":"ack","id":"x","disposition":"executed"}"#.utf8)))
        XCTAssertThrowsError(try RelayEvent.decode(Data(repeating: 32, count: 256 * 1024 + 1)))
    }

    func testCancelCommandTargetsOneRun() throws {
        let command = PhoneCommand.cancel(id: "cancel-1", session: "s1", runId: "run-1")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: String])
        XCTAssertEqual(value, ["type": "cancel", "id": "cancel-1", "sessionId": "s1", "runId": "run-1"])
        guard case .acknowledged("cancel-1", cancelled: true) = try RelayEvent.decode(Data(#"{"type":"ack","id":"cancel-1","disposition":"cancelled"}"#.utf8)) else {
            return XCTFail("Expected cancellation acknowledgement")
        }
    }

    func testPromptsHaveExplicitSessionAndIdentity() throws {
        let command = PhoneCommand.prompt(id: "c1", session: "s1", text: "Hello")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: String])
        XCTAssertEqual(value, ["type": "prompt", "id": "c1", "sessionId": "s1", "text": "Hello"])
    }
}
