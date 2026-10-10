import Foundation
import XCTest
@testable import AxoProtocol

final class PiContractTests: XCTestCase {
    private let machine = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let host = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let workspace = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let session = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let pane = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    private let runtime = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
    private let chat = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
    private let command = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!

    private var sessionTarget: PiSessionTarget {
        PiSessionTarget(machineId: machine, hostGeneration: host, workspaceId: workspace, sessionId: session, paneId: pane)
    }

    private var chatTarget: PiChatTarget {
        PiChatTarget(machineId: machine, hostGeneration: host, workspaceId: workspace, sessionId: session, paneId: pane,
                     runtimeHostGeneration: host, runtimeGeneration: runtime, chatId: chat)
    }

    func testRequestShapesUseTheSharedManagedPiContracts() throws {
        XCTAssertEqual(AxoProtocol.Method.startSession, "axo.session.start")
        XCTAssertEqual(AxoProtocol.Method.sendChatSteeringMessage, "axo.chat.sendSteeringMessage")

        let start = PiSessionStartParameters(target: sessionTarget, commandId: command, persistence: .fresh)
        let startJSON = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(start))
        guard case .object(let startFields) = startJSON,
              case .object(let persistence)? = startFields["persistence"] else {
            return XCTFail("Expected typed start parameters with explicit persistence")
        }
        XCTAssertEqual(persistence["kind"], .string("fresh"))

        let message = PiChatTextParameters(target: chatTarget, commandId: command, text: "hello")
        let messageJSON = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(message))
        guard case .object(let messageFields) = messageJSON else { return XCTFail("Expected typed chat parameters") }
        XCTAssertEqual(messageFields["commandId"], .string(command.uuidString))
        XCTAssertEqual(messageFields["text"], .string("hello"))

        let cursor = PiHistoryCursor(target: chatTarget, readMode: .live, leafId: nil, after: "entry-1")
        let cursorJSON = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(cursor))
        guard case .object(let cursorFields) = cursorJSON else { return XCTFail("Expected typed history cursor") }
        XCTAssertEqual(cursorFields["leafId"], .null)
    }

    func testSessionStartResultIsBoundToTheCapturedFreshIntent() throws {
        let value = try jsonValue(#"{"hostGeneration":"22222222-2222-4222-8222-222222222222","receipt":{"commandId":"99999999-9999-4999-8999-999999999999","intent":{"kind":"start","target":{"machineId":"11111111-1111-4111-8111-111111111111","hostGeneration":"22222222-2222-4222-8222-222222222222","workspaceId":"33333333-3333-4333-8333-333333333333","sessionId":"44444444-4444-4444-8444-444444444444","paneId":"55555555-5555-4555-8555-555555555555"},"persistence":{"kind":"fresh"}},"disposition":{"kind":"dispatched"},"runtime":{"host_generation":"22222222-2222-4222-8222-222222222222","target":{"session_id":"44444444-4444-4444-8444-444444444444","pane_id":"55555555-5555-4555-8555-555555555555"},"runtime_generation":"77777777-7777-4777-8777-777777777777"}},"chat":{"machineId":"11111111-1111-4111-8111-111111111111","hostGeneration":"22222222-2222-4222-8222-222222222222","workspaceId":"33333333-3333-4333-8333-333333333333","sessionId":"44444444-4444-4444-8444-444444444444","paneId":"55555555-5555-4555-8555-555555555555","runtimeHostGeneration":"22222222-2222-4222-8222-222222222222","runtimeGeneration":"77777777-7777-4777-8777-777777777777","chatId":"88888888-8888-4888-8888-888888888888"},"admission":"ready"}"#)

        let result = try PiProtocolValidator.sessionStart(value, target: sessionTarget,
                                                          commandId: command, persistence: .fresh)
        XCTAssertEqual(result.admission, .ready)
        XCTAssertEqual(result.chat, chatTarget)
        XCTAssertThrowsError(try PiProtocolValidator.sessionStart(
            value, target: PiSessionTarget(machineId: machine, hostGeneration: host, workspaceId: workspace,
                                           sessionId: UUID(), paneId: pane),
            commandId: command, persistence: .fresh
        ))
    }

    func testMutationResultMustMatchTheCapturedCommandAndOperation() throws {
        let value = try jsonValue(#"{"hostGeneration":"22222222-2222-4222-8222-222222222222","receipt":{"commandId":"99999999-9999-4999-8999-999999999999","intent":{"kind":"chat","target":{"machineId":"11111111-1111-4111-8111-111111111111","hostGeneration":"22222222-2222-4222-8222-222222222222","workspaceId":"33333333-3333-4333-8333-333333333333","sessionId":"44444444-4444-4444-8444-444444444444","paneId":"55555555-5555-4555-8555-555555555555","runtimeHostGeneration":"22222222-2222-4222-8222-222222222222","runtimeGeneration":"77777777-7777-4777-8777-777777777777","chatId":"88888888-8888-4888-8888-888888888888"},"operation":"sendMessage"},"disposition":{"kind":"dispatched"},"runtime":{"host_generation":"22222222-2222-4222-8222-222222222222","target":{"session_id":"44444444-4444-4444-8444-444444444444","pane_id":"55555555-5555-4555-8555-555555555555"},"runtime_generation":"77777777-7777-4777-8777-777777777777"}}}"#)

        let result = try PiProtocolValidator.mutation(value, target: chatTarget, commandId: command,
                                                      operation: .sendMessage, method: AxoProtocol.Method.sendChatMessage)
        XCTAssertEqual(result.receipt.disposition, .dispatched)
        XCTAssertThrowsError(try PiProtocolValidator.mutation(
            value, target: chatTarget, commandId: command, operation: .cancelTurn,
            method: AxoProtocol.Method.cancelChatTurn
        ))
    }

    private func jsonValue(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}
