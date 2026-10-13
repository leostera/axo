import Foundation

struct CentralJSON {
    let method: String
    var failure: AxoProtocolValidationError { .invalidResult(method: method) }
    static func validID(_ value: UUID) -> Bool { value.uuidString != "00000000-0000-0000-0000-000000000000" }
    static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.utf16.count <= 80 && value.trimmingCharacters(in: .whitespacesAndNewlines) == value &&
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func validPath(_ value: String) -> Bool { value.hasPrefix("/") && value.utf8.count <= 4096 && !value.utf8.contains(0) }
    func object(_ value: JSONValue, keys: Set<String>) throws -> [String: JSONValue] {
        guard case .object(let fields) = value, Set(fields.keys) == keys else { throw failure }
        return fields
    }
    func field(_ fields: [String: JSONValue], _ key: String) throws -> JSONValue {
        guard let value = fields[key] else { throw failure }; return value
    }
    func string(_ value: JSONValue) throws -> String { guard case .string(let value) = value else { throw failure }; return value }
    func boolean(_ value: JSONValue) throws -> Bool { guard case .bool(let value) = value else { throw failure }; return value }
    func integer(_ value: JSONValue) throws -> Int {
        guard case .number(let value) = value, value.isFinite, value.rounded() == value, abs(value) <= 9_007_199_254_740_991 else { throw failure }
        return Int(value)
    }
    func id(_ value: JSONValue) throws -> UUID {
        let raw = try string(value)
        guard raw.utf8.count == 36, let id = UUID(uuidString: raw), id.uuidString.lowercased() == raw.lowercased(), Self.validID(id) else { throw failure }
        return id
    }
    func optionalID(_ value: JSONValue) throws -> UUID? { value == .null ? nil : try id(value) }
    func revision(_ value: JSONValue) throws -> CentralRevision {
        guard let revision = CentralRevision(rawValue: try integer(value)) else { throw failure }; return revision
    }
    func array(_ value: JSONValue, maximum: Int, minimum: Int = 0) throws -> [JSONValue] {
        guard case .array(let values) = value, (minimum...maximum).contains(values.count) else { throw failure }; return values
    }
    func source(_ value: JSONValue) throws -> CentralSource {
        let f = try object(value, keys: ["machineId", "hostGeneration", "storeGeneration"])
        return try CentralSource(machine: MachineTarget(machineId: id(field(f, "machineId")), hostGeneration: id(field(f, "hostGeneration"))), storeGeneration: id(field(f, "storeGeneration")))
    }
    func lifecycle(_ value: JSONValue) throws -> CentralLifecycle {
        guard let result = CentralLifecycle(rawValue: try string(value)) else { throw failure }; return result
    }
    func workspace(_ value: JSONValue, revision limit: CentralRevision) throws -> CentralWorkspace {
        let f = try object(value, keys: ["workspaceId", "name", "directory", "lifecycle", "configRevision"])
        let name = try string(field(f, "name")), directory = try string(field(f, "directory")), revision = try revision(field(f, "configRevision"))
        guard Self.validName(name), Self.validPath(directory), revision <= limit else { throw failure }
        return try CentralWorkspace(workspaceId: id(field(f, "workspaceId")), name: name, directory: directory, lifecycle: lifecycle(field(f, "lifecycle")), configRevision: revision)
    }
    func session(_ value: JSONValue, revision limit: CentralRevision) throws -> CentralSession {
        let f = try object(value, keys: ["sessionId", "workspaceId", "name", "manualName", "lifecycle", "configRevision"])
        let name = try string(field(f, "name")), revision = try revision(field(f, "configRevision"))
        guard Self.validName(name), revision <= limit else { throw failure }
        return try CentralSession(sessionId: id(field(f, "sessionId")), workspaceId: optionalID(field(f, "workspaceId")), name: name, manualName: boolean(field(f, "manualName")), lifecycle: lifecycle(field(f, "lifecycle")), configRevision: revision)
    }
    func pane(_ value: JSONValue, revision limit: CentralRevision) throws -> CentralPane {
        let f = try object(value, keys: ["paneId", "sessionId", "role", "present", "ordinal", "configRevision"])
        let roleValue = try field(f, "role")
        guard case .object(let roleFields) = roleValue else { throw failure }
        let role: CentralPaneRole
        switch try string(field(roleFields, "kind")) {
        case "pi": _ = try object(roleValue, keys: ["kind"]); role = .pi
        case "accountShell": _ = try object(roleValue, keys: ["kind"]); role = .accountShell
        case "profileShell":
            _ = try object(roleValue, keys: ["kind", "profileId"])
            let profile = try string(field(roleFields, "profileId"))
            guard !profile.isEmpty, profile.utf8.count <= 80, profile.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) }) else { throw failure }
            role = .profileShell(profile)
        default: throw failure
        }
        let ordinal = try integer(field(f, "ordinal")), revision = try revision(field(f, "configRevision"))
        guard (0...31).contains(ordinal), revision <= limit else { throw failure }
        return try CentralPane(paneId: id(field(f, "paneId")), sessionId: id(field(f, "sessionId")), role: role, present: boolean(field(f, "present")), ordinal: ordinal, configRevision: revision)
    }
    func graph(_ value: JSONValue, revision: CentralRevision) throws -> CentralSessionGraph {
        let f = try object(value, keys: ["session", "panes"])
        let session = try session(field(f, "session"), revision: revision)
        let panes = try array(field(f, "panes"), maximum: 32, minimum: 2).map { try pane($0, revision: revision) }
        try graphIdentity(session, panes)
        return CentralSessionGraph(session: session, panes: panes)
    }
    func graphIdentity(_ session: CentralSession, _ panes: [CentralPane]) throws {
        guard Set(panes.map(\.paneId)).count == panes.count, Set(panes.map(\.ordinal)).count == panes.count,
              panes.allSatisfy({ $0.sessionId == session.sessionId }), panes.filter({ $0.role == .pi }).count == 1,
              panes.contains(where: { $0.role == .pi && $0.ordinal == 0 && $0.present }),
              panes.contains(where: { $0.role != .pi && $0.present }) else { throw failure }
    }
    func runtime(_ value: JSONValue) throws -> TerminalRuntime {
        let f = try object(value, keys: ["host_generation", "target", "runtime_generation"])
        let t = try object(field(f, "target"), keys: ["session_id", "pane_id"])
        return try TerminalRuntime(hostGeneration: id(field(f, "host_generation")), target: .init(sessionId: id(field(t, "session_id")), paneId: id(field(t, "pane_id"))), runtimeGeneration: id(field(f, "runtime_generation")))
    }
    func terminal(_ value: JSONValue) throws -> TerminalSnapshot {
        let f = try object(value, keys: ["runtime", "process", "attached", "backlog_bytes"])
        // Central terminal observations authorize attachment only while actually
        // owned and running. No stopped/predecessor snapshot is a live terminal.
        let p = try object(field(f, "process"), keys: ["kind", "pid"])
        let pid = try integer(field(p, "pid")), backlog = try integer(field(f, "backlog_bytes"))
        guard try string(field(p, "kind")) == "running", pid > 0, pid <= Int(Int32.max), (0...8192).contains(backlog) else { throw failure }
        return try TerminalSnapshot(runtime: runtime(field(f, "runtime")), process: .running(pid: pid), attached: boolean(field(f, "attached")), backlogBytes: backlog)
    }
    func view(_ value: JSONValue, source: CentralSource, revision: CentralRevision) throws -> CentralSessionView {
        let f = try object(value, keys: ["session", "panes", "readiness"])
        let session = try session(field(f, "session"), revision: revision)
        guard let readiness = CentralReadiness(rawValue: try string(field(f, "readiness"))) else { throw failure }
        let panes = try array(field(f, "panes"), maximum: 32, minimum: 2).map { value in
            let p = try object(value, keys: ["desired", "availability", "lastRuntime", "terminal"])
            let desired = try pane(field(p, "desired"), revision: revision)
            guard desired.present, let availability = CentralAvailability(rawValue: try string(field(p, "availability"))) else { throw failure }
            let lastValue = try field(p, "lastRuntime"), terminalValue = try field(p, "terminal")
            let last = lastValue == .null ? nil : try runtime(lastValue)
            let terminal = terminalValue == .null ? nil : try terminal(terminalValue)
            if let last { guard last.target.sessionId == desired.sessionId, last.target.paneId == desired.paneId else { throw failure } }
            if let terminal {
                guard availability == .live, terminal.runtime == last, terminal.runtime.hostGeneration == source.machine.hostGeneration else { throw failure }
            }
            return CentralPaneView(desired: desired, availability: availability, lastRuntime: last, terminal: terminal)
        }
        try graphIdentity(session, panes.map(\.desired))
        if readiness == .ready { guard panes.allSatisfy({ $0.availability == .live && $0.terminal != nil }) else { throw failure } }
        if readiness == .stopped { guard panes.allSatisfy({ $0.availability == .stopped }) else { throw failure } }
        return CentralSessionView(session: session, panes: panes, readiness: readiness)
    }
    func domain(_ value: JSONValue) throws -> CentralPageDomain {
        guard case .object(let f) = value else { throw failure }
        switch try string(field(f, "kind")) {
        case "workspaces": _ = try object(value, keys: ["kind"]); return .workspaces
        case "sessions": _ = try object(value, keys: ["kind", "workspaceId"]); return try .sessions(workspaceId: optionalID(field(f, "workspaceId")))
        default: throw failure
        }
    }
    func cursor(_ value: JSONValue) throws -> CentralCursor {
        let f = try object(value, keys: ["target", "revision", "domain", "after"])
        return try CentralCursor(source: source(field(f, "target")), revision: revision(field(f, "revision")), domain: domain(field(f, "domain")), after: id(field(f, "after")))
    }
    func subject(_ value: JSONValue) throws -> CentralSubject {
        guard case .object(let f) = value else { throw failure }
        switch try string(field(f, "kind")) {
        case "workspace": _ = try object(value, keys: ["kind", "workspaceId"]); return try .workspace(id(field(f, "workspaceId")))
        case "session": _ = try object(value, keys: ["kind", "workspaceId", "sessionId"]); return try .session(workspaceId: optionalID(field(f, "workspaceId")), sessionId: id(field(f, "sessionId")))
        default: throw failure
        }
    }
    func operation(_ value: JSONValue, revision limit: CentralRevision) throws -> CentralOperation {
        let f = try object(value, keys: ["kind", "accepted"]), a = try object(field(f, "accepted"), keys: ["commandId", "revision", "graph"])
        let command = try id(field(a, "commandId")), revision = try revision(field(a, "revision")), graphValue = try field(a, "graph")
        guard revision.rawValue > 0, revision <= limit else { throw failure }
        switch try string(field(f, "kind")) {
        case "createWorkspace":
            let w = try object(graphValue, keys: ["workspace", "initialSession"])
            let workspace = try workspace(field(w, "workspace"), revision: revision), session = try graph(field(w, "initialSession"), revision: revision)
            guard session.session.workspaceId == workspace.workspaceId else { throw failure }
            return .createWorkspace(.init(commandId: command, revision: revision, graph: .init(workspace: workspace, initialSession: session)))
        case "createSession", "createStandalone":
            let graph = try graph(graphValue, revision: revision)
            let accepted = CentralAccepted(commandId: command, revision: revision, graph: graph)
            if try string(field(f, "kind")) == "createStandalone" {
                guard graph.session.workspaceId == nil else { throw failure }; return .createStandalone(accepted)
            }
            guard graph.session.workspaceId != nil else { throw failure }; return .createSession(accepted)
        case "addShell":
            let pane = try pane(graphValue, revision: revision)
            guard pane.role != .pi, pane.present else { throw failure }
            return .addShell(.init(commandId: command, revision: revision, graph: pane))
        case "removeShell": return try .removeShell(.init(commandId: command, revision: revision, graph: id(graphValue)))
        case "setLifecycle": return try .setLifecycle(.init(commandId: command, revision: revision, graph: subject(graphValue)))
        default: throw failure
        }
    }
}

struct CentralResultParser {
    let request: CentralRequest
    func parse(_ value: JSONValue) throws -> CentralResponse {
        let json = CentralJSON(method: request.method)
        let f = try json.object(value, keys: ["hostGeneration", "storeGeneration", "revision", "value"])
        let host = try json.id(json.field(f, "hostGeneration")), store = try json.id(json.field(f, "storeGeneration")), revision = try json.revision(json.field(f, "revision"))
        guard host == request.machine.hostGeneration else { throw AxoProtocolValidationError.staleHost(expected: request.machine.hostGeneration, actual: host) }
        if let expected = request.source?.storeGeneration, store != expected { throw AxoProtocolValidationError.staleStore(expected: expected, actual: store) }
        let source = try CentralSource(machine: request.machine, storeGeneration: store), body = try json.field(f, "value")
        let payload: CentralPayload
        switch request.intent {
        case .bootstrap:
            let b = try json.object(body, keys: ["backendCompleteCreation", "schemaVersion"])
            guard try json.boolean(json.field(b, "backendCompleteCreation")), try json.integer(json.field(b, "schemaVersion")) == 3 else { throw json.failure }
            payload = .bootstrap
        case .session(let workspace, let id):
            let view = try json.view(body, source: source, revision: revision)
            guard view.session.sessionId == id, view.session.workspaceId == workspace else { throw json.failure }
            payload = .session(view)
        case .piHistory(let target, let readMode, let collection, let cursor, let limit):
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            guard try encoder.encode(value).count <= 48 * 1024 else { throw json.failure }
            payload = try .piHistory(json.piHistory(body, target: target, readMode: readMode, collection: collection, cursor: cursor, limit: limit))
        case .piSnapshot(let expected):
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            guard try encoder.encode(value).count <= 48 * 1024 else { throw json.failure }
            let observed = try json.piObservation(body, source: source, workspaceId: expected.workspaceId, sessionId: expected.sessionId)
            guard case .live(let actual, let state) = observed, actual == expected else { throw json.failure }
            payload = .piSnapshot(target: actual, state: state)
        case .piObservation(let workspace, let session):
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            guard try encoder.encode(value).count <= 48 * 1024 else { throw json.failure }
            payload = try .piObservation(json.piObservation(body, source: source, workspaceId: workspace, sessionId: session))
        case .page(let domain, let prior, let limit):
            let b = try json.object(body, keys: ["records", "cursor"]), values = try json.array(json.field(b, "records"), maximum: limit)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let recordBytes = try values.reduce(0) { try $0 + encoder.encode($1).count }
            guard recordBytes <= 48 * 1024 else { throw json.failure }
            if let prior { guard prior.revision == revision else { throw json.failure } }
            let cursorValue = try json.field(b, "cursor"), next = cursorValue == .null ? nil : try json.cursor(cursorValue)
            let ids: [UUID]
            switch domain {
            case .workspaces:
                let records = try values.map { try json.workspace($0, revision: revision) }
                ids = records.map(\.workspaceId); payload = .workspaces(records: records, cursor: next)
            case .sessions(let workspace):
                let records = try values.map { try json.view($0, source: source, revision: revision) }
                guard records.allSatisfy({ $0.session.workspaceId == workspace }) else { throw json.failure }
                ids = records.map { $0.session.sessionId }; payload = .sessions(records: records, cursor: next)
            }
            let ordered = ids.map { $0.uuidString.lowercased() }
            guard Set(ids).count == ids.count, ordered == ordered.sorted(), prior.map({ cursor in ids.allSatisfy { $0.uuidString.lowercased() > cursor.after.uuidString.lowercased() } }) ?? true else { throw json.failure }
            if let next { guard next.source == source, next.revision == revision, next.domain == domain, next.after == ids.last else { throw json.failure } }
        case .mutation(let command, let expectedRevision, let mutation):
            let (original, observation) = try operationBody(body, source: source, revision: revision, json: json)
            guard let original, original.commandId == command, original.revision.rawValue == expectedRevision.rawValue + 1 else { throw json.failure }
            try correlate(original, mutation, json: json)
            payload = .operation(original: original, observation: observation)
        case .operation(let command):
            let (original, observation) = try operationBody(body, source: source, revision: revision, json: json)
            guard original == nil || original?.commandId == command else { throw json.failure }
            payload = .operation(original: original, observation: observation)
        case .completion(_, _, let captured):
            let b = try json.object(body, keys: ["completed"])
            let completed = try json.array(json.field(b, "completed"), maximum: captured.count).map(json.runtime)
            guard completed.allSatisfy(captured.contains), completed.enumerated().allSatisfy({ i, item in !completed.prefix(i).contains(item) }) else { throw json.failure }
            payload = .completion(completed)
        }
        return CentralResponse(source: source, revision: revision, payload: payload)
    }
    private func operationBody(_ value: JSONValue, source: CentralSource, revision: CentralRevision, json: CentralJSON) throws -> (CentralOperation?, CentralSessionView?) {
        let b = try json.object(value, keys: ["operation", "session"])
        let originalValue = try json.field(b, "operation"), sessionValue = try json.field(b, "session")
        let original = originalValue == .null ? nil : try json.operation(originalValue, revision: revision)
        let session = sessionValue == .null ? nil : try json.view(sessionValue, source: source, revision: revision)
        if let session { guard session.session.sessionId == original?.observedSessionId else { throw json.failure } }
        return (original, session)
    }
    private func correlate(_ original: CentralOperation, _ mutation: CentralRequest.Mutation, json: CentralJSON) throws {
        switch (original, mutation) {
        case (.createWorkspace(let accepted), .workspace(let name, _)):
            // The daemon canonicalizes the selected path. Its original command
            // receipt owns that directory identity, not frontend path equality.
            guard accepted.graph.workspace.name == name else { throw json.failure }
        case (.createSession(let accepted), .session(let workspace, let name)), (.createStandalone(let accepted), .session(let workspace, let name)):
            guard accepted.graph.session.workspaceId == workspace, accepted.graph.session.name == name else { throw json.failure }
        case (.setLifecycle(let accepted), .lifecycle(let subject, _)):
            guard accepted.graph == subject else { throw json.failure }
        case (.addShell(let accepted), .add(_, let session)):
            guard accepted.graph.sessionId == session else { throw json.failure }
        case (.removeShell(let accepted), .remove(_, _, let pane)):
            guard accepted.graph == pane else { throw json.failure }
        default: throw json.failure
        }
    }
}
