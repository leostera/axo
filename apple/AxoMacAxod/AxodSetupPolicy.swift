import AxoProtocol
import Foundation

/// ServiceManagement registration and actual host readiness are independent.
enum AxodSetupPolicy {
    enum Connection: Equatable { case checking, unavailable, loaded(MachineTarget) }
    enum Stage: Equatable { case enableService, approval, checking, unavailable, ready(MachineTarget) }

    struct Step: Identifiable, Equatable {
        let number: Int
        let title: String
        let complete: Bool
        var id: Int { number }
    }

    static func steps(registration: AxodServiceLifecycle.Registration) -> [Step] {
        [
            Step(number: 1, title: "Register background service", complete: registration == .enabled || registration == .requiresApproval),
            Step(number: 2, title: "Allow background activity", complete: registration == .enabled),
            Step(number: 3, title: "Open Axo", complete: false),
        ]
    }

    static func stage(registration: AxodServiceLifecycle.Registration,
                      availability: AxodServiceLifecycle.Availability, connection: Connection) -> Stage {
        switch registration {
        case .notRegistered: return .enableService
        case .requiresApproval: return .approval
        case .notFound: return .unavailable
        case .unavailable: return connection == .checking ? .checking : .unavailable
        case .enabled: break
        }
        switch connection {
        case .checking: return .checking
        case .unavailable: return .unavailable
        case .loaded(let target): return availability == .ready(target) ? .ready(target) : .unavailable
        }
    }
}
