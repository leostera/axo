import AxoProtocol
import Foundation

@main
struct DaemonUpgradePlanChecks {
    static func main() throws {
        let target = MachineTarget(machineId: UUID(), hostGeneration: UUID())
        let captured = HostUpgradeParameters(target: target, plan: HostUpgradePlan(handoffId: UUID(),
            expectedVersion: "old-helper", replacementVersion: "new-helper", replacementBuildNumber: 162))
        let bytes = try JSONEncoder().encode(captured)
        func choose(_ pending: AxodDaemonUpgradePlan.Pending, source: MachineTarget? = nil,
                    running: String = "old-helper", replacement: String = "new-helper", build: UInt64 = 162) -> AxodDaemonUpgradePlan.Choice {
            AxodDaemonUpgradePlan.choose(target: source ?? target, runningVersion: running,
                replacementVersion: replacement, replacementBuild: build, pending: pending)
        }
        precondition(choose(.absent, running: "new-helper") == .keepCurrent)
        guard case .prepare(let fresh) = choose(.absent) else { preconditionFailure("Missing fresh plan") }
        precondition(fresh.target == target && fresh.plan.expectedVersion == "old-helper")
        precondition(fresh.plan.replacementVersion == "new-helper" && fresh.plan.replacementBuildNumber == 162)
        precondition(choose(.encoded(bytes)) == .prepare(captured), "Exact original handoff changed")
        precondition(choose(.encoded(bytes), build: 173) == .awaitOriginalHandoff, "New package must not invalidate the read-only connection")
        precondition(choose(.encoded(bytes), replacement: "later-helper") == .awaitOriginalHandoff)
        precondition(choose(.encoded(bytes), running: "new-helper") == .keepCurrent, "An old capture must not block a verified-current helper")
        precondition(choose(.opaque, running: "new-helper") == .keepCurrent, "Opaque historical handoff cannot disable current helper capabilities")
        precondition(AxodDaemonUpgradePlan.choose(target: target, runningVersion: "old-helper",
            replacementVersion: "frontend-only-build", replacementBuild: 173, pending: .encoded(bytes),
            compatibleVersions: ["old-helper"]) == .keepCurrent, "Identical execution code must remain usable across frontend-only builds")
        precondition(AxodDaemonUpgradePlan.choose(target: target, runningVersion: "unknown-helper",
            replacementVersion: "frontend-only-build", replacementBuild: 173, pending: .encoded(bytes),
            compatibleVersions: ["old-helper"]) == .awaitOriginalHandoff, "Unknown helper compatibility must not be invented")
        precondition(choose(.encoded(bytes), source: MachineTarget(machineId: target.machineId, hostGeneration: UUID())) == .awaitOriginalHandoff)
        precondition(choose(.encoded(bytes), source: MachineTarget(machineId: UUID(), hostGeneration: target.hostGeneration)) == .awaitOriginalHandoff)
        precondition(choose(.init(stored: "opaque")) == .awaitOriginalHandoff)
        precondition(choose(.encoded(Data("invalid".utf8))) == .awaitOriginalHandoff)
        precondition(choose(.encoded(Data(repeating: 32, count: 4097))) == .awaitOriginalHandoff)
        var extra = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        extra["unrecognized"] = true
        let extraBytes = try JSONSerialization.data(withJSONObject: extra)
        precondition(choose(.encoded(extraBytes)) == .awaitOriginalHandoff)
        let suite = "Axo.UpgradePlanFixture.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(bytes, forKey: "original")
        precondition(choose(.init(stored: preferences.object(forKey: "original")), build: 173) == .awaitOriginalHandoff)
        precondition(choose(.init(stored: preferences.object(forKey: "original")), running: "new-helper") == .keepCurrent)
        precondition(preferences.data(forKey: "original") == bytes, "Original intent was discarded or replaced")
        print("PASS: exact helper handoff capture, changed package/source and opaque intent stay fenced without losing read-only connectivity or replacing original bytes")
    }
}
