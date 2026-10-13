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
}
