import Foundation
import XCTest
@testable import AxoProtocol

final class SessionLifecycleTests: XCTestCase {
    func testLifecycleObservationRejectsUnknownFieldsAndStaleSource() throws {
        let source = MachineTarget(machineId: UUID(), hostGeneration: UUID())
        let valid: JSONValue = .object(["hostGeneration": .string(source.hostGeneration.uuidString), "sessionKeepAlive": .bool(true)])
        XCTAssertTrue(try AxoProtocolResultValidator.hostLifecycle(valid, target: source).sessionKeepAlive)
        XCTAssertThrowsError(try AxoProtocolResultValidator.hostLifecycle(.object([
            "hostGeneration": .string(UUID().uuidString), "sessionKeepAlive": .bool(true)]), target: source))
        XCTAssertThrowsError(try AxoProtocolResultValidator.hostLifecycle(.object([
            "hostGeneration": .string(source.hostGeneration.uuidString), "sessionKeepAlive": .bool(true), "restart": .bool(true)]), target: source))
    }
    func testCompletionOnlyGrantsCapturedRuntimeAuthority() throws {
        let target = WorkSessionTarget(machineId: UUID(), hostGeneration: UUID(), workspaceId: nil, sessionId: UUID())
        let runtime = TerminalRuntime(hostGeneration: UUID(), target: .init(sessionId: target.sessionId, paneId: UUID()), runtimeGeneration: UUID())
        let parameters = SessionCompletionParameters(target: target, runtimes: [runtime])
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(runtime))
        func proof(_ runtimes: [JSONValue]) -> JSONValue {
            .object(["hostGeneration": .string(target.hostGeneration.uuidString), "completed": .array(runtimes), "retiredShellReceipts": .array([])])
        }
        XCTAssertEqual(try AxoProtocolResultValidator.sessionCompletion(proof([encoded]), parameters: parameters).completed, [runtime])
        XCTAssertTrue(try AxoProtocolResultValidator.sessionCompletion(proof([]), parameters: parameters).completed.isEmpty)
        XCTAssertThrowsError(try AxoProtocolResultValidator.sessionCompletion(proof([encoded, encoded]), parameters: parameters))
        let other = TerminalRuntime(hostGeneration: runtime.hostGeneration, target: runtime.target, runtimeGeneration: UUID())
        let unrequested = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(other))
        XCTAssertThrowsError(try AxoProtocolResultValidator.sessionCompletion(proof([unrequested]), parameters: parameters))
    }
}
