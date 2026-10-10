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

        let initialWorkspaces: WorkspaceListResult = try await call(
            socket, method: AxoProtocol.Method.listWorkspaces,
            params: WorkspaceListParameters(target: listParameters.target)
        )
        XCTAssertEqual(initialWorkspaces.revision.rawValue, 0)
        let workspaceCommand = UUID()
        let createdWorkspace: WorkspaceMutationResult = try await call(
            socket, method: AxoProtocol.Method.createWorkspace,
            params: WorkspaceCreateParameters(
                target: listParameters.target, commandId: workspaceCommand,
                expectedRevision: initialWorkspaces.revision,
                directoryId: profileID, name: "Native protocol test"
            )
        )
        XCTAssertEqual(createdWorkspace.hostGeneration, generation)
        let workspaceReceipt: CommandGetResult = try await call(
            socket, method: AxoProtocol.Method.getCommand,
            params: CommandGetParameters(target: listParameters.target, commandId: workspaceCommand)
        )
        guard case .work(let workspaceCommit)? = workspaceReceipt.receipt else {
            return XCTFail("Workspace mutation receipt must reconcile through command.get")
        }
        XCTAssertEqual(workspaceCommit.revision, createdWorkspace.revision)

        let workspaceRenameCommand = UUID()
        let renamedWorkspace: WorkspaceMutationResult = try await call(
            socket, method: AxoProtocol.Method.renameWorkspace,
            params: WorkspaceRenameParameters(
                target: WorkWorkspaceTarget(machineId: machine, hostGeneration: generation,
                                             workspaceId: createdWorkspace.workspace.workspaceId),
                commandId: workspaceRenameCommand, expectedRevision: createdWorkspace.revision,
                name: "Renamed workspace"
            )
        )
        XCTAssertEqual(renamedWorkspace.workspace.name, "Renamed workspace")

        let createdSession: SessionMutationResult = try await call(
            socket, method: AxoProtocol.Method.createSession,
            params: SessionCreateParameters(
                target: WorkWorkspaceTarget(machineId: machine, hostGeneration: generation,
                                             workspaceId: createdWorkspace.workspace.workspaceId),
                commandId: UUID(), expectedRevision: renamedWorkspace.revision, name: "Unadmitted work"
            )
        )
        XCTAssertNil(createdSession.session.pi.chatId)
        XCTAssertEqual(createdSession.session.pi.admission, .notAdmitted)

        let sessionRenameCommand = UUID()
        let renamedSession: SessionMutationResult = try await call(
            socket, method: AxoProtocol.Method.renameSession,
            params: SessionRenameParameters(
                target: WorkSessionTarget(machineId: machine, hostGeneration: generation,
                                           workspaceId: createdWorkspace.workspace.workspaceId,
                                           sessionId: createdSession.session.sessionId),
                commandId: sessionRenameCommand,
                expectedRevision: createdSession.revision, name: "Renamed work"
            )
        )
        XCTAssertEqual(renamedSession.session.name, "Renamed work")
        let sessionReceipt: CommandGetResult = try await call(
            socket, method: AxoProtocol.Method.getCommand,
            params: CommandGetParameters(target: listParameters.target, commandId: sessionRenameCommand)
        )
        guard case .work(let sessionCommit)? = sessionReceipt.receipt else {
            return XCTFail("Session mutation receipt must reconcile through command.get")
        }
        XCTAssertEqual(sessionCommit.revision, renamedSession.revision)

        let secondSession: SessionMutationResult = try await call(
            socket, method: AxoProtocol.Method.createSession,
            params: SessionCreateParameters(
                target: WorkWorkspaceTarget(machineId: machine, hostGeneration: generation,
                                             workspaceId: createdWorkspace.workspace.workspaceId),
                commandId: UUID(), expectedRevision: renamedSession.revision, name: "Second work"
            )
        )
        let firstPage: SessionListResult = try await call(
            socket, method: AxoProtocol.Method.listSessions,
            params: SessionListParameters(target: listParameters.target,
                                          workspaceId: createdWorkspace.workspace.workspaceId, limit: 1)
        )
        XCTAssertEqual(firstPage.sessions.count, 1)
        let nextCursor = try XCTUnwrap(firstPage.next)
        let secondPage: SessionListResult = try await call(
            socket, method: AxoProtocol.Method.listSessions,
            params: SessionListParameters(target: listParameters.target,
                                          workspaceId: createdWorkspace.workspace.workspaceId,
                                          cursor: nextCursor, limit: 1)
        )
        XCTAssertEqual(Set((firstPage.sessions + secondPage.sessions).map(\.sessionId)),
                       [createdSession.session.sessionId, secondSession.session.sessionId])
        let readSession: SessionGetResult = try await call(
            socket, method: AxoProtocol.Method.getSession,
            params: SessionGetParameters(target: WorkSessionTarget(
                machineId: machine, hostGeneration: generation,
                workspaceId: createdWorkspace.workspace.workspaceId,
                sessionId: createdSession.session.sessionId
            ))
        )
        XCTAssertEqual(readSession.session, renamedSession.session)

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
        let runtimeReceipt: CommandGetResult = try await call(
            socket, method: AxoProtocol.Method.getCommand,
            params: CommandGetParameters(target: listParameters.target, commandId: commandID)
        )
        guard case .runtime(let reference, let observation)? = runtimeReceipt.receipt else {
            return XCTFail("Runtime mutation receipt must reconcile through command.get")
        }
        XCTAssertEqual(reference, started.terminal.runtime)
        XCTAssertEqual(observation?.runtime, started.terminal.runtime)

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
        let unknownReceipt: CommandGetResult = try await call(
            socket, method: AxoProtocol.Method.getCommand,
            params: CommandGetParameters(target: listParameters.target, commandId: UUID())
        )
        XCTAssertNil(unknownReceipt.receipt, "A missing receipt is unknown, not rejection or permission to replay")
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
