import Foundation

public enum AxoProtocol {
    public static let version = 1
    public static let maximumMachineCount = 16
    public static let maximumLabelLength = 80
    public static let maximumPageSize = 50
    public static let maximumBacklogBytes = 8_192
    public static let maximumPendingCalls = 32
    public static let maximumAdvertisedMethodCount = 64
    public static let maximumCallDurationSeconds = 10.0
    public static let deliveryCreditFrameCount = 32
    public static let deliveryCreditBytes = 128 * 1_024

    public enum Method {
        public static let negotiate = "axo.protocol.negotiate"
        public static let registerMachine = "axo.machine.register"
        public static let heartbeat = "axo.machine.heartbeat"
        public static let listMachines = "axo.machine.list"
        public static let listRuntimes = "axo.runtime.list"
        public static let startApprovedRuntime = "axo.runtime.startApproved"
        public static let acknowledgeTransport = "axo.transport.ack"
        public static let listWorkspaceDirectories = "axo.workspace.directories"
        public static let listWorkspaces = "axo.workspace.list"
        public static let createWorkspace = "axo.workspace.create"
        public static let renameWorkspace = "axo.workspace.rename"
        public static let listSessions = "axo.session.list"
        public static let getSession = "axo.session.get"
        public static let createSession = "axo.session.create"
        public static let renameSession = "axo.session.rename"
        public static let getCommand = "axo.command.get"
        public static let startSession = "axo.session.start"
        public static let getChat = "axo.chat.get"
        public static let getChatHistory = "axo.chat.history"
        public static let getToolOutput = "axo.chat.getToolOutput"
        public static let sendChatMessage = "axo.chat.sendMessage"
        public static let sendChatSteeringMessage = "axo.chat.sendSteeringMessage"
        public static let cancelChatTurn = "axo.chat.cancelTurn"
        public static let answerChatQuestion = "axo.chat.answerQuestion"
        public static let setChatViewing = "axo.chat.setViewing"
    }
}

public struct EmptyRPCParameters: Codable, Equatable, Sendable {
    public init() {}
}

public struct NegotiationParameters: Codable, Equatable, Sendable {
    public let protocolVersion: Int

    public init() { protocolVersion = AxoProtocol.version }
}

public struct ProtocolNegotiationResult: Codable, Equatable, Sendable {
    public struct DeliveryCredits: Codable, Equatable, Sendable {
        public let frames: Int
        public let bytes: Int

        public init(frames: Int, bytes: Int) {
            self.frames = frames
            self.bytes = bytes
        }
    }

    public let protocolVersion: Int
    public let methods: [String]
    public let deliveryCredits: DeliveryCredits

    public init(protocolVersion: Int, methods: [String], deliveryCredits: DeliveryCredits) {
        self.protocolVersion = protocolVersion
        self.methods = methods
        self.deliveryCredits = deliveryCredits
    }
}

public struct MachineRegistration: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let machineId: UUID
    public let hostGeneration: UUID
    public let label: String

    public init(machineId: UUID, hostGeneration: UUID, label: String) {
        self.protocolVersion = AxoProtocol.version
        self.machineId = machineId
        self.hostGeneration = hostGeneration
        self.label = label
    }
}

public struct RegisteredMachine: Codable, Equatable, Sendable {
    public let leaseId: String
    public let hostGeneration: UUID

    public init(leaseId: String, hostGeneration: UUID) {
        self.leaseId = leaseId
        self.hostGeneration = hostGeneration
    }
}

public struct MachineHeartbeat: Codable, Equatable, Sendable {
    public let leaseId: String

    public init(leaseId: String) { self.leaseId = leaseId }
}

public struct MachineTarget: Codable, Equatable, Sendable {
    public let machineId: UUID
    public let hostGeneration: UUID

    public init(machineId: UUID, hostGeneration: UUID) {
        self.machineId = machineId
        self.hostGeneration = hostGeneration
    }
}

public struct TerminalTarget: Codable, Equatable, Sendable {
    public let machineId: UUID
    public let hostGeneration: UUID
    public let sessionId: UUID
    public let paneId: UUID

    public init(machineId: UUID, hostGeneration: UUID, sessionId: UUID, paneId: UUID) {
        self.machineId = machineId
        self.hostGeneration = hostGeneration
        self.sessionId = sessionId
        self.paneId = paneId
    }
}

public struct MachineSummary: Codable, Equatable, Sendable {
    public let machineId: UUID
    public let label: String
    public let online: Bool
    public let hostGeneration: UUID?

    public init(machineId: UUID, label: String, online: Bool, hostGeneration: UUID?) {
        self.machineId = machineId
        self.label = label
        self.online = online
        self.hostGeneration = hostGeneration
    }
}

public struct MachineListResult: Codable, Equatable, Sendable {
    public let machines: [MachineSummary]

    public init(machines: [MachineSummary]) { self.machines = machines }
}

public struct RuntimeListParameters: Codable, Equatable, Sendable {
    public let target: MachineTarget
    public let after: UUID?
    public let limit: Int

    public init(target: MachineTarget, after: UUID? = nil, limit: Int = AxoProtocol.maximumPageSize) {
        self.target = target
        self.after = after
        self.limit = limit
    }
}

public struct RuntimeStartParameters: Codable, Equatable, Sendable {
    public let target: TerminalTarget
    public let commandId: UUID
    public let profileId: String

    public init(target: TerminalTarget, commandId: UUID, profileId: String) {
        self.target = target
        self.commandId = commandId
        self.profileId = profileId
    }
}

public enum TerminalProcess: Equatable, Sendable, Codable {
    case starting
    case running(pid: Int)
    case stopping(pid: Int)
    case exited(waitStatus: Int)
    case failed
    case recoveryRequired

    private enum CodingKeys: String, CodingKey {
        case kind, pid, waitStatus = "wait_status"
    }

    private enum Kind: String, Codable {
        case starting, running, stopping, exited, failed
        case recoveryRequired = "recovery_required"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .starting: self = .starting
        case .running: self = .running(pid: try container.decode(Int.self, forKey: .pid))
        case .stopping: self = .stopping(pid: try container.decode(Int.self, forKey: .pid))
        case .exited: self = .exited(waitStatus: try container.decode(Int.self, forKey: .waitStatus))
        case .failed: self = .failed
        case .recoveryRequired: self = .recoveryRequired
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .starting:
            try container.encode(Kind.starting, forKey: .kind)
        case .running(let pid):
            try container.encode(Kind.running, forKey: .kind)
            try container.encode(pid, forKey: .pid)
        case .stopping(let pid):
            try container.encode(Kind.stopping, forKey: .kind)
            try container.encode(pid, forKey: .pid)
        case .exited(let waitStatus):
            try container.encode(Kind.exited, forKey: .kind)
            try container.encode(waitStatus, forKey: .waitStatus)
        case .failed:
            try container.encode(Kind.failed, forKey: .kind)
        case .recoveryRequired:
            try container.encode(Kind.recoveryRequired, forKey: .kind)
        }
    }
}

public struct TerminalRuntime: Codable, Equatable, Sendable {
    public struct Target: Codable, Equatable, Sendable {
        public let sessionId: UUID
        public let paneId: UUID

        public init(sessionId: UUID, paneId: UUID) {
            self.sessionId = sessionId
            self.paneId = paneId
        }

        private enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case paneId = "pane_id"
        }
    }

    public let hostGeneration: UUID
    public let target: Target
    public let runtimeGeneration: UUID

    public init(hostGeneration: UUID, target: Target, runtimeGeneration: UUID) {
        self.hostGeneration = hostGeneration
        self.target = target
        self.runtimeGeneration = runtimeGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case hostGeneration = "host_generation"
        case target
        case runtimeGeneration = "runtime_generation"
    }
}

public struct TerminalSnapshot: Codable, Equatable, Sendable {
    public let runtime: TerminalRuntime
    public let process: TerminalProcess
    public let attached: Bool
    public let backlogBytes: Int

    public init(runtime: TerminalRuntime, process: TerminalProcess, attached: Bool, backlogBytes: Int) {
        self.runtime = runtime
        self.process = process
        self.attached = attached
        self.backlogBytes = backlogBytes
    }

    private enum CodingKeys: String, CodingKey {
        case runtime, process, attached
        case backlogBytes = "backlog_bytes"
    }
}

public struct RuntimeListResult: Codable, Equatable, Sendable {
    public let hostGeneration: UUID
    public let terminals: [TerminalSnapshot]
    public let next: UUID?

    public init(hostGeneration: UUID, terminals: [TerminalSnapshot], next: UUID?) {
        self.hostGeneration = hostGeneration
        self.terminals = terminals
        self.next = next
    }
}

/// JavaScript-safe, nonnegative daemon work-record revision.
public struct WorkRevision: RawRepresentable, Codable, Comparable, Equatable, Sendable {
    public static let maximumSafeInteger = 9_007_199_254_740_991

    public let rawValue: Int

    public init?(rawValue: Int) {
        guard (0...Self.maximumSafeInteger).contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(Int.self)
        guard let revision = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Work revisions must be nonnegative safe integers.")
        }
        self = revision
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum WorkCursorScope: Codable, Equatable, Sendable {
    case workspaces
    case sessions(workspaceId: UUID?)

    private enum CodingKeys: String, CodingKey { case kind, workspaceId }
    private enum Kind: String, Codable { case workspaces, sessions }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .workspaces:
            guard Set(container.allKeys) == [.kind] else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Workspace cursor scope has unexpected fields.")
            }
            self = .workspaces
        case .sessions:
            guard container.contains(.workspaceId) else {
                throw DecodingError.keyNotFound(CodingKeys.workspaceId, .init(codingPath: decoder.codingPath, debugDescription: "Session cursor scope must bind its workspace filter."))
            }
            self = .sessions(workspaceId: try container.decodeIfPresent(UUID.self, forKey: .workspaceId))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .workspaces:
            try container.encode(Kind.workspaces, forKey: .kind)
        case .sessions(let workspaceId):
            try container.encode(Kind.sessions, forKey: .kind)
            if let workspaceId { try container.encode(workspaceId, forKey: .workspaceId) }
            else { try container.encodeNil(forKey: .workspaceId) }
        }
    }
}

public struct WorkPageCursor: Codable, Equatable, Sendable {
    public let target: MachineTarget
    public let revision: WorkRevision
    public let scope: WorkCursorScope
    public let after: UUID

    public init(target: MachineTarget, revision: WorkRevision, scope: WorkCursorScope, after: UUID) {
        self.target = target
        self.revision = revision
        self.scope = scope
        self.after = after
    }
}

public struct WorkspaceDirectoryListParameters: Encodable, Sendable {
    public let target: MachineTarget
    public init(target: MachineTarget) { self.target = target }
}

public struct WorkspaceDirectorySummary: Decodable, Equatable, Sendable, Identifiable {
    public var id: String { directoryId }
    public let directoryId: String
    public let name: String
}

public struct WorkspaceDirectoryListResult: Decodable, Equatable, Sendable {
    public let hostGeneration: UUID
    public let directories: [WorkspaceDirectorySummary]
}

public struct WorkspaceListParameters: Encodable, Sendable {
    public let target: MachineTarget
    public let cursor: WorkPageCursor?
    public let limit: Int

    public init(target: MachineTarget, cursor: WorkPageCursor? = nil, limit: Int = AxoProtocol.maximumPageSize) {
        self.target = target
        self.cursor = cursor
        self.limit = limit
    }
}

public struct SessionListParameters: Encodable, Sendable {
    public let target: MachineTarget
    public let workspaceId: UUID?
    public let cursor: WorkPageCursor?
    public let limit: Int

    public init(target: MachineTarget, workspaceId: UUID? = nil, cursor: WorkPageCursor? = nil, limit: Int = AxoProtocol.maximumPageSize) {
        self.target = target
        self.workspaceId = workspaceId
        self.cursor = cursor
        self.limit = limit
    }
}

public struct WorkSessionTarget: Codable, Equatable, Sendable {
    public let machineId: UUID
    public let hostGeneration: UUID
    public let workspaceId: UUID
    public let sessionId: UUID

    public init(machineId: UUID, hostGeneration: UUID, workspaceId: UUID, sessionId: UUID) {
        self.machineId = machineId
        self.hostGeneration = hostGeneration
        self.workspaceId = workspaceId
        self.sessionId = sessionId
    }
}

public struct SessionGetParameters: Encodable, Sendable {
    public let target: WorkSessionTarget
    public init(target: WorkSessionTarget) { self.target = target }
}

public struct WorkWorkspaceTarget: Codable, Equatable, Sendable {
    public let machineId: UUID
    public let hostGeneration: UUID
    public let workspaceId: UUID

    public init(machineId: UUID, hostGeneration: UUID, workspaceId: UUID) {
        self.machineId = machineId
        self.hostGeneration = hostGeneration
        self.workspaceId = workspaceId
    }
}

public struct WorkspaceCreateParameters: Encodable, Sendable {
    public let target: MachineTarget
    public let commandId: UUID
    public let expectedRevision: WorkRevision
    public let directoryId: String
    public let name: String

    public init(target: MachineTarget, commandId: UUID, expectedRevision: WorkRevision, directoryId: String, name: String) {
        self.target = target
        self.commandId = commandId
        self.expectedRevision = expectedRevision
        self.directoryId = directoryId
        self.name = name
    }
}

public struct WorkspaceRenameParameters: Encodable, Sendable {
    public let target: WorkWorkspaceTarget
    public let commandId: UUID
    public let expectedRevision: WorkRevision
    public let name: String

    public init(target: WorkWorkspaceTarget, commandId: UUID, expectedRevision: WorkRevision, name: String) {
        self.target = target
        self.commandId = commandId
        self.expectedRevision = expectedRevision
        self.name = name
    }
}

public struct SessionCreateParameters: Encodable, Sendable {
    public let target: WorkWorkspaceTarget
    public let commandId: UUID
    public let expectedRevision: WorkRevision
    public let name: String

    public init(target: WorkWorkspaceTarget, commandId: UUID, expectedRevision: WorkRevision, name: String) {
        self.target = target
        self.commandId = commandId
        self.expectedRevision = expectedRevision
        self.name = name
    }
}

public struct SessionRenameParameters: Encodable, Sendable {
    public let target: WorkSessionTarget
    public let commandId: UUID
    public let expectedRevision: WorkRevision
    public let name: String

    public init(target: WorkSessionTarget, commandId: UUID, expectedRevision: WorkRevision, name: String) {
        self.target = target
        self.commandId = commandId
        self.expectedRevision = expectedRevision
        self.name = name
    }
}

public struct CommandGetParameters: Encodable, Sendable {
    public let target: MachineTarget
    public let commandId: UUID

    public init(target: MachineTarget, commandId: UUID) {
        self.target = target
        self.commandId = commandId
    }
}

public struct WorkspaceRecord: Decodable, Equatable, Sendable, Identifiable {
    public var id: UUID { workspaceId }
    public let workspaceId: UUID
    public let name: String
    public let directoryId: String

    public init(workspaceId: UUID, name: String, directoryId: String) {
        self.workspaceId = workspaceId
        self.name = name
        self.directoryId = directoryId
    }
}

public typealias ProtocolWorkspaceRecord = WorkspaceRecord
public typealias WorkWorkspaceRecord = WorkspaceRecord

public enum WorkSessionNameSource: String, Decodable, Equatable, Sendable { case manual }
public struct WorkSessionPiBinding: Decodable, Equatable, Sendable {
    public let paneId: UUID
    public let chatId: UUID?
    public let admission: PiAdmission

    public init(paneId: UUID, chatId: UUID?, admission: PiAdmission) {
        self.paneId = paneId
        self.chatId = chatId
        self.admission = admission
    }
}

public struct WorkSessionRecord: Decodable, Equatable, Sendable, Identifiable {
    public var id: UUID { sessionId }
    public let sessionId: UUID
    public let workspaceId: UUID
    public let name: String
    public let nameSource: WorkSessionNameSource
    public let pi: WorkSessionPiBinding
    public let runtime: TerminalSnapshot?

    public init(sessionId: UUID, workspaceId: UUID, name: String, nameSource: WorkSessionNameSource,
                pi: WorkSessionPiBinding, runtime: TerminalSnapshot?) {
        self.sessionId = sessionId
        self.workspaceId = workspaceId
        self.name = name
        self.nameSource = nameSource
        self.pi = pi
        self.runtime = runtime
    }
}

public struct WorkspaceListResult: Decodable, Equatable, Sendable {
    public let hostGeneration: UUID
    public let revision: WorkRevision
    public let workspaces: [WorkWorkspaceRecord]
    public let next: WorkPageCursor?
}

public struct SessionListResult: Decodable, Equatable, Sendable {
    public let hostGeneration: UUID
    public let revision: WorkRevision
    public let sessions: [WorkSessionRecord]
    public let next: WorkPageCursor?
}

public struct SessionGetResult: Decodable, Equatable, Sendable {
    public let hostGeneration: UUID
    public let revision: WorkRevision
    public let session: WorkSessionRecord
}

public struct WorkspaceMutationResult: Decodable, Equatable, Sendable {
    public let hostGeneration: UUID
    public let revision: WorkRevision
    public let workspace: WorkWorkspaceRecord
}

public struct SessionRecord: Decodable, Equatable, Sendable {
    public let sessionId: UUID
    public let workspaceId: UUID
    public let name: String
    public let piPaneId: UUID
}

public enum CommittedWorkRecord: Decodable, Equatable, Sendable {
    case workspace(WorkWorkspaceRecord)
    case session(SessionRecord)

    private enum CodingKeys: String, CodingKey { case kind, record }
    private enum Kind: String, Decodable { case workspace, session }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == [.kind, .record] else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Invalid committed work record.")
        }
        switch try container.decode(Kind.self, forKey: .kind) {
        case .workspace: self = .workspace(try container.decode(WorkWorkspaceRecord.self, forKey: .record))
        case .session: self = .session(try container.decode(SessionRecord.self, forKey: .record))
        }
    }
}

public struct CommittedWork: Decodable, Equatable, Sendable {
    public let revision: WorkRevision
    public let record: CommittedWorkRecord
}

public enum CommandReceipt: Decodable, Equatable, Sendable {
    case pi(PiCommandReceipt)
    case work(committed: CommittedWork)
    case runtime(runtime: TerminalRuntime, terminal: TerminalSnapshot?)

    private enum CodingKeys: String, CodingKey { case kind, receipt, committed, runtime, terminal }
    private enum Kind: String, Decodable { case pi, work, runtime }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .pi:
            guard Set(container.allKeys) == [.kind, .receipt] else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Invalid Pi receipt.")
            }
            self = .pi(try container.decode(PiCommandReceipt.self, forKey: .receipt))
        case .work:
            guard Set(container.allKeys) == [.kind, .committed] else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Invalid work receipt.")
            }
            self = .work(committed: try container.decode(CommittedWork.self, forKey: .committed))
        case .runtime:
            guard Set(container.allKeys) == [.kind, .runtime, .terminal] else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Invalid runtime receipt.")
            }
            self = .runtime(
                runtime: try container.decode(TerminalRuntime.self, forKey: .runtime),
                terminal: try container.decodeIfPresent(TerminalSnapshot.self, forKey: .terminal)
            )
        }
    }
}

public struct CommandGetResult: Decodable, Equatable, Sendable {
    public let hostGeneration: UUID
    public let receipt: CommandReceipt?
}

public struct SessionMutationResult: Decodable, Equatable, Sendable {
    public let hostGeneration: UUID
    public let revision: WorkRevision
    public let session: WorkSessionRecord
}

public struct RuntimeStartResult: Codable, Equatable, Sendable {
    public let hostGeneration: UUID
    public let terminal: TerminalSnapshot

    public init(hostGeneration: UUID, terminal: TerminalSnapshot) {
        self.hostGeneration = hostGeneration
        self.terminal = terminal
    }
}

public struct TransportAcknowledgement: Codable, Equatable, Sendable {
    public let frames: Int

    public init(frames: Int) { self.frames = frames }
}
