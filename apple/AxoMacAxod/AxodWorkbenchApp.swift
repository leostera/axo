import AppKit
import SwiftUI

@main
@MainActor
final class AxodWorkbenchApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private static let mainWindowFrameAutosaveName = "Axo.MainWindow.\(Bundle.main.bundleIdentifier ?? "default")"
    private static let applicationName: String = {
        let base = "dev.leostera.axo.mac"
        let identifier = Bundle.main.bundleIdentifier ?? base
        guard identifier.hasPrefix(base + ".") else { return "Axo" }
        return "Axo (\(identifier.dropFirst(base.count + 1)))"
    }()
    private var coordinator: AxodWorkbenchCoordinator?
    private var window: NSWindow?
    private var sidebarToolbar: AxodSidebarToolbar?
    private var waitingForDraftSave = false

    static func main() {
        let application = NSApplication.shared
        let delegate = AxodWorkbenchApp()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MacAppearance.applyPreference()
        let coordinator = AxodWorkbenchCoordinator()
        self.coordinator = coordinator

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.applicationName
        window.identifier = NSUserInterfaceItemIdentifier(Self.mainWindowFrameAutosaveName)
        window.delegate = self
        let sidebarToolbar = AxodSidebarToolbar {
            let preferences = UserDefaults.standard
            let key = AxodSidebarToolbar.collapsedPreferenceKey
            preferences.set(!preferences.bool(forKey: key), forKey: key)
        }
        self.sidebarToolbar = sidebarToolbar
        window.toolbarStyle = .unifiedCompact
        window.toolbar = sidebarToolbar.makeToolbar()
        window.contentViewController = NSHostingController(rootView: AxodWorkbenchView(coordinator: coordinator))
        let restoredFrame = window.setFrameUsingName(Self.mainWindowFrameAutosaveName)
        window.setFrameAutosaveName(Self.mainWindowFrameAutosaveName)
        if !restoredFrame { window.center() }

        self.window = window
        installMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        coordinator.registerForStartup()
        coordinator.registerDaemonService()
        coordinator.connect(createInitialSession: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }
        guard !waitingForDraftSave else { return .terminateLater }
        // Commit the field editor before freezing accepted draft edits. A failed
        // responder transfer cancels quit rather than silently dropping input.
        if let window, !window.makeFirstResponder(nil) { return .terminateCancel }
        waitingForDraftSave = true
        Task { [weak self] in
            let saved = await coordinator.chatDrafts.prepareToQuit()
            guard let self else { sender.reply(toApplicationShouldTerminate: false); return }
            self.waitingForDraftSave = false
            if !saved { self.window?.makeKeyAndOrderFront(nil) }
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        window?.saveFrame(usingName: Self.mainWindowFrameAutosaveName)
        coordinator?.voice.shutdown()
        // Axod owns its process tree; closing the client never stops or adopts daemon work.
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    @objc private func showAbout(_ sender: Any?) { coordinator?.showAboutWindow() }

    @objc private func showSettings(_ sender: Any?) {
        coordinator?.showSettingsWindow()
    }

    @objc private func refresh(_ sender: Any?) { coordinator?.refresh() }
    @objc private func connect(_ sender: Any?) { coordinator?.connect() }
    @objc private func newWorkspace(_ sender: Any?) { coordinator?.newWorkspace() }
    @objc private func newSession(_ sender: Any?) { coordinator?.newSession() }
    @objc private func splitRight(_ sender: Any?) {
        guard let window, NSApp.keyWindow === window else { return }
        coordinator?.splitRight(sender)
    }
    @objc private func splitDown(_ sender: Any?) {
        guard let window, NSApp.keyWindow === window else { return }
        coordinator?.splitDown(sender)
    }
    @objc private func toggleSidebar(_ sender: Any?) {
        guard let window, NSApp.keyWindow === window else { return }
        sidebarToolbar?.toggleSidebar(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSidebar(_:)) {
            return window != nil && NSApp.keyWindow === window
        }
        if menuItem.action == #selector(splitRight(_:)) || menuItem.action == #selector(splitDown(_:)) {
            return window != nil && NSApp.keyWindow === window && coordinator?.canSplitPane == true
        }
        if menuItem.action == #selector(newWorkspace(_:)) {
            return coordinator?.canEditWork == true && coordinator?.workEditor == nil
        }
        if menuItem.action == #selector(newSession(_:)) {
            return coordinator?.canEditWork == true && coordinator?.workEditor == nil
        }
        return true
    }

    private func installMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem(title: Self.applicationName, action: nil, keyEquivalent: "")
        menu.addItem(applicationItem)
        let applicationMenu = NSMenu()
        let about = applicationMenu.addItem(withTitle: "About Axo", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        applicationMenu.addItem(.separator())
        let settings = applicationMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        applicationMenu.addItem(.separator())
        let quit = applicationMenu.addItem(withTitle: "Quit \(Self.applicationName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        applicationItem.submenu = applicationMenu

        let workspaceItem = NSMenuItem()
        menu.addItem(workspaceItem)
        let workspaceMenu = NSMenu(title: "Workspace")
        let newWorkspaceItem = workspaceMenu.addItem(withTitle: "New Workspace…", action: #selector(newWorkspace(_:)), keyEquivalent: "n")
        newWorkspaceItem.target = self
        let newSessionItem = workspaceMenu.addItem(withTitle: "New Session", action: #selector(newSession(_:)), keyEquivalent: "t")
        newSessionItem.target = self
        workspaceMenu.addItem(.separator())
        let refreshItem = workspaceMenu.addItem(withTitle: "Refresh", action: #selector(refresh(_:)), keyEquivalent: "r")
        refreshItem.target = self
        let connectItem = workspaceMenu.addItem(withTitle: "Connect / Reconnect", action: #selector(connect(_:)), keyEquivalent: "r")
        connectItem.target = self
        connectItem.keyEquivalentModifierMask = [.command, .shift]
        workspaceItem.submenu = workspaceMenu

        let paneItem = NSMenuItem()
        menu.addItem(paneItem)
        let paneMenu = NSMenu(title: "Pane")
        let right = paneMenu.addItem(withTitle: "Split Right", action: #selector(splitRight(_:)), keyEquivalent: "d")
        right.target = self
        let down = paneMenu.addItem(withTitle: "Split Down", action: #selector(splitDown(_:)), keyEquivalent: "d")
        down.target = self
        down.keyEquivalentModifierMask = [.command, .shift]
        paneItem.submenu = paneMenu

        let viewItem = NSMenuItem()
        menu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let toggle = viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar(_:)), keyEquivalent: "s")
        toggle.target = self
        toggle.keyEquivalentModifierMask = [.control, .command]
        viewItem.submenu = viewMenu

        NSApp.mainMenu = menu
    }

}
