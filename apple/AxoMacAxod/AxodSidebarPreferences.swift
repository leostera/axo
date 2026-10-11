import Foundation

/// Expanded width is separate; collapse never destroys navigation or work.
enum AxodSidebarPreferences {
    static let collapsedPreferenceKey = "Axo.axod.sidebarCollapsed"

    static func toggle(in preferences: UserDefaults) {
        preferences.set(!preferences.bool(forKey: collapsedPreferenceKey), forKey: collapsedPreferenceKey)
    }
}
