import Foundation

public struct HostGetParameters: Encodable, Sendable {
    public let target: MachineTarget
    public init(target: MachineTarget) { self.target = target }
}
public struct HostStatusResult: Decodable, Equatable, Sendable {
    public struct Cloud: Decodable, Equatable, Sendable {
        public enum Kind: String, Decodable, Sendable { case notConfigured, connecting, offline, online }
        public let kind: Kind
        public let leaseId: UUID?
        public let expiresAt: Double?
        public var isOnline: Bool { kind == .online && (expiresAt ?? 0) > Date().timeIntervalSince1970 * 1000 }
    }
    public let hostGeneration: UUID
    public let machineId: UUID
    public let hostname: String
    public let machineType: String
    public let daemonVersion: String
    public let cloud: Cloud
}

public extension AxoProtocolResultValidator {
    static func host(_ value: JSONValue, target: MachineTarget) throws -> HostStatusResult {
        let method = AxoProtocol.Method.getHost
        guard case .object(let fields) = value,
              Set(fields.keys) == Set(["hostGeneration", "machineId", "hostname", "machineType", "daemonVersion", "cloud"]),
              case .object(let cloud)? = fields["cloud"], case .string(let kind)? = cloud["kind"] else {
            throw AxoProtocolValidationError.invalidResult(method: method)
        }
        let expectedKeys: Set<String> = kind == "online" ? ["kind", "leaseId", "expiresAt"] : ["kind"]
        guard Set(cloud.keys) == expectedKeys else { throw AxoProtocolValidationError.invalidResult(method: method) }
        let data = try JSONEncoder().encode(value)
        let result: HostStatusResult
        do { result = try JSONDecoder().decode(HostStatusResult.self, from: data) }
        catch { throw AxoProtocolValidationError.invalidResult(method: method) }
        guard result.machineId == target.machineId else { throw AxoProtocolValidationError.invalidResult(method: method) }
        guard result.hostGeneration == target.hostGeneration else { throw AxoProtocolValidationError.staleHost(expected: target.hostGeneration, actual: result.hostGeneration) }
        guard [result.hostname, result.machineType].allSatisfy({ !$0.isEmpty && $0.utf16.count <= 80 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }),
              !result.daemonVersion.isEmpty, result.daemonVersion.utf16.count <= 128 else { throw AxoProtocolValidationError.invalidResult(method: method) }
        if kind == "online" {
            guard result.cloud.leaseId != nil, let expiresAt = result.cloud.expiresAt, expiresAt.isFinite,
                  expiresAt > 0, expiresAt.rounded() == expiresAt, expiresAt <= 9_007_199_254_740_991 else {
                throw AxoProtocolValidationError.invalidResult(method: method)
            }
        }
        return result
    }
}
