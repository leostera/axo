import AppKit

@MainActor
enum MacAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    static let settingsKey = "axoMacAppearance"
    var id: Self { self }
    var title: String {
        switch self { case .system: "System"; case .light: "Light"; case .dark: "Dark" }
    }
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
    static func applyPreference() {
        (MacAppearance(rawValue: UserDefaults.standard.string(forKey: settingsKey) ?? "") ?? .system).apply()
    }
}
