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
    private var savesWindowFrame = true

    static func main() {
        let application = NSApplication.shared
        let delegate = AxodWorkbenchApp()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MacAppearance.applyPreference()
#if DEBUG
        let selfTest: AxodAppSelfTest?
        if CommandLine.arguments.contains("-self-test") {
            guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "-self-test",
                  CommandLine.arguments[2].hasPrefix("/") else {
                fputs("Usage: Axo -self-test /absolute/private/fixture-root\n", stderr); exit(2)
            }
            do { selfTest = try AxodAppSelfTest(root: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)) }
            catch { fputs("Axo self-test requires a safe prepared fixture root\n", stderr); exit(2) }
        } else { selfTest = nil }
        let coordinator = AxodWorkbenchCoordinator(preferences: selfTest?.preferences ?? .standard,
            voiceHistoryURL: selfTest?.root.appendingPathComponent("voice-transcripts.json"))
        if let selfTest { coordinator.configureSelfTest(selfTest); savesWindowFrame = false }
#else
        if CommandLine.arguments.contains("-self-test") {
            fputs("Axo -self-test requires a development build\n", stderr); exit(2)
        }
        let coordinator = AxodWorkbenchCoordinator()
#endif
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
        let restoredFrame = savesWindowFrame && window.setFrameUsingName(Self.mainWindowFrameAutosaveName)
        if savesWindowFrame { window.setFrameAutosaveName(Self.mainWindowFrameAutosaveName) }
        if !restoredFrame { window.center() }

        self.window = window
        installMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

#if DEBUG
        if selfTest == nil {
            coordinator.registerForStartup()
            coordinator.registerDaemonService()
        }
#else
        coordinator.registerForStartup()
        coordinator.registerDaemonService()
#endif
        coordinator.connect(createInitialSession: true)
#if DEBUG
        if let selfTest {
            Task { await selfTest.run(coordinator: coordinator, window: window) }
        }
#endif
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
        if savesWindowFrame { window?.saveFrame(usingName: Self.mainWindowFrameAutosaveName) }
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
        sidebarToolbar?.toggleSidebar(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let direction = focusDirection(for: menuItem.action) {
            guard let window, NSApp.keyWindow === window else { return false }
            return coordinator?.capturePaneFocus(direction, in: window) != nil
        }
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
        paneMenu.addItem(.separator())
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
