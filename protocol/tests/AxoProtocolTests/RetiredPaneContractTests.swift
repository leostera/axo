import Foundation
import XCTest
@testable import AxoProtocol

final class RetiredPaneContractTests: XCTestCase {
    func testRetiredPaneReceiptCannotDecodeOrAuthorizeACommand() throws {
        let source = MachineTarget(machineId: UUID(), hostGeneration: UUID())
        let receipt: JSONValue = .object([
            "kind": .string("pane"), "receipt": .object([
                "commandId": .string(UUID().uuidString), "paneId": .string(UUID().uuidString),
                "runtime": .null, "disposition": .object(["kind": .string("prepared")]),
                "intent": .object([
                    "operation": .string("addPane"), "profileId": .null,
                    "target": .object([
                        "machineId": .string(source.machineId.uuidString),
                        "hostGeneration": .string(source.hostGeneration.uuidString),
                        "workspaceId": .null, "sessionId": .string(UUID().uuidString),
                    ]),
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
