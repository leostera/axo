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

    func testCatalogPageMatchesWireFormatAndPreservesTypedIDs() throws {
        let json = #"{"type":"catalog_page","requestId":"page-1","revision":7,"items":[{"kind":"workspace","workspace":{"id":"11111111-1111-4111-8111-111111111111","name":"Axo","kind":"project"}},{"kind":"session","session":{"id":"22222222-2222-4222-8222-222222222222","workspaceId":"11111111-1111-4111-8111-111111111111","name":"iOS work","conversationId":"pi-conversation-1","availability":"running"}}],"nextCursor":null,"hostOnline":true}"#
        guard case .catalogPage(let page) = try RelayEvent.decode(Data(json.utf8)) else { return XCTFail("Expected a catalog page") }
        XCTAssertEqual(page.requestId, "page-1")
        XCTAssertEqual(page.revision, 7)
        XCTAssertTrue(page.hostOnline)
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(page.items.count, 2)
        guard case .workspace(let workspace) = page.items[0],
              case .session(let session) = page.items[1] else { return XCTFail("Expected workspace then session records") }
        XCTAssertEqual(workspace.id.rawValue.uuidString.lowercased(), "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(workspace.name, "Axo")
        XCTAssertEqual(workspace.kind, .project)
        XCTAssertEqual(session.id.rawValue.uuidString.lowercased(), "22222222-2222-4222-8222-222222222222")
        XCTAssertEqual(session.workspaceId, workspace.id)
        XCTAssertEqual(session.conversationId, "pi-conversation-1")
        XCTAssertEqual(session.availability, .running)
    }

    func testCatalogPageRejectsInvalidBoundsAndDuplicateIDs() {
        let negativeRevision = #"{"type":"catalog_page","revision":-1,"items":[],"nextCursor":null,"hostOnline":false}"#
        XCTAssertThrowsError(try RelayEvent.decode(Data(negativeRevision.utf8)))

        let duplicateWorkspace = #"{"type":"catalog_page","revision":1,"items":[{"kind":"workspace","workspace":{"id":"11111111-1111-4111-8111-111111111111","name":"A","kind":"project"}},{"kind":"workspace","workspace":{"id":"11111111-1111-4111-8111-111111111111","name":"B","kind":"project"}}],"nextCursor":null,"hostOnline":true}"#
        XCTAssertThrowsError(try RelayEvent.decode(Data(duplicateWorkspace.utf8)))

        let invalidName = #"{"type":"catalog_page","revision":1,"items":[{"kind":"workspace","workspace":{"id":"11111111-1111-4111-8111-111111111111","name":"bad\u0001name","kind":"project"}}],"nextCursor":null,"hostOnline":true}"#
        XCTAssertThrowsError(try RelayEvent.decode(Data(invalidName.utf8)))
    }

    func testCatalogControlCommandsMatchWireFormat() throws {
        let page = PhoneCommand.catalogPage(id: "page-1", revision: nil, cursor: nil)
        let pageValue = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
        XCTAssertEqual(pageValue["type"] as? String, "catalog_page")
        XCTAssertEqual(pageValue["id"] as? String, "page-1")
        XCTAssertTrue(pageValue["revision"] is NSNull)
        XCTAssertTrue(pageValue["cursor"] is NSNull)

        let sessionID = AxoSessionID(UUID(uuidString: "22222222-2222-4222-8222-222222222222")!)
        let selected = PhoneCommand.subscribe(id: "select-1", sessionID: sessionID)
        let selectedValue = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(selected)) as? [String: String])
        XCTAssertEqual(selectedValue, ["type": "subscribe", "id": "select-1", "sessionId": sessionID.rawValue.uuidString])
        let clear = PhoneCommand.subscribe(id: "clear-1", sessionID: nil)
        let clearValue = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(clear)) as? [String: Any])
        XCTAssertTrue(clearValue["sessionId"] is NSNull)

        let create = PhoneCommand.createWorkspace(id: "create-1", name: "Axo")
        let createValue = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(create)) as? [String: String])
        XCTAssertEqual(createValue, ["type": "create_workspace", "id": "create-1", "name": "Axo"])

        let workspaceID = WorkspaceID(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        let rename = PhoneCommand.renameWorkspace(id: "rename-1", workspaceID: workspaceID, name: "Axo 2", expectedRevision: 8)
        let renameValue = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rename)) as? [String: Any])
        XCTAssertEqual(renameValue["type"] as? String, "rename_workspace")
        XCTAssertEqual(renameValue["workspaceId"] as? String, workspaceID.rawValue.uuidString)
        XCTAssertEqual(renameValue["expectedRevision"] as? Int, 8)
    }

    func testSubscriptionAndCreationAcknowledgementsMatchWireFormat() throws {
        let subscription = #"{"type":"subscription","id":"select-1","sessionId":"22222222-2222-4222-8222-222222222222","hostOnline":true}"#
        guard case .subscription(let value) = try RelayEvent.decode(Data(subscription.utf8)) else { return XCTFail("Expected subscription acknowledgement") }
        XCTAssertEqual(value.id, "select-1")
        XCTAssertEqual(value.sessionID?.rawValue.uuidString.lowercased(), "22222222-2222-4222-8222-222222222222")
        XCTAssertTrue(value.hostOnline)

        let created = #"{"type":"ack","id":"create-1","sessionId":"22222222-2222-4222-8222-222222222222","disposition":"created"}"#
        guard case .creationAcknowledged(let acknowledgement) = try RelayEvent.decode(Data(created.utf8)) else { return XCTFail("Expected creation acknowledgement") }
        XCTAssertEqual(acknowledgement.id, "create-1")
        XCTAssertEqual(acknowledgement.sessionID?.rawValue.uuidString.lowercased(), "22222222-2222-4222-8222-222222222222")
    }

    func testSnapshotMatchesWireFormat() throws {
        let json = #"{"type":"snapshot","sessionId":"22222222-2222-4222-8222-222222222222","conversationId":"pi-conversation-1","viewId":"v","state":"running","hasEarlierMessages":false,"messages":[{"id":"m1","role":"assistant","text":"Working"}],"activities":[{"id":"tool-1","toolName":"bash","summary":"ls","status":"running","output":"README.md"}],"events":[{"id":"event-1","sequence":1,"timestamp":1000,"category":"tool","name":"tool_execution_start","summary":"bash started","detail":"ls"}],"droppedEvents":0,"liveText":"Partial answer","runId":"run-1","question":null}"#
        guard case .snapshot(let snapshot) = try RelayEvent.decode(Data(json.utf8)) else { return XCTFail("Expected snapshot") }
        XCTAssertEqual(snapshot.sessionID.rawValue.uuidString.lowercased(), "22222222-2222-4222-8222-222222222222")
        XCTAssertEqual(snapshot.conversationID, "pi-conversation-1")
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
        let json = #"{"type":"snapshot","sessionId":"22222222-2222-4222-8222-222222222222","conversationId":"pi-conversation-1","viewId":"v","state":"idle","hasEarlierMessages":false,"messages":[{"id":"think","role":"thinking","text":"Thinking block · content not shared"},{"id":"tool-ok","role":"tool","toolName":"bash","toolCallId":"call-ok","text":"ls","status":"completed","output":"README.md"},{"id":"tool-error","role":"tool","toolName":"read","toolCallId":"call-error","text":"missing.txt","status":"failed","output":"File not found"}],"question":null}"#
        guard case .snapshot(let snapshot) = try RelayEvent.decode(Data(json.utf8)) else { return XCTFail("Expected snapshot") }
        XCTAssertEqual(snapshot.messages.map(\.role), ["thinking", "tool", "tool"])
        XCTAssertEqual(snapshot.messages[1].status, .completed)
        XCTAssertEqual(snapshot.messages[1].toolCallId, "call-ok")
        XCTAssertEqual(snapshot.messages[2].status, .failed)
        XCTAssertEqual(snapshot.messages[2].output, "File not found")
    }

    func testSnapshotsRemainCompatibleWithoutActivities() throws {
        let json = #"{"type":"snapshot","sessionId":"22222222-2222-4222-8222-222222222222","conversationId":"pi-conversation-1","viewId":"v","state":"idle","hasEarlierMessages":false,"messages":[],"question":null}"#
        guard case .snapshot(let snapshot) = try RelayEvent.decode(Data(json.utf8)) else { return XCTFail("Expected snapshot") }
        XCTAssertNil(snapshot.activities)
        XCTAssertNil(snapshot.events)
        XCTAssertNil(snapshot.droppedEvents)
    }

    func testMissingHistoryFieldIsAProtocolMismatchNotANetworkError() {
        let json = #"{"type":"snapshot","sessionId":"22222222-2222-4222-8222-222222222222","conversationId":"pi-conversation-1","viewId":"v","state":"idle","messages":[],"question":null}"#
        do {
            _ = try RelayEvent.decode(Data(json.utf8))
            XCTFail("Expected the new protocol to reject a stripped history field")
        } catch DecodingError.keyNotFound(let key, _) {
            XCTAssertEqual(key.stringValue, "hasEarlierMessages")
        } catch {
            XCTFail("Expected a decoding error, got \(error)")
        }
    }

    func testMalformedAndOversizedFramesFail() {
        XCTAssertThrowsError(try RelayEvent.decode(Data(#"{"type":"presence"}"#.utf8)))
        XCTAssertThrowsError(try RelayEvent.decode(Data(#"{"type":"ack","id":"x","disposition":"executed"}"#.utf8)))
        XCTAssertThrowsError(try RelayEvent.decode(Data(repeating: 32, count: 256 * 1024 + 1)))
    }

    func testCancelCommandTargetsOneRun() throws {
        let sessionID = AxoSessionID(UUID(uuidString: "22222222-2222-4222-8222-222222222222")!)
        let command = PhoneCommand.cancel(id: "cancel-1", sessionID: sessionID, runId: "run-1")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: String])
        XCTAssertEqual(value, ["type": "cancel", "id": "cancel-1", "sessionId": sessionID.rawValue.uuidString, "runId": "run-1"])
        guard case .acknowledged("cancel-1", cancelled: true, delivery: nil) = try RelayEvent.decode(Data(#"{"type":"ack","id":"cancel-1","disposition":"cancelled"}"#.utf8)) else {
            return XCTFail("Expected cancellation acknowledgement")
        }
    }

    func testPromptsHaveExplicitSessionAndIdentity() throws {
        let sessionID = AxoSessionID(UUID(uuidString: "22222222-2222-4222-8222-222222222222")!)
        let command = PhoneCommand.prompt(id: "c1", sessionID: sessionID, text: "Hello")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: String])
        XCTAssertEqual(value, ["type": "prompt", "id": "c1", "sessionId": sessionID.rawValue.uuidString, "text": "Hello"])
    }
}
