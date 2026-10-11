import AxoProtocol
import Foundation

public struct AxoControlPlaneEndpoint: Equatable, Sendable {
    public static let production = try! AxoControlPlaneEndpoint("https://api.axo.leostera.dev")
    public static let accessAudience = "b4ce8a1f58bff7fd09c1d2b64fdbbd7a2098df4a0e46850b78caa05783676073"

    public let baseURL: URL

    public init(_ origin: String) throws {
        guard let url = URL(string: origin), url.scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/"
        else { throw ProtocolError.invalidEndpoint }
        baseURL = url
    }

    public var rpcURL: URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/v1/rpc"
        return components.url!
    }

    public func clientSocketURL(machineID: UUID) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = "wss"
        components.path = "/v1/machines/\(machineID.uuidString.lowercased())/client"
        return components.url!
    }
}

/// A structurally checked JWT for the new API's Access application, not the legacy relay.
/// This local audience/expiry check prevents credential mix-ups; Cloudflare and the Worker verify its signature.
public struct AxoControlPlaneAccessCookie: Equatable, Sendable {
    private let jwt: String
    public let expiresAt: Date

    public init(_ jwt: String, now: Date = .now) throws {
        let segments = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard jwt.utf8.count <= 16_384, segments.count == 3,
              segments.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy(Self.isBase64URLByte) }),
              let payload = Self.decodePayload(String(segments[1])),
              let claims = try? JSONDecoder().decode(AccessClaims.self, from: payload),
              claims.type == "app",
              claims.audiences.contains(AxoControlPlaneEndpoint.accessAudience),
              claims.exp > now.timeIntervalSince1970
        else { throw AccessCookieError.invalidOrExpired }
        self.jwt = jwt
        self.expiresAt = Date(timeIntervalSince1970: claims.exp)
    }

    var cookieHeaderValue: String { "CF_Authorization=\(jwt)" }
    public var valueForKeychainStorage: String { jwt }

    private struct AccessClaims: Decodable {
        enum Audience: Decodable {
            case one(String)
            case many([String])

            init(from decoder: Decoder) throws {
                let value = try decoder.singleValueContainer()
                if let single = try? value.decode(String.self) {
                    self = .one(single)
                } else {
                    self = .many(try value.decode([String].self))
                }
            }
        }

        let aud: Audience
        let exp: TimeInterval
        let type: String

        var audiences: Set<String> {
            switch aud {
            case .one(let value): [value]
            case .many(let values): Set(values)
            }
        }
    }

    private static func isBase64URLByte(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
    }

    private static func decodePayload(_ segment: String) -> Data? {
        var base64 = segment.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}

public enum AccessCookieError: Error, Equatable, Sendable, LocalizedError {
    case invalidOrExpired

    public var errorDescription: String? {
        "Sign in to the Axo private control plane again."
    }
}

public enum AxoControlPlaneSessionError: Error, Equatable, Sendable, LocalizedError {
    case machineOffline(UUID)
    case noSelectedMachine
    case superseded
    case protocolMismatch
    case unsupportedMethod(String)
    case invalidPageRequest

    public var errorDescription: String? {
        switch self {
        case .machineOffline: "This machine is offline. Runtime data shown here is historical."
        case .noSelectedMachine: "Select an online machine before listing runtimes."
        case .superseded: "The selected machine changed while the request was in flight."
        case .protocolMismatch: "The host and client do not support the same control protocol."
        case .unsupportedMethod(let method): "This host does not support \(method)."
        case .invalidPageRequest: "The work-record page request does not match its captured scope."
        }
    }
}

/// Authenticated discovery, runtime, work-record, and managed-Pi RPCs. Mutations are sent once; uncertain outcomes require receipt reconciliation.
public actor AxoControlPlaneSession {
    private let endpoint: AxoControlPlaneEndpoint
    private let accessCookie: AxoControlPlaneAccessCookie
    private let rpc: AxoJSONRPCClient
    private var connection: AxoJSONRPCWebSocketConnection?
    private var target: MachineTarget?
    private var negotiatedMethods = Set<String>()
    private var operationID = UUID()

    public init(
        endpoint: AxoControlPlaneEndpoint = .production,
        accessCookie: AxoControlPlaneAccessCookie,
        rpc: AxoJSONRPCClient = AxoJSONRPCClient()
    ) {
        self.endpoint = endpoint
        self.accessCookie = accessCookie
        self.rpc = rpc
    }

    public func discoverMachines() async throws -> MachineListResult {
        let value = try await rpc.callHTTP(
            endpoint: endpoint,
            accessCookie: accessCookie,
            method: AxoProtocol.Method.listMachines,
            parameters: EmptyRPCParameters()
        )
        return try AxoProtocolResultValidator.machineList(value)
    }

    public func connect(to machine: MachineSummary) async throws -> RuntimeListResult {
        guard machine.online, let hostGeneration = machine.hostGeneration else {
            throw AxoControlPlaneSessionError.machineOffline(machine.machineId)
        }
        let destination = MachineTarget(machineId: machine.machineId, hostGeneration: hostGeneration)
        let thisOperation = UUID()
        operationID = thisOperation
        let oldConnection = connection
        connection = nil
        negotiatedMethods = []
        target = destination
        await oldConnection?.close()
        try requireCurrent(thisOperation, destination: destination)

        do {
            let directory = try await discoverMachines()
            try requireCurrent(thisOperation, destination: destination)
            guard let currentMachine = directory.machines.first(where: { $0.machineId == machine.machineId }),
                  currentMachine.online, let currentGeneration = currentMachine.hostGeneration else {
                throw AxoControlPlaneSessionError.machineOffline(machine.machineId)
            }
            guard currentGeneration == hostGeneration else {
                throw AxoProtocolValidationError.staleHost(expected: hostGeneration, actual: currentGeneration)
            }
        } catch {
            if operationID == thisOperation { target = nil }
            throw error
        }

        let newConnection: AxoJSONRPCWebSocketConnection
        do {
            newConnection = try rpc.openWebSocket(
                endpoint: endpoint,
                machineID: machine.machineId,
                accessCookie: accessCookie
            )
        } catch {
            if operationID == thisOperation { target = nil }
            throw error
        }
        connection = newConnection
        do {
            let negotiation = try await newConnection.request(
                method: AxoProtocol.Method.negotiate,
                parameters: NegotiationParameters()
            )
            let capabilities: ProtocolNegotiationResult
            do { capabilities = try AxoProtocolResultValidator.negotiation(negotiation) }
            catch { throw AxoControlPlaneSessionError.protocolMismatch }
            try requireCurrent(thisOperation, destination: destination, connection: newConnection)
            negotiatedMethods = Set(capabilities.methods)

            let runtimes = try await newConnection.request(
                method: AxoProtocol.Method.listRuntimes,
                parameters: RuntimeListParameters(target: destination)
            )
            let result = try AxoProtocolResultValidator.runtimeList(runtimes, target: destination)
            try requireCurrent(thisOperation, destination: destination)
            return result
        } catch {
            if operationID == thisOperation {
                connection = nil
                negotiatedMethods = []
                target = nil
            }
            await newConnection.close()
            throw error
        }
    }

    public func supports(method: String) -> Bool {
        connection != nil && negotiatedMethods.contains(method)
    }

    public func listWorkspaceDirectories() async throws -> WorkspaceDirectoryListResult {
        let destination = try selectedTarget()
        let (_, value) = try await requestCurrent(
            method: AxoProtocol.Method.listWorkspaceDirectories,
            parameters: WorkspaceDirectoryListParameters(target: destination)
        )
        return try AxoProtocolResultValidator.workspaceDirectories(value, target: destination)
    }

    public func listWorkspaces(
        cursor: WorkPageCursor? = nil,
        limit: Int = AxoProtocol.maximumPageSize
    ) async throws -> WorkspaceListResult {
        let (destination, value) = try await requestCurrent(
            method: AxoProtocol.Method.listWorkspaces,
            parameters: WorkspaceListParameters(target: try selectedTarget(), cursor: cursor, limit: limit),
            cursor: cursor,
            scope: .workspaces,
            limit: limit
        )
        return try AxoProtocolResultValidator.workspaceList(value, target: destination, cursor: cursor, limit: limit)
    }

    public func listSessions(
        workspaceID: UUID? = nil,
        cursor: WorkPageCursor? = nil,
        limit: Int = AxoProtocol.maximumPageSize
    ) async throws -> SessionListResult {
        let scope = WorkCursorScope.sessions(workspaceId: workspaceID)
        let (destination, value) = try await requestCurrent(
            method: AxoProtocol.Method.listSessions,
            parameters: SessionListParameters(target: try selectedTarget(), workspaceId: workspaceID, cursor: cursor, limit: limit),
            cursor: cursor,
            scope: scope,
            limit: limit
        )
        return try AxoProtocolResultValidator.sessionList(value, target: destination, workspaceID: workspaceID, cursor: cursor, limit: limit)
    }

    public func getSession(workspaceID: UUID?, sessionID: UUID) async throws -> SessionGetResult {
        let destination = try selectedTarget()
        let target = WorkSessionTarget(
            machineId: destination.machineId,
            hostGeneration: destination.hostGeneration,
            workspaceId: workspaceID,
            sessionId: sessionID
        )
        let (_, value) = try await requestCurrent(
            method: AxoProtocol.Method.getSession,
            parameters: SessionGetParameters(target: target)
        )
        return try AxoProtocolResultValidator.sessionGet(value, target: target)
    }

    /// Reconcile an uncertain command by its stable command ID; never resend it automatically.
    public func getCommand(commandID: UUID) async throws -> CommandGetResult {
        let destination = try selectedTarget()
        let (_, value) = try await requestCurrent(
            method: AxoProtocol.Method.getCommand,
            parameters: CommandGetParameters(target: destination, commandId: commandID)
        )
        return try AxoProtocolResultValidator.commandGet(value, target: destination)
    }

    public func createWorkspace(commandID: UUID = UUID(), expectedRevision: WorkRevision,
                                directoryID: String, name: String) async throws -> WorkspaceMutationResult {
        let destination = try selectedTarget()
        let parameters = WorkspaceCreateParameters(target: destination, commandId: commandID,
                                                   expectedRevision: expectedRevision, directoryId: directoryID, name: name)
        try AxoProtocolWorkRequestValidator.validate(parameters)
        let (_, value) = try await requestCurrent(method: AxoProtocol.Method.createWorkspace, parameters: parameters)
        return try AxoProtocolResultValidator.workspaceCreate(value, target: destination,
                                                             expectedRevision: expectedRevision, name: name,
                                                             directoryID: directoryID)
    }

    public func renameWorkspace(workspaceID: UUID, commandID: UUID = UUID(), expectedRevision: WorkRevision,
                                name: String) async throws -> WorkspaceMutationResult {
        let destination = try selectedTarget()
        let workTarget = WorkWorkspaceTarget(machineId: destination.machineId,
                                             hostGeneration: destination.hostGeneration, workspaceId: workspaceID)
        let parameters = WorkspaceRenameParameters(target: workTarget, commandId: commandID,
                                                   expectedRevision: expectedRevision, name: name)
        try AxoProtocolWorkRequestValidator.validate(parameters)
        let (_, value) = try await requestCurrent(method: AxoProtocol.Method.renameWorkspace, parameters: parameters)
        return try AxoProtocolResultValidator.workspaceRename(value, target: workTarget,
                                                             expectedRevision: expectedRevision, name: name)
    }

    public func createSession(workspaceID: UUID? = nil, commandID: UUID = UUID(), expectedRevision: WorkRevision,
                              name: String) async throws -> SessionMutationResult {
        let destination = try selectedTarget()
        let workTarget = WorkSessionDestination(machineId: destination.machineId,
                                               hostGeneration: destination.hostGeneration, workspaceId: workspaceID)
        let parameters = SessionCreateParameters(target: workTarget, commandId: commandID,
                                                 expectedRevision: expectedRevision, name: name)
        try AxoProtocolWorkRequestValidator.validate(parameters)
        let (_, value) = try await requestCurrent(method: AxoProtocol.Method.createSession, parameters: parameters)
        return try AxoProtocolResultValidator.sessionCreate(value, target: workTarget,
                                                            expectedRevision: expectedRevision, name: name)
    }

    public func renameSession(workspaceID: UUID?, sessionID: UUID, commandID: UUID = UUID(),
                              expectedRevision: WorkRevision, name: String) async throws -> SessionMutationResult {
        let destination = try selectedTarget()
        let workTarget = WorkSessionTarget(machineId: destination.machineId,
                                           hostGeneration: destination.hostGeneration,
                                           workspaceId: workspaceID, sessionId: sessionID)
        let parameters = SessionRenameParameters(target: workTarget, commandId: commandID,
                                                 expectedRevision: expectedRevision, name: name)
        try AxoProtocolWorkRequestValidator.validate(parameters)
        let (_, value) = try await requestCurrent(method: AxoProtocol.Method.renameSession, parameters: parameters)
        return try AxoProtocolResultValidator.sessionRename(value, target: workTarget,
                                                           expectedRevision: expectedRevision, name: name)
    }

    public func startPiSession(target: PiSessionTarget, commandID: UUID = UUID(),
                               persistence: PiPersistence = .fresh) async throws -> PiSessionStartResult {
        guard let destination = self.target, let activeConnection = connection else {
            throw AxoControlPlaneSessionError.noSelectedMachine
        }
        guard target.machineId == destination.machineId, target.hostGeneration == destination.hostGeneration,
              [target.machineId, target.hostGeneration, target.sessionId, target.paneId, commandID]
                .allSatisfy(isNonNilUUID), target.workspaceId.map(isNonNilUUID) ?? true else {
            throw AxoProtocolValidationError.invalidResult(method: AxoProtocol.Method.startSession)
        }
        if case .resume(let chatId, let previousRuntime) = persistence {
            guard isNonNilUUID(chatId), isNonNilUUID(previousRuntime.hostGeneration),
                  isNonNilUUID(previousRuntime.runtimeGeneration),
                  previousRuntime.target.sessionId == target.sessionId,
                  previousRuntime.target.paneId == target.paneId else {
                throw AxoProtocolValidationError.invalidResult(method: AxoProtocol.Method.startSession)
            }
        }
        try requireSupported(AxoProtocol.Method.startSession)
        let thisOperation = operationID
        let value = try await activeConnection.request(
            method: AxoProtocol.Method.startSession,
            parameters: PiSessionStartParameters(target: target, commandId: commandID, persistence: persistence)
        )
        let result = try PiProtocolValidator.sessionStart(value, target: target, commandId: commandID,
                                                          persistence: persistence)
        try requireCurrent(thisOperation, destination: destination, connection: activeConnection)
        return result
    }

    public func getPiChat(_ chat: PiChatTarget, readMode: PiReadMode = .live) async throws -> PiChatSnapshot {
        let (destination, activeConnection) = try captureChat(chat, method: AxoProtocol.Method.getChat)
        let thisOperation = operationID
        let value = try await activeConnection.request(
            method: AxoProtocol.Method.getChat,
            parameters: PiChatGetParameters(target: chat, readMode: readMode)
        )
        let result = try PiProtocolValidator.chatGet(value, target: chat, readMode: readMode)
        try requireCurrent(thisOperation, destination: destination, connection: activeConnection)
        return result
    }

    public func getPiChatHistory(_ chat: PiChatTarget, readMode: PiReadMode = .live,
                                 limit: Int = 50, cursor: PiHistoryCursor? = nil) async throws -> PiChatHistoryResult {
        let (destination, activeConnection) = try captureChat(chat, method: AxoProtocol.Method.getChatHistory)
        guard (1...50).contains(limit), cursor.map({ $0.target == chat && $0.readMode == readMode }) ?? true else {
            throw AxoProtocolValidationError.invalidResult(method: AxoProtocol.Method.getChatHistory)
        }
        let thisOperation = operationID
        let value = try await activeConnection.request(
            method: AxoProtocol.Method.getChatHistory,
            parameters: PiChatHistoryParameters(target: chat, readMode: readMode, limit: limit, cursor: cursor)
        )
        let result = try PiProtocolValidator.chatHistory(value, target: chat, readMode: readMode,
                                                        limit: limit, cursor: cursor)
        try requireCurrent(thisOperation, destination: destination, connection: activeConnection)
        return result
    }

    public func getPiToolOutput(_ chat: PiChatTarget, entryID: String, toolCallID: String,
                                offset: Int, readMode: PiReadMode = .live,
                                limit: Int = PiProtocolValidator.maximumToolOutputBytes) async throws -> PiToolOutputResult {
        let (destination, activeConnection) = try captureChat(chat, method: AxoProtocol.Method.getToolOutput)
        guard (1...PiProtocolValidator.maximumToolOutputBytes).contains(limit),
              (0...9_007_199_254_740_991).contains(offset) else {
            throw AxoProtocolValidationError.invalidResult(method: AxoProtocol.Method.getToolOutput)
        }
        let thisOperation = operationID
        let value = try await activeConnection.request(
            method: AxoProtocol.Method.getToolOutput,
            parameters: PiToolOutputParameters(target: chat, readMode: readMode, entryId: entryID,
                                               toolCallId: toolCallID, offset: offset, limit: limit)
        )
        let result = try PiProtocolValidator.toolOutput(value, target: chat, readMode: readMode,
                                                        entryId: entryID, toolCallId: toolCallID,
                                                        offset: offset, limit: limit)
        try requireCurrent(thisOperation, destination: destination, connection: activeConnection)
        return result
    }

    public func sendPiMessage(_ chat: PiChatTarget, commandID: UUID = UUID(), text: String) async throws -> PiMutationResult {
        guard PiProtocolValidator.validMessageText(text) else {
            throw AxoProtocolValidationError.invalidResult(method: AxoProtocol.Method.sendChatMessage)
        }
        return try await mutatePiChat(chat, commandID: commandID, operation: .sendMessage,
                                      method: AxoProtocol.Method.sendChatMessage,
                                      parameters: PiChatTextParameters(target: chat, commandId: commandID, text: text))
    }

    public func steerPiChat(_ chat: PiChatTarget, commandID: UUID = UUID(), interactionID: UUID,
                            text: String) async throws -> PiMutationResult {
        guard PiProtocolValidator.validMessageText(text), isNonNilUUID(interactionID) else {
            throw AxoProtocolValidationError.invalidResult(method: AxoProtocol.Method.sendChatSteeringMessage)
        }
        return try await mutatePiChat(chat, commandID: commandID, operation: .sendSteeringMessage,
                                      method: AxoProtocol.Method.sendChatSteeringMessage,
                                      parameters: PiChatSteeringParameters(target: chat, commandId: commandID,
                                                                          interactionId: interactionID, text: text))
    }

    public func cancelPiTurn(_ chat: PiChatTarget, commandID: UUID = UUID(),
                             interactionID: UUID) async throws -> PiMutationResult {
        guard isNonNilUUID(interactionID) else {
            throw AxoProtocolValidationError.invalidResult(method: AxoProtocol.Method.cancelChatTurn)
        }
        return try await mutatePiChat(chat, commandID: commandID, operation: .cancelTurn,
                                      method: AxoProtocol.Method.cancelChatTurn,
                                      parameters: PiChatCancelParameters(target: chat, commandId: commandID,
                                                                        interactionId: interactionID))
    }

    public func answerPiQuestion(_ chat: PiChatTarget, commandID: UUID = UUID(),
                                 interactionID: UUID, questionID: UUID, optionID: UUID) async throws -> PiMutationResult {
        guard [interactionID, questionID, optionID].allSatisfy(isNonNilUUID) else {
            throw AxoProtocolValidationError.invalidResult(method: AxoProtocol.Method.answerChatQuestion)
        }
        return try await mutatePiChat(chat, commandID: commandID, operation: .answerQuestion,
                                      method: AxoProtocol.Method.answerChatQuestion,
                                      parameters: PiChatAnswerParameters(target: chat, commandId: commandID,
                                                                        interactionId: interactionID,
                                                                        questionId: questionID, optionId: optionID))
    }

    public func setPiChatViewing(_ chat: PiChatTarget, commandID: UUID = UUID(), leaseID: UUID,
                                 viewing: Bool, ttlSeconds: Int = 45) async throws -> PiMutationResult {
        guard isNonNilUUID(leaseID), (1...120).contains(ttlSeconds) else {
            throw AxoProtocolValidationError.invalidResult(method: AxoProtocol.Method.setChatViewing)
        }
        return try await mutatePiChat(chat, commandID: commandID, operation: .setViewing,
                                      method: AxoProtocol.Method.setChatViewing,
                                      parameters: PiChatViewingParameters(target: chat, commandId: commandID,
                                                                         leaseId: leaseID, viewing: viewing,
                                                                         ttlSeconds: ttlSeconds))
    }

    private func mutatePiChat<Parameters: Encodable & Sendable>(_ chat: PiChatTarget, commandID: UUID,
                                                                  operation: PiChatOperation, method: String,
                                                                  parameters: Parameters) async throws -> PiMutationResult {
        let (destination, activeConnection) = try captureChat(chat, method: method)
        guard isNonNilUUID(commandID) else { throw AxoProtocolValidationError.invalidResult(method: method) }
        let thisOperation = operationID
        let value = try await activeConnection.request(method: method, parameters: parameters)
        let result = try PiProtocolValidator.mutation(value, target: chat, commandId: commandID,
                                                       operation: operation, method: method)
        try requireCurrent(thisOperation, destination: destination, connection: activeConnection)
        return result
    }

    private func captureChat(_ chat: PiChatTarget, method: String) throws -> (MachineTarget, AxoJSONRPCWebSocketConnection) {
        guard let destination = target, let activeConnection = connection else {
            throw AxoControlPlaneSessionError.noSelectedMachine
        }
        guard chat.machineId == destination.machineId, chat.hostGeneration == destination.hostGeneration,
              [chat.machineId, chat.hostGeneration, chat.sessionId, chat.paneId,
               chat.runtimeHostGeneration, chat.runtimeGeneration, chat.chatId].allSatisfy(isNonNilUUID),
              chat.workspaceId.map(isNonNilUUID) ?? true else {
            throw AxoProtocolValidationError.invalidResult(method: method)
        }
        try requireSupported(method)
        return (destination, activeConnection)
    }

    private func isNonNilUUID(_ id: UUID) -> Bool {
        id != UUID(uuidString: "00000000-0000-0000-0000-000000000000")
    }

    private func requireSupported(_ method: String) throws {
        guard negotiatedMethods.contains(method) else {
            throw AxoControlPlaneSessionError.unsupportedMethod(method)
        }
    }

    public func refreshRuntimes(after: UUID? = nil) async throws -> RuntimeListResult {
        guard let destination = target, let activeConnection = connection else {
            throw AxoControlPlaneSessionError.noSelectedMachine
        }
        let thisOperation = operationID
        let runtimes = try await activeConnection.request(
            method: AxoProtocol.Method.listRuntimes,
            parameters: RuntimeListParameters(target: destination, after: after)
        )
        let result = try AxoProtocolResultValidator.runtimeList(runtimes, target: destination)
        try requireCurrent(thisOperation, destination: destination, connection: activeConnection)
        return result
    }

    public func disconnect() async {
        operationID = UUID()
        target = nil
        negotiatedMethods = []
        let oldConnection = connection
        connection = nil
        await oldConnection?.close()
    }

    private func selectedTarget() throws -> MachineTarget {
        guard let target, connection != nil else { throw AxoControlPlaneSessionError.noSelectedMachine }
        return target
    }

    private func requestCurrent<Parameters: Encodable & Sendable>(
        method: String,
        parameters: Parameters,
        cursor: WorkPageCursor? = nil,
        scope: WorkCursorScope? = nil,
        limit: Int = AxoProtocol.maximumPageSize
    ) async throws -> (MachineTarget, JSONValue) {
        let destination = try selectedTarget()
        guard negotiatedMethods.contains(method) else {
            throw AxoControlPlaneSessionError.unsupportedMethod(method)
        }
        guard (1...AxoProtocol.maximumPageSize).contains(limit),
              cursor == nil || (cursor?.target == destination && cursor?.scope == scope) else {
            throw AxoControlPlaneSessionError.invalidPageRequest
        }
        guard let activeConnection = connection else { throw AxoControlPlaneSessionError.noSelectedMachine }
        let thisOperation = operationID
        let value = try await activeConnection.request(method: method, parameters: parameters)
        try requireCurrent(thisOperation, destination: destination, connection: activeConnection)
        return (destination, value)
    }

    private func requireCurrent(
        _ expectedOperation: UUID,
        destination: MachineTarget,
        connection expectedConnection: AxoJSONRPCWebSocketConnection? = nil
    ) throws {
        guard operationID == expectedOperation, target == destination else {
            throw AxoControlPlaneSessionError.superseded
        }
        if let expectedConnection, connection !== expectedConnection {
            throw AxoControlPlaneSessionError.superseded
        }
    }
}
