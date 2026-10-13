import AxoProtocol
import Foundation
import XCTest
@testable import AxoCore

final class CentralSessionDisplayNameTests: XCTestCase {
    private let machineId = UUID()
    private let hostGeneration = UUID()
    private let storeGeneration = UUID()
    private let workspaceId = UUID()
    private let sessionId = UUID()
    private let paneId = UUID()
    private var validSource: CentralSource!

    override func setUpWithError() throws {
        validSource = try CentralSource(
            machine: MachineTarget(machineId: machineId, hostGeneration: hostGeneration),
            storeGeneration: storeGeneration
        )
    }

    func testPiTitleRequiresTheSelectedExactCurrentLiveBinding() throws {
        let catalogSource = validSource!
        let response = try observation(source: catalogSource, revision: 4, title: "Observed title")
        XCTAssertEqual(resolve(response: response), "Observed title")
        XCTAssertEqual(resolve(response: response, selectedSessionId: UUID()), "Central name")
        XCTAssertEqual(resolve(response: response, revision: 5), "Central name")
        XCTAssertEqual(resolve(response: response, piReadUnavailable: true), "Central name")
        XCTAssertEqual(resolve(response: response, workspaceId: UUID()), "Central name")

        let foreignSource = try CentralSource(
            machine: MachineTarget(machineId: machineId, hostGeneration: hostGeneration),
            storeGeneration: UUID()
        )
        let foreignResponse = try observation(source: foreignSource, revision: 4, title: "Foreign title")
        XCTAssertEqual(resolve(response: foreignResponse), "Central name")

        let foreignSession = try observation(source: catalogSource, revision: 4, title: "Foreign title", sessionId: UUID())
        XCTAssertEqual(resolve(response: foreignSession), "Central name")
    }

    func testManualNamesAndNonliveObservationsKeepTheCentralName() throws {
        let catalogSource = validSource!
        let liveResponse = try observation(source: catalogSource, revision: 4, title: "Pi title")
        XCTAssertEqual(resolve(response: liveResponse, manualName: true), "Central name")

        let unadmitted = try observation(source: catalogSource, revision: 4, kind: "notAdmitted")
        XCTAssertEqual(resolve(response: unadmitted), "Central name")

        let stopped = try observation(source: catalogSource, revision: 4, kind: "stopped")
        XCTAssertEqual(resolve(response: stopped), "Central name")

        let untitled = try observation(source: catalogSource, revision: 4, title: nil)
        XCTAssertEqual(resolve(response: untitled), "Central name")
    }

    private func resolve(
        response: CentralResponse?,
        manualName: Bool = false,
        selectedSessionId: UUID? = nil,
        workspaceId: UUID? = nil,
        revision: Int = 4,
        piReadUnavailable: Bool = false
    ) -> String {
        CentralSessionDisplayName.resolve(
            catalogName: "Central name",
            manualName: manualName,
            sessionId: sessionId,
            workspaceId: workspaceId ?? self.workspaceId,
            selectedSessionId: selectedSessionId ?? sessionId,
            source: validSource!,
            revision: CentralRevision(rawValue: revision),
            piResponse: response,
            piReadUnavailable: piReadUnavailable
        )
    }

    private func observation(
        source: CentralSource,
        revision: Int,
        title: String? = nil,
        kind: String = "live",
        sessionId: UUID? = nil,
        workspaceId: UUID? = nil
    ) throws -> CentralResponse {
        let targetSessionId = sessionId ?? self.sessionId
        let targetWorkspaceId = workspaceId ?? self.workspaceId
        let request = try CentralRequest.observePi(
            source: source,
            workspaceId: targetWorkspaceId,
            sessionId: targetSessionId
        )
        let value: [String: Any]
        if kind == "notAdmitted" {
            value = ["kind": kind]
        } else {
            let target: [String: Any] = [
                "machineId": source.machine.machineId.uuidString,
                "hostGeneration": source.machine.hostGeneration.uuidString,
                "storeGeneration": source.storeGeneration.uuidString,
                "workspaceId": targetWorkspaceId.uuidString,
                "sessionId": targetSessionId.uuidString,
                "paneId": paneId.uuidString,
                "chatId": UUID().uuidString,
                "runtime": [
                    "host_generation": source.machine.hostGeneration.uuidString,
                    "runtime_generation": UUID().uuidString,
                    "target": ["session_id": targetSessionId.uuidString, "pane_id": paneId.uuidString],
                ],
            ]
            if kind == "stopped" {
                value = ["kind": kind, "target": target]
            } else {
                value = [
                    "kind": kind,
                    "target": target,
                    "state": [
                        "title": title as Any? ?? NSNull(),
                        "leafId": NSNull(),
                        "busy": false,
                        "interactionId": NSNull(),
                        "uiWaits": 0,
                        "question": NSNull(),
                        "pending": false,
                        "recovery": false,
                    ],
                ]
            }
        }
        let envelope: [String: Any] = [
            "hostGeneration": source.machine.hostGeneration.uuidString,
            "storeGeneration": source.storeGeneration.uuidString,
            "revision": revision,
            "value": value,
        ]
        let encoded = try JSONSerialization.data(withJSONObject: envelope)
        return try request.parseResult(JSONDecoder().decode(JSONValue.self, from: encoded))
    }
}
