import AxoCore
import AxoProtocol
import Foundation
import Observation

/// Durable hints + captured local pane operations, never restoration launch permission.
@MainActor @Observable
final class AxodShellCreation {
    struct Session: Hashable {
        let machineID: UUID
        let sessionID: UUID
    }
    enum State: Equatable {
        case starting(UUID), unresolved(UUID), unavailable, ready, rejected
        var message: String {
            switch self {
            case .starting: return "Starting the independent regular shell…"
            case .unresolved: return "Shell start outcome is unknown. Reconcile its saved command; no new shell was sent."
            case .unavailable: return "The saved shell intent cannot be validated. It was preserved; no new shell was sent."
            case .ready: return "The shell PTY was launched. Startup and exit status remain in its terminal."
            case .rejected: return "The shell start was rejected before execution. The session and Pi startup were preserved."
            }
        }
    }
    @ObservationIgnored private let preferences: UserDefaults
    private(set) var states: [Session: State] = [:]
    private static let prefix = "Axo.axod.pendingShellAdd."
    init(preferences: UserDefaults) { self.preferences = preferences }

    func restore(session: WorkSessionRecord, machineID: UUID) {
        let identity = Session(machineID: machineID, sessionID: session.sessionId)
        guard preferences.object(forKey: key(identity)) != nil else { return }
        guard let data = preferences.data(forKey: key(identity)), let saved = try? JSONDecoder().decode(ShellPaneAddParameters.self, from: data),
              saved.target.machineId == machineID, saved.target.sessionId == session.sessionId,
              saved.target.workspaceId == session.workspaceId, saved.profileId == nil else {
            states[identity] = .unavailable
            return
        }
        if states[identity] != .starting(saved.commandId) { states[identity] = .unresolved(saved.commandId) }
    }

    /// Called only for a freshly committed explicit creation, never by restore/reconnect.
    func start(session: WorkSessionRecord, source: MachineTarget,
               send: @MainActor (ShellPaneAddParameters) async throws -> JSONValue,
               validate: @MainActor () throws -> Void) async -> ShellPaneRecord? {
        let identity = Session(machineID: source.machineId, sessionID: session.sessionId)
        guard preferences.object(forKey: key(identity)) == nil else {
            restore(session: session, machineID: source.machineId)
            return nil
        }
        let pending = ShellPaneAddParameters(target: WorkSessionTarget(machineId: source.machineId,
            hostGeneration: source.hostGeneration, workspaceId: session.workspaceId, sessionId: session.sessionId), commandId: UUID())
        do {
            try validate()
            preferences.set(try JSONEncoder().encode(pending), forKey: key(identity))
        } catch { states[identity] = .unavailable; return nil }
        states[identity] = .starting(pending.commandId)
        do {
            let value = try await send(pending)
            let result = try AxoProtocolResultValidator.shellPaneAdd(value, parameters: pending)
            try validate()
            switch result.receipt.disposition {
            case .prepared:
                states[identity] = .unresolved(pending.commandId)
            case .added:
                clear(identity, command: pending.commandId)
                states[identity] = .ready
            case .rejected:
                clear(identity, command: pending.commandId)
                states[identity] = .rejected
            case .removed:
                throw AxoProtocolValidationError.invalidResult(method: AxoProtocol.Method.addShellPane)
            }
            return result.pane
        } catch {
            if Self.noEffect(error) {
                clear(identity, command: pending.commandId)
                states[identity] = .rejected
            } else { states[identity] = .unresolved(pending.commandId) }
            return nil
        }
    }

    func reconcile(session: WorkSessionRecord, source: MachineTarget,
                   lookup: @MainActor (CommandGetParameters) async throws -> JSONValue,
                   validate: @MainActor () throws -> Void) async {
        let identity = Session(machineID: source.machineId, sessionID: session.sessionId)
        guard let data = preferences.data(forKey: key(identity)),
              let pending = try? JSONDecoder().decode(ShellPaneAddParameters.self, from: data),
              pending.target.machineId == source.machineId, pending.target.sessionId == session.sessionId,
              pending.target.workspaceId == session.workspaceId, pending.profileId == nil else {
            states[identity] = .unavailable; return
        }
        do {
            try validate()
            let value = try await lookup(CommandGetParameters(target: source, commandId: pending.commandId))
            let result = try AxoProtocolResultValidator.commandGet(value, target: source)
            try validate()
            guard case .pane(let receipt)? = result.receipt, receipt.commandId == pending.commandId,
                  receipt.intent == .add(target: pending.target, profileId: nil) else {
                states[identity] = .unresolved(pending.commandId); return
            }
            switch receipt.disposition {
            case .prepared: states[identity] = .unresolved(pending.commandId)
            case .added:
                clear(identity, command: pending.commandId); states[identity] = .ready
            case .rejected:
                clear(identity, command: pending.commandId); states[identity] = .rejected
            case .removed:
                states[identity] = .unresolved(pending.commandId)
            }
        } catch { states[identity] = .unresolved(pending.commandId) }
    }
    private func key(_ identity: Session) -> String {
        Self.prefix + identity.machineID.uuidString + "." + identity.sessionID.uuidString
    }
    private func clear(_ identity: Session, command: UUID) {
        guard let data = preferences.data(forKey: key(identity)),
              let saved = try? JSONDecoder().decode(ShellPaneAddParameters.self, from: data), saved.commandId == command else { return }
        preferences.removeObject(forKey: key(identity))
    }
    private static func noEffect(_ error: Error) -> Bool {
        guard case AxoJSONRPCClientError.remote(let code, _) = error else { return false }
        return [-32601, -32602, -32002, -32003, -32006, -32007, -32010].contains(code)
    }
}
