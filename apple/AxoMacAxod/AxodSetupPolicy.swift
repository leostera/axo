import AxoProtocol
import Foundation

/// Presentation facts only. Registered is not responding, and a responding
/// host is not a successfully loaded workbench catalog.
enum AxodSetupPolicy {
    enum Connection: Equatable { case checking, unavailable, loaded(MachineTarget) }
    enum Stage: Equatable { case installation, enableService, approval, checking, unavailable, ready(MachineTarget) }

    static func isInstalled(bundle: URL, home: URL) -> Bool {
        let path = bundle.standardizedFileURL.resolvingSymlinksInPath().path
        let applications = home.appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        guard bundle.pathExtension == "app", !path.contains("/AppTranslocation/") else { return false }
        return path.hasPrefix("/Applications/") || path.hasPrefix(applications + "/")
    }

    static func stage(installed: Bool, registration: AxodServiceLifecycle.Registration,
                      availability: AxodServiceLifecycle.Availability, connection: Connection) -> Stage {
        guard installed else { return .installation }
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
