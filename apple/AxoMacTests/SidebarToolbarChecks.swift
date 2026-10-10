import AppKit

/// Exercises only owned hidden-window chrome and disposable preferences, never the live client.
@main
struct SidebarToolbarChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let suite = "Axo.SidebarFixture.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let key = AxodSidebarToolbar.collapsedPreferenceKey
        let controller = AxodSidebarToolbar { preferences.set(!preferences.bool(forKey: key), forKey: key) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.toolbar = controller.makeToolbar()
        let toolbar = window.toolbar!
        guard let item = toolbar.items.first(where: { $0.itemIdentifier == AxodSidebarToolbar.toggleItemIdentifier }),
              let action = item.action else { preconditionFailure("Persistent sidebar toggle missing") }
        for _ in 0..<20 {
            precondition(!preferences.bool(forKey: key))
            precondition(NSApp.sendAction(action, to: item.target, from: item))
            precondition(preferences.bool(forKey: key))
            precondition(window.toolbar === toolbar && toolbar.isVisible && item.isEnabled)
            precondition(NSApp.sendAction(action, to: item.target, from: item))
            precondition(!preferences.bool(forKey: key))
        }
        preferences.set(true, forKey: key) // Restore an already-collapsed preference.
        precondition(NSApp.sendAction(action, to: item.target, from: item))
        precondition(!preferences.bool(forKey: key))
        print("Sidebar toolbar: repeated close/reopen and restored-collapsed state passed in an owned hidden window.")
    }
}
