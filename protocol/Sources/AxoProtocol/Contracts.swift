import Foundation

public enum AxoProtocol {
    public static let version = 1
    public static let maximumMachineCount = 16
    public static let maximumLabelLength = 80
    public static let maximumPageSize = 50
    public static let maximumBacklogBytes = 8_192

    public enum Method {
        public static let negotiate = "axo.protocol.negotiate"
        public static let registerMachine = "axo.machine.register"
        public static let heartbeat = "axo.machine.heartbeat"
        public static let listMachines = "axo.machine.list"
        public static let listRuntimes = "axo.runtime.list"
        public static let startApprovedRuntime = "axo.runtime.startApproved"
        public static let acknowledgeTransport = "axo.transport.ack"
    }
}

public struct NegotiationParameters: Codable, Equatable, Sendable {
    public let protocolVersion: Int

    public init() { protocolVersion = AxoProtocol.version }
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
