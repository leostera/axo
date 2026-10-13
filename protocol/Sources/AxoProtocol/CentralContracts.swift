import Foundation

/// Identity of one central authority, not just one running helper. A fresh store
/// on the same machine must never inherit cached revisions or pending commands.
public struct CentralSource: Equatable, Sendable {
    public let machine: MachineTarget
    public let storeGeneration: UUID
    public init(machine: MachineTarget, storeGeneration: UUID) throws {
        guard CentralJSON.validID(machine.machineId), CentralJSON.validID(machine.hostGeneration), CentralJSON.validID(storeGeneration) else {
            throw AxoProtocolValidationError.invalidParameters(method: "axo.state.get")
        }
        self.machine = machine; self.storeGeneration = storeGeneration
    }
    var json: JSONValue {
        .object(["machineId": .id(machine.machineId), "hostGeneration": .id(machine.hostGeneration), "storeGeneration": .id(storeGeneration)])
    }
}

public struct CentralRevision: Equatable, Comparable, Sendable {
    public let rawValue: Int
    public init?(rawValue: Int) {
        guard (0...9_007_199_254_740_991).contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
public enum CentralLifecycle: String, Sendable { case open, archived }
public enum CentralPaneRole: Equatable, Sendable { case pi, accountShell, profileShell(String) }
public enum CentralAvailability: String, Sendable { case live, materializing, restarting, stopping, stopped, blocked }
public enum CentralReadiness: String, Sendable { case ready, materializing, blocked, stopped }
public struct CentralWorkspace: Equatable, Sendable {
    public let workspaceId: UUID
    public let name: String
    public let directory: String
    public let lifecycle: CentralLifecycle
    public let configRevision: CentralRevision
}
public struct CentralSession: Equatable, Sendable {
    public let sessionId: UUID
    public let workspaceId: UUID?
    public let name: String
    public let manualName: Bool
    public let lifecycle: CentralLifecycle
    public let configRevision: CentralRevision
}
public struct CentralPane: Equatable, Sendable {
    public let paneId: UUID
    public let sessionId: UUID
    public let role: CentralPaneRole
    public let present: Bool
    public let ordinal: Int
    public let configRevision: CentralRevision
}
public struct CentralPaneView: Equatable, Sendable {
    public let desired: CentralPane
    public let availability: CentralAvailability
    public let lastRuntime: TerminalRuntime?
    public let terminal: TerminalSnapshot?
}
public struct CentralSessionView: Equatable, Sendable {
    public let session: CentralSession
    public let panes: [CentralPaneView]
    public let readiness: CentralReadiness
    public var terminals: [TerminalSnapshot] { panes.compactMap(\.terminal) }
}
public struct CentralSessionGraph: Equatable, Sendable {
    public let session: CentralSession
    public let panes: [CentralPane]
}
public struct CentralWorkspaceGraph: Equatable, Sendable {
    public let workspace: CentralWorkspace
    public let initialSession: CentralSessionGraph
}
public enum CentralSubject: Equatable, Sendable {
    case workspace(UUID)
    case session(workspaceId: UUID?, sessionId: UUID)
    var json: JSONValue {
        switch self {
        case .workspace(let id): .object(["kind": .string("workspace"), "workspaceId": .id(id)])
        case .session(let workspace, let id): .object(["kind": .string("session"), "workspaceId": .nullableID(workspace), "sessionId": .id(id)])
        }
    }
}
public enum CentralPageDomain: Equatable, Sendable {
    case workspaces
    case sessions(workspaceId: UUID?)
    var json: JSONValue {
        switch self {
        case .workspaces: .object(["kind": .string("workspaces")])
        case .sessions(let workspace): .object(["kind": .string("sessions"), "workspaceId": .nullableID(workspace)])
        }
    }
}
/// Only the parser can mint a continuation. Its source, revision, scope and last
/// record remain inseparable; null is never encoded as a request continuation.
public struct CentralCursor: Equatable, Sendable {
    public let source: CentralSource
    public let revision: CentralRevision
    public let domain: CentralPageDomain
    public let after: UUID
    var json: JSONValue {
        .object(["target": source.json, "revision": .number(Double(revision.rawValue)), "domain": domain.json, "after": .id(after)])
    }
}
public struct CentralAccepted<Graph: Equatable & Sendable>: Equatable, Sendable {
    public let commandId: UUID
    public let revision: CentralRevision
    public let graph: Graph
}
public enum CentralOperation: Equatable, Sendable {
    case createWorkspace(CentralAccepted<CentralWorkspaceGraph>)
    case createSession(CentralAccepted<CentralSessionGraph>)
    case createStandalone(CentralAccepted<CentralSessionGraph>)
    case addShell(CentralAccepted<CentralPane>)
    case removeShell(CentralAccepted<UUID>)
    case setLifecycle(CentralAccepted<CentralSubject>)
    public var commandId: UUID {
        switch self {
        case .createWorkspace(let value): value.commandId
        case .createSession(let value), .createStandalone(let value): value.commandId
        case .addShell(let value): value.commandId
        case .removeShell(let value): value.commandId
        case .setLifecycle(let value): value.commandId
        }
    }
    public var revision: CentralRevision {
        switch self {
        case .createWorkspace(let value): value.revision
        case .createSession(let value), .createStandalone(let value): value.revision
        case .addShell(let value): value.revision
        case .removeShell(let value): value.revision
        case .setLifecycle(let value): value.revision
        }
    }
    var observedSessionId: UUID? {
        switch self {
        case .createWorkspace(let value): value.graph.initialSession.session.sessionId
        case .createSession(let value), .createStandalone(let value): value.graph.session.sessionId
        case .addShell(let value): value.graph.sessionId
        default: nil
        }
    }
}
public enum CentralPayload: Equatable, Sendable {
    case bootstrap
    case workspaces(records: [CentralWorkspace], cursor: CentralCursor?)
    case sessions(records: [CentralSessionView], cursor: CentralCursor?)
    case session(CentralSessionView)
    case piObservation(CentralPiObservation)
    case piSnapshot(target: CentralPiBindingTarget, state: CentralPiLiveState)
    case piHistory(CentralPiHistoryPage)
    case piTool(CentralPiToolChunk)
    case operation(original: CentralOperation?, observation: CentralSessionView?)
    case completion([TerminalRuntime])
}
public struct CentralResponse: Equatable, Sendable {
    public let source: CentralSource
    public let revision: CentralRevision
    public let payload: CentralPayload
}

extension JSONValue {
    static func id(_ value: UUID) -> Self { .string(value.uuidString.lowercased()) }
    static func nullableID(_ value: UUID?) -> Self { value.map(Self.id) ?? .null }
}
