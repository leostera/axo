import Foundation
import XCTest
@testable import AxoProtocol

final class LocalDaemonBootstrapTests: XCTestCase {
    func testLocalEndpointRequiresExactLoopbackDescriptor() throws {
        let machine = UUID()
        let generation = UUID()
        let endpoint = try LocalDaemonEndpoint(
            endpoint: "ws://127.0.0.1:43210/v1/rpc",
            machineId: machine,
            hostGeneration: generation
        )
        XCTAssertEqual(endpoint.url.absoluteString, "ws://127.0.0.1:43210/v1/rpc")

        let decoder = JSONDecoder()
        for raw in [
            #"{"version":1,"protocolVersion":1,"endpoint":"ws://localhost:43210/v1/rpc","machineId":"\#(machine)","hostGeneration":"\#(generation)"}"#,
            #"{"version":1,"protocolVersion":1,"endpoint":"ws://127.0.0.1:43210/v1/rpc?token=secret","machineId":"\#(machine)","hostGeneration":"\#(generation)"}"#,
            #"{"version":1,"protocolVersion":2,"endpoint":"ws://127.0.0.1:43210/v1/rpc","machineId":"\#(machine)","hostGeneration":"\#(generation)"}"#,
            #"{"version":1,"protocolVersion":1,"endpoint":"ws://127.0.0.1:43210/v1/rpc","machineId":"\#(machine)","hostGeneration":"\#(generation)","credential":"secret"}"#,
        ] {
            XCTAssertThrowsError(try decoder.decode(LocalDaemonEndpoint.self, from: Data(raw.utf8)))
        }
    }

    func testLocalNegotiationCapturesClosedMethodCapabilities() throws {
        let decoder = JSONDecoder()
        let compatible = try decoder.decode(JSONValue.self, from: Data(#"{"protocolVersion":1,"methods":["axo.state.get","axo.state.chat.command.submit"]}"#.utf8))
        let result = try AxoProtocolResultValidator.localNegotiation(compatible)
        XCTAssertEqual(result.protocolVersion, 1)
        XCTAssertTrue(result.supports("axo.state.chat.command.submit"))
        XCTAssertFalse(result.supports("axo.legacy.startPi"))

        let tooManyMethods = (0...128).map { "\"method-\($0)\"" }.joined(separator: ",")
        let tooLongMethod = String(repeating: "x", count: 129)
        for raw in [
            #"{"protocolVersion":2,"methods":[]}"#,
            #"{"protocolVersion":1}"#,
            #"{"protocolVersion":1,"methods":["duplicate","duplicate"]}"#,
            #"{"protocolVersion":1,"methods":[""]}"#,
            #"{"protocolVersion":1,"methods":[],"unexpected":true}"#,
            "{\"protocolVersion\":1,\"methods\":[\(tooManyMethods)]}",
            #"{"protocolVersion":1,"methods":["\#(tooLongMethod)"]}"#,
            #"{"protocolVersion":1,"methods":["bad\u0001name"]}"#,
        ] {
            let value = try decoder.decode(JSONValue.self, from: Data(raw.utf8))
            XCTAssertThrowsError(try AxoProtocolResultValidator.localNegotiation(value))
        }
    }

    func testApprovedRuntimeResultIsBoundToRequestedTarget() throws {
        let machineID = UUID()
        let host = UUID()
        let session = UUID()
        let pane = UUID()
        let runtime = UUID()
        let target = TerminalTarget(machineId: machineID, hostGeneration: host, sessionId: session, paneId: pane)
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"hostGeneration":"\#(host)","terminal":{"runtime":{"host_generation":"\#(host)","target":{"session_id":"\#(session)","pane_id":"\#(pane)"},"runtime_generation":"\#(runtime)"},"process":{"kind":"running","pid":42},"attached":false,"backlog_bytes":0}}"#.utf8))

        let result = try AxoProtocolResultValidator.runtimeStart(value, target: target)
        XCTAssertEqual(result.terminal.runtime.target.sessionId, session)
        XCTAssertEqual(result.terminal.runtime.target.paneId, pane)

        let wrongTarget = TerminalTarget(machineId: machineID, hostGeneration: host, sessionId: UUID(), paneId: pane)
        XCTAssertThrowsError(try AxoProtocolResultValidator.runtimeStart(value, target: wrongTarget))
    }
}
