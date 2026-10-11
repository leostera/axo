import AxoCore
import AxoProtocol
import Foundation

/// Planning may freeze an idle helper, but only the coordinator's captured registration
/// operation performs the handoff. A lost acknowledgement retains the same plan.
@MainActor enum AxodDaemonUpgrade {
    enum Decision { case keepCurrent, legacyAwaitingSafeStop, deferredActiveWork, quiesced }
    static func pendingKey(_ machineID: UUID) -> String { "Axo.axod.pendingUpgrade.\(machineID.uuidString)" }

    static func prepare(over connection: AxoJSONRPCWebSocketConnection, endpoint: LocalDaemonEndpoint,
                        preferences: UserDefaults, info: [String: Any], validate: () throws -> Void) async throws -> Decision {
        let target = MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration)
        let value = try await connection.request(method: AxoProtocol.Method.getHost, parameters: HostGetParameters(target: target))
        try validate()
        let running = try AxoProtocolResultValidator.host(value, target: target)
        guard let version = info["AxoBundledAxodVersion"] as? String, !version.isEmpty,
              let buildString = info["CFBundleVersion"] as? String, let build = UInt64(buildString),
              build > 0, build <= WorkRevision.maximumSafeInteger else { return .keepCurrent }
        let key = pendingKey(endpoint.machineId)
        if running.daemonVersion == version {
            preferences.removeObject(forKey: key)
            return .keepCurrent
        }
        let parameters: HostUpgradeParameters
        if let saved = preferences.data(forKey: key) {
            let captured = try JSONDecoder().decode(HostUpgradeParameters.self, from: saved)
            if captured.target == target {
                guard captured.plan.replacementVersion == version, captured.plan.replacementBuildNumber == build else {
                    throw AxoProtocolValidationError.invalidParameters(method: AxoProtocol.Method.prepareHostUpgrade)
                }
                parameters = captured
            } else {
                parameters = HostUpgradeParameters(target: target, plan: HostUpgradePlan(handoffId: UUID(),
                    expectedVersion: running.daemonVersion, replacementVersion: version, replacementBuildNumber: build))
            }
        } else {
            parameters = HostUpgradeParameters(target: target, plan: HostUpgradePlan(handoffId: UUID(),
                expectedVersion: running.daemonVersion, replacementVersion: version, replacementBuildNumber: build))
        }
        try validate()
        preferences.set(try JSONEncoder().encode(parameters), forKey: key)
        do {
            let value = try await connection.request(method: AxoProtocol.Method.prepareHostUpgrade, parameters: parameters)
            try validate()
            let result = try HostUpgradeValidator.prepare(value, parameters: parameters)
            switch result.disposition {
            case .quiesced: return .quiesced
            case .deferredActiveWork:
                preferences.removeObject(forKey: key)
                return .deferredActiveWork
            case .notNewer:
                preferences.removeObject(forKey: key)
                return .keepCurrent
            }
        } catch AxoJSONRPCClientError.remote(let code, _) where code == -32601 {
            preferences.removeObject(forKey: key)
            return .legacyAwaitingSafeStop
        }
    }
}
