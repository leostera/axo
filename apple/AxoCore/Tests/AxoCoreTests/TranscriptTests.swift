import XCTest
@testable import AxoCore

final class TranscriptTests: XCTestCase {
    private func snapshot(_ messages: [[String: Any]], session: String = "session") throws -> RelayEvent {
        let data = try JSONSerialization.data(withJSONObject: ["type": "snapshot", "sessionId": session,
            "state": "idle", "messages": messages, "hasEarlierMessages": false, "question": NSNull()])
        return try RelayEvent.decode(data)
    }

    @MainActor
    func testToolUpdatesReplaceRowsAndOlderRowsSurviveWindowMovement() throws {
        let client = ConversationClient()
        defer { client.disconnect() }
        let older: [String: Any] = ["id": "old", "role": "user", "text": "Earlier message"]
        let running: [String: Any] = ["id": "call", "role": "tool", "text": "ls", "toolName": "bash", "toolCallId": "call", "status": "running"]
        let done: [String: Any] = ["id": "call", "role": "tool", "text": "ls", "toolName": "bash", "toolCallId": "call", "status": "completed", "output": "README.md"]
        client.apply(try snapshot([older, running]))
        client.apply(try snapshot([done]))
        XCTAssertEqual(client.messages.map(\.id), ["old", "call"])
        XCTAssertEqual(client.messages.last?.status, .completed)
        client.apply(try snapshot([done]))
        XCTAssertEqual(client.messages.count, 2)
        client.apply(try snapshot([done], session: "other-session"))
        XCTAssertEqual(client.messages.map(\.id), ["call"])
    }

    func testToolPresentationAndReadOnlyWireCommands() throws {
        let event = try snapshot([["id": "call", "role": "tool", "text": "npm test", "toolName": "bash",
            "toolPresentation": ["kind": "shell", "title": "Bash", "subtitle": "Timeout: 30s"]]])
        guard case .snapshot(let value) = event else { return XCTFail("Expected snapshot") }
        XCTAssertEqual(value.messages.first?.toolPresentation?.kind, .shell)
        let output = PhoneCommand.toolOutput(id: "expand", session: "s", toolCallId: "call", offset: 12000)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(output)) as? [String: Any])
        XCTAssertEqual(wire["type"] as? String, "tool_output")
        XCTAssertEqual(wire["offset"] as? Int, 12000)
        XCTAssertNil(wire["text"])
        let history = PhoneCommand.history(id: "earlier", session: "s", beforeId: "oldest")
        XCTAssertEqual(history.beforeId, "oldest")
    }

    func testHistoryAndFullOutputPagesDecode() throws {
        let history = #"{"type":"history","id":"h","sessionId":"s","beforeId":"m","hasEarlierMessages":true,"messages":[{"id":"call","role":"tool","text":"ls","status":"completed"}]}"#
        guard case .history(let page) = try RelayEvent.decode(Data(history.utf8)) else { return XCTFail("Expected history") }
        XCTAssertEqual(page.messages.first?.status, .completed)
        XCTAssertTrue(page.hasEarlierMessages)
        let output = #"{"type":"tool_output","id":"o","sessionId":"s","toolCallId":"call","offset":0,"nextOffset":12000,"text":"Full output"}"#
        guard case .toolOutput(let chunk) = try RelayEvent.decode(Data(output.utf8)) else { return XCTFail("Expected output") }
        XCTAssertEqual(chunk.nextOffset, 12000)
        XCTAssertEqual(chunk.text, "Full output")
    }

    @MainActor
    func testUnsolicitedOutputDoesNotLeakAcrossSessions() throws {
        let client = ConversationClient()
        defer { client.disconnect() }
        client.apply(try snapshot([]))
        let output = #"{"type":"tool_output","id":"unknown","sessionId":"other","toolCallId":"call","offset":0,"nextOffset":null,"text":"Wrong session"}"#
        client.apply(try RelayEvent.decode(Data(output.utf8)))
        XCTAssertTrue(client.toolOutputs.isEmpty)
    }
}
