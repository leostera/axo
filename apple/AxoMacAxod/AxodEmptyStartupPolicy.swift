import Foundation

/// Preferences are reconciliation hints, not empty-state authority. Even malformed
/// hints block automatic launch until explicitly reconciled; none are removed here.
enum AxodEmptyStartupPolicy {
    static func hasPendingIntent(in preferences: UserDefaults, machineID: UUID) -> Bool {
        let machine = "." + machineID.uuidString.lowercased()
        return preferences.dictionaryRepresentation().keys.contains {
            let key = $0.lowercased()
            return key.hasPrefix("axo.axod.pending") && (key.hasSuffix(machine) || key.contains(machine + "."))
        }
    }
}
