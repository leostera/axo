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
