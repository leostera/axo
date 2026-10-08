import AppKit

@main
final class AxoMacApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var terminal: TerminalView?
    private var runtime: GhosttyRuntime?

    static func main() {
        let app = NSApplication.shared
        let delegate = AxoMacApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard let root = ProcessInfo.processInfo.environment["AXO_REPO"] else {
                throw LaunchError.missingRepository
            }
            let runtime = try GhosttyRuntime()
            self.runtime = runtime
            let terminal = try TerminalView(runtime: runtime, repository: root)
            self.terminal = terminal
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Axo — Playground"
            window.delegate = self
            window.contentView = terminal
            window.center()
            self.window = window
            installMenu()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(terminal)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Axo could not start"
            alert.informativeText = "\(error). Launch with scripts/run-mac.sh after building the Ghostty framework."
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) { runtime?.setFocus(true) }
    func applicationDidResignActive(_ notification: Notification) { runtime?.setFocus(false) }
    func windowDidBecomeKey(_ notification: Notification) { terminal?.setFocus(true) }
    func windowDidResignKey(_ notification: Notification) { terminal?.setFocus(false) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Keep the terminal surface/process alive when hiding the only window.
        sender.orderOut(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminal != nil else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Axo and stop Pi?"
        alert.informativeText = "Closing the window keeps Pi running. Quitting stops the terminal. The Pi conversation remains saved locally."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Axo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
        editItem.submenu = edit
        NSApp.mainMenu = menu
    }
}

enum LaunchError: Error { case missingRepository, ghosttyInitialization, surfaceCreation }
