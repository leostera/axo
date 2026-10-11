import AxoCore
import AxoProtocol
import Foundation

/// Planning may freeze an idle helper, but only the coordinator's captured registration
/// operation performs the handoff. A lost acknowledgement retains the same plan.
@MainActor enum AxodDaemonUpgrade {
    enum Decision { case keepCurrent, legacyAwaitingSafeStop, deferredActiveWork, awaitingOriginalHandoff, quiesced }
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
        let choice = AxodDaemonUpgradePlan.choose(target: target, runningVersion: running.daemonVersion,
            replacementVersion: version, replacementBuild: build,
            pending: .init(stored: preferences.object(forKey: key)))
        let parameters: HostUpgradeParameters
        switch choice {
        case .keepCurrent: return .keepCurrent
        case .awaitOriginalHandoff: return .awaitingOriginalHandoff
        case .prepare(let captured): parameters = captured
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
