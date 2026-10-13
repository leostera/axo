import Foundation

/// Closed requests paired with their result parser. Callers cannot construct raw
/// params, omit nullable workspace scope, or validate against a later selection.
public struct CentralRequest: Sendable {
    public let method: String
    public let parameters: JSONValue
    public let machine: MachineTarget
    public let source: CentralSource?
    let intent: Intent
    /// Durable intent identity, distinct from the transport request ID. Reads
    /// (including original-operation lookup and completion) carry no mutation.
    public var commandId: UUID? {
        if case .mutation(let id, _, _) = intent { return id }
        if case .submitPi(let capture) = intent { return capture.commandId }
        if case .deletion(_, let commandId) = intent { return commandId }
        return nil
    }
    enum Intent: Sendable {
        case bootstrap
        case submitPi(CentralPiCommandCapture)
        case piCommand(CentralPiCommandCapture)
        case page(CentralPageDomain, CentralCursor?, Int)
        case session(UUID?, UUID)
        case piObservation(UUID?, UUID)
        case piSnapshot(CentralPiBindingTarget)
        case piHistory(CentralPiBindingTarget, CentralPiHistoryReadMode, CentralPiHistoryCollection, CentralPiHistoryCursor?, Int)
        case piTool(target: CentralPiBindingTarget, readMode: CentralPiHistoryReadMode, entryId: String, toolCallId: String, cursor: CentralPiToolCursor?, limit: Int)
        case mutation(UUID, CentralRevision, Mutation)
        case operation(UUID)
        case deletion(CentralSessionDeletionIntent, UUID)
        case completion(UUID?, UUID, [TerminalRuntime])
    }
    enum Mutation: Sendable {
        case workspace(String, String)
        case session(UUID?, String)
        case lifecycle(CentralSubject, CentralLifecycle)
        case add(UUID?, UUID)
        case remove(UUID?, UUID, UUID)
        case renameWorkspace(UUID, String)
        case renameSession(UUID?, UUID, String)
    }
    private init(method: String, parameters: JSONValue, machine: MachineTarget, source: CentralSource?, intent: Intent) {
        self.method = method; self.parameters = parameters; self.machine = machine; self.source = source; self.intent = intent
    }
    public static let readMethods: Set<String> = ["axo.state.get", "axo.state.workspace.list", "axo.state.session.list", "axo.state.session.get", "axo.state.chat.observe", "axo.state.chat.get", "axo.state.chat.history", "axo.state.chat.tool.get", "axo.state.chat.command.get", "axo.state.operation.get"]
    public static let piSubmissionMethods: Set<String> = ["axo.state.chat.command.submit", "axo.state.chat.command.get"]
    public static func bootstrap(machine: MachineTarget) throws -> Self {
        let method = "axo.state.get"
        try ids([machine.machineId, machine.hostGeneration], method: method)
        return Self(method: method, parameters: .object(["target": .object(["machineId": .id(machine.machineId), "hostGeneration": .id(machine.hostGeneration)])]), machine: machine, source: nil, intent: .bootstrap)
    }
    public static func workspaces(source: CentralSource, cursor: CentralCursor? = nil, limit: Int = 8) throws -> Self {
        try page(source: source, domain: .workspaces, cursor: cursor, limit: limit)
    }
    public static func sessions(source: CentralSource, workspaceId: UUID?, cursor: CentralCursor? = nil, limit: Int = 8) throws -> Self {
        try page(source: source, domain: .sessions(workspaceId: workspaceId), cursor: cursor, limit: limit)
    }
    private static func page(source: CentralSource, domain: CentralPageDomain, cursor: CentralCursor?, limit: Int) throws -> Self {
        let method = domain == .workspaces ? "axo.state.workspace.list" : "axo.state.session.list"
        guard (1...50).contains(limit), cursor.map({ $0.source == source && $0.domain == domain }) ?? true else {
            throw AxoProtocolValidationError.invalidParameters(method: method)
        }
        var fields: [String: JSONValue] = ["target": source.json, "limit": .number(Double(limit))]
        if case .sessions(let workspace) = domain {
            try ids(workspace.map { [$0] } ?? [], method: method)
            fields["workspaceId"] = .nullableID(workspace)
        }
        if let cursor { fields["cursor"] = cursor.json }
        return Self(method: method, parameters: .object(fields), machine: source.machine, source: source, intent: .page(domain, cursor, limit))
    }
    public static func session(source: CentralSource, workspaceId: UUID?, sessionId: UUID) throws -> Self {
        let method = "axo.state.session.get"
        let target = try sessionTarget(source, workspaceId, sessionId, method: method)
        return Self(method: method, parameters: .object(["target": target]), machine: source.machine, source: source, intent: .session(workspaceId, sessionId))
    }
    public static func observePi(source: CentralSource, workspaceId: UUID?, sessionId: UUID) throws -> Self {
        let method = "axo.state.chat.observe"
        let target = try sessionTarget(source, workspaceId, sessionId, method: method)
        return Self(method: method, parameters: .object(["target": target]), machine: source.machine, source: source, intent: .piObservation(workspaceId, sessionId))
    }
    public static func piSnapshot(target: CentralPiBindingTarget) throws -> Self {
        let method = "axo.state.chat.get"
        guard target.runtime.hostGeneration == target.source.machine.hostGeneration else {
            throw AxoProtocolValidationError.invalidParameters(method: method)
        }
        return try Self(method: method, parameters: .object(["target": target.json]), machine: target.source.machine, source: target.source, intent: .piSnapshot(target))
    }
    public static func piHistory(target: CentralPiBindingTarget, readMode: CentralPiHistoryReadMode, collection: CentralPiHistoryCollection = .branch, cursor: CentralPiHistoryCursor? = nil, limit: Int = 8) throws -> Self {
        let method = "axo.state.chat.history"
        guard (1...50).contains(limit), readMode != .live || target.runtime.hostGeneration == target.source.machine.hostGeneration,
              cursor.map({ $0.target == target && $0.readMode == readMode && $0.collection == collection }) ?? true else {
            throw AxoProtocolValidationError.invalidParameters(method: method)
        }
        var fields: [String: JSONValue] = ["target": try target.json, "readMode": .string(readMode.rawValue), "collection": .string(collection.rawValue), "limit": .number(Double(limit))]
        if let cursor { fields["cursor"] = try cursor.json }
        return Self(method: method, parameters: .object(fields), machine: target.source.machine, source: target.source, intent: .piHistory(target, readMode, collection, cursor, limit))
    }
    public static func piTool(target: CentralPiBindingTarget, readMode: CentralPiHistoryReadMode, entryId: String, toolCallId: String, cursor: CentralPiToolCursor? = nil, limit: Int = 8192) throws -> Self {
        let method = "axo.state.chat.tool.get"
        let validID: (String) -> Bool = { !$0.isEmpty && $0.utf8.count <= 128 && !$0.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) }
        guard validID(entryId), validID(toolCallId), (4...8192).contains(limit),
              readMode != .live || target.runtime.hostGeneration == target.source.machine.hostGeneration,
              cursor.map({ $0.target == target && $0.readMode == readMode && $0.entryId == entryId && $0.toolCallId == toolCallId }) ?? true else {
            throw AxoProtocolValidationError.invalidParameters(method: method)
        }
        var fields: [String: JSONValue] = ["target": try target.json, "readMode": .string(readMode.rawValue), "entryId": .string(entryId), "toolCallId": .string(toolCallId), "limit": .number(Double(limit))]
        if let cursor { fields["cursor"] = try cursor.json }
        return Self(method: method, parameters: .object(fields), machine: target.source.machine, source: target.source,
                    intent: .piTool(target: target, readMode: readMode, entryId: entryId, toolCallId: toolCallId, cursor: cursor, limit: limit))
    }
    public static func capturePi(target: CentralPiBindingTarget, commandId: UUID, expectedRevision: CentralRevision, action: CentralPiAction) throws -> CentralPiCommandCapture {
        let method = "axo.state.chat.command.submit"
        try ids([commandId] + action.identifiers, method: method)
        guard target.runtime.hostGeneration == target.source.machine.hostGeneration, expectedRevision.rawValue < 9_007_199_254_740_991 else { throw AxoProtocolValidationError.invalidParameters(method: method) }
        if let text = action.text {
            let scalars = text.unicodeScalars.drop(while: { $0.properties.isWhitespace })
            guard text.utf8.count <= 65_536, let first = scalars.first, first != "/" else { throw AxoProtocolValidationError.invalidParameters(method: method) }
        }
        let capture = CentralPiCommandCapture(target: target, commandId: commandId, expectedRevision: expectedRevision, action: action)
        // Same encoder/framing as the client, including a bounded transport ID.
        let lookup = try JSONValue.object(["target": target.source.json, "capture": capture.parameters])
        for (name, params) in [(method, try capture.parameters), ("axo.state.chat.command.get", lookup)] {
            let bounded = RPCRequest(id: .string(String(repeating: "0", count: 36)), method: name, params: params)
            guard try JSONEncoder().encode(bounded).count <= AxoProtocolCodec.maximumFrameBytes else { throw AxoProtocolValidationError.invalidParameters(method: method) }
        }
        return capture
    }
    public static func submitPi(_ capture: CentralPiCommandCapture) throws -> Self {
        try Self(method: "axo.state.chat.command.submit", parameters: capture.parameters, machine: capture.target.source.machine, source: capture.target.source, intent: .submitPi(capture))
    }
    public static func piCommand(source: CentralSource, capture: CentralPiCommandCapture) throws -> Self {
        let method = "axo.state.chat.command.get"
        guard source.machine.machineId == capture.target.source.machine.machineId, source.storeGeneration == capture.target.source.storeGeneration else { throw AxoProtocolValidationError.invalidParameters(method: method) }
        return Self(method: method, parameters: try .object(["target": source.json, "capture": capture.parameters]), machine: source.machine, source: source, intent: .piCommand(capture))
    }
    public static func createWorkspace(source: CentralSource, commandId: UUID, expectedRevision: CentralRevision, name: String, directoryPath: String) throws -> Self {
        try mutate(source, commandId, expectedRevision, .workspace(name, directoryPath))
    }
    public static func createSession(source: CentralSource, workspaceId: UUID?, commandId: UUID, expectedRevision: CentralRevision, name: String = "New Session") throws -> Self {
        try mutate(source, commandId, expectedRevision, .session(workspaceId, name))
    }
    public static func setLifecycle(source: CentralSource, subject: CentralSubject, lifecycle: CentralLifecycle, commandId: UUID, expectedRevision: CentralRevision) throws -> Self {
        try mutate(source, commandId, expectedRevision, .lifecycle(subject, lifecycle))
    }
    public static func addShell(source: CentralSource, workspaceId: UUID?, sessionId: UUID, commandId: UUID, expectedRevision: CentralRevision) throws -> Self {
        try mutate(source, commandId, expectedRevision, .add(workspaceId, sessionId))
    }
    public static func removeShell(source: CentralSource, workspaceId: UUID?, sessionId: UUID, paneId: UUID, commandId: UUID, expectedRevision: CentralRevision) throws -> Self {
        try mutate(source, commandId, expectedRevision, .remove(workspaceId, sessionId, paneId))
    }
    public static func renameWorkspace(source: CentralSource, workspaceId: UUID, commandId: UUID, expectedRevision: CentralRevision, name: String) throws -> Self {
        try mutate(source, commandId, expectedRevision, .renameWorkspace(workspaceId, name))
    }
    public static func renameSession(source: CentralSource, workspaceId: UUID?, sessionId: UUID, commandId: UUID, expectedRevision: CentralRevision, name: String) throws -> Self {
        try mutate(source, commandId, expectedRevision, .renameSession(workspaceId, sessionId, name))
    }
    private static func mutate(_ source: CentralSource, _ command: UUID, _ revision: CentralRevision, _ mutation: Mutation) throws -> Self {
        var fields: [String: JSONValue] = ["target": source.json, "commandId": .id(command), "expectedRevision": .number(Double(revision.rawValue))]
        let method: String
        switch mutation {
        case .workspace(let name, let directory):
            method = "axo.state.workspace.create"
            guard CentralJSON.validName(name), CentralJSON.validPath(directory) else { throw AxoProtocolValidationError.invalidParameters(method: method) }
            fields["name"] = .string(name); fields["directoryPath"] = .string(directory)
        case .session(let workspace, let name):
            method = "axo.state.session.create"
            try ids(workspace.map { [$0] } ?? [], method: method)
            guard CentralJSON.validName(name) else { throw AxoProtocolValidationError.invalidParameters(method: method) }
            fields["workspaceId"] = .nullableID(workspace); fields["name"] = .string(name)
        case .lifecycle(let subject, let lifecycle):
            method = "axo.state.lifecycle.set"
            switch subject {
            case .workspace(let id): try ids([id], method: method)
            case .session(let workspace, let id): try ids([id] + (workspace.map { [$0] } ?? []), method: method)
            }
            fields["subject"] = subject.json; fields["lifecycle"] = .string(lifecycle.rawValue)
        case .add(let workspace, let session):
            method = "axo.state.pane.add"
            fields["target"] = try sessionTarget(source, workspace, session, method: method)
        case .remove(let workspace, let session, let pane):
            method = "axo.state.pane.remove"
            try ids([pane], method: method)
            fields["target"] = try sessionTarget(source, workspace, session, method: method)
            fields["paneId"] = .id(pane)
        case .renameWorkspace(let workspace, let name):
            method = "axo.state.workspace.rename"
            try ids([workspace], method: method)
            guard CentralJSON.validName(name) else { throw AxoProtocolValidationError.invalidParameters(method: method) }
            fields["workspaceId"] = .id(workspace); fields["name"] = .string(name)
        case .renameSession(let workspace, let session, let name):
            method = "axo.state.session.rename"
            fields["target"] = try sessionTarget(source, workspace, session, method: method)
            guard CentralJSON.validName(name) else { throw AxoProtocolValidationError.invalidParameters(method: method) }
            fields["name"] = .string(name)
        }
        try ids([command], method: method)
        guard revision.rawValue < 9_007_199_254_740_991 else { throw AxoProtocolValidationError.invalidParameters(method: method) }
        return Self(method: method, parameters: .object(fields), machine: source.machine, source: source, intent: .mutation(command, revision, mutation))
    }
    public static func deleteSessions(source: CentralSource, commandId: UUID, expectedRevision: CentralRevision, sessions: [CentralSessionAddress]) throws -> Self {
        let method = "axo.state.session.delete"
        try ids([commandId] + sessions.flatMap { [$0.sessionId] + ($0.workspaceId.map { [$0] } ?? []) }, method: method)
        guard (1...32).contains(sessions.count), expectedRevision.rawValue < 9_007_199_254_740_991,
              Set(sessions.map(\.sessionId)).count == sessions.count else {
            throw AxoProtocolValidationError.invalidParameters(method: method)
        }
        let intent = CentralSessionDeletionIntent(target: source, sessions: sessions, expectedRevision: expectedRevision)
        let parameters = JSONValue.object(["target": source.json, "commandId": .id(commandId), "expectedRevision": .number(Double(expectedRevision.rawValue)), "sessions": .array(sessions.map(\.json))])
        return Self(method: method, parameters: parameters, machine: source.machine, source: source, intent: .deletion(intent, commandId))
    }
    public static func operation(source: CentralSource, commandId: UUID) throws -> Self {
        let method = "axo.state.operation.get"
        try ids([commandId], method: method)
        return Self(method: method, parameters: .object(["target": source.json, "commandId": .id(commandId)]), machine: source.machine, source: source, intent: .operation(commandId))
    }
    public static func completion(source: CentralSource, workspaceId: UUID?, sessionId: UUID, runtimes: [TerminalRuntime]) throws -> Self {
        let method = "axo.state.session.completion"
        let target = try sessionTarget(source, workspaceId, sessionId, method: method)
        guard (1...32).contains(runtimes.count), runtimes.allSatisfy({ $0.target.sessionId == sessionId }),
              runtimes.enumerated().allSatisfy({ index, runtime in !runtimes.prefix(index).contains(runtime) }) else {
            throw AxoProtocolValidationError.invalidParameters(method: method)
        }
        for runtime in runtimes { try ids([runtime.hostGeneration, runtime.runtimeGeneration, runtime.target.sessionId, runtime.target.paneId], method: method) }
        let values = try runtimes.map { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0)) }
        return Self(method: method, parameters: .object(["target": target, "runtimes": .array(values)]), machine: source.machine, source: source, intent: .completion(workspaceId, sessionId, runtimes))
    }
    private static func sessionTarget(_ source: CentralSource, _ workspace: UUID?, _ session: UUID, method: String) throws -> JSONValue {
        try ids([session] + (workspace.map { [$0] } ?? []), method: method)
        return .object(["machineId": .id(source.machine.machineId), "hostGeneration": .id(source.machine.hostGeneration), "storeGeneration": .id(source.storeGeneration), "workspaceId": .nullableID(workspace), "sessionId": .id(session)])
    }
    private static func ids(_ values: [UUID], method: String) throws {
        guard values.allSatisfy(CentralJSON.validID) else { throw AxoProtocolValidationError.invalidParameters(method: method) }
    }
    public func parseResult(_ value: JSONValue) throws -> CentralResponse {
        try CentralResultParser(request: self).parse(value)
    }
}
