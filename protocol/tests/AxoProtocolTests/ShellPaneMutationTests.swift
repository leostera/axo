import Foundation
import XCTest
@testable import AxoProtocol

final class ShellPaneMutationTests: XCTestCase {
    private let machine = UUID(), host = UUID(), session = UUID(), pane = UUID(), command = UUID(), generation = UUID()
    private var target: WorkSessionTarget { .init(machineId: machine, hostGeneration: host, workspaceId: nil, sessionId: session) }
    private var source: MachineTarget { .init(machineId: machine, hostGeneration: host) }
    private var reference: JSONValue { .object(["host_generation": .string(host.uuidString), "runtime_generation": .string(generation.uuidString),
        "target": .object(["session_id": .string(session.uuidString), "pane_id": .string(pane.uuidString)])]) }
    private var receipt: JSONValue { .object(["commandId": .string(command.uuidString), "paneId": .string(pane.uuidString), "runtime": reference,
        "intent": .object(["operation": .string("addPane"), "profileId": .null,
            "target": .object(["machineId": .string(machine.uuidString), "hostGeneration": .string(host.uuidString), "workspaceId": .null, "sessionId": .string(session.uuidString)])]),
        "disposition": .object(["kind": .string("added")])]) }
    private var result: JSONValue { .object(["hostGeneration": .string(host.uuidString), "receipt": receipt,
        "pane": .object(["paneId": .string(pane.uuidString), "kind": .string("shell"), "profileId": .null, "state": .string("open"), "runtime": reference,
            "terminal": .object(["runtime": reference, "process": .object(["kind": .string("running"), "pid": .number(123)]), "attached": .bool(false), "backlog_bytes": .number(0)])])]) }
    func testCapturedDefaultAddAndMachineScopedReceipt() throws {
        let parameters = ShellPaneAddParameters(target: target, commandId: command)
        let parsed = try AxoProtocolResultValidator.shellPaneAdd(result, parameters: parameters)
        XCTAssertEqual(parsed.receipt.intent, .add(target: target, profileId: nil))
        XCTAssertEqual(parsed.pane.paneId, pane)
        let observed = try AxoProtocolResultValidator.commandGet(.object(["hostGeneration": .string(host.uuidString), "receipt": .object(["kind": .string("pane"), "receipt": receipt])]), target: source)
        XCTAssertEqual(observed.receipt, .pane(parsed.receipt))
    }
    func testWrongCommandSourceAndUnknownFieldsCannotAuthorizeAnAdd() {
        XCTAssertThrowsError(try AxoProtocolResultValidator.shellPaneAdd(result, parameters: .init(target: target, commandId: UUID())))
        XCTAssertThrowsError(try AxoProtocolResultValidator.shellPaneAdd(result, parameters: .init(target: target, commandId: command, profileId: "shell")))
        guard case .object(var fields) = result else { return XCTFail() }
        fields["argv"] = .array([.string("/bin/sh")])
        XCTAssertThrowsError(try AxoProtocolResultValidator.shellPaneAdd(.object(fields), parameters: .init(target: target, commandId: command)))
    }
    func testHistoricalReceiptUsesCurrentEnvelopeAndNeverBecomesLaunchPermission() throws {
        let current = MachineTarget(machineId: machine, hostGeneration: UUID())
        let value: JSONValue = .object(["hostGeneration": .string(current.hostGeneration.uuidString), "receipt": .object(["kind": .string("pane"), "receipt": receipt])])
        let result = try AxoProtocolResultValidator.commandGet(value, target: current)
        guard case .pane(let original)? = result.receipt else { return XCTFail() }
        XCTAssertEqual(original.intent, .add(target: target, profileId: nil))
        let other = MachineTarget(machineId: UUID(), hostGeneration: current.hostGeneration)
        XCTAssertThrowsError(try AxoProtocolResultValidator.commandGet(value, target: other))
    }
    func testPreparedWithoutRuntimeAndNullLookupPreserveUncertainty() throws {
        guard case .object(var fields) = receipt else { return XCTFail() }
        fields["runtime"] = .null
        fields["disposition"] = .object(["kind": .string("prepared")])
        let lookup: JSONValue = .object(["hostGeneration": .string(host.uuidString), "receipt": .object(["kind": .string("pane"), "receipt": .object(fields)])])
        guard case .pane(let original)? = try AxoProtocolResultValidator.commandGet(lookup, target: source).receipt else { return XCTFail() }
        XCTAssertEqual(original.disposition, .prepared)
        XCTAssertNil(original.runtime)
        XCTAssertNil(try AxoProtocolResultValidator.commandGet(.object(["hostGeneration": .string(host.uuidString), "receipt": .null]), target: source).receipt)
        fields["disposition"] = .object(["kind": .string("added")])
        XCTAssertThrowsError(try AxoProtocolResultValidator.commandGet(.object(["hostGeneration": .string(host.uuidString), "receipt": .object(["kind": .string("pane"), "receipt": .object(fields)])]), target: source))
    }
}
