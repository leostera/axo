import AppKit

/// Client UI only. Menu actions never own a daemon or execution resource.
@MainActor
final class AxodMenuBarController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let statusLine = NSMenuItem(title: "Axo", action: nil, keyEquivalent: "")
    private let status: () -> String
    private let open: () -> Void
    private let settings: () -> Void
    private let service: () -> Void

    init(status: @escaping () -> String, open: @escaping () -> Void,
         settings: @escaping () -> Void, service: @escaping () -> Void) {
        self.status = status; self.open = open; self.settings = settings; self.service = service
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let image = NSImage(systemSymbolName: "hammer", accessibilityDescription: "Axo")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Axo — Open the workbench or background-service setup"
        item.button?.setAccessibilityLabel("Axo menu")
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        add("Open Axo", action: #selector(openAxo(_:)), to: menu)
        add("Settings…", action: #selector(openSettings(_:)), to: menu)
        add("Background Service…", action: #selector(openService(_:)), to: menu)
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Axo — Leave Daemon Running", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) { statusLine.title = status() }
    func remove() { NSStatusBar.system.removeStatusItem(item) }
    private func add(_ title: String, action: Selector, to menu: NSMenu) {
        let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        entry.target = self
    }
    @objc private func openAxo(_ sender: Any?) { open() }
    @objc private func openSettings(_ sender: Any?) { settings() }
    @objc private func openService(_ sender: Any?) { service() }

#if AXO_RESIDENT_FIXTURE
    var fixtureItem: NSStatusItem { item }
    var fixtureMenu: NSMenu { item.menu! }
#endif
}
