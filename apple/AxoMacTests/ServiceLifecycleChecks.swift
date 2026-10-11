import AxoProtocol
import Darwin
import Foundation

@MainActor private final class ServicePlatformFixture: AxodServicePlatform {
    var agentRegistration: AxodServiceLifecycle.Registration = .notRegistered
    var loginRegistration: AxodServiceLifecycle.Registration = .notRegistered
    var agentCalls = 0
    var loginCalls = 0
    var logoutCalls = 0
    var approvalCalls = 0
    var failAgent = false
    func registerAgent() throws {
        agentCalls += 1
        if failAgent { throw NSError(domain: "fixture", code: 99) }
        agentRegistration = .enabled
    }
    func registerLogin() throws { loginCalls += 1; loginRegistration = .enabled }
    func unregisterLogin() async throws { logoutCalls += 1; loginRegistration = .notRegistered }
    func openApprovalSettings() { approvalCalls += 1 }
}

@main struct ServiceLifecycleChecks {
    @MainActor static func main() async throws {
        let platform = ServicePlatformFixture()
        let lifecycle = AxodServiceLifecycle(platform: platform)
        precondition(lifecycle.availability == .unknown && platform.agentCalls == 0)
        for status in [AxodServiceLifecycle.Registration.notRegistered, .requiresApproval, .notFound, .unavailable] {
            platform.agentRegistration = status
            do { try lifecycle.requireEnabled(); preconditionFailure("Missing setup must not launch") }
            catch is AxodServiceLifecycle.Failure { }
            precondition(platform.agentCalls == 0 && platform.loginCalls == 0)
        }
        platform.agentRegistration = .enabled
        try lifecycle.requireEnabled()
        precondition(lifecycle.availability == .unknown, "Registration does not prove readiness")
        let stale = lifecycle.beginObservation()
        let current = lifecycle.beginObservation()
        let target = MachineTarget(machineId: UUID(), hostGeneration: UUID())
        lifecycle.observedReady(target, observation: stale)
        precondition(lifecycle.availability == .waiting)
        lifecycle.observedReady(target, observation: current)
        lifecycle.observedUnavailable(observation: stale)
        precondition(lifecycle.availability == .ready(target))
        lifecycle.observedUnavailable(observation: current)
        precondition(lifecycle.availability == .unavailable && platform.agentCalls == 0)

        // Owned disposable directory and actual owner-lock contention, no service effects.
        var template = Array("/tmp/axo-service-lifecycle-XXXXXX".utf8CString)
        guard let path = mkdtemp(&template) else { fatalError("Private fixture required") }
        let root = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try AxodOwnerAbsenceLease.acquire(in: root)!
        platform.agentRegistration = .notRegistered
        do { try lifecycle.enableAgent(in: root); preconditionFailure("Cannot enable a competing supervisor") }
        catch AxodServiceLifecycle.Failure.liveOwner { }
        precondition(platform.agentCalls == 0 && lifecycle.operation == .idle)
        owner.release()
        try lifecycle.enableAgent(in: root)
        precondition(platform.agentCalls == 1 && lifecycle.registration == .enabled)
        try lifecycle.enableAgent(in: root)
        precondition(platform.agentCalls == 1, "Observation/setup does not repeatedly register")
        await lifecycle.setFrontendAtLogin(true)
        precondition(platform.loginCalls == 1 && platform.agentCalls == 1)
        await lifecycle.setFrontendAtLogin(false)
        precondition(platform.logoutCalls == 1 && platform.agentRegistration == .enabled)
        lifecycle.openApprovalSettings()
        precondition(platform.approvalCalls == 1)

        platform.agentRegistration = .requiresApproval
        do { try lifecycle.enableAgent(in: root); preconditionFailure("Approval cannot be bypassed") }
        catch AxodServiceLifecycle.Failure.approval { }
        precondition(platform.agentCalls == 1)
        platform.agentRegistration = .notRegistered
        platform.failAgent = true
        do { try lifecycle.enableAgent(in: root); preconditionFailure("Failure required") }
        catch { }
        precondition(platform.agentCalls == 2 && lifecycle.failureMessage != nil)
        for _ in 0..<5 { lifecycle.observeRegistration() }
        precondition(platform.agentCalls == 2, "Unknown setup outcome is observed, not replayed")
        print("PASS: registration/readiness separation, stale observation fencing, explicit ownerless setup, approval/installation refusal, no reconnect effects, and independent frontend login startup")
    }
}
