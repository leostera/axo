import XCTest
@testable import AxoCore

final class PromptSubmissionTests: XCTestCase {
    private let sessionID = "22222222-2222-4222-8222-222222222222"
    private let conversationID = "pi-conversation-1"

    private func snapshot(commandID: String? = nil, view: String = "view") throws -> RelayEvent {
        var record: [String: Any] = ["id": "persisted-entry", "role": "user", "text": "Steer this run"]
        if let commandID { record["commandId"] = commandID; record["timestamp"] = 1234; record["delivery"] = "steering" }
        return try RelayEvent.decode(JSONSerialization.data(withJSONObject: ["type": "snapshot", "sessionId": sessionID,
            "conversationId": conversationID, "viewId": view, "state": "running",
            "messages": commandID == nil ? [] : [record], "hasEarlierMessages": false, "question": NSNull()]))
    }

    @MainActor
    private func selectedClient() -> ConversationClient {
        let client = ConversationClient()
        client.selectSession(AxoSessionID(UUID(uuidString: sessionID)!), conversationID: conversationID)
        return client
    }

    @MainActor
    private func prompt(_ id: String) -> PhoneCommand {
        PhoneCommand.prompt(id: id, sessionID: AxoSessionID(UUID(uuidString: sessionID)!), text: "Steer this run")
    }

    @MainActor
    func testSteeringIsVisibleBeforeRecordingAndReconcilesByIdentityNotText() throws {
        let client = selectedClient()
        defer { client.disconnect() }
        client.apply(try snapshot())
        XCTAssertTrue(client.recordPromptSubmission(prompt("command")))
        client.apply(.acknowledged("command", cancelled: false, delivery: .steering))
        XCTAssertEqual(client.pendingPrompts.first?.delivery, .steering)
        XCTAssertNil(client.notice, "Successful submission should not create a composer banner")
        client.apply(try snapshot(commandID: "different-command"))
        XCTAssertEqual(client.pendingPrompts.count, 1, "Identical text is not message identity")
        client.apply(try snapshot(commandID: "command"))
        XCTAssertTrue(client.pendingPrompts.isEmpty)
        XCTAssertEqual(client.messages.count, 1)
        XCTAssertEqual(client.messages.first?.timestamp, 1234)
    }

    @MainActor
    func testSnapshotBeforeAckDoesNotDuplicateTheRecordedPrompt() throws {
        let client = selectedClient()
        defer { client.disconnect() }
        client.apply(try snapshot())
        XCTAssertTrue(client.recordPromptSubmission(prompt("command")))
        client.apply(try snapshot(commandID: "command"))
        client.apply(.acknowledged("command", cancelled: false, delivery: .steering))
        XCTAssertTrue(client.pendingPrompts.isEmpty)
        XCTAssertEqual(client.messages.count, 1)
    }

    @MainActor
    func testUncertainSubmissionIsNotReplayedOrShownOnAnotherBranch() throws {
        let client = selectedClient()
        defer { client.disconnect() }
        client.apply(try snapshot())
        XCTAssertTrue(client.recordPromptSubmission(prompt("command")))
        client.disconnect()
        client.apply(try snapshot())
        XCTAssertEqual(client.pendingPrompts.first?.delivery, .uncertain)
        XCTAssertNil(client.pendingID)
        client.apply(try snapshot(view: "other-view"))
        XCTAssertTrue(client.pendingPrompts.isEmpty)
    }
}
