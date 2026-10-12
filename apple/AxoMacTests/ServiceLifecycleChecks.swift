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
    var agentResult: AxodServiceLifecycle.Registration = .enabled
    var approvalError = false
    func registerAgent() throws {
        agentCalls += 1
        if failAgent { throw NSError(domain: "fixture", code: 99) }
        agentRegistration = agentResult
        if approvalError { throw NSError(domain: "fixture", code: 100) }
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
        platform.loginRegistration = .requiresApproval
        let disabledPendingApproval = await lifecycle.setFrontendAtLogin(false)
        precondition(disabledPendingApproval)
        precondition(platform.logoutCalls == 2 && platform.agentCalls == 2)
        platform.loginRegistration = .unavailable
        let enabledUnavailableLogin = await lifecycle.setFrontendAtLogin(true)
        precondition(!enabledUnavailableLogin)
        precondition(lifecycle.failureMessage != nil && platform.agentCalls == 2)
        try checkFirstLaunchRegistration(in: root)
        print("PASS: first-visible registration once, approval/error semantics, durable unknown/no replay, receipt and repair preservation, owner refusal, read-only reconnect, independent login, and stale readiness fencing")
    }

    @MainActor private static func checkFirstLaunchRegistration(in parent: URL) throws {
        func privateRoot(_ name: String) throws -> URL {
            let root = parent.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            return root
        }
        let fresh = try privateRoot("fresh")
        let platform = ServicePlatformFixture()
        platform.agentResult = .requiresApproval
        platform.approvalError = true
        let lifecycle = AxodServiceLifecycle(platform: platform)
        try lifecycle.registerForFirstLaunch(in: fresh)
        precondition(platform.agentCalls == 1 && lifecycle.registration == .requiresApproval)
        precondition(lifecycle.failureMessage == nil && lifecycle.availability == .unknown)
        precondition(platform.loginCalls == 0 && platform.logoutCalls == 0, "Agent setup does not opt in frontend login")
        precondition((try? AxodAgentRegistrationRequest.hasReceipt(in: fresh)) == true)
        try lifecycle.registerForFirstLaunch(in: fresh)
        precondition(platform.agentCalls == 1, "Repeated presentation is not another request")
        platform.agentRegistration = .notRegistered
        let reopened = AxodServiceLifecycle(platform: platform)
        try reopened.registerForFirstLaunch(in: fresh)
        precondition(platform.agentCalls == 1, "A recorded registration later removed by the user is not silently restored")

        let unknown = try privateRoot("unknown")
        let failurePlatform = ServicePlatformFixture()
        failurePlatform.failAgent = true
        let failureLifecycle = AxodServiceLifecycle(platform: failurePlatform)
        do { try failureLifecycle.registerForFirstLaunch(in: unknown); preconditionFailure("SDK failure required") }
        catch { }
        let pending = unknown.appendingPathComponent("agent-registration.pending.json")
        let original = try Data(contentsOf: pending)
        let nextLaunch = AxodServiceLifecycle(platform: failurePlatform)
        do { try nextLaunch.registerForFirstLaunch(in: unknown); preconditionFailure("Original pending request must block redispatch") }
        catch AxodAgentRegistrationRequest.Failure.unresolved { }
        precondition(failurePlatform.agentCalls == 1)
        precondition((try? Data(contentsOf: pending)) == original)
        var metadata = stat()
        precondition(lstat(pending.path, &metadata) == 0 && metadata.st_mode & 0o777 == 0o600 && metadata.st_nlink == 1)

        for name in ["agent-service-repair.pending.json", "agent-parent-repair.pending.json", "agent-registration.pending.json"] {
            let blocked = try privateRoot("\(name)-fixture")
            let evidence = blocked.appendingPathComponent(name)
            let opaque = Data("opaque-original".utf8)
            try opaque.write(to: evidence)
            let refused = ServicePlatformFixture()
            do { try AxodServiceLifecycle(platform: refused).registerForFirstLaunch(in: blocked); preconditionFailure("Opaque original must remain") }
            catch AxodAgentRegistrationRequest.Failure.unresolved { }
            precondition(refused.agentCalls == 0 && (try? Data(contentsOf: evidence)) == opaque)
        }

        let busy = try privateRoot("busy")
        let owner = try AxodOwnerAbsenceLease.acquire(in: busy)!
        defer { owner.release() }
        let competing = ServicePlatformFixture()
        do { try AxodServiceLifecycle(platform: competing).registerForFirstLaunch(in: busy); preconditionFailure("Live owner refusal required") }
        catch AxodServiceLifecycle.Failure.liveOwner { }
        precondition(competing.agentCalls == 0)
        precondition(!FileManager.default.fileExists(atPath: busy.appendingPathComponent("agent-registration.pending.json").path))

        for status in [AxodServiceLifecycle.Registration.enabled, .requiresApproval, .notFound, .unavailable] {
            let registered = ServicePlatformFixture()
            registered.agentRegistration = status
            try AxodServiceLifecycle(platform: registered).registerForFirstLaunch(in: parent)
            precondition(registered.agentCalls == 0, "Existing registration/approval is observation only")
        }

        let tampered = try privateRoot("tampered")
        let request = try AxodAgentRegistrationRequest.prepare(in: tampered)
        let changed = tampered.appendingPathComponent("agent-registration.pending.json")
        let opaque = Data("changed".utf8)
        try opaque.write(to: changed)
        do { try request.confirmRegistration(); preconditionFailure("Changed original cannot become a receipt") }
        catch AxodAgentRegistrationRequest.Failure.unsafeStorage { }
        precondition((try? Data(contentsOf: changed)) == opaque)
    }
}
