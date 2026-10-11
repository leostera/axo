import AxoCore
import AxoProtocol
import Foundation

/// Pure captured-client state checks; this does not fake native/daemon acceptance.
@main
struct ShellCreationChecks {
    @MainActor static func main() async throws {
        let suite = "Axo.ShellCreationCheck.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let machine = UUID(), host = UUID(), sessionID = UUID()
        let source = MachineTarget(machineId: machine, hostGeneration: host)
        let session = WorkSessionRecord(sessionId: sessionID, workspaceId: nil, name: "Fixture", nameSource: .manual,
            pi: .init(paneId: UUID(), chatId: nil, admission: .notAdmitted), runtime: nil)
        let key = "Axo.axod.pendingShellAdd." + machine.uuidString + "." + sessionID.uuidString
        let identity = AxodShellCreation.Session(machineID: machine, sessionID: sessionID)
        let service = AxodShellCreation(preferences: preferences)
        var sends = 0
        let failed = await service.start(session: session, source: source, send: { _ in sends += 1; return .null }, validate: { throw CancellationError() })
        precondition(failed == nil && sends == 0 && preferences.object(forKey: key) == nil)
        preferences.set("unreadable", forKey: key)
        _ = await service.start(session: session, source: source, send: { _ in sends += 1; return .null }, validate: {})
        precondition(sends == 0 && preferences.string(forKey: key) == "unreadable")
        precondition(service.states[identity] == .unavailable)
        preferences.removeObject(forKey: key)

        var captured: ShellPaneAddParameters?
        _ = await service.start(session: session, source: source, send: { parameters in
            sends += 1; captured = parameters
            // Intent identity must be present before any transport effect.
            let saved = try JSONDecoder().decode(ShellPaneAddParameters.self, from: preferences.data(forKey: key)!)
            precondition(saved == parameters)
            throw AxoJSONRPCClientError.outcomeUnknown(requestID: "fixture")
        }, validate: {})
        let pending = captured!
        precondition(service.states[identity] == .unresolved(pending.commandId))
        _ = await service.start(session: session, source: source, send: { _ in sends += 1; return .null }, validate: {})
        precondition(sends == 1, "Uncertainty caused a second shell dispatch")
        let restored = AxodShellCreation(preferences: preferences)
        restored.restore(session: session, machineID: machine)
        precondition(restored.states[identity] == .unresolved(pending.commandId))
        await restored.reconcile(session: session, source: source, lookup: { parameters in
            precondition(parameters.commandId == pending.commandId)
            return .object(["hostGeneration": .string(host.uuidString), "receipt": .null])
        }, validate: {})
        precondition(preferences.data(forKey: key) != nil, "Missing receipt authorized replacement")
        let nextSource = MachineTarget(machineId: machine, hostGeneration: UUID())
        await restored.reconcile(session: session, source: nextSource, lookup: { parameters in
            precondition(parameters.target == nextSource && parameters.commandId == pending.commandId)
            let target: JSONValue = .object(["machineId": .string(machine.uuidString), "hostGeneration": .string(host.uuidString),
                                             "workspaceId": .null, "sessionId": .string(sessionID.uuidString)])
            return .object(["hostGeneration": .string(nextSource.hostGeneration.uuidString), "receipt": .object(["kind": .string("pane"),
                "receipt": .object(["commandId": .string(pending.commandId.uuidString), "paneId": .string(UUID().uuidString), "runtime": .null,
                    "intent": .object(["operation": .string("addPane"), "target": target, "profileId": .null]),
                    "disposition": .object(["kind": .string("rejected"), "reason": .string("launch_failed")])])])])
        }, validate: {})
        precondition(preferences.object(forKey: key) == nil && restored.states[identity] == .rejected)
        precondition(sends == 1, "Read-only restoration/reconciliation dispatched work")
        print("PASS: captured shell intent saved before dispatch, corrupt hint preservation, unknown/no-replay and historical read-only reconciliation (client-state checks only)")
    }
}
