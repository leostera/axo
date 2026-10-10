import AppKit

/// Window chrome, not a detail-surface overlay: hiding the sidebar cannot hide its toggle.
@MainActor
final class AxodSidebarToolbar: NSObject, NSToolbarDelegate {
    static let collapsedPreferenceKey = "Axo.axod.sidebarCollapsed"
    // The reserved .toggleSidebar item overrides target/action for NSSplitViewController.
    // This window hosts a custom split view, so route a normal toolbar item explicitly.
    static let toggleItemIdentifier = NSToolbarItem.Identifier("Axo.ToggleSidebar")
    private let onToggle: () -> Void

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        super.init()
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "Axo.MainWindow.Toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    @objc func toggleSidebar(_ sender: Any?) { onToggle() }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.toggleItemIdentifier] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.toggleItemIdentifier] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == Self.toggleItemIdentifier else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Toggle Sidebar"
        item.toolTip = "Show or hide sidebar (⌃⌘S)"
        item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")
        item.target = self
        item.action = #selector(toggleSidebar(_:))
        return item
    }
}
