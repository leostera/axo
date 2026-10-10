import Foundation

public enum AxoProtocolValidationError: Error, Equatable, Sendable, LocalizedError {
    case invalidResult(method: String)
    case staleHost(expected: UUID, actual: UUID)

    public var errorDescription: String? {
        switch self {
        case .invalidResult(let method): "Invalid result for \(method)."
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
              !methodsValue.isEmpty, methodsValue.count <= 16,
              let methods = methodsValue.asStrings,
              methods.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 128 }),
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
