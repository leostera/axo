import Foundation
import XCTest
@testable import AxoProtocol

final class ShellPaneSessionTests: XCTestCase {
    private let machine = UUID(), host = UUID(), workspace = UUID(), session = UUID(), piPane = UUID(), shellPane = UUID()
    private var target: WorkSessionTarget {
        WorkSessionTarget(machineId: machine, hostGeneration: host, workspaceId: workspace, sessionId: session)
    }
    private func result(panes: [JSONValue]?) -> JSONValue {
        var fields: [String: JSONValue] = ["sessionId": .string(session.uuidString), "workspaceId": .string(workspace.uuidString),
            "name": .string("Native session"), "nameSource": .string("manual"),
            "pi": .object(["paneId": .string(piPane.uuidString), "chatId": .null, "admission": .string("notAdmitted")]), "runtime": .null]
        if let panes { fields["shellPanes"] = .array(panes) }
        return .object(["hostGeneration": .string(host.uuidString), "revision": .number(1), "session": .object(fields)])
    }
    private func pane(id: UUID? = nil, sessionID: UUID? = nil) -> JSONValue {
        let id = id ?? shellPane
        let runtime: JSONValue = .object(["host_generation": .string(host.uuidString),
            "runtime_generation": .string(UUID().uuidString),
            "target": .object(["session_id": .string((sessionID ?? session).uuidString), "pane_id": .string(id.uuidString)])])
        return .object(["paneId": .string(id.uuidString), "kind": .string("shell"), "profileId": .string("shell"),
            "state": .string("open"), "runtime": runtime,
            "terminal": .object(["runtime": runtime, "process": .object(["kind": .string("running"), "pid": .number(1234)]),
                                 "attached": .bool(false), "backlog_bytes": .number(0)])])
    }
    func testProductionSessionShapeWithEmptyShellPaneArray() throws {
        let session = try AxoProtocolResultValidator.sessionGet(result(panes: []), target: target).session
        XCTAssertEqual(session.shellPanes, [])
    }
    func testPaneIsTypedAndOwnedByTheCapturedSession() throws {
        let parsed = try AxoProtocolResultValidator.sessionGet(result(panes: [pane()]), target: target).session
        XCTAssertEqual(parsed.shellPanes.count, 1)
        XCTAssertEqual(parsed.shellPanes[0].paneId, shellPane)
        XCTAssertEqual(parsed.shellPanes[0].state, .open)
        XCTAssertThrowsError(try AxoProtocolResultValidator.sessionGet(result(panes: [pane(sessionID: UUID())]), target: target))
    }
    func testDefaultShellIsExplicitlyNullableWithoutPathAuthority() throws {
        guard case .object(var fields) = pane() else { return XCTFail() }
        fields["profileId"] = .null
        let parsed = try AxoProtocolResultValidator.sessionGet(result(panes: [.object(fields)]), target: target).session
        XCTAssertNil(parsed.shellPanes[0].profileId)
        for invalid in [JSONValue.string(""), .string("../shell"), .object(["argv": .array([.string("/bin/sh")])])] {
            fields["profileId"] = invalid
            XCTAssertThrowsError(try AxoProtocolResultValidator.sessionGet(result(panes: [.object(fields)]), target: target))
        }
        fields.removeValue(forKey: "profileId")
        XCTAssertThrowsError(try AxoProtocolResultValidator.sessionGet(result(panes: [.object(fields)]), target: target))
    }
    func testDuplicatePaneIDsAndPiPaneCollisionsAreRejected() {
        let value = pane()
        XCTAssertThrowsError(try AxoProtocolResultValidator.sessionGet(result(panes: [value, value]), target: target))
        XCTAssertThrowsError(try AxoProtocolResultValidator.sessionGet(result(panes: [pane(id: piPane)]), target: target))
    }
    func testAbsentPaneArrayMatchesSharedDefaultButUnknownFieldsAreRejected() throws {
        XCTAssertEqual(try AxoProtocolResultValidator.sessionGet(result(panes: nil), target: target).session.shellPanes, [])
        guard case .object(var fields) = pane() else { return XCTFail() }
        fields["argv"] = .array([.string("not execution authority")])
        XCTAssertThrowsError(try AxoProtocolResultValidator.sessionGet(result(panes: [.object(fields)]), target: target))
    }
    func testSessionCatalogUsesTheSameClosedPaneAwareRecordParser() throws {
        let source = MachineTarget(machineId: machine, hostGeneration: host)
        func catalog(panes: [JSONValue]?) -> JSONValue {
            guard case .object(let fields) = result(panes: panes), let record = fields["session"] else {
                preconditionFailure("Synthetic session shape")
            }
            return .object(["hostGeneration": .string(host.uuidString), "revision": .number(1),
                            "sessions": .array([record]), "next": .null])
        }
        for panes in [nil, [], [pane()]] as [[JSONValue]?] {
            let parsed = try AxoProtocolResultValidator.sessionList(catalog(panes: panes), target: source)
            XCTAssertEqual(parsed.sessions.count, 1)
            XCTAssertEqual(parsed.sessions[0].shellPanes.count, panes?.count ?? 0)
        }
        guard case .object(var shell) = pane(), case .object(var fields) = result(panes: []) else { return XCTFail() }
        shell["profileId"] = .null
        guard case .object(var standalone)? = fields["session"] else { return XCTFail() }
        standalone["workspaceId"] = .null
        standalone["shellPanes"] = .array([.object(shell)])
        fields.removeValue(forKey: "session")
        fields["sessions"] = .array([.object(standalone)])
        fields["next"] = .null
        let parsed = try AxoProtocolResultValidator.sessionList(.object(fields), target: source)
        XCTAssertNil(parsed.sessions[0].workspaceId)
        XCTAssertNil(parsed.sessions[0].shellPanes[0].profileId)
        standalone["argv"] = .array([.string("not catalog authority")])
        fields["sessions"] = .array([.object(standalone)])
        XCTAssertThrowsError(try AxoProtocolResultValidator.sessionList(.object(fields), target: source))
        XCTAssertThrowsError(try AxoProtocolResultValidator.sessionList(catalog(panes: [pane(sessionID: UUID())]), target: source))
        XCTAssertThrowsError(try AxoProtocolResultValidator.sessionList(catalog(panes: [pane(), pane()]), target: source))
    }
    func testTerminalReferenceCannotDivergeFromItsPane() {
        guard case .object(var fields) = pane(), case .object(var terminal)? = fields["terminal"] else { return XCTFail() }
        terminal["runtime"] = .object([:]); fields["terminal"] = .object(terminal)
        XCTAssertThrowsError(try AxoProtocolResultValidator.sessionGet(result(panes: [.object(fields)]), target: target))
    }
}
