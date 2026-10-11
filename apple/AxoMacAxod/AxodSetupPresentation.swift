import AxoProtocol
import CoreFoundation
import Foundation
import Observation

@MainActor @Observable
final class AxodSetupPresentation {
    static let completionKey = "Axo.app.setup.version"
    private(set) var enteredWorkbench = false
    var requestedLoginStartup: Bool?
    var isFinishing = false
    var failure: String?
    @ObservationIgnored private let preferences: UserDefaults

    init(preferences: UserDefaults) { self.preferences = preferences }

    private var hint: Hint {
        guard let value = preferences.object(forKey: Self.completionKey) else { return .absent }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number == NSNumber(value: 1) else { return .unrecognized }
        return .current
    }
    private enum Hint { case absent, current, unrecognized }

    func restoreIfKnownReady(_ stage: AxodSetupPolicy.Stage) {
        if case .ready = stage, hint == .current { enteredWorkbench = true }
    }

    @discardableResult
    func complete(captured: MachineTarget, stage: AxodSetupPolicy.Stage) -> Bool {
        guard stage == .ready(captured) else { return false }
        // Unknown future/opaque preferences are retained, not downgraded.
        if hint != .unrecognized { preferences.set(1, forKey: Self.completionKey) }
        enteredWorkbench = true
        return true
    }
}
