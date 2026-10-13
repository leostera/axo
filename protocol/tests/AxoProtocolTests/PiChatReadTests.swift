import Foundation
import XCTest
@testable import AxoProtocol

final class PiChatReadTests: XCTestCase {
    private let target = PiChatTarget(
        machineId: UUID(), hostGeneration: UUID(), workspaceId: nil,
        sessionId: UUID(), paneId: UUID(), runtimeHostGeneration: UUID(),
        runtimeGeneration: UUID(), chatId: UUID()
    )

    func testLiveSnapshotRequiresTheExactCapturedBinding() throws {
        let fields = try snapshotFields(admission: "ready", readMode: "live")
        let snapshot = try PiProtocolValidator.chatGet(.object(fields), target: target)
        XCTAssertEqual(snapshot.target, target)
        XCTAssertFalse(snapshot.busy)

        var staleHost = fields
        staleHost["hostGeneration"] = .string(UUID().uuidString)
        XCTAssertThrowsError(try PiProtocolValidator.chatGet(.object(staleHost), target: target))

        var staleRuntime = try encodedTarget()
        staleRuntime["runtimeGeneration"] = .string(UUID().uuidString)
        var staleBinding = fields
        staleBinding["target"] = .object(staleRuntime)
        XCTAssertThrowsError(try PiProtocolValidator.chatGet(.object(staleBinding), target: target))
    }

    func testStoppedSnapshotCannotClaimAnActiveInteraction() throws {
        var fields = try snapshotFields(admission: "stopped", readMode: "stopped")
        let snapshot = try PiProtocolValidator.chatGet(.object(fields), target: target, readMode: .stopped)
        XCTAssertEqual(snapshot.admission, .stopped)
        XCTAssertThrowsError(try PiProtocolValidator.chatGet(.object(fields), target: target))
        fields["busy"] = .bool(true)
        XCTAssertThrowsError(try PiProtocolValidator.chatGet(.object(fields), target: target, readMode: .stopped))
    }

    func testStoppedHistoryReadsDoNotRequireAStartReceipt() throws {
        let fields: [String: JSONValue] = [
            "hostGeneration": .string(target.hostGeneration.uuidString),
            "readMode": .string("stopped"), "target": .object(try encodedTarget()),
            "leafId": .null, "entries": .array([]), "next": .null,
        ]
        let history = try PiProtocolValidator.chatHistory(.object(fields), target: target, readMode: .stopped)
        XCTAssertEqual(history.target, target)
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertThrowsError(try PiProtocolValidator.chatHistory(.object(fields), target: target))
    }

    private func snapshotFields(admission: String, readMode: String) throws -> [String: JSONValue] {
        [
            "hostGeneration": .string(target.hostGeneration.uuidString),
            "readMode": .string(readMode), "target": .object(try encodedTarget()),
            "admission": .string(admission), "busy": .bool(false),
            "interactionId": .null, "uiWaits": .number(0), "question": .null,
            "recovery": .bool(false), "leafId": .null,
            "recentEntries": .array([]), "viewingCount": .number(0),
        ]
    }

    private func encodedTarget() throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(target))
        guard case .object(let fields) = value else {
            throw AxoProtocolValidationError.invalidParameters(method: "chat read fixture")
        }
        return fields
    }
}
