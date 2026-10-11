import AxoProtocol
import Foundation
import Observation
import OSLog
import ServiceManagement

/// One application-scoped service owner. Connecting a window has no registration
/// side effects; only explicit setup can register. This type cannot unregister axod.
@MainActor @Observable
final class AxodServiceLifecycle {
    enum Registration: Equatable {
        case notRegistered, enabled, requiresApproval, notFound, unavailable

        var message: String {
            switch self {
            case .notRegistered: "The Axod background service is not enabled."
            case .enabled: "Axod is registered and eligible to run. Registration is not a readiness check."
            case .requiresApproval: "Approve Axod in System Settings → General → Login Items & Extensions."
            case .notFound: "macOS cannot find the registered service. Check the installed app location; no service was replaced."
            case .unavailable: "macOS service registration status is unavailable."
            }
        }
    }
    enum Availability: Equatable {
        case unknown, waiting, ready(MachineTarget), unavailable
    }
    enum Operation: String { case idle, enablingAgent, enablingLogin, disablingLogin }
    enum Failure: Error, LocalizedError {
        case liveOwner, registration, approval, installation, superseded
        var errorDescription: String? {
            switch self {
            case .liveOwner: "An existing helper owns Axod's state. It was left running. Enabling another supervisor requires a separate safe handoff."
            case .registration: "Axod is not enabled. Choose Enable Background Service to set it up."
            case .approval: "Axod needs approval in System Settings Login Items & Extensions. No helper was launched to bypass approval."
            case .installation: "The Axod service installation is unavailable. Check the app's installed location; reconnect cannot repair or replace it."
            case .superseded: "Service observation was superseded."
            }
        }
    }

    static let shared = AxodServiceLifecycle(platform: AxodSystemServicePlatform())
    private(set) var registration: Registration = .unavailable
    private(set) var loginRegistration: Registration = .unavailable
    private(set) var availability: Availability = .unknown
    private(set) var operation: Operation = .idle
    private(set) var failureMessage: String?
    @ObservationIgnored private let platform: any AxodServicePlatform
    @ObservationIgnored private var observation = UUID()
    @ObservationIgnored private let logger = Logger(subsystem: "dev.leostera.axo.mac", category: "axod-lifecycle")

    init(platform: any AxodServicePlatform) { self.platform = platform }

    func observeRegistration() {
        registration = platform.agentRegistration
        loginRegistration = platform.loginRegistration
    }

    func requireEnabled() throws {
        observeRegistration()
        switch registration {
        case .enabled: return
        case .notRegistered: throw Failure.registration
        case .requiresApproval: throw Failure.approval
        case .notFound, .unavailable: throw Failure.installation
        }
    }

    func beginObservation() -> UUID {
        observation = UUID()
        availability = .waiting
        logger.info("Waiting for daemon readiness; no service operation dispatched")
        return observation
    }

    func observedReady(_ target: MachineTarget, observation captured: UUID) {
        guard observation == captured else { return }
        availability = .ready(target)
        logger.info("Validated daemon readiness")
    }

    func observedUnavailable(observation captured: UUID) {
        guard observation == captured else { return }
        availability = .unavailable
        logger.error("Daemon readiness unavailable; service and work were not restarted")
    }

    /// Explicit non-destructive setup only. Hold the private root proof until
    /// immediately before registration, which may launch the agent synchronously.
    func enableAgent(in root: URL) throws {
        guard operation == .idle else { return }
        operation = .enablingAgent
        defer { operation = .idle; observeRegistration() }
        failureMessage = nil
        observeRegistration()
        guard registration == .notRegistered else {
            if registration == .enabled { return }
            throw registration == .requiresApproval ? Failure.approval : Failure.installation
        }
        guard let absence = try AxodOwnerAbsenceLease.acquire(in: root) else {
            failureMessage = Failure.liveOwner.localizedDescription
            throw Failure.liveOwner
        }
        defer { absence.release() }
        absence.release()
        do {
            try platform.registerAgent()
            logger.info("Explicit background service registration dispatched")
        } catch {
            failureMessage = "Background service registration could not be confirmed. Review its actual status before another setup attempt."
            logger.error("Service registration failed; code \((error as NSError).code, privacy: .public)")
            throw error
        }
    }

    /// Main-app login registration is independent from daemon supervision.
    /// Disabling this login item never unregisters the agent or quits the app.
    func setFrontendAtLogin(_ enabled: Bool) async {
        guard operation == .idle else { return }
        operation = enabled ? .enablingLogin : .disablingLogin
        defer { operation = .idle; observeRegistration() }
        failureMessage = nil
        observeRegistration()
        do {
            if enabled, loginRegistration == .notRegistered { try platform.registerLogin() }
            else if !enabled, loginRegistration == .enabled { try await platform.unregisterLogin() }
        } catch {
            failureMessage = "Frontend login startup could not be changed. Review the actual status in System Settings."
            logger.error("Frontend login registration failed; code \((error as NSError).code, privacy: .public)")
        }
    }

    func openApprovalSettings() { platform.openApprovalSettings() }
}

@MainActor
protocol AxodServicePlatform {
    var agentRegistration: AxodServiceLifecycle.Registration { get }
    var loginRegistration: AxodServiceLifecycle.Registration { get }
    func registerAgent() throws
    func registerLogin() throws
    func unregisterLogin() async throws
    func openApprovalSettings()
}

@MainActor
private struct AxodSystemServicePlatform: AxodServicePlatform {
    private var agent: SMAppService { .agent(plistName: "dev.leostera.axo.axod.plist") }
    var agentRegistration: AxodServiceLifecycle.Registration { Self.parse(agent.status) }
    var loginRegistration: AxodServiceLifecycle.Registration { Self.parse(SMAppService.mainApp.status) }
    func registerAgent() throws { try agent.register() }
    func registerLogin() throws { try SMAppService.mainApp.register() }
    func unregisterLogin() async throws { try await SMAppService.mainApp.unregister() }
    func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }
    private static func parse(_ status: SMAppService.Status) -> AxodServiceLifecycle.Registration {
        switch status {
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unavailable
        }
    }
}
