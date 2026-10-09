import AppKit

@main
final class AxoMacApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var workspaces: WorkspaceController?
    private var runtime: GhosttyRuntime?

    static func main() {
        let app = NSApplication.shared
        let delegate = AxoMacApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !CommandLine.arguments.contains("--axo-workspaces-self-test"),
           let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
            existing.unhide()
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }

        do {
            let environment = ProcessInfo.processInfo.environment
            guard let configuredRoot = environment["AXO_REPO"]
                ?? Bundle.main.object(forInfoDictionaryKey: "AxoRepositoryPath") as? String,
                !configuredRoot.isEmpty else {
                throw LaunchError.missingRepository
            }
            let root = URL(fileURLWithPath: configuredRoot).standardizedFileURL.path
            guard FileManager.default.isReadableFile(atPath: root + "/scripts/run-pi.sh") else {
                throw LaunchError.repositoryUnavailable(root)
            }
            // Finder launches do not inherit the development shell's resource paths.
            if environment["GHOSTTY_RESOURCES_DIR"] == nil {
                setenv("GHOSTTY_RESOURCES_DIR", root + "/vendor/ghostty/zig-out/share/ghostty", 1)
            }
            if environment["TERMINFO"] == nil {
                setenv("TERMINFO", root + "/vendor/ghostty/zig-out/share/terminfo", 1)
            }
            let runtime = try GhosttyRuntime()
            self.runtime = runtime
            #if DEBUG
            if CommandLine.arguments.contains("--axo-workspaces-self-test") {
                do {
                    try WorkspaceSelfTest.run(runtime: runtime, repository: root) { controller in
                        self.workspaces = controller; self.installMenu()
                    }
                    exit(0)
                }
                catch { fputs("Axo workspace self-test failed: \(error)\n", stderr); exit(1) }
            }
            #endif
            let workspaces = try WorkspaceController(runtime: runtime, repository: root)
            self.workspaces = workspaces
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Axo"
            window.delegate = self
            window.contentView = workspaces.view
            workspaces.onTitle = { [weak window] title in window?.title = title }
            window.center()
            self.window = window
            installMenu()
            window.makeKeyAndOrderFront(nil)
            workspaces.restoreFocus()
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            #if DEBUG
            if CommandLine.arguments.contains("--axo-workspaces-self-test") {
                fputs("Axo workspace self-test initialization failed: \(error)\n", stderr); exit(1)
            }
            #endif
            let alert = NSAlert()
            alert.messageText = "Axo could not start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspaces?.shutdownVoice()
        workspaces?.stopBridgeHost()
    }

    func applicationDidBecomeActive(_ notification: Notification) { runtime?.setFocus(true) }
    func applicationDidResignActive(_ notification: Notification) { runtime?.setFocus(false) }
    func windowDidBecomeKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.workspaces?.setFocus(true) }
    }
    func windowDidResignKey(_ notification: Notification) { workspaces?.setFocus(false) }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        workspaces?.setWindowVisible(window?.occlusionState.contains(.visible) ?? false)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Keep the terminal surface/process alive when hiding the only window.
        sender.orderOut(nil)
        workspaces?.setWindowVisible(false)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        workspaces?.setWindowVisible(true)
        workspaces?.restoreFocus()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard workspaces?.hasLiveProcesses == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Axo and stop all terminals?"
        alert.informativeText = "Closing the window keeps sessions and shells running. Quitting stops all app-owned processes. Pi conversations and layouts remain saved locally."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(WorkspaceController.showSettings(_:)), keyEquivalent: ",")
        settings.target = workspaces
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Axo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let workItem = NSMenuItem()
        menu.addItem(workItem)
        let work = NSMenu(title: "Workspace")
        func add(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
            let item = work.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = workspaces; item.keyEquivalentModifierMask = modifiers
        }
        add("New Workspace…", #selector(WorkspaceController.newWorkspace(_:)), "n")
        add("New Session…", #selector(WorkspaceController.newSession(_:)), "t")
        add("Command Palette…", #selector(WorkspaceController.showCommandPalette(_:)), "p", [.command, .shift])
        let voice = work.addItem(withTitle: "Voice Dictation…", action: #selector(WorkspaceController.toggleVoiceDictation(_:)), keyEquivalent: "")
        voice.target = workspaces
        work.addItem(.separator())
        add("Previous Pane", #selector(WorkspaceController.previousPane(_:)), "[")
        add("Next Pane", #selector(WorkspaceController.nextPane(_:)), "]")
        add("Previous Session", #selector(WorkspaceController.previousSession(_:)), "{")
        add("Next Session", #selector(WorkspaceController.nextSession(_:)), "}")
        add("Previous Workspace", #selector(WorkspaceController.previousWorkspace(_:)), "<")
        add("Next Workspace", #selector(WorkspaceController.nextWorkspace(_:)), ">")
        work.addItem(.separator())
        add("Split Right", #selector(WorkspaceController.splitRight(_:)), "d")
        add("Split Down", #selector(WorkspaceController.splitDown(_:)), "e", [.command, .shift])
        add("Close Pane…", #selector(WorkspaceController.closePane(_:)), "w")
        add("Rename Session…", #selector(WorkspaceController.renameSession(_:)), "")
        add("Rename Workspace…", #selector(WorkspaceController.renameWorkspace(_:)), "")
        add("Toggle Sidebar", #selector(WorkspaceController.toggleSidebar(_:)), "s", [.command, .control])
        workItem.submenu = work
        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
        editItem.submenu = edit
        NSApp.mainMenu = menu
    }
}

enum LaunchError: LocalizedError {
    case missingRepository, repositoryUnavailable(String), ghosttyInitialization, surfaceCreation, missingDirectory

    var errorDescription: String? {
        switch self {
        case .missingRepository:
            "This development build is missing its checkout location. Run scripts/build-mac.sh from the Axo checkout, then open dist/Axo.app."
        case .repositoryUnavailable(let path):
            "The Axo checkout is unavailable at \(path). Keep the checkout in place, or rebuild the app from its new location with scripts/build-mac.sh."
        case .ghosttyInitialization:
            "The Ghostty terminal could not initialize. Build its framework with scripts/build-ghostty.sh, then rebuild Axo with scripts/build-mac.sh."
        case .surfaceCreation:
            "The terminal surface could not be created. Check that the Ghostty framework and resources are built for this checkout."
        case .missingDirectory:
            "The terminal's working directory is missing. Restore it or choose an existing directory."
        }
    }
}
