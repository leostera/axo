import Foundation
import XCTest
@testable import AxoProtocol

final class CentralContractTests: XCTestCase {
    private let machine = MachineTarget(machineId: UUID(), hostGeneration: UUID())
    private let store = UUID(), sessionID = UUID(), piID = UUID(), shellID = UUID(), command = UUID()
    private var source: CentralSource { try! CentralSource(machine: machine, storeGeneration: store) }
    private var revision: CentralRevision { CentralRevision(rawValue: 1)! }
    private func json(_ value: Any) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value)) }
    private func sourceObject() -> [String: Any] { ["machineId": machine.machineId.uuidString, "hostGeneration": machine.hostGeneration.uuidString, "storeGeneration": store.uuidString] }
    private func session(workspace: Any = NSNull()) -> [String: Any] {
        ["sessionId": sessionID.uuidString, "workspaceId": workspace, "name": "New Session", "manualName": false, "lifecycle": "open", "configRevision": 1]
    }
    private func pane(_ id: UUID, ordinal: Int, role: String) -> [String: Any] {
        ["paneId": id.uuidString, "sessionId": sessionID.uuidString, "role": ["kind": role], "present": true, "ordinal": ordinal, "configRevision": 1]
    }
    private func runtime(_ paneID: UUID) -> [String: Any] {
        ["host_generation": machine.hostGeneration.uuidString, "runtime_generation": UUID().uuidString,
         "target": ["session_id": sessionID.uuidString, "pane_id": paneID.uuidString]]
    }
    private func observed(_ id: UUID, ordinal: Int, role: String) -> [String: Any] {
        let runtime = runtime(id)
        return ["desired": pane(id, ordinal: ordinal, role: role), "availability": "live", "lastRuntime": runtime,
                "terminal": ["runtime": runtime, "process": ["kind": "running", "pid": 42], "attached": false, "backlog_bytes": 0]]
    }
    private func view() -> [String: Any] {
        ["session": session(), "panes": [observed(piID, ordinal: 0, role: "pi"), observed(shellID, ordinal: 1, role: "accountShell")], "readiness": "ready"]
    }
    private func envelope(_ body: Any, revision: Int = 1) -> [String: Any] {
        ["hostGeneration": machine.hostGeneration.uuidString, "storeGeneration": store.uuidString, "revision": revision, "value": body]
    }
    func testBootstrapPinsHostStoreAndDoesNotRequireLegacyRuntimeCapability() throws {
        let request = try CentralRequest.bootstrap(machine: machine)
        let value = try json(envelope(["backendCompleteCreation": true, "schemaVersion": 3]))
        let result = try request.parseResult(value)
        XCTAssertEqual(result.source, source); XCTAssertEqual(result.payload, .bootstrap)
        let negotiation = try json(["protocolVersion": 1, "methods": Array(CentralRequest.readMethods), "deliveryCredits": ["frames": 32, "bytes": 131072]])
        XCTAssertEqual(Set(try AxoProtocolResultValidator.negotiation(negotiation).methods), CentralRequest.readMethods)
        var stale = envelope(["backendCompleteCreation": true, "schemaVersion": 3])
        stale["hostGeneration"] = UUID().uuidString
        XCTAssertThrowsError(try request.parseResult(json(stale)))
        stale = envelope(["backendCompleteCreation": true, "schemaVersion": 4])
        XCTAssertThrowsError(try request.parseResult(json(stale)))
    }
    func testRequestsCaptureExplicitScopeBoundsAndNeverEncodeNullCursor() throws {
        let request = try CentralRequest.sessions(source: source, workspaceId: nil)
        guard case .object(let fields) = request.parameters else { return XCTFail("Object params") }
        XCTAssertEqual(fields["workspaceId"], .null); XCTAssertNil(fields["cursor"])
        XCTAssertEqual(fields["target"], source.json)
        for limit in [0, 51, Int.max] { XCTAssertThrowsError(try CentralRequest.sessions(source: source, workspaceId: nil, limit: limit)) }
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        XCTAssertThrowsError(try CentralRequest.session(source: source, workspaceId: zero, sessionId: sessionID))
        XCTAssertThrowsError(try CentralRequest.createSession(source: source, workspaceId: nil, commandId: zero, expectedRevision: revision))
        for name in ["", " padded", "control\nname", String(repeating: "🦊", count: 41)] {
            XCTAssertThrowsError(try CentralRequest.createSession(source: source, workspaceId: nil, commandId: command, expectedRevision: revision, name: name))
        }
        for path in ["relative", "/nul\0path", "/" + String(repeating: "x", count: 4096)] {
            XCTAssertThrowsError(try CentralRequest.createWorkspace(source: source, commandId: command, expectedRevision: revision, name: "Workspace", directoryPath: path))
        }
        XCTAssertNil(CentralRevision(rawValue: -1)); XCTAssertNil(CentralRevision(rawValue: 9_007_199_254_740_992))
    }
    func testSessionResultRejectsForgedReadinessIdentityUnknownFieldsAndStore() throws {
        let request = try CentralRequest.session(source: source, workspaceId: nil, sessionId: sessionID)
        guard case .session(let parsed) = try request.parseResult(json(envelope(view()))).payload else { return XCTFail("Session result") }
        XCTAssertEqual(parsed.terminals.count, 2)
        for change in ["noTerminal", "duplicate", "wrongSession", "wrongOrdinal", "absent", "extra", "oldOwner", "stopping", "foreignRuntime", "fakeProcess"] {
            var body = view(), panes = body["panes"] as! [[String: Any]], changed = panes[1]
            var desired = changed["desired"] as! [String: Any]
            switch change {
            case "noTerminal": changed["terminal"] = NSNull()
            case "duplicate": changed = panes[0]
            case "wrongSession": desired["sessionId"] = UUID().uuidString; changed["desired"] = desired
            case "wrongOrdinal": desired["ordinal"] = 0; changed["desired"] = desired
            case "absent": desired["present"] = false; changed["desired"] = desired
            case "extra": changed["argv"] = ["untrusted"]
            case "oldOwner":
                var terminal = changed["terminal"] as! [String: Any], runtime = terminal["runtime"] as! [String: Any]
                runtime["host_generation"] = UUID().uuidString; terminal["runtime"] = runtime; changed["terminal"] = terminal; changed["lastRuntime"] = runtime
            case "stopping": changed["availability"] = "stopping"
            case "foreignRuntime": changed["lastRuntime"] = runtime(shellID)
            default:
                var terminal = changed["terminal"] as! [String: Any]; terminal["process"] = ["kind": "exited", "wait_status": 0]; changed["terminal"] = terminal
            }
            panes[1] = changed; body["panes"] = panes
            XCTAssertThrowsError(try request.parseResult(json(envelope(body))), change)
        }
        var stale = envelope(view()); stale["storeGeneration"] = UUID().uuidString
        XCTAssertThrowsError(try request.parseResult(json(stale))) { error in
            guard case AxoProtocolValidationError.staleStore = error else { return XCTFail("Store fence") }
        }
        var scoped = view(); scoped["session"] = session(workspace: UUID().uuidString)
        XCTAssertThrowsError(try request.parseResult(json(envelope(scoped))))
    }
    func testPageContinuationIsSourceRevisionDomainAndExactLastRecordBound() throws {
        let request = try CentralRequest.sessions(source: source, workspaceId: nil)
        let domain: [String: Any] = ["kind": "sessions", "workspaceId": NSNull()]
        let cursor: [String: Any] = ["target": sourceObject(), "revision": 1, "domain": domain, "after": sessionID.uuidString]
        let body: [String: Any] = ["records": [view()], "cursor": cursor]
        guard case .sessions(_, let next?) = try request.parseResult(json(envelope(body))).payload else { return XCTFail("Cursor") }
        let continuation = try CentralRequest.sessions(source: source, workspaceId: nil, cursor: next)
        XCTAssertThrowsError(try CentralRequest.workspaces(source: source, cursor: next))
        XCTAssertThrowsError(try CentralRequest.sessions(source: source, workspaceId: UUID(), cursor: next))
        let replaced = try CentralSource(machine: machine, storeGeneration: UUID())
        XCTAssertThrowsError(try CentralRequest.sessions(source: replaced, workspaceId: nil, cursor: next))
        XCTAssertThrowsError(try continuation.parseResult(json(envelope(["records": [], "cursor": NSNull()], revision: 2))))
        for key in ["target", "revision", "domain", "after"] {
            var bad = cursor
            switch key {
            case "target": var target = sourceObject(); target["storeGeneration"] = UUID().uuidString; bad[key] = target
            case "revision": bad[key] = 2
            case "domain": bad[key] = ["kind": "workspaces"]
            default: bad[key] = UUID().uuidString
            }
            XCTAssertThrowsError(try request.parseResult(json(envelope(["records": [view()], "cursor": bad]))), key)
        }
        XCTAssertThrowsError(try request.parseResult(json(envelope(["records": [], "cursor": cursor]))))
        XCTAssertThrowsError(try request.parseResult(json(envelope(["records": [view(), view()], "cursor": NSNull()]))))
    }
    func testOriginalCreationGraphIsIndependentOfCurrentObservation() throws {
        let request = try CentralRequest.createSession(source: source, workspaceId: nil, commandId: command, expectedRevision: CentralRevision(rawValue: 0)!)
        XCTAssertEqual(request.commandId, command)
        XCTAssertNil(try CentralRequest.operation(source: source, commandId: command).commandId)
        XCTAssertNil(try CentralRequest.bootstrap(machine: machine).commandId)
        let graph: [String: Any] = ["session": session(), "panes": [pane(piID, ordinal: 0, role: "pi"), pane(shellID, ordinal: 1, role: "accountShell")]]
        let accepted: [String: Any] = ["commandId": command.uuidString, "revision": 1, "graph": graph]
        let operation: [String: Any] = ["kind": "createStandalone", "accepted": accepted]
        var observation = view(), changed = session()
        changed["name"] = "Later name"; changed["configRevision"] = 2; observation["session"] = changed
        let response = try request.parseResult(json(envelope(["operation": operation, "session": observation], revision: 2)))
        guard case .operation(.createStandalone(let original)?, let current?) = response.payload else { return XCTFail("Original and observation") }
        XCTAssertEqual(original.graph.session.name, "New Session"); XCTAssertEqual(current.session.name, "Later name")
        for key in ["kind", "commandId", "revision"] {
            var bad = operation, value = accepted
            if key == "kind" { bad[key] = "createSession" }
            else { value[key] = key == "commandId" ? UUID().uuidString as Any : 2 as Any; bad["accepted"] = value }
            XCTAssertThrowsError(try request.parseResult(json(envelope(["operation": bad, "session": NSNull()], revision: 2))), key)
        }
        let lookup = try CentralRequest.operation(source: source, commandId: command)
        XCTAssertNoThrow(try lookup.parseResult(json(envelope(["operation": NSNull(), "session": NSNull()]))))
        XCTAssertThrowsError(try lookup.parseResult(json(envelope(["operation": NSNull(), "session": view()]))))
    }
    func testCompletionReturnsOnlyUniqueExactCapturedRuntimes() throws {
        let jsonParser = CentralJSON(method: "fixture")
        let captured = try jsonParser.runtime(json(runtime(shellID)))
        let request = try CentralRequest.completion(source: source, workspaceId: nil, sessionId: sessionID, runtimes: [captured])
        XCTAssertNil(request.commandId)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(captured))
        XCTAssertNoThrow(try request.parseResult(json(envelope(["completed": [encoded]]))))
        XCTAssertNoThrow(try request.parseResult(json(envelope(["completed": []]))))
        XCTAssertThrowsError(try request.parseResult(json(envelope(["completed": [runtime(shellID)]]))))
        XCTAssertThrowsError(try request.parseResult(json(envelope(["completed": [encoded, encoded]]))))
        XCTAssertThrowsError(try CentralRequest.completion(source: source, workspaceId: nil, sessionId: sessionID, runtimes: []))
        XCTAssertThrowsError(try CentralRequest.completion(source: source, workspaceId: nil, sessionId: sessionID, runtimes: [captured, captured]))
    }
}
