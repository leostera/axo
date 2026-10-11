import XCTest
@testable import AxoProtocol

final class SessionDeletionTests: XCTestCase {
    private let machine = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let host = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let session = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    private let command = UUID(uuidString: "00000000-0000-4000-8000-000000000004")!
    private func parameters() -> SessionDeletionParameters {
        .init(target: MachineTarget(machineId: machine, hostGeneration: host), commandId: command,
            sessions: [.init(workspaceId: nil, sessionId: session)], expectedRevision: WorkRevision(rawValue: 7)!)
    }
    private func value<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
    private func result(revision: JSONValue = .number(8)) throws -> JSONValue {
        let p = parameters()
        return .object(["hostGeneration": .string(host.uuidString), "receipt": .object([
            "commandId": .string(command.uuidString), "intent": try value(p.intent), "runtimes": .array([]), "revision": revision])])
    }
    func testExplicitNullStandaloneScopeAndExactOriginalReceipt() throws {
        let parameters = parameters()
        XCTAssertEqual(try AxoProtocolResultValidator.sessionDeletionParameters(value(parameters)), parameters)
        let result = try AxoProtocolResultValidator.sessionDeletion(result(), parameters: parameters)
        XCTAssertEqual(result.receipt.revision?.rawValue, 8)
        let prepared = try AxoProtocolResultValidator.sessionDeletion(self.result(revision: .null), parameters: parameters)
        XCTAssertNil(prepared.receipt.revision)
        let commandResult: JSONValue = .object(["hostGeneration": .string(host.uuidString), "receipt": .object(["kind": .string("deletion"), "receipt": try value(result.receipt)])])
        guard case .deletion(let receipt) = try AxoProtocolResultValidator.commandGet(commandResult, target: parameters.target).receipt else { return XCTFail("Deletion receipt") }
        XCTAssertEqual(receipt, result.receipt)
    }
    func testRejectsMissingScopeDuplicatesWrongRevisionSourceAndExtraFields() throws {
        let p = parameters()
        guard case .object(var fields) = try value(p) else { return XCTFail() }
        fields["sessions"] = .array([.object(["sessionId": .string(session.uuidString)])])
        XCTAssertThrowsError(try AxoProtocolResultValidator.sessionDeletionParameters(.object(fields)))
        fields["sessions"] = .array([try value(p.sessions[0]), try value(p.sessions[0])])
        XCTAssertThrowsError(try AxoProtocolResultValidator.sessionDeletionParameters(.object(fields)))
        XCTAssertThrowsError(try AxoProtocolResultValidator.sessionDeletion(result(revision: .number(9)), parameters: p))
        let different = SessionDeletionParameters(target: p.target, commandId: UUID(), sessions: p.sessions, expectedRevision: p.expectedRevision)
        XCTAssertThrowsError(try AxoProtocolResultValidator.sessionDeletion(result(), parameters: different))
        guard case .object(let original) = try value(p) else { return XCTFail() }
        fields = original
        fields["argv"] = .array([.string("/bin/sh")])
        XCTAssertThrowsError(try AxoProtocolResultValidator.sessionDeletionParameters(.object(fields)))
    }
}
