import Foundation
import XCTest
@testable import AxoProtocol

final class RetiredDeletionContractTests: XCTestCase {
    func testRetiredDeletionReceiptCannotDecodeOrAuthorizeRemoval() throws {
        let source = MachineTarget(machineId: UUID(), hostGeneration: UUID())
        let receipt: JSONValue = .object([
            "kind": .string("deletion"), "receipt": .object([
                "commandId": .string(UUID().uuidString), "runtimes": .array([]), "revision": .number(1),
                "intent": .object([
                    "expectedRevision": .number(0),
                    "target": .object([
                        "machineId": .string(source.machineId.uuidString),
                        "hostGeneration": .string(source.hostGeneration.uuidString),
                    ]),
                    "sessions": .array([.object([
                        "workspaceId": .null, "sessionId": .string(UUID().uuidString),
                    ])]),
                ]),
            ]),
        ])
        XCTAssertThrowsError(try JSONDecoder().decode(CommandReceipt.self, from: JSONEncoder().encode(receipt)))
        let envelope: JSONValue = .object([
            "hostGeneration": .string(source.hostGeneration.uuidString), "receipt": receipt,
        ])
        XCTAssertThrowsError(try AxoProtocolResultValidator.commandGet(envelope, target: source))
    }
}
