import Foundation

/// Private state-file discovery for an explicitly selected local daemon.
/// The descriptor contains routing metadata only; it is not an authentication token.
public struct LocalDaemonEndpoint: Codable, Equatable, Sendable {
    public let version: Int
    public let protocolVersion: Int
    public let endpoint: String
    public let machineId: UUID
    public let hostGeneration: UUID

    public init(
        version: Int = 1,
        protocolVersion: Int = AxoProtocol.version,
        endpoint: String,
        machineId: UUID,
        hostGeneration: UUID
    ) throws {
        guard version == 1, protocolVersion == AxoProtocol.version,
              Self.validEndpoint(endpoint) else {
            throw LocalDaemonEndpointError.invalidDescriptor
        }
        self.version = version
        self.protocolVersion = protocolVersion
        self.endpoint = endpoint
        self.machineId = machineId
        self.hostGeneration = hostGeneration
    }

    public var url: URL { URL(string: endpoint)! }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let expectedKeys: Set<String> = ["version", "protocolVersion", "endpoint", "machineId", "hostGeneration"]
        guard Set(container.allKeys.map(\.stringValue)) == expectedKeys else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unexpected local daemon descriptor fields."))
        }
        let version = try container.decode(Int.self, forKey: AnyCodingKey("version"))
        let protocolVersion = try container.decode(Int.self, forKey: AnyCodingKey("protocolVersion"))
        let endpoint = try container.decode(String.self, forKey: AnyCodingKey("endpoint"))
        let machineId = try container.decode(UUID.self, forKey: AnyCodingKey("machineId"))
        let hostGeneration = try container.decode(UUID.self, forKey: AnyCodingKey("hostGeneration"))
        do {
            try self.init(version: version, protocolVersion: protocolVersion, endpoint: endpoint,
                          machineId: machineId, hostGeneration: hostGeneration)
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid local daemon descriptor."))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(machineId, forKey: .machineId)
        try container.encode(hostGeneration, forKey: .hostGeneration)
    }

    private enum CodingKeys: String, CodingKey {
        case version, protocolVersion, endpoint, machineId, hostGeneration
    }

    private static func validEndpoint(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme == "ws", components.host == "127.0.0.1",
              let port = components.port, (1...65_535).contains(port),
              components.path == "/v1/rpc", components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return false }
        return true
    }
}

private struct AnyCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int? = nil

    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

public enum LocalDaemonEndpointError: Error, Equatable, Sendable, LocalizedError {
    case invalidDescriptor

    public var errorDescription: String? { "The local daemon discovery file is invalid or incompatible." }
}

/// The local adapter currently negotiates only the shared application protocol version.
public struct LocalDaemonNegotiationResult: Codable, Equatable, Sendable {
    public let protocolVersion: Int

    public init(protocolVersion: Int) { self.protocolVersion = protocolVersion }
}

public extension AxoProtocolResultValidator {
    static func localNegotiation(_ value: JSONValue) throws -> LocalDaemonNegotiationResult {
        guard case .object(let fields) = value,
              Set(fields.keys) == ["protocolVersion"],
              case .number(let version)? = fields["protocolVersion"],
              version == Double(AxoProtocol.version) else {
            throw AxoProtocolValidationError.invalidResult(method: AxoProtocol.Method.negotiate)
        }
        return LocalDaemonNegotiationResult(protocolVersion: Int(version))
    }

    static func runtimeStart(_ value: JSONValue, target: TerminalTarget) throws -> RuntimeStartResult {
        guard case .object(let result) = value,
              Set(result.keys) == ["hostGeneration", "terminal"],
              case .string(let generationText)? = result["hostGeneration"],
              let generation = UUID(uuidString: generationText),
              generation == target.hostGeneration,
              case .object(let terminal)? = result["terminal"],
              Set(terminal.keys) == ["runtime", "process", "attached", "backlog_bytes"],
              case .object(let runtime)? = terminal["runtime"],
              Set(runtime.keys) == ["host_generation", "target", "runtime_generation"],
              case .string(let runtimeHostText)? = runtime["host_generation"],
              UUID(uuidString: runtimeHostText) == target.hostGeneration,
              case .string(let runtimeGenerationText)? = runtime["runtime_generation"],
              UUID(uuidString: runtimeGenerationText) != nil,
              case .object(let runtimeTarget)? = runtime["target"],
              Set(runtimeTarget.keys) == ["session_id", "pane_id"],
              case .string(let sessionText)? = runtimeTarget["session_id"],
              UUID(uuidString: sessionText) == target.sessionId,
              case .string(let paneText)? = runtimeTarget["pane_id"],
              UUID(uuidString: paneText) == target.paneId,
              validProcess(terminal["process"]),
              case .bool? = terminal["attached"],
              case .number(let backlog)? = terminal["backlog_bytes"],
              backlog.isFinite, backlog.rounded(.towardZero) == backlog,
              backlog >= 0, backlog <= Double(AxoProtocol.maximumBacklogBytes) else {
            throw AxoProtocolValidationError.invalidResult(method: AxoProtocol.Method.startApprovedRuntime)
        }

        do {
            return try JSONDecoder().decode(RuntimeStartResult.self, from: JSONEncoder().encode(value))
        } catch {
            throw AxoProtocolValidationError.invalidResult(method: AxoProtocol.Method.startApprovedRuntime)
        }
    }

    private static func validProcess(_ value: JSONValue?) -> Bool {
        guard case .object(let process)? = value, case .string(let kind)? = process["kind"] else { return false }
        switch kind {
        case "starting", "failed", "recovery_required":
            return Set(process.keys) == ["kind"]
        case "running", "stopping":
            guard Set(process.keys) == ["kind", "pid"], case .number(let pid)? = process["pid"] else { return false }
            return pid.isFinite && pid.rounded(.towardZero) == pid && pid > 0
        case "exited":
            guard Set(process.keys) == ["kind", "wait_status"], case .number(let status)? = process["wait_status"] else { return false }
            return status.isFinite && status.rounded(.towardZero) == status
        default:
            return false
        }
    }
}
