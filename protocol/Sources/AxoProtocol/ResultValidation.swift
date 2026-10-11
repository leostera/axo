import Foundation

public enum AxoProtocolValidationError: Error, Equatable, Sendable, LocalizedError {
    case invalidResult(method: String)
    case invalidParameters(method: String)
    case staleHost(expected: UUID, actual: UUID)

    public var errorDescription: String? {
        switch self {
        case .invalidResult(let method): "Invalid result for \(method)."
        case .invalidParameters(let method): "Invalid parameters for \(method)."
        case .staleHost: "The machine restarted. Refresh discovery and runtimes."
        }
    }
}

/// Runtime validation for method results; Codable decoding alone accepts unknown fields and invalid domain values.
public enum AxoProtocolResultValidator {
    public static func negotiation(_ value: JSONValue) throws -> ProtocolNegotiationResult {
        let method = AxoProtocol.Method.negotiate
        guard let fields = object(value, keys: ["protocolVersion", "methods", "deliveryCredits"]),
              let version = integer(fields["protocolVersion"]),
              version == AxoProtocol.version,
              case .array(let methodsValue)? = fields["methods"],
              !methodsValue.isEmpty, methodsValue.count <= AxoProtocol.maximumAdvertisedMethodCount,
              let methods = methodsValue.asStrings,
              methods.allSatisfy({ $0.hasPrefix("axo.") && $0.utf16.count <= 128 }),
              Set(methods).count == methods.count,
              methods.contains(AxoProtocol.Method.listRuntimes),
              let credits = object(fields["deliveryCredits"], keys: ["frames", "bytes"]),
              let frames = integer(credits["frames"]), frames == AxoProtocol.deliveryCreditFrameCount,
              let bytes = integer(credits["bytes"]), bytes == AxoProtocol.deliveryCreditBytes
        else { throw invalid(method) }

        return try decode(value, as: ProtocolNegotiationResult.self, method: method)
    }

    public static func machineList(_ value: JSONValue) throws -> MachineListResult {
        let method = AxoProtocol.Method.listMachines
        guard let result = object(value, keys: ["machines"]),
              case .array(let machines)? = result["machines"],
              machines.count <= AxoProtocol.maximumMachineCount
        else { throw invalid(method) }

        var seen = Set<UUID>()
        for machineValue in machines {
            guard let machine = object(machineValue, keys: ["machineId", "label", "online", "hostGeneration"]),
                  let id = uuid(machine["machineId"]), seen.insert(id).inserted,
                  let label = string(machine["label"]), validLabel(label),
                  case .bool(let online)? = machine["online"],
                  let generationValue = machine["hostGeneration"]
            else { throw invalid(method) }

            let generation: UUID?
            if case .null = generationValue {
                generation = nil
            } else {
                guard let decodedGeneration = uuid(generationValue) else { throw invalid(method) }
                generation = decodedGeneration
            }
            guard online == (generation != nil) else { throw invalid(method) }
        }

        return try decode(value, as: MachineListResult.self, method: method)
    }

    public static func runtimeList(_ value: JSONValue, target: MachineTarget) throws -> RuntimeListResult {
        let method = AxoProtocol.Method.listRuntimes
        guard let result = object(value, keys: ["hostGeneration", "terminals", "next"]),
              let sourceGeneration = uuid(result["hostGeneration"]),
              case .array(let terminals)? = result["terminals"],
              terminals.count <= AxoProtocol.maximumPageSize,
              let next = result["next"],
              next.isNull || uuid(next) != nil
        else { throw invalid(method) }

        for terminal in terminals {
            guard let record = object(terminal, keys: ["runtime", "process", "attached", "backlog_bytes"]),
                  let runtime = object(record["runtime"], keys: ["host_generation", "target", "runtime_generation"]),
                  uuid(runtime["host_generation"]) != nil,
                  uuid(runtime["runtime_generation"]) != nil,
                  let runtimeTarget = object(runtime["target"], keys: ["session_id", "pane_id"]),
                  uuid(runtimeTarget["session_id"]) != nil,
                  uuid(runtimeTarget["pane_id"]) != nil,
                  validProcess(record["process"]),
                  case .bool? = record["attached"],
                  let backlog = integer(record["backlog_bytes"]),
                  (0...AxoProtocol.maximumBacklogBytes).contains(backlog)
            else { throw invalid(method) }
        }

        guard sourceGeneration == target.hostGeneration else {
            throw AxoProtocolValidationError.staleHost(expected: target.hostGeneration, actual: sourceGeneration)
        }
        return try decode(value, as: RuntimeListResult.self, method: method)
    }

    public static func workspaceDirectories(
        _ value: JSONValue,
        target: MachineTarget
    ) throws -> WorkspaceDirectoryListResult {
        let method = AxoProtocol.Method.listWorkspaceDirectories
        guard let fields = object(value, keys: ["hostGeneration", "directories"]),
              let hostGeneration = uuid(fields["hostGeneration"]),
              case .array(let values)? = fields["directories"], values.count <= 16
        else { throw invalid(method) }
        guard hostGeneration == target.hostGeneration else {
            throw AxoProtocolValidationError.staleHost(expected: target.hostGeneration, actual: hostGeneration)
        }
        var seen = Set<String>()
        for value in values {
            guard let directory = object(value, keys: ["directoryId", "name"]),
                  let id = string(directory["directoryId"]), validDirectoryID(id), seen.insert(id).inserted,
                  let name = string(directory["name"]), validWorkName(name)
            else { throw invalid(method) }
        }
        return try decode(value, as: WorkspaceDirectoryListResult.self, method: method)
    }

    public static func workspaceList(
        _ value: JSONValue,
        target: MachineTarget,
        cursor: WorkPageCursor? = nil,
        limit: Int = AxoProtocol.maximumPageSize
    ) throws -> WorkspaceListResult {
        let method = AxoProtocol.Method.listWorkspaces
        let expectedScope = WorkCursorScope.workspaces
        guard (1...AxoProtocol.maximumPageSize).contains(limit),
              let fields = object(value, keys: ["hostGeneration", "revision", "workspaces", "next"]),
              let hostGeneration = uuid(fields["hostGeneration"]),
              let revisionValue = integer(fields["revision"]),
              let revision = WorkRevision(rawValue: revisionValue),
              case .array(let workspaceValues)? = fields["workspaces"],
              workspaceValues.count <= limit,
              let next = fields["next"],
              next.isNull || validCursor(next, target: target, revision: revision, scope: expectedScope)
        else { throw invalid(method) }

        guard hostGeneration == target.hostGeneration else {
            throw AxoProtocolValidationError.staleHost(expected: target.hostGeneration, actual: hostGeneration)
        }
        if let cursor, cursor.target != target || cursor.scope != expectedScope || cursor.revision != revision {
            throw invalid(method)
        }

        var seen = Set<UUID>()
        for item in workspaceValues {
            guard let record = object(item, keys: ["workspaceId", "name", "directoryId"]),
                  let id = uuid(record["workspaceId"]), seen.insert(id).inserted,
                  let name = string(record["name"]), validWorkName(name),
                  let directoryID = string(record["directoryId"]), validDirectoryID(directoryID)
            else { throw invalid(method) }
        }
        guard validNextAfter(fields["next"], lastID: workspaceValues.last.flatMap(workspaceID)) else {
            throw invalid(method)
        }
        return try decode(value, as: WorkspaceListResult.self, method: method)
    }

    public static func sessionList(
        _ value: JSONValue,
        target: MachineTarget,
        workspaceID: UUID? = nil,
        cursor: WorkPageCursor? = nil,
        limit: Int = AxoProtocol.maximumPageSize
    ) throws -> SessionListResult {
        let method = AxoProtocol.Method.listSessions
        let expectedScope = WorkCursorScope.sessions(workspaceId: workspaceID)
        guard (1...AxoProtocol.maximumPageSize).contains(limit),
              let fields = object(value, keys: ["hostGeneration", "revision", "sessions", "next"]),
              let hostGeneration = uuid(fields["hostGeneration"]),
              let revisionValue = integer(fields["revision"]),
              let revision = WorkRevision(rawValue: revisionValue),
              case .array(let sessionValues)? = fields["sessions"],
              sessionValues.count <= limit,
              let next = fields["next"],
              next.isNull || validCursor(next, target: target, revision: revision, scope: expectedScope)
        else { throw invalid(method) }

        guard hostGeneration == target.hostGeneration else {
            throw AxoProtocolValidationError.staleHost(expected: target.hostGeneration, actual: hostGeneration)
        }
        if let cursor, cursor.target != target || cursor.scope != expectedScope || cursor.revision != revision {
            throw invalid(method)
        }

        var seen = Set<UUID>()
        for item in sessionValues {
            guard validWorkSession(item),
                  let session = object(item, keys: ["sessionId", "workspaceId", "name", "nameSource", "pi", "runtime"]),
                  let id = uuid(session["sessionId"]), seen.insert(id).inserted,
                  workspaceID == nil || uuid(session["workspaceId"]) == workspaceID
            else { throw invalid(method) }
        }
        guard validNextAfter(fields["next"], lastID: sessionValues.last.flatMap(sessionID)) else {
            throw invalid(method)
        }
        return try decode(value, as: SessionListResult.self, method: method)
    }

    public static func sessionGet(_ value: JSONValue, target: WorkSessionTarget) throws -> SessionGetResult {
        let method = AxoProtocol.Method.getSession
        guard let fields = object(value, keys: ["hostGeneration", "revision", "session"]),
              let hostGeneration = uuid(fields["hostGeneration"]),
              let revisionValue = integer(fields["revision"]), WorkRevision(rawValue: revisionValue) != nil,
              validWorkSession(fields["session"]),
              let session = workSessionFields(fields["session"]),
              uuid(session["sessionId"]) == target.sessionId,
              uuid(session["workspaceId"]) == target.workspaceId
        else { throw invalid(method) }
        guard hostGeneration == target.hostGeneration else {
            throw AxoProtocolValidationError.staleHost(expected: target.hostGeneration, actual: hostGeneration)
        }
        return try decode(value, as: SessionGetResult.self, method: method)
    }

    public static func workspaceCreate(
        _ value: JSONValue,
        target: MachineTarget,
        expectedRevision: WorkRevision,
        name: String,
        directoryID: String
    ) throws -> WorkspaceMutationResult {
        let method = AxoProtocol.Method.createWorkspace
        guard validWorkName(name), validDirectoryID(directoryID), expectedRevision.rawValue < WorkRevision.maximumSafeInteger else {
            throw invalid(method)
        }
        let result = try workspaceMutationResult(value, method: method, target: target, expectedRevision: expectedRevision)
        guard result.workspace.name == name, result.workspace.directoryId == directoryID else { throw invalid(method) }
        return result
    }

    public static func localWorkspaceCreate(
        _ value: JSONValue, target: MachineTarget, expectedRevision: WorkRevision, name: String, initialSessionName: String? = nil
    ) throws -> LocalWorkspaceMutationResult {
        let method = AxoProtocol.Method.createLocalWorkspace
        guard validWorkName(name), initialSessionName.map(validWorkName) ?? true,
              expectedRevision.rawValue < WorkRevision.maximumSafeInteger,
              case .object(var fields) = value else { throw invalid(method) }
        let sessionValue = fields.removeValue(forKey: "session")
        let result = try workspaceMutationResult(.object(fields), method: method, target: target, expectedRevision: expectedRevision)
        guard result.workspace.name == name,
              result.workspace.directoryId == "local_" + result.workspace.workspaceId.uuidString.lowercased()
        else { throw invalid(method) }
        let session: WorkSessionRecord?
        if let initialSessionName {
            guard let sessionValue, validWorkSession(sessionValue) else { throw invalid(method) }
            let parsed = try decode(sessionValue, as: WorkSessionRecord.self, method: method)
            guard parsed.workspaceId == result.workspace.workspaceId, parsed.name == initialSessionName else { throw invalid(method) }
            session = parsed
        } else {
            guard sessionValue == nil else { throw invalid(method) }
            session = nil
        }
        return LocalWorkspaceMutationResult(hostGeneration: result.hostGeneration, revision: result.revision,
                                            workspace: result.workspace, session: session)
    }

    public static func workspaceRename(
        _ value: JSONValue,
        target: WorkWorkspaceTarget,
        expectedRevision: WorkRevision,
        name: String
    ) throws -> WorkspaceMutationResult {
        let method = AxoProtocol.Method.renameWorkspace
        guard validWorkName(name), expectedRevision.rawValue < WorkRevision.maximumSafeInteger else { throw invalid(method) }
        let result = try workspaceMutationResult(
            value,
            method: method,
            target: MachineTarget(machineId: target.machineId, hostGeneration: target.hostGeneration),
            expectedRevision: expectedRevision
        )
        guard result.workspace.workspaceId == target.workspaceId, result.workspace.name == name else { throw invalid(method) }
        return result
    }

    public static func emptyStartupSession(_ value: JSONValue, parameters: EmptyStartupSessionParameters) throws -> SessionMutationResult {
        try AxoProtocolWorkRequestValidator.validate(parameters)
        let method = AxoProtocol.Method.createEmptyStartupSession
        let result = try sessionMutationResult(value, method: method, target: parameters.target, expectedRevision: parameters.expectedRevision)
        guard result.session.workspaceId == nil, result.session.name == parameters.name else { throw invalid(method) }
        return result
    }

    public static func sessionCreate(
        _ value: JSONValue,
        target: WorkSessionDestination,
        expectedRevision: WorkRevision,
        name: String
    ) throws -> SessionMutationResult {
        let method = AxoProtocol.Method.createSession
        guard validWorkName(name), expectedRevision.rawValue < WorkRevision.maximumSafeInteger else { throw invalid(method) }
        let result = try sessionMutationResult(
            value,
            method: method,
            target: MachineTarget(machineId: target.machineId, hostGeneration: target.hostGeneration),
            expectedRevision: expectedRevision
        )
        guard result.session.workspaceId == target.workspaceId, result.session.name == name else { throw invalid(method) }
        return result
    }

    public static func sessionRename(
        _ value: JSONValue,
        target: WorkSessionTarget,
        expectedRevision: WorkRevision,
        name: String
    ) throws -> SessionMutationResult {
        let method = AxoProtocol.Method.renameSession
        guard validWorkName(name), expectedRevision.rawValue < WorkRevision.maximumSafeInteger else { throw invalid(method) }
        let result = try sessionMutationResult(
            value,
            method: method,
            target: MachineTarget(machineId: target.machineId, hostGeneration: target.hostGeneration),
            expectedRevision: expectedRevision
        )
        guard result.session.sessionId == target.sessionId,
              result.session.workspaceId == target.workspaceId,
              result.session.name == name else { throw invalid(method) }
        return result
    }

    public static func shellPaneAdd(_ value: JSONValue, parameters: ShellPaneAddParameters) throws -> ShellPaneAddResult {
        let method = AxoProtocol.Method.addShellPane
        let source = MachineTarget(machineId: parameters.target.machineId, hostGeneration: parameters.target.hostGeneration)
        guard let fields = object(value, keys: ["hostGeneration", "receipt", "pane"]),
              uuid(fields["hostGeneration"]) == source.hostGeneration,
              let receipt = fields["receipt"], validPaneReceipt(receipt, machineID: source.machineId),
              let pane = fields["pane"], validShellPane(pane, sessionID: parameters.target.sessionId)
        else { throw invalid(method) }
        let result = try decode(value, as: ShellPaneAddResult.self, method: method)
        guard result.receipt.commandId == parameters.commandId,
              result.receipt.intent == .add(target: parameters.target, profileId: parameters.profileId),
              result.pane.paneId == result.receipt.paneId,
              result.pane.profileId == parameters.profileId,
              result.pane.runtime == result.receipt.runtime,
              result.receipt.disposition != .removed else { throw invalid(method) }
        return result
    }

    public static func commandGet(_ value: JSONValue, target: MachineTarget) throws -> CommandGetResult {
        let method = AxoProtocol.Method.getCommand
        guard let fields = object(value, keys: ["hostGeneration", "receipt"]),
              let hostGeneration = uuid(fields["hostGeneration"]),
              let receipt = fields["receipt"], validCommandReceipt(receipt, target: target)
        else { throw invalid(method) }
        guard hostGeneration == target.hostGeneration else {
            throw AxoProtocolValidationError.staleHost(expected: target.hostGeneration, actual: hostGeneration)
        }
        return try decode(value, as: CommandGetResult.self, method: method)
    }

    private static func workspaceMutationResult(
        _ value: JSONValue,
        method: String,
        target: MachineTarget,
        expectedRevision: WorkRevision
    ) throws -> WorkspaceMutationResult {
        guard let fields = object(value, keys: ["hostGeneration", "revision", "workspace"]),
              let hostGeneration = uuid(fields["hostGeneration"]),
              let revisionValue = integer(fields["revision"]),
              WorkRevision(rawValue: revisionValue)?.rawValue == expectedRevision.rawValue + 1,
              let workspace = object(fields["workspace"], keys: ["workspaceId", "name", "directoryId"]),
              uuid(workspace["workspaceId"]) != nil,
              let name = string(workspace["name"]), validWorkName(name),
              let directoryID = string(workspace["directoryId"]), validDirectoryID(directoryID)
        else { throw invalid(method) }
        guard hostGeneration == target.hostGeneration else {
            throw AxoProtocolValidationError.staleHost(expected: target.hostGeneration, actual: hostGeneration)
        }
        return try decode(value, as: WorkspaceMutationResult.self, method: method)
    }

    private static func sessionMutationResult(
        _ value: JSONValue,
        method: String,
        target: MachineTarget,
        expectedRevision: WorkRevision
    ) throws -> SessionMutationResult {
        guard let fields = object(value, keys: ["hostGeneration", "revision", "session"]),
              let hostGeneration = uuid(fields["hostGeneration"]),
              let revisionValue = integer(fields["revision"]),
              WorkRevision(rawValue: revisionValue)?.rawValue == expectedRevision.rawValue + 1,
              validWorkSession(fields["session"])
        else { throw invalid(method) }
        guard hostGeneration == target.hostGeneration else {
            throw AxoProtocolValidationError.staleHost(expected: target.hostGeneration, actual: hostGeneration)
        }
        return try decode(value, as: SessionMutationResult.self, method: method)
    }

    private static func validCommandReceipt(_ value: JSONValue, target: MachineTarget) -> Bool {
        if value.isNull { return true }
        guard case .object(let fields) = value, let kind = string(fields["kind"]) else { return false }
        switch kind {
        case "pi":
            guard Set(fields.keys) == ["kind", "receipt"],
                  let receipt = fields["receipt"], PiProtocolValidator.validReceipt(receipt, target: target) else { return false }
            return true
        case "pane":
            guard Set(fields.keys) == ["kind", "receipt"], let receipt = fields["receipt"] else { return false }
            return validPaneReceipt(receipt, machineID: target.machineId)
        case "work":
            guard Set(fields.keys) == ["kind", "committed"],
                  let committed = object(fields["committed"], keys: ["revision", "record"]),
                  let revision = integer(committed["revision"]), WorkRevision(rawValue: revision) != nil, revision > 0,
                  let record = committed["record"], validCommittedRecord(record)
            else { return false }
            return true
        case "runtime":
            guard Set(fields.keys) == ["kind", "runtime", "terminal"],
                  let runtimeValue = fields["runtime"], let runtime = validTerminalRuntime(runtimeValue),
                  let terminalValue = fields["terminal"]
            else { return false }
            if terminalValue.isNull { return true }
            guard validTerminal(terminalValue),
                  let terminalFields = object(terminalValue, keys: ["runtime", "process", "attached", "backlog_bytes"]),
                  let observedRuntime = validTerminalRuntime(terminalFields["runtime"])
            else { return false }
            return observedRuntime == runtime
        default:
            return false
        }
    }

    private static func validCommittedRecord(_ value: JSONValue) -> Bool {
        guard let fields = object(value, keys: ["kind", "record"]),
              let kind = string(fields["kind"]), let record = fields["record"]
        else { return false }
        switch kind {
        case "workspace":
            guard let workspace = object(record, keys: ["workspaceId", "name", "directoryId"]),
                  uuid(workspace["workspaceId"]) != nil,
                  let name = string(workspace["name"]), validWorkName(name),
                  let directoryID = string(workspace["directoryId"]), validDirectoryID(directoryID)
            else { return false }
            return true
        case "workspaceSession":
            guard let pair = object(record, keys: ["workspace", "session"]),
                  let workspaceValue = pair["workspace"], let sessionValue = pair["session"],
                  case .object(let workspace) = workspaceValue, case .object(let session) = sessionValue,
                  validCommittedRecord(.object(["kind": .string("workspace"), "record": workspaceValue])),
                  validCommittedRecord(.object(["kind": .string("session"), "record": sessionValue])) else { return false }
            return uuid(workspace["workspaceId"]) == uuid(session["workspaceId"])
        case "session":
            guard let session = object(record, keys: ["sessionId", "workspaceId", "name", "piPaneId"]),
                  uuid(session["sessionId"]) != nil, nullableWorkspace(session["workspaceId"]),
                  let name = string(session["name"]), validWorkName(name), uuid(session["piPaneId"]) != nil
            else { return false }
            return true
        default:
            return false
        }
    }

    private static func validTerminalRuntime(_ value: JSONValue?) -> TerminalRuntime? {
        guard let value,
              let fields = object(value, keys: ["host_generation", "target", "runtime_generation"]),
              uuid(fields["host_generation"]) != nil, uuid(fields["runtime_generation"]) != nil,
              let target = object(fields["target"], keys: ["session_id", "pane_id"]),
              uuid(target["session_id"]) != nil, uuid(target["pane_id"]) != nil
        else { return nil }
        return try? decode(value, as: TerminalRuntime.self, method: AxoProtocol.Method.getCommand)
    }

    private static func validCursor(
        _ value: JSONValue,
        target: MachineTarget,
        revision: WorkRevision,
        scope: WorkCursorScope
    ) -> Bool {
        guard let fields = object(value, keys: ["target", "revision", "scope", "after"]),
              let targetFields = object(fields["target"], keys: ["machineId", "hostGeneration"]),
              uuid(targetFields["machineId"]) == target.machineId,
              uuid(targetFields["hostGeneration"]) == target.hostGeneration,
              integer(fields["revision"]) == revision.rawValue,
              uuid(fields["after"]) != nil,
              let scopeFields = fields["scope"]
        else { return false }

        switch scope {
        case .workspaces:
            guard let value = object(scopeFields, keys: ["kind"]),
                  string(value["kind"]) == "workspaces" else { return false }
        case .sessions(let workspaceID):
            guard let value = object(scopeFields, keys: ["kind", "workspaceId"]),
                  string(value["kind"]) == "sessions" else { return false }
            if let workspaceID {
                guard uuid(value["workspaceId"]) == workspaceID else { return false }
            } else if case .null? = value["workspaceId"] {
                // The unfiltered cursor must explicitly carry a null filter.
            } else {
                return false
            }
        }
        return true
    }

    private static func validNextAfter(_ next: JSONValue?, lastID: UUID?) -> Bool {
        guard let next else { return false }
        if next.isNull { return true }
        guard let fields = object(next, keys: ["target", "revision", "scope", "after"]),
              let after = uuid(fields["after"]), let lastID else { return false }
        return after == lastID
    }

    private static func workspaceID(_ value: JSONValue) -> UUID? {
        guard let fields = object(value, keys: ["workspaceId", "name", "directoryId"]) else { return nil }
        return uuid(fields["workspaceId"])
    }

    private static func sessionID(_ value: JSONValue) -> UUID? {
        guard let fields = workSessionFields(value) else { return nil }
        return uuid(fields["sessionId"])
    }

    private static func nullableWorkspace(_ value: JSONValue?) -> Bool {
        value?.isNull == true || uuid(value) != nil
    }
    private static func validWorkSession(_ value: JSONValue?) -> Bool {
        guard let fields = workSessionFields(value),
              let sessionID = uuid(fields["sessionId"]), nullableWorkspace(fields["workspaceId"]),
              let name = string(fields["name"]), validWorkName(name),
              string(fields["nameSource"]) == "manual",
              case .object(let pi)? = fields["pi"],
              Set(pi.keys).isSuperset(of: ["paneId", "chatId", "admission"]),
              Set(pi.keys).isSubset(of: ["paneId", "chatId", "admission", "title"]),
              let paneID = uuid(pi["paneId"]),
              let admissionName = string(pi["admission"]), let admission = PiAdmission(rawValue: admissionName),
              let chatValue = pi["chatId"],
              let runtime = fields["runtime"]
        else { return false }
        if let title = pi["title"], title != .null {
            guard let name = string(title), validWorkName(name) else { return false }
        }
        if let panes = fields["shellPanes"] {
            guard case .array(let values) = panes, values.count <= 32 else { return false }
            var ids: Set<UUID> = [paneID]
            for pane in values {
                guard validShellPane(pane, sessionID: sessionID),
                      case .object(let fields) = pane,
                      let id = uuid(fields["paneId"]), ids.insert(id).inserted else { return false }
            }
        }
        if case .null = chatValue {
            guard admission == .notAdmitted else { return false }
        } else {
            guard uuid(chatValue) != nil, admission != .notAdmitted else { return false }
        }
        if case .null = runtime { return true }
        guard validTerminal(runtime),
              let terminal = object(runtime, keys: ["runtime", "process", "attached", "backlog_bytes"]),
              let reference = object(terminal["runtime"], keys: ["host_generation", "target", "runtime_generation"]),
              let target = object(reference["target"], keys: ["session_id", "pane_id"])
        else { return false }
        return uuid(target["session_id"]) == sessionID && uuid(target["pane_id"]) == paneID
    }

    private static func workSessionFields(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let fields)? = value else { return nil }
        let required: Set<String> = ["sessionId", "workspaceId", "name", "nameSource", "pi", "runtime"]
        guard Set(fields.keys) == required || Set(fields.keys) == required.union(["shellPanes"]) else { return nil }
        return fields
    }

    private static func validPaneReceipt(_ value: JSONValue, machineID: UUID) -> Bool {
        guard let receipt = object(value, keys: ["commandId", "intent", "paneId", "runtime", "disposition"]),
              uuid(receipt["commandId"]) != nil, let paneID = uuid(receipt["paneId"]),
              case .object(let intent)? = receipt["intent"], let operation = string(intent["operation"]),
              let target = object(intent["target"], keys: ["machineId", "hostGeneration", "workspaceId", "sessionId"]),
              uuid(target["machineId"]) == machineID, let host = uuid(target["hostGeneration"]),
              let workspace = target["workspaceId"], workspace.isNull || uuid(workspace) != nil,
              let sessionID = uuid(target["sessionId"]), let runtime = receipt["runtime"],
              case .object(let disposition)? = receipt["disposition"], let kind = string(disposition["kind"])
        else { return false }
        switch operation {
        case "addPane":
            guard Set(intent.keys) == ["operation", "target", "profileId"], let profile = intent["profileId"],
                  profile.isNull || string(profile).map(validDirectoryID) == true, kind != "removed" else { return false }
        case "removePane":
            guard Set(intent.keys) == ["operation", "target", "paneId", "runtime"], uuid(intent["paneId"]) == paneID,
                  intent["runtime"] == runtime, kind != "added" else { return false }
        default: return false
        }
        if kind == "rejected" {
            guard Set(disposition.keys) == ["kind", "reason"], let reason = string(disposition["reason"]),
                  ShellPaneRejection(rawValue: reason) != nil else { return false }
        } else {
            guard Set(disposition.keys) == ["kind"], ["prepared", "added", "removed"].contains(kind) else { return false }
        }
        if runtime.isNull { return kind != "added" }
        guard let reference = validTerminalRuntime(runtime) else { return false }
        return reference.hostGeneration == host && reference.target.sessionId == sessionID && reference.target.paneId == paneID
    }

    private static func validShellPane(_ value: JSONValue, sessionID: UUID) -> Bool {
        guard let pane = object(value, keys: ["paneId", "kind", "profileId", "state", "runtime", "terminal"]),
              let paneID = uuid(pane["paneId"]), string(pane["kind"]) == "shell",
              let profile = pane["profileId"], profile.isNull || string(profile).map(validDirectoryID) == true,
              let state = string(pane["state"]), ShellPaneState(rawValue: state) != nil,
              let runtime = pane["runtime"], let terminal = pane["terminal"] else { return false }
        if !runtime.isNull {
            guard let reference = object(runtime, keys: ["host_generation", "target", "runtime_generation"]),
                  uuid(reference["host_generation"]) != nil, uuid(reference["runtime_generation"]) != nil,
                  let target = object(reference["target"], keys: ["session_id", "pane_id"]),
                  uuid(target["session_id"]) == sessionID, uuid(target["pane_id"]) == paneID else { return false }
        }
        if !terminal.isNull {
            guard validTerminal(terminal), case .object(let fields) = terminal,
                  fields["runtime"] == runtime else { return false }
        }
        return true
    }

    private static func validTerminal(_ value: JSONValue?) -> Bool {
        guard let record = object(value, keys: ["runtime", "process", "attached", "backlog_bytes"]),
              let runtime = object(record["runtime"], keys: ["host_generation", "target", "runtime_generation"]),
              uuid(runtime["host_generation"]) != nil, uuid(runtime["runtime_generation"]) != nil,
              let target = object(runtime["target"], keys: ["session_id", "pane_id"]),
              uuid(target["session_id"]) != nil, uuid(target["pane_id"]) != nil,
              validProcess(record["process"]), case .bool? = record["attached"],
              let backlog = integer(record["backlog_bytes"]), (0...AxoProtocol.maximumBacklogBytes).contains(backlog)
        else { return false }
        return true
    }

    private static func validWorkName(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        return !scalars.isEmpty && scalars.count <= 80 &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            !scalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .surrogate })
    }

    private static func validDirectoryID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 &&
            value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }

    private static func validProcess(_ value: JSONValue?) -> Bool {
        guard case .object(let process)? = value, let kind = string(process["kind"]) else { return false }
        switch kind {
        case "starting", "failed", "recovery_required":
            return Set(process.keys) == ["kind"]
        case "running", "stopping":
            guard Set(process.keys) == ["kind", "pid"], let pid = integer(process["pid"]) else { return false }
            return pid > 0
        case "exited":
            return Set(process.keys) == ["kind", "wait_status"] && integer(process["wait_status"]) != nil
        default:
            return false
        }
    }

    private static func validLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf16.count <= AxoProtocol.maximumLabelLength
    }

    private static func object(_ value: JSONValue?, keys: Set<String>) -> [String: JSONValue]? {
        guard case .object(let fields)? = value, Set(fields.keys) == keys else { return nil }
        return fields
    }

    private static func uuid(_ value: JSONValue?) -> UUID? {
        guard case .string(let raw)? = value else { return nil }
        return UUID(uuidString: raw)
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard case .number(let number)? = value, number.isFinite,
              number.rounded(.towardZero) == number,
              abs(number) <= 9_007_199_254_740_991
        else { return nil }
        return Int(number)
    }

    private static func invalid(_ method: String) -> AxoProtocolValidationError {
        .invalidResult(method: method)
    }

    private static func decode<T: Decodable>(_ value: JSONValue, as type: T.Type, method: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
        } catch {
            throw invalid(method)
        }
    }
}

private extension Array where Element == JSONValue {
    var asStrings: [String]? {
        var values: [String] = []
        values.reserveCapacity(count)
        for value in self {
            guard case .string(let string) = value else { return nil }
            values.append(string)
        }
        return values
    }
}

private extension JSONValue {
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}
