import AxoProtocol
import Foundation

enum AxodDaemonUpgradePlan {
    enum Pending {
        case absent
        case opaque
        case encoded(Data)

        init(stored: Any?) {
            guard let stored else { self = .absent; return }
            if let data = stored as? Data { self = .encoded(data) }
            else { self = .opaque }
        }
    }

    enum Choice: Equatable {
        case keepCurrent
        case awaitOriginalHandoff
        case prepare(HostUpgradeParameters)
    }

    static func choose(target: MachineTarget, runningVersion: String, replacementVersion: String,
                       replacementBuild: UInt64, pending: Pending, compatibleVersions: Set<String> = []) -> Choice {
        // Current helper capability is independent of an older unresolved handoff.
        // Preserve the capture, but do not fence unrelated fresh work on this host.
        if runningVersion == replacementVersion || compatibleVersions.contains(runningVersion) { return .keepCurrent }
        switch pending {
        case .opaque:
            return .awaitOriginalHandoff
        case .encoded(let data):
            guard let captured = decode(data), captured.target == target,
                  captured.plan.expectedVersion == runningVersion,
                  captured.plan.replacementVersion == replacementVersion,
                  captured.plan.replacementBuildNumber == replacementBuild else { return .awaitOriginalHandoff }
            return .prepare(captured)
        case .absent:
            return .prepare(HostUpgradeParameters(target: target, plan: HostUpgradePlan(handoffId: UUID(),
                expectedVersion: runningVersion, replacementVersion: replacementVersion,
                replacementBuildNumber: replacementBuild)))
        }
    }

    private static func decode(_ data: Data) -> HostUpgradeParameters? {
        guard data.count <= 4096,
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let fields) = value, Set(fields.keys) == ["target", "plan"],
              case .object(let target)? = fields["target"], Set(target.keys) == ["machineId", "hostGeneration"],
              case .object(let plan)? = fields["plan"],
              Set(plan.keys) == ["handoffId", "expectedVersion", "replacementVersion", "replacementBuildNumber"],
              let captured = try? JSONDecoder().decode(HostUpgradeParameters.self, from: data),
              captured.plan.replacementBuildNumber > 0,
              captured.plan.replacementBuildNumber <= AxoProtocol.maximumSafeInteger,
              [captured.plan.expectedVersion, captured.plan.replacementVersion].allSatisfy({ version in
                  !version.isEmpty && version.utf8.count <= 128 && !version.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
              }) else { return nil }
        return captured
    }
}
