import XCTest
@testable import AxoCore

final class PromptSubmissionTests: XCTestCase {
    private func snapshot(commandID: String? = nil, view: String = "view") throws -> RelayEvent {
        var record: [String: Any] = ["id": "persisted-entry", "role": "user", "text": "Steer this run"]
        if let commandID { record["commandId"] = commandID; record["timestamp"] = 1234; record["delivery"] = "steering" }
        return try RelayEvent.decode(JSONSerialization.data(withJSONObject: ["type": "snapshot", "sessionId": "session", "viewId": view,
            "state": "running", "messages": commandID == nil ? [] : [record], "hasEarlierMessages": false, "question": NSNull()]))
    }

    @MainActor
    func testSteeringIsVisibleBeforeRecordingAndReconcilesByIdentityNotText() throws {
        let client = ConversationClient()
        client.apply(try snapshot())
        XCTAssertTrue(client.recordPromptSubmission(.prompt(id: "command", session: "session", text: "Steer this run")))
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
        let client = ConversationClient()
        client.apply(try snapshot())
        XCTAssertTrue(client.recordPromptSubmission(.prompt(id: "command", session: "session", text: "Steer this run")))
        client.apply(try snapshot(commandID: "command"))
        client.apply(.acknowledged("command", cancelled: false, delivery: .steering))
        XCTAssertTrue(client.pendingPrompts.isEmpty)
        XCTAssertEqual(client.messages.count, 1)
    }

    @MainActor
    func testUncertainSubmissionIsNotReplayedOrShownOnAnotherBranch() throws {
        let client = ConversationClient()
        client.apply(try snapshot())
        XCTAssertTrue(client.recordPromptSubmission(.prompt(id: "command", session: "session", text: "Steer this run")))
        client.disconnect()
        client.apply(try snapshot())
        XCTAssertEqual(client.pendingPrompts.first?.delivery, .uncertain)
        XCTAssertNil(client.pendingID)
        client.apply(try snapshot(view: "other-view"))
        XCTAssertTrue(client.pendingPrompts.isEmpty)
    }
}
