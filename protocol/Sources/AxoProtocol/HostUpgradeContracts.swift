import Foundation

extension AxoProtocol.Method {
    public static let prepareHostUpgrade = "axo.host.prepareUpgrade"
}
public struct HostUpgradePlan: Codable, Equatable, Sendable {
    public let handoffId: UUID
    public let expectedVersion: String
    public let replacementVersion: String
    public let replacementBuildNumber: UInt64
    public init(handoffId: UUID, expectedVersion: String, replacementVersion: String, replacementBuildNumber: UInt64) {
        self.handoffId = handoffId
        self.expectedVersion = expectedVersion
        self.replacementVersion = replacementVersion
        self.replacementBuildNumber = replacementBuildNumber
    }
}
public struct HostUpgradeParameters: Codable, Equatable, Sendable {
    public let target: MachineTarget
    public let plan: HostUpgradePlan
    public init(target: MachineTarget, plan: HostUpgradePlan) { self.target = target; self.plan = plan }
}
public enum HostUpgradeDisposition: String, Decodable, Equatable, Sendable {
    case quiesced, deferredActiveWork, notNewer
}
public struct HostUpgradeResult: Decodable, Equatable, Sendable {
    public let machineId: UUID
    public let hostGeneration: UUID
    public let daemonVersion: String
    public let daemonBuildNumber: UInt64
    public let plan: HostUpgradePlan
    public let disposition: HostUpgradeDisposition
}
public enum HostUpgradeValidator {
    public static func prepare(_ value: JSONValue, parameters: HostUpgradeParameters) throws -> HostUpgradeResult {
        let method = AxoProtocol.Method.prepareHostUpgrade
        guard case .object(let fields) = value,
              Set(fields.keys) == ["machineId", "hostGeneration", "daemonVersion", "daemonBuildNumber", "plan", "disposition"],
              case .object(let plan)? = fields["plan"],
              Set(plan.keys) == ["handoffId", "expectedVersion", "replacementVersion", "replacementBuildNumber"] else {
            throw AxoProtocolValidationError.invalidResult(method: method)
        }
        let result: HostUpgradeResult
        do { result = try JSONDecoder().decode(HostUpgradeResult.self, from: JSONEncoder().encode(value)) }
        catch { throw AxoProtocolValidationError.invalidResult(method: method) }
        guard result.machineId == parameters.target.machineId, result.hostGeneration == parameters.target.hostGeneration,
              result.plan == parameters.plan, result.daemonVersion == parameters.plan.expectedVersion,
              result.daemonBuildNumber <= AxoProtocol.maximumSafeInteger else {
            throw AxoProtocolValidationError.invalidResult(method: method)
        }
        let newer = result.daemonBuildNumber > 0 && result.plan.replacementBuildNumber > result.daemonBuildNumber
        guard (result.disposition == .notNewer) != newer else {
            throw AxoProtocolValidationError.invalidResult(method: method)
        }
        return result
    }
}
