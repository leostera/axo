import AppKit
import AxoCore
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
    private var menuBar: AxodMenuBarController?

    static func main() {
#if DEBUG
        if CommandLine.arguments.count == 2, ["-repair-stopped-service", "-repair-stopped-service-parent"].contains(CommandLine.arguments[1]) {
            // Explicit operator action in the actual signed app's Bundle.main
            // context. Never a connection fallback or a hidden execution command.
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            guard !NSWorkspace.shared.runningApplications.contains(where: {
                $0.bundleIdentifier == "dev.leostera.axo.mac" && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }) else { fputs("Quit Axo frontends before stopped-service maintenance\n", stderr); exit(2) }
            Task { @MainActor in
                do { try await AxodStoppedServiceRepair.run(refreshParent: CommandLine.arguments[1] == "-repair-stopped-service-parent"); exit(0) }
                catch {
                    if let failure = error as? AxodStoppedServiceRepair.Failure {
                        fputs("Stopped-service maintenance failure: \(failure)\n", stderr)
                    } else { fputs("Stopped-service platform error code: \((error as NSError).code)\n", stderr) }
                    fputs("Its original ticket is preserved; no retry or state reset was performed.\n", stderr)
                    exit(3)
                }
            }
            application.run()
            return
        }
#endif
        let application = NSApplication.shared
        let delegate = AxodWorkbenchApp()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MacAppearance.applyPreference()
        if CommandLine.arguments.contains("-self-test") || CommandLine.arguments.contains("-ui-test") {
            fputs("Retired startup fixture flags are unsupported\n", stderr); exit(2)
        }
#if !DEBUG
        if CommandLine.arguments.contains("-repair-stopped-service") || CommandLine.arguments.contains("-repair-stopped-service-parent") {
            fputs("Axo diagnostic flags require a development build\n", stderr); exit(2)
        }
#endif
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
        window.contentViewController = NSHostingController(rootView: AxodApplicationView(coordinator: coordinator))
        let restoredFrame = window.setFrameUsingName(Self.mainWindowFrameAutosaveName)
        window.setFrameAutosaveName(Self.mainWindowFrameAutosaveName)
        if !restoredFrame { window.center() }

        self.window = window
        installMenu()
        menuBar = AxodMenuBarController(status: { [weak coordinator] in
            guard let coordinator else { return "Axo — Service state unavailable" }
            if coordinator.showsSetup { return "Axo — Setup required" }
            return coordinator.connectionState == .connected ? "Axo — Connected locally" : "Axo — Service unavailable"
        }, open: { [weak self] in self?.showWorkbench(nil) },
           settings: { [weak self] in self?.showSettings(nil) },
           service: { [weak self] in self?.serviceSettings(nil) })
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowPresentationChanged(_:)), name: NSWindow.willCloseNotification, object: nil)
        center.addObserver(self, selector: #selector(windowPresentationChanged(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        let loginLaunch = AxodResidentPresentation.isLoginLaunch(NSAppleEventManager.shared().currentAppleEvent)
        if loginLaunch { NSApp.setActivationPolicy(.accessory) }
        else { showWorkbench(nil) }

        // Neither foreground nor login-only connection creates work.
        coordinator.connect()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Unsent input is volatile. Commit the native field editor, without a
        // save barrier, helper stop or runtime lifecycle intent.
        if let window = NSApp.keyWindow ?? window, !window.makeFirstResponder(nil) { return .terminateCancel }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        window?.saveFrame(usingName: Self.mainWindowFrameAutosaveName)
        NotificationCenter.default.removeObserver(self)
        menuBar?.remove()
        menuBar = nil
        coordinator?.voice.shutdown()
        // Axod owns its process tree; closing the client never stops or adopts daemon work.
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        AxodResidentPresentation.hide(sender)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWorkbench(nil)
        return true
    }

    @objc private func showWorkbench(_ sender: Any?) {
        if let window { AxodResidentPresentation.show(window) }
        // First visible onboarding asks macOS to register the bundled LaunchAgent.
        // Login-only residency and subsequent reconnects never dispatch setup.
        if coordinator?.beginFirstLaunchSetup() == true { coordinator?.connect() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Returning from macOS approval observes readiness; it cannot register again.
        coordinator?.refreshSetupAfterActivation()
    }

    @objc private func windowPresentationChanged(_ notification: Notification) {
        // willClose is delivered before the window leaves the application's
        // visible set; observe after that transition, not from a stale count.
        Task { @MainActor [weak self] in self?.updateActivationPolicy() }
    }

    private func updateActivationPolicy() {
        let policy = AxodResidentPresentation.activationPolicy(windows: NSApp.windows)
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    @objc private func showAbout(_ sender: Any?) { coordinator?.showAboutWindow() }

    @objc private func showSettings(_ sender: Any?) {
        NSApp.setActivationPolicy(.regular)
        coordinator?.showSettingsWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func serviceSettings(_ sender: Any?) {
        NSApp.setActivationPolicy(.regular)
        coordinator?.showServiceSettingsWindow()
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func refresh(_ sender: Any?) { coordinator?.refresh() }
    @objc private func connect(_ sender: Any?) { coordinator?.connect() }
    @objc private func newSession(_ sender: Any?) { coordinator?.createSession() }
    @objc private func newWorkspace(_ sender: Any?) {
        guard let coordinator, coordinator.canCreate, let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Workspace Folder"
        panel.message = "Axo will reserve the workspace and its initial session as one operation."
        panel.prompt = "Create Workspace"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let name = try WorkbenchName(url.lastPathComponent)
                coordinator.createWorkspace(name: name.value, directoryPath: url.resolvingSymlinksInPath().standardizedFileURL.path)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Workspace name is invalid"
                alert.informativeText = "Choose a folder whose name is non-empty and no longer than 120 UTF-8 bytes."
                alert.alertStyle = .warning
                alert.beginSheetModal(for: window)
            }
        }
    }
    @objc private func focusLeft(_ sender: Any?) { movePaneFocus(.left) }
    @objc private func focusRight(_ sender: Any?) { movePaneFocus(.right) }
    @objc private func focusUp(_ sender: Any?) { movePaneFocus(.up) }
    @objc private func focusDown(_ sender: Any?) { movePaneFocus(.down) }
    @objc private func focusPrevious(_ sender: Any?) { movePaneFocus(.previous) }
    @objc private func focusNext(_ sender: Any?) { movePaneFocus(.next) }
    private func movePaneFocus(_ direction: AxodPaneFocusDirection) {
        guard let window, NSApp.keyWindow === window else { return }
        coordinator?.focusPane(direction, in: window)
    }
    private func focusDirection(for action: Selector?) -> AxodPaneFocusDirection? {
        switch action {
        case #selector(focusLeft(_:)): return .left
        case #selector(focusRight(_:)): return .right
        case #selector(focusUp(_:)): return .up
        case #selector(focusDown(_:)): return .down
        case #selector(focusPrevious(_:)): return .previous
        case #selector(focusNext(_:)): return .next
        default: return nil
        }
    }
    @objc private func toggleSidebar(_ sender: Any?) {
        guard let window, NSApp.keyWindow === window else { return }
        guard let coordinator else { return }
        AxodSidebarPreferences.toggle(in: coordinator.preferences)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let direction = focusDirection(for: menuItem.action) {
            guard let window, NSApp.keyWindow === window else { return false }
            return coordinator?.capturePaneFocus(direction, in: window) != nil
        }
        if menuItem.action == #selector(toggleSidebar(_:)) {
            return window != nil && NSApp.keyWindow === window
        }
        if menuItem.action == #selector(newSession(_:)) { return coordinator?.canCreateSession == true }
        if menuItem.action == #selector(newWorkspace(_:)) { return coordinator?.canCreate == true }
        return true
    }

    private struct PaneFocusMenuItem {
        let title: String
        let action: Selector
        let key: String
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
        let service = applicationMenu.addItem(withTitle: "Background Service…", action: #selector(serviceSettings(_:)), keyEquivalent: "")
        service.target = self
        let open = applicationMenu.addItem(withTitle: "Open Axo", action: #selector(showWorkbench(_:)), keyEquivalent: "")
        open.target = self
        applicationMenu.addItem(.separator())
        let quit = applicationMenu.addItem(withTitle: "Quit \(Self.applicationName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        applicationItem.submenu = applicationMenu

        // Native editors and the system folder picker rely on responder-chain
        // editing commands; terminal copy/paste also route to their real view.
        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let workspaceItem = NSMenuItem()
        menu.addItem(workspaceItem)
        let workspaceMenu = NSMenu(title: "Workspace")
        let newSessionItem = workspaceMenu.addItem(withTitle: "New Session", action: #selector(newSession(_:)), keyEquivalent: "t")
        newSessionItem.target = self
        let newWorkspaceItem = workspaceMenu.addItem(withTitle: "New Workspace…", action: #selector(newWorkspace(_:)), keyEquivalent: "")
        newWorkspaceItem.target = self
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
        let focusItems: [PaneFocusMenuItem] = [
            .init(title: "Focus Left", action: #selector(focusLeft(_:)), key: "\u{F702}"),
            .init(title: "Focus Right", action: #selector(focusRight(_:)), key: "\u{F703}"),
            .init(title: "Focus Up", action: #selector(focusUp(_:)), key: "\u{F700}"),
            .init(title: "Focus Down", action: #selector(focusDown(_:)), key: "\u{F701}"),
            .init(title: "Focus Previous Pane", action: #selector(focusPrevious(_:)), key: ""),
            .init(title: "Focus Next Pane", action: #selector(focusNext(_:)), key: ""),
        ]
        for descriptor in focusItems {
            let item = paneMenu.addItem(withTitle: descriptor.title, action: descriptor.action, keyEquivalent: descriptor.key)
            item.target = self
            item.keyEquivalentModifierMask = [.command, .option]
        }
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
