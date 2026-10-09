import Foundation
import XCTest
@testable import AxoProtocol
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class AxoProtocolE2ETests: XCTestCase {
    func testSwiftProtocolContractsAgainstRealAxod() async throws {
        guard let baseURL = ProcessInfo.processInfo.environment["AXO_PROTOCOL_E2E_URL"],
              let machineID = ProcessInfo.processInfo.environment["AXO_PROTOCOL_E2E_MACHINE_ID"],
              let hostGeneration = ProcessInfo.processInfo.environment["AXO_PROTOCOL_E2E_HOST_GENERATION"],
              let tokenPath = ProcessInfo.processInfo.environment["AXO_PROTOCOL_E2E_TOKEN_FILE"],
              let profileID = ProcessInfo.processInfo.environment["AXO_PROTOCOL_E2E_PROFILE"],
              let statePath = ProcessInfo.processInfo.environment["AXO_PROTOCOL_E2E_STATE_FILE"]
        else {
            throw XCTSkip("Set AXO_PROTOCOL_E2E_* to run the real axod end-to-end test.")
        }

        let token = try String(contentsOfFile: tokenPath, encoding: .utf8)
        let socketURL = try clientSocketURL(baseURL: baseURL, machineID: machineID)
        var request = URLRequest(url: socketURL)
        request.setValue(token, forHTTPHeaderField: "Cf-Access-Jwt-Assertion")
        request.setValue("CF_Authorization=\(token)", forHTTPHeaderField: "Cookie")

        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: request)
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        socket.resume()

        let negotiation: JSONValue = try await call(
            socket,
            method: AxoProtocol.Method.negotiate,
            params: NegotiationParameters()
        )
        guard case .object(let negotiationFields) = negotiation,
              negotiationFields["protocolVersion"] == .number(Double(AxoProtocol.version))
        else {
            XCTFail("Unexpected negotiation result: \(negotiation)")
            return
        }

        let machine = try XCTUnwrap(UUID(uuidString: machineID))
        let generation = try XCTUnwrap(UUID(uuidString: hostGeneration))
        let listParameters = RuntimeListParameters(
            target: MachineTarget(machineId: machine, hostGeneration: generation)
        )
        let before: RuntimeListResult = try await call(
            socket,
            method: AxoProtocol.Method.listRuntimes,
            params: listParameters
        )
        XCTAssertEqual(before.hostGeneration, generation)

        let sessionID = UUID()
        let paneID = UUID()
        let commandID = UUID()
        let startParameters = RuntimeStartParameters(
            target: TerminalTarget(
                machineId: machine,
                hostGeneration: generation,
                sessionId: sessionID,
                paneId: paneID
            ),
            commandId: commandID,
            profileId: profileID
        )
        let started: RuntimeStartResult = try await call(
            socket,
            method: AxoProtocol.Method.startApprovedRuntime,
            params: startParameters
        )
        XCTAssertEqual(started.hostGeneration, generation)
        XCTAssertEqual(started.terminal.runtime.target.sessionId, sessionID)
        XCTAssertEqual(started.terminal.runtime.target.paneId, paneID)
        XCTAssertEqual(started.terminal.process.kind, "running")

        let retried: RuntimeStartResult = try await call(
            socket,
            method: AxoProtocol.Method.startApprovedRuntime,
            params: startParameters
        )
        XCTAssertEqual(
            retried.terminal.runtime.runtimeGeneration,
            started.terminal.runtime.runtimeGeneration,
            "Retrying the same command ID must reconcile the original runtime."
        )

        let after: RuntimeListResult = try await call(
            socket,
            method: AxoProtocol.Method.listRuntimes,
            params: listParameters
        )
        XCTAssertTrue(after.terminals.contains { $0.runtime.target.paneId == paneID })
        let stateDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: statePath), Date() < stateDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: statePath))
    }

    private func clientSocketURL(baseURL: String, machineID: String) throws -> URL {
        guard var components = URLComponents(string: baseURL),
              components.scheme == "http" || components.scheme == "https"
        else {
            throw URLError(.badURL)
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/v1/machines/\(machineID)/client"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    private func call<Parameters: Encodable, Result: Decodable>(
        _ socket: URLSessionWebSocketTask,
        method: String,
        params: Parameters,
        as resultType: Result.Type = Result.self
    ) async throws -> Result {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let parameters = try decoder.decode(JSONValue.self, from: encoder.encode(params))
        let id = UUID().uuidString.lowercased()
        let request = RPCRequest(id: .string(id), method: method, params: parameters)
        let requestData = try encoder.encode(request)
        try await socket.send(.string(String(decoding: requestData, as: UTF8.self)))

        let responseMessage = try await socket.receive()
        guard case .string(let raw) = responseMessage else {
            throw RPCProtocolError(code: -32600, message: "Expected a text JSON-RPC response")
        }
        let response = try decoder.decode(RPCResponse.self, from: Data(raw.utf8))
        try await sendAcknowledgement(socket)

        let value: JSONValue
        switch response {
        case .result(let responseID, let result):
            guard responseID == .string(id) else {
                throw RPCProtocolError(code: -32600, message: "Mismatched JSON-RPC response ID")
            }
            value = result
        case .failure(let responseID, let error):
            guard responseID == .string(id) else {
                throw RPCProtocolError(code: -32600, message: "Mismatched JSON-RPC response ID")
            }
            throw RPCProtocolError(code: error.code, message: error.message)
        }

        return try decoder.decode(Result.self, from: encoder.encode(value))
    }

    private func sendAcknowledgement(_ socket: URLSessionWebSocketTask) async throws {
        let ack = RPCRequest(
            id: nil,
            method: AxoProtocol.Method.acknowledgeTransport,
            params: .object(["frames": .number(1)])
        )
        guard let data = try? JSONEncoder().encode(ack) else { return }
        let raw = String(decoding: data, as: UTF8.self)
        try await socket.send(.string(raw))
    }
}

private extension TerminalProcess {
    var kind: String {
        switch self {
        case .starting: "starting"
        case .running: "running"
        case .stopping: "stopping"
        case .exited: "exited"
        case .failed: "failed"
        case .recoveryRequired: "recovery_required"
        }
    }
}
