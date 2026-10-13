import AxoProtocol
import Foundation
import XCTest
@testable import AxoCore

@MainActor final class CentralRenameTests: XCTestCase {
    private let machine = UUID(), host = UUID(), store = UUID(), workspace = UUID(), session = UUID()
    private var source: CentralSource {
        try! CentralSource(machine: .init(machineId: machine, hostGeneration: host), storeGeneration: store)
    }
    private var revision: CentralRevision { CentralRevision(rawValue: 8)! }

    private func json(_ value: Any) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func envelope(_ operation: [String: Any], header: CentralSource? = nil) throws -> JSONValue {
        let source = header ?? self.source
        return try json(["hostGeneration": source.machine.hostGeneration.uuidString,
                         "storeGeneration": source.storeGeneration.uuidString,
                         "revision": 9, "value": ["operation": operation, "session": NSNull(), "deletion": NSNull()]])
    }
    private func workspaceOperation(_ ticket: CentralRenameTicket, name: String) -> [String: Any] {
        ["kind": "renameWorkspace", "accepted": ["commandId": ticket.commandId.uuidString,
          "revision": 9, "graph": ["workspaceId": workspace.uuidString, "name": name,
            "directory": "/approved", "lifecycle": "open", "configRevision": 9]]]
    }
    private func sessionOperation(_ ticket: CentralRenameTicket, name: String, manualName: Bool = true) -> [String: Any] {
        ["kind": "renameSession", "accepted": ["commandId": ticket.commandId.uuidString,
          "revision": 9, "graph": ["sessionId": session.uuidString, "workspaceId": workspace.uuidString,
            "name": name, "manualName": manualName, "lifecycle": "open", "configRevision": 9]]]
    }

    func testWorkspaceRenameIsCapturedOnceAndClearedOnlyByItsExactOriginal() throws {
        let renames = CentralRenames()
        let ticket = try renames.captureWorkspace(source: source, revision: revision,
                                                  workspaceId: workspace, name: "Project")
        XCTAssertEqual(ticket.request.method, "axo.state.workspace.rename")
        XCTAssertEqual(ticket.request.commandId, ticket.commandId)
        XCTAssertThrowsError(try renames.captureWorkspace(source: source, revision: revision,
                                                          workspaceId: workspace, name: "Other"))
        let request = try renames.beginSubmission(ticket)
        XCTAssertEqual(request.commandId, ticket.commandId)
        XCTAssertThrowsError(try renames.beginSubmission(ticket))
        XCTAssertThrowsError(try ticket.request.parseResult(envelope(workspaceOperation(ticket, name: "Other"))))
        XCTAssertTrue(renames.hasPending)
        let result = try renames.acknowledgeSubmission(ticket,
            result: envelope(workspaceOperation(ticket, name: "Project")))
        guard case .renamed(.renameWorkspace(let accepted)) = result else { return XCTFail("Exact workspace receipt") }
        XCTAssertEqual(accepted.commandId, ticket.commandId)
        XCTAssertEqual(accepted.graph.workspaceId, workspace)
        XCTAssertEqual(accepted.graph.name, "Project")
        XCTAssertFalse(renames.hasPending)
    }

    func testSessionRenameRequiresExactScopeAndManualNameReceipt() throws {
        let renames = CentralRenames()
        let ticket = try renames.captureSession(source: source, revision: revision,
            workspaceId: workspace, sessionId: session, name: "Manual")
        _ = try renames.beginSubmission(ticket)
        XCTAssertThrowsError(try renames.acknowledgeSubmission(ticket,
            result: envelope(sessionOperation(ticket, name: "Manual", manualName: false))))
        XCTAssertTrue(renames.hasPending)
        XCTAssertThrowsError(try renames.acknowledgeSubmission(ticket,
            result: envelope(sessionOperation(ticket, name: "Different"))))
        XCTAssertTrue(renames.hasPending)
        let result = try renames.acknowledgeSubmission(ticket,
            result: envelope(sessionOperation(ticket, name: "Manual")))
        guard case .renamed(.renameSession(let accepted)) = result else { return XCTFail("Exact manual-name receipt") }
        XCTAssertEqual(accepted.commandId, ticket.commandId)
        XCTAssertEqual(accepted.graph.sessionId, session)
        XCTAssertTrue(accepted.graph.manualName)
        XCTAssertFalse(renames.hasPending)
    }

    func testLostReplyReconcilesReadOnlyAndStoreChangesKeepTheRenameFenced() throws {
        let renames = CentralRenames()
        let ticket = try renames.captureSession(source: source, revision: revision,
            workspaceId: workspace, sessionId: session, name: "Manual")
        _ = try renames.beginSubmission(ticket)
        let missing = try json(["hostGeneration": host.uuidString, "storeGeneration": store.uuidString,
                                "revision": 9, "value": ["operation": NSNull(), "session": NSNull(), "deletion": NSNull()]])
        XCTAssertEqual(try renames.acknowledgeReconciliation(ticket, source: source, result: missing), .missing)
        let nextHost = try CentralSource(machine: .init(machineId: machine, hostGeneration: UUID()), storeGeneration: store)
        let lookup = try renames.reconciliation(ticket, source: nextHost)
        XCTAssertEqual(lookup.method, "axo.state.operation.get")
        XCTAssertNil(lookup.commandId)
        let changedStore = try CentralSource(machine: nextHost.machine, storeGeneration: UUID())
        XCTAssertThrowsError(try renames.reconciliation(ticket, source: changedStore))
        XCTAssertTrue(renames.hasPending)
    }
}
