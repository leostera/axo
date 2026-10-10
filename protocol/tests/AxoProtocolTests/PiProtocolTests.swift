import Foundation
import XCTest
@testable import AxoProtocol

final class PiProtocolTests: XCTestCase {
    private let machine = "11111111-1111-4111-8111-111111111111"
    private let host = "22222222-2222-4222-8222-222222222222"
    private let workspace = "33333333-3333-4333-8333-333333333333"
    private let session = "44444444-4444-4444-8444-444444444444"
    private let pane = "55555555-5555-4555-8555-555555555555"
    private let runtime = "66666666-6666-4666-8666-666666666666"
    private let chat = "77777777-7777-4777-8777-777777777777"
    private let command = "88888888-8888-4888-8888-888888888888"

    func testManagedStartAndReadResultsStayBoundToTheCapturedPiDestination() throws {
        let startTarget = #"{"machineId":"\#(machine)","hostGeneration":"\#(host)","workspaceId":"\#(workspace)","sessionId":"\#(session)","paneId":"\#(pane)"}"#
        let chatTarget = #"{"machineId":"\#(machine)","hostGeneration":"\#(host)","workspaceId":"\#(workspace)","sessionId":"\#(session)","paneId":"\#(pane)","runtimeHostGeneration":"\#(host)","runtimeGeneration":"\#(runtime)","chatId":"\#(chat)"}"#
        let runtimeRef = #"{"host_generation":"\#(host)","target":{"session_id":"\#(session)","pane_id":"\#(pane)"},"runtime_generation":"\#(runtime)"}"#
        let start = #"{"hostGeneration":"\#(host)","receipt":{"commandId":"\#(command)","intent":{"kind":"start","target":\#(startTarget),"persistence":{"kind":"fresh"}},"disposition":{"kind":"dispatched"},"runtime":\#(runtimeRef)},"chat":\#(chatTarget),"admission":"ready"}"#
        let target = PiSessionTarget(machineId: UUID(uuidString: machine)!, hostGeneration: UUID(uuidString: host)!,
                                    workspaceId: UUID(uuidString: workspace)!, sessionId: UUID(uuidString: session)!,
                                    paneId: UUID(uuidString: pane)!)
        let startResult = try PiProtocolValidator.sessionStart(json(start), target: target,
                                                               commandId: UUID(uuidString: command)!, persistence: .fresh)
        XCTAssertEqual(startResult.admission, .ready)
        XCTAssertEqual(startResult.chat?.chatId.uuidString.lowercased(), chat)

        let snapshot = #"{"hostGeneration":"\#(host)","readMode":"live","target":\#(chatTarget),"admission":"ready","busy":false,"interactionId":null,"uiWaits":0,"question":null,"recovery":false,"leafId":null,"recentEntries":[],"viewingCount":0}"#
        let decodedTarget = try XCTUnwrap(startResult.chat)
        let chatResult = try PiProtocolValidator.chatGet(json(snapshot), target: decodedTarget)
        XCTAssertFalse(chatResult.busy)
        XCTAssertNil(chatResult.interactionId)

        let history = #"{"hostGeneration":"\#(host)","readMode":"stopped","target":\#(chatTarget),"leafId":null,"entries":[],"next":null}"#
        let stoppedHistory = try PiProtocolValidator.chatHistory(json(history), target: decodedTarget, readMode: .stopped)
        XCTAssertTrue(stoppedHistory.entries.isEmpty)

        let staleChat = snapshot.replacingOccurrences(of: #""runtimeGeneration":"\#(runtime)""#, with: #""runtimeGeneration":"99999999-9999-4999-8999-999999999999""#)
        XCTAssertThrowsError(try PiProtocolValidator.chatGet(json(staleChat), target: decodedTarget))
    }

    func testWorkSessionRecognizesActualAdmissionWithoutFabricatingIt() throws {
        let target = MachineTarget(machineId: UUID(uuidString: machine)!, hostGeneration: UUID(uuidString: host)!)
        let admitted = #"{"hostGeneration":"\#(host)","revision":3,"sessions":[{"sessionId":"\#(session)","workspaceId":"\#(workspace)","name":"Build","nameSource":"manual","pi":{"paneId":"\#(pane)","chatId":"\#(chat)","admission":"ready"},"runtime":{"runtime":{"host_generation":"\#(host)","target":{"session_id":"\#(session)","pane_id":"\#(pane)"},"runtime_generation":"\#(runtime)"},"process":{"kind":"running","pid":42},"attached":false,"backlog_bytes":0}}],"next":null}"#
        let page = try AxoProtocolResultValidator.sessionList(json(admitted), target: target,
                                                               workspaceID: UUID(uuidString: workspace)!, cursor: nil)
        XCTAssertEqual(page.sessions.first?.pi.admission, .ready)
        XCTAssertEqual(page.sessions.first?.pi.chatId?.uuidString.lowercased(), chat)

        let inconsistent = admitted.replacingOccurrences(of: #""admission":"ready""#, with: #""admission":"notAdmitted""#)
        XCTAssertThrowsError(try AxoProtocolResultValidator.sessionList(json(inconsistent), target: target,
            workspaceID: UUID(uuidString: workspace)!, cursor: nil))
    }

    func testPiReceiptsRoundTripThroughCommandGetWithoutExposingPreparationMetadata() throws {
        let chatTargetJSON = #"{"machineId":"\#(machine)","hostGeneration":"\#(host)","workspaceId":"\#(workspace)","sessionId":"\#(session)","paneId":"\#(pane)","runtimeHostGeneration":"\#(host)","runtimeGeneration":"\#(runtime)","chatId":"\#(chat)"}"#
        let runtimeRef = #"{"host_generation":"\#(host)","target":{"session_id":"\#(session)","pane_id":"\#(pane)"},"runtime_generation":"\#(runtime)"}"#
        let receipt = #"{"commandId":"\#(command)","intent":{"kind":"chat","target":\#(chatTargetJSON),"operation":"sendMessage"},"disposition":{"kind":"dispatched"},"runtime":\#(runtimeRef)}"#
        let value = #"{"hostGeneration":"\#(host)","receipt":{"kind":"pi","receipt":\#(receipt)}}"#
        let decoded = try AxoProtocolResultValidator.commandGet(json(value),
            target: MachineTarget(machineId: UUID(uuidString: machine)!, hostGeneration: UUID(uuidString: host)!))
        guard case .pi(let piReceipt)? = decoded.receipt else { return XCTFail("Expected managed Pi receipt") }
        XCTAssertEqual(piReceipt.commandId.uuidString.lowercased(), command)
        XCTAssertEqual(piReceipt.disposition, .dispatched)

        let leaked = String(receipt.dropLast()) + #","text":"private prompt"}"#
        let leakedValue = #"{"hostGeneration":"\#(host)","receipt":{"kind":"pi","receipt":\#(leaked)}}"#
        let target = MachineTarget(machineId: UUID(uuidString: machine)!, hostGeneration: UUID(uuidString: host)!)
        XCTAssertThrowsError(try AxoProtocolResultValidator.commandGet(json(leakedValue), target: target))

        let wrongMachine = value.replacingOccurrences(of: #""machineId":"\#(machine)""#,
                                                       with: #""machineId":"99999999-9999-4999-8999-999999999999""#)
        XCTAssertThrowsError(try AxoProtocolResultValidator.commandGet(json(wrongMachine), target: target))
        let wrongHost = value.replacingOccurrences(
            of: #""target":{"machineId":"\#(machine)","hostGeneration":"\#(host)""#,
            with: #""target":{"machineId":"\#(machine)","hostGeneration":"99999999-9999-4999-8999-999999999999""#
        )
        XCTAssertThrowsError(try AxoProtocolResultValidator.commandGet(json(wrongHost), target: target))
    }

    func testPiMutationAndHistoryValidationEnforceBoundsAndIntentKind() throws {
        let target = #"{"machineId":"\#(machine)","hostGeneration":"\#(host)","workspaceId":"\#(workspace)","sessionId":"\#(session)","paneId":"\#(pane)","runtimeHostGeneration":"\#(host)","runtimeGeneration":"\#(runtime)","chatId":"\#(chat)"}"#
        let receipt = #"{"commandId":"\#(command)","intent":{"kind":"chat","target":\#(target),"operation":"sendMessage"},"disposition":{"kind":"prepared"},"runtime":null}"#
        let result = #"{"hostGeneration":"\#(host)","receipt":\#(receipt)}"#
        let chatTarget = PiChatTarget(machineId: UUID(uuidString: machine)!, hostGeneration: UUID(uuidString: host)!,
                                      workspaceId: UUID(uuidString: workspace)!, sessionId: UUID(uuidString: session)!,
                                      paneId: UUID(uuidString: pane)!, runtimeHostGeneration: UUID(uuidString: host)!,
                                      runtimeGeneration: UUID(uuidString: runtime)!, chatId: UUID(uuidString: chat)!)
        _ = try PiProtocolValidator.mutation(json(result), target: chatTarget, commandId: UUID(uuidString: command)!,
                                             operation: .sendMessage, method: AxoProtocol.Method.sendChatMessage)
        XCTAssertThrowsError(try PiProtocolValidator.mutation(json(result), target: chatTarget,
            commandId: UUID(uuidString: command)!, operation: .sendSteeringMessage,
            method: AxoProtocol.Method.sendChatSteeringMessage))
        XCTAssertFalse(PiProtocolValidator.validMessageText("/new"))
        XCTAssertFalse(PiProtocolValidator.validMessageText(" \n\t"))
        XCTAssertFalse(PiProtocolValidator.validMessageText(String(repeating: "界", count: 20_000)))
        XCTAssertTrue(PiProtocolValidator.validMessageText("hello λ 界"))
    }

    func testPiRequestsEncodeCapturedTargetsAndNullableCursorFields() throws {
        let chatTarget = PiChatTarget(machineId: UUID(uuidString: machine)!, hostGeneration: UUID(uuidString: host)!,
                                      workspaceId: UUID(uuidString: workspace)!, sessionId: UUID(uuidString: session)!,
                                      paneId: UUID(uuidString: pane)!, runtimeHostGeneration: UUID(uuidString: host)!,
                                      runtimeGeneration: UUID(uuidString: runtime)!, chatId: UUID(uuidString: chat)!)
        let params = PiChatHistoryParameters(target: chatTarget, readMode: .stopped, limit: 12)
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(params))
        guard case .object(let fields) = encoded else { return XCTFail("Expected a JSON object") }
        XCTAssertEqual(fields["readMode"], .string("stopped"))
        XCTAssertEqual(fields["limit"], .number(12))
        XCTAssertNil(fields["cursor"])

        let cursor = PiHistoryCursor(target: chatTarget, readMode: .stopped, leafId: nil, after: "entry-1")
        let cursorValue = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(cursor))
        guard case .object(let cursorFields) = cursorValue else { return XCTFail("Expected a JSON cursor") }
        XCTAssertEqual(cursorFields["leafId"], .null)
        XCTAssertEqual(cursorFields["after"], .string("entry-1"))

        let previous = TerminalRuntime(hostGeneration: UUID(uuidString: host)!,
                                       target: .init(sessionId: UUID(uuidString: session)!, paneId: UUID(uuidString: pane)!),
                                       runtimeGeneration: UUID(uuidString: runtime)!)
        let start = PiSessionStartParameters(
            target: PiSessionTarget(machineId: UUID(uuidString: machine)!, hostGeneration: UUID(uuidString: host)!,
                                    workspaceId: UUID(uuidString: workspace)!, sessionId: UUID(uuidString: session)!,
                                    paneId: UUID(uuidString: pane)!),
            commandId: UUID(uuidString: command)!, persistence: .resume(chatId: UUID(uuidString: chat)!, previousRuntime: previous)
        )
        let startValue = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(start))
        guard case .object(let startFields) = startValue,
              case .object(let persistence)? = startFields["persistence"] else { return XCTFail("Expected explicit resume intent") }
        XCTAssertEqual(persistence["kind"], .string("resume"))
        XCTAssertNotNil(persistence["previousRuntime"])
    }

    private func json(_ raw: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
    }
}
