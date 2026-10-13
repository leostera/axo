import Foundation
import XCTest
@testable import AxoProtocol

final class CentralPiObservationTests: XCTestCase {
    private func id(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012x", n) }
    private var source: CentralSource { get throws {
        try CentralSource(machine: MachineTarget(machineId: UUID(uuidString: id(1))!, hostGeneration: UUID(uuidString: id(2))!), storeGeneration: UUID(uuidString: id(3))!)
    } }
    private func request() throws -> CentralRequest {
        try .observePi(source: source, workspaceId: nil, sessionId: UUID(uuidString: id(4))!)
    }
    private func json(_ value: Any) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func envelope(_ value: [String: Any]) throws -> JSONValue {
        try json(["hostGeneration": id(2), "storeGeneration": id(3), "revision": 1, "value": value])
    }
    private func target(host: Int = 2) -> [String: Any] {
        ["machineId": id(1), "hostGeneration": id(2), "storeGeneration": id(3), "workspaceId": NSNull(), "sessionId": id(4), "paneId": id(5), "chatId": id(6), "runtime": ["host_generation": id(host), "runtime_generation": id(7), "target": ["session_id": id(4), "pane_id": id(5)]]]
    }
    private func state() -> [String: Any] {
        ["title": "Observed title", "leafId": NSNull(), "busy": false, "interactionId": NSNull(), "uiWaits": 0, "question": NSNull(), "pending": false, "recovery": false]
    }
    func testReadRequestIsScopedAndCannotCarryMutationIdentity() throws {
        let request = try request()
        XCTAssertEqual(request.method, "axo.state.chat.observe")
        XCTAssertNil(request.commandId)
        XCTAssertTrue(CentralRequest.readMethods.contains(request.method))
        let parsed = try request.parseResult(envelope(["kind": "notAdmitted"]))
        XCTAssertEqual(parsed.payload, .piObservation(.notAdmitted))
        XCTAssertThrowsError(try request.parseResult(envelope(["kind": "notAdmitted", "target": target()])))
    }
    func testLiveBindingIsExactAndPrivateFieldsAreRejected() throws {
        let request = try request()
        let parsed = try request.parseResult(envelope(["kind": "live", "target": target(), "state": state()]))
        guard case .piObservation(.live(let target, let state)) = parsed.payload else { return XCTFail("Expected admitted observation") }
        XCTAssertEqual(target.source, try source)
        XCTAssertEqual(target.runtime.target.sessionId, target.sessionId)
        XCTAssertEqual(target.runtime.target.paneId, target.paneId)
        XCTAssertFalse(state.busy)
        for key in ["machineId", "storeGeneration", "sessionId", "paneId"] {
            var wrong = self.target(); wrong[key] = id(20)
            XCTAssertThrowsError(try request.parseResult(envelope(["kind": "live", "target": wrong, "state": self.state()])))
        }
        var privateState = self.state(); privateState["file"] = "/private/chat.jsonl"
        XCTAssertThrowsError(try request.parseResult(envelope(["kind": "live", "target": self.target(), "state": privateState])))
        var leaf = self.state(); leaf["leafId"] = String(repeating: "é", count: 65)
        XCTAssertThrowsError(try request.parseResult(envelope(["kind": "live", "target": self.target(), "state": leaf])))
    }
    func testStoppedCarriesNoIdleStateAndHistoricalRuntimeCannotBeLive() throws {
        let request = try request()
        let parsed = try request.parseResult(envelope(["kind": "stopped", "target": target(host: 8)]))
        guard case .piObservation(.stopped) = parsed.payload else { return XCTFail("Expected completion observation") }
        XCTAssertThrowsError(try request.parseResult(envelope(["kind": "live", "target": target(host: 8), "state": state()])))
        XCTAssertThrowsError(try request.parseResult(envelope(["kind": "stopped", "target": target(), "state": state()])))
    }
    func testSnapshotRequestAndResultKeepTheOriginalRuntimeAndChat() throws {
        let discovered = try request().parseResult(envelope(["kind": "live", "target": target(), "state": state()]))
        guard case .piObservation(.live(let captured, _)) = discovered.payload else { return XCTFail("Binding discovery") }
        let read = try CentralRequest.piSnapshot(target: captured)
        XCTAssertEqual(read.method, "axo.state.chat.get")
        XCTAssertNil(read.commandId)
        let parsed = try read.parseResult(envelope(["kind": "live", "target": target(), "state": state()]))
        guard case .piSnapshot(let actual, _) = parsed.payload else { return XCTFail("Exact snapshot") }
        XCTAssertEqual(actual, captured)
        var foreign = target(); foreign["chatId"] = id(20)
        XCTAssertThrowsError(try read.parseResult(envelope(["kind": "live", "target": foreign, "state": state()])))
        var replacement = target(); replacement["runtime"] = ["host_generation": id(2), "runtime_generation": id(21), "target": ["session_id": id(4), "pane_id": id(5)]]
        XCTAssertThrowsError(try read.parseResult(envelope(["kind": "live", "target": replacement, "state": state()])))
        XCTAssertThrowsError(try read.parseResult(envelope(["kind": "stopped", "target": target()])))
        XCTAssertThrowsError(try read.parseResult(envelope(["kind": "notAdmitted"])))
    }
    func testStoppedHistoryBindsContinuationToTargetCollectionAndHead() throws {
        let observed = try request().parseResult(envelope(["kind": "stopped", "target": target(host: 8)]))
        guard case .piObservation(.stopped(let captured)) = observed.payload else { return XCTFail("Stopped binding") }
        XCTAssertThrowsError(try CentralRequest.piHistory(target: captured, readMode: .live))
        let read = try CentralRequest.piHistory(target: captured, readMode: .stopped, limit: 1)
        let entry: [String: Any] = ["entryId": "first", "parentId": NSNull(), "timestamp": "now", "kind": "message", "role": "user", "text": "owned turn", "truncated": false, "toolCallId": NSNull(), "toolName": NSNull(), "toolCalls": []]
        let digest = String(repeating: "a", count: 64)
        let cursor: [String: Any] = ["target": target(host: 8), "readMode": "stopped", "collection": "branch", "headDigest": digest, "after": "first"]
        var page: [String: Any] = ["target": target(host: 8), "readMode": "stopped", "collection": "branch", "headDigest": digest, "leafId": "last", "entries": [entry], "cursor": cursor]
        let parsed = try read.parseResult(envelope(page))
        guard case .piHistory(let history) = parsed.payload, let next = history.cursor else { return XCTFail("Continuation") }
        XCTAssertEqual(history.target, captured)
        XCTAssertNil(read.commandId)
        let continued = try CentralRequest.piHistory(target: captured, readMode: .stopped, cursor: next, limit: 1)
        XCTAssertThrowsError(try CentralRequest.piHistory(target: captured, readMode: .stopped, collection: .entries, cursor: next))
        page["headDigest"] = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try continued.parseResult(envelope(page)))
        page["headDigest"] = digest; page["readMode"] = "live"
        XCTAssertThrowsError(try read.parseResult(envelope(page)))
        page["readMode"] = "stopped"; page["entries"] = [entry, entry]
        XCTAssertThrowsError(try read.parseResult(envelope(page)))
        page["entries"] = []; page["cursor"] = cursor
        XCTAssertThrowsError(try read.parseResult(envelope(page)))
    }
    func testLiveHistoryIsExactAndContinuationCannotCrossReadMode() throws {
        let observed = try request().parseResult(envelope(["kind": "live", "target": target(), "state": state()]))
        guard case .piObservation(.live(let captured, _)) = observed.payload else { return XCTFail("Live binding") }
        let read = try CentralRequest.piHistory(target: captured, readMode: .live, limit: 1)
        let entry: [String: Any] = ["entryId": "first", "parentId": NSNull(), "timestamp": "now", "kind": "message", "role": "user", "text": "owned turn", "truncated": false, "toolCallId": NSNull(), "toolName": NSNull(), "toolCalls": []]
        let digest = String(repeating: "a", count: 64)
        let continuation: [String: Any] = ["target": target(), "readMode": "live", "collection": "branch", "headDigest": digest, "after": "first"]
        var page: [String: Any] = ["target": target(), "readMode": "live", "collection": "branch", "headDigest": digest, "leafId": "last", "entries": [entry], "cursor": continuation]
        let parsed = try read.parseResult(envelope(page))
        guard case .piHistory(let history) = parsed.payload, let cursor = history.cursor else { return XCTFail("Live page") }
        XCTAssertEqual(history.readMode, .live)
        XCTAssertEqual(cursor.readMode, .live)
        XCTAssertNil(read.commandId)
        XCTAssertThrowsError(try CentralRequest.piHistory(target: captured, readMode: .stopped, cursor: cursor))
        var foreign = target(); foreign["chatId"] = id(20); page["target"] = foreign
        XCTAssertThrowsError(try read.parseResult(envelope(page)))
        page["target"] = target(); page["readMode"] = "stopped"
        XCTAssertThrowsError(try read.parseResult(envelope(page)))
    }
    func testToolChunksRequireExactCallHeadAndUtf8Progress() throws {
        let observed = try request().parseResult(envelope(["kind": "live", "target": target(), "state": state()]))
        guard case .piObservation(.live(let captured, _)) = observed.payload else { return XCTFail("Binding") }
        let read = try CentralRequest.piTool(target: captured, readMode: .live, entryId: "result", toolCallId: "call")
        let digest = String(repeating: "a", count: 64)
        let next: [String: Any] = ["target": target(), "readMode": "live", "entryId": "result", "toolCallId": "call", "headDigest": digest, "offset": 5]
        var body: [String: Any] = ["target": target(), "readMode": "live", "entryId": "result", "toolCallId": "call", "headDigest": digest, "offset": 0, "text": "λ界", "totalBytes": 10, "cursor": next]
        let parsed = try read.parseResult(envelope(body))
        guard case .piTool(let chunk) = parsed.payload, let cursor = chunk.cursor else { return XCTFail("Chunk") }
        XCTAssertEqual(cursor.offset, 5)
        XCTAssertNil(read.commandId)
        let continued = try CentralRequest.piTool(target: captured, readMode: .live, entryId: "result", toolCallId: "call", cursor: cursor)
        body["offset"] = 5; body["cursor"] = NSNull()
        _ = try continued.parseResult(envelope(body))
        body["headDigest"] = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try continued.parseResult(envelope(body)))
        XCTAssertThrowsError(try CentralRequest.piTool(target: captured, readMode: .stopped, entryId: "result", toolCallId: "call", cursor: cursor))
        XCTAssertThrowsError(try CentralRequest.piTool(target: captured, readMode: .live, entryId: "result", toolCallId: "other", cursor: cursor))
        XCTAssertThrowsError(try CentralRequest.piTool(target: captured, readMode: .live, entryId: "result", toolCallId: "call", limit: 3))
        body["offset"] = 0; body["headDigest"] = digest; body["cursor"] = next; body["text"] = ""
        XCTAssertThrowsError(try read.parseResult(envelope(body)))
    }
    func testQuestionBoundsAndInteractionCannotDrift() throws {
        let request = try request()
        let options: [[String: Any]] = [["id": id(10), "label": "First"], ["id": id(11), "label": "Second"]]
        var question: [String: Any] = ["id": id(9), "interactionId": id(12), "title": String(repeating: "😀", count: 1000), "options": options]
        var waiting = state(); waiting["interactionId"] = id(12); waiting["uiWaits"] = 1; waiting["question"] = question
        _ = try request.parseResult(envelope(["kind": "live", "target": target(), "state": waiting]))
        for key in ["interactionId", "uiWaits"] {
            var invalid = waiting; invalid[key] = key == "uiWaits" ? 0 : NSNull()
            XCTAssertThrowsError(try request.parseResult(envelope(["kind": "live", "target": target(), "state": invalid])))
        }
        question["options"] = [options[0], options[0]]; waiting["question"] = question
        XCTAssertThrowsError(try request.parseResult(envelope(["kind": "live", "target": target(), "state": waiting])))
        question["options"] = options; question["title"] = String(repeating: "😀", count: 1001); waiting["question"] = question
        XCTAssertThrowsError(try request.parseResult(envelope(["kind": "live", "target": target(), "state": waiting])))
    }
}
