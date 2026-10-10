import Foundation
import XCTest
@testable import AxoProtocol

final class HostContractTests: XCTestCase {
    private let target = MachineTarget(machineId: UUID(), hostGeneration: UUID())
    private func metadata(_ cloud: [String: JSONValue]) -> JSONValue {
        .object(["machineId": .string(target.machineId.uuidString), "hostGeneration": .string(target.hostGeneration.uuidString),
                 "hostname": .string("Test Mac"), "machineType": .string("Mac Studio"), "daemonVersion": .string("0.1.0 (test)"), "cloud": .object(cloud)])
    }
    func testCloudOnlineRequiresAnUnexpiredLeaseAndExactShape() throws {
        let offline = try AxoProtocolResultValidator.host(metadata(["kind": .string("notConfigured")]), target: target)
        XCTAssertFalse(offline.cloud.isOnline)
        let expiry = (Date().timeIntervalSince1970 * 1000 + 10000).rounded()
        let online = try AxoProtocolResultValidator.host(metadata(["kind": .string("online"), "leaseId": .string(UUID().uuidString), "expiresAt": .number(expiry)]), target: target)
        XCTAssertTrue(online.cloud.isOnline)
        let expired = try AxoProtocolResultValidator.host(metadata(["kind": .string("online"), "leaseId": .string(UUID().uuidString), "expiresAt": .number(1)]), target: target)
        XCTAssertFalse(expired.cloud.isOnline)
        XCTAssertThrowsError(try AxoProtocolResultValidator.host(metadata(["kind": .string("online")]), target: target))
        XCTAssertThrowsError(try AxoProtocolResultValidator.host(metadata(["kind": .string("offline"), "leaseId": .string(UUID().uuidString)]), target: target))
    }
    func testHostResultCannotRetargetToAnotherMachineOrGeneration() throws {
        let value = metadata(["kind": .string("offline")])
        XCTAssertThrowsError(try AxoProtocolResultValidator.host(value, target: MachineTarget(machineId: UUID(), hostGeneration: target.hostGeneration)))
        XCTAssertThrowsError(try AxoProtocolResultValidator.host(value, target: MachineTarget(machineId: target.machineId, hostGeneration: UUID())))
    }
}
