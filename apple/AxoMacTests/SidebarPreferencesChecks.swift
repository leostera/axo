import Foundation

@main
struct SidebarPreferencesChecks {
    static func main() {
        let suite = "Axo.SidebarFixture.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let key = AxodSidebarPreferences.collapsedPreferenceKey
        for _ in 0..<20 {
            precondition(!preferences.bool(forKey: key))
            AxodSidebarPreferences.toggle(in: preferences)
            precondition(preferences.bool(forKey: key))
            AxodSidebarPreferences.toggle(in: preferences)
            precondition(!preferences.bool(forKey: key))
        }
        preferences.set(true, forKey: key)
        AxodSidebarPreferences.toggle(in: preferences)
        precondition(!preferences.bool(forKey: key))
        print("Sidebar preferences: scoped repeated collapse/expand and restored state passed.")
    }
}
