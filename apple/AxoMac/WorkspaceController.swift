import AppKit
import AxoCore
import GhosttyKit
import SwiftUI

/// Owns surfaces independently of selected views. Switching never releases a process.
final class WorkspaceController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSplitViewDelegate, NSMenuItemValidation {
    typealias SurfaceTree = SplitTree<PaneHostView>
    private static let minimumContentWidth: CGFloat = 200
    private enum NavigationDirection: Equatable { case previous, next }
    private enum NavigationScope { case pane, session, workspace }

    let view = NSSplitView()
    private let sidebar = WorkspaceOutlineView()
    private var editingSidebar = false
    private let sidebarContainer = NSVisualEffectView()
    private let reopenSidebar = NSButton()
    private var sidebarMinimumWidth: NSLayoutConstraint?
    private var sidebarWidth: CGFloat = CGFloat(WorkspaceWindowState.defaultSidebarWidth)
    private var sidebarStateSaveWork: DispatchWorkItem?
    private var positionedSidebar = false
    private(set) var sidebarCollapsed = false
    private let titleQueue = DispatchQueue(label: "dev.leostera.axo.session-titles", qos: .utility)
    private var pendingTitleReads = Set<PaneID>()
    private var deferredTitleReads = Set<PaneID>()
    private let content = NSView()
    private let store: WorkspaceStore
    private let repository: String
    private let scratchRoot: URL
    private let sidebarStateURL: URL
    private let stateRoot: URL
    private let bridgeDirectory: URL
    private let bindingDirectory: URL
    private var bridgeHost: BridgeHostProcess?
    private var stateBindings: [PaneID: MacSessionBinding] = [:]
    private var initialObservationDeadlines: [PaneID: Date] = [:]
    private var agentSnapshots: [PaneID: MacSessionState] = [:]
    private var attentionReceipts: [PaneID: MacAttentionReceipt] = [:]
    private var stateObserver: MacSessionObserver?
    private var notifications: MacSessionNotifications?
    private var voiceCoordinator: MacVoiceCoordinator?
    private var voiceKeyMonitor: Any?
    private var voiceApplicationResignObserver: NSObjectProtocol?
    private var voiceKeyGesture = MacVoiceKeyGesture()
    private var voiceKeyOwnsCapture = false
    private var voiceGestureTimeoutTask: Task<Void, Never>?
    private let runtime: GhosttyRuntime
    private var livePanes: [PaneID: TerminalView] = [:]
    private var launchFailures: [PaneID: String] = [:]
    private var paneHosts: [PaneID: PaneHostView] = [:]
    private var splitHost: NSHostingView<PaneSplitTreeView>?
    private var closeConfirmation: NSAlert?
    private var commandPalette: NSPanel?
    private var sidebarItems: [SidebarItem] = []
    private var refreshingSidebar = false
    private var collapsedWorkspaces = Set<WorkspaceID>()
    private let launchOverride: ((PaneRecord, WorkSession) -> TerminalLaunch)?
    struct WorkspaceCreationRequest { let directory: String; let name: String }
    var workspaceRequestProvider: ((String?) -> WorkspaceCreationRequest?)?
    var nameProvider: ((String, String) -> String?)?
    var registry: WorkspaceRegistry { store.registry }
    func terminal(for pane: PaneID) -> TerminalView? { livePanes[pane] }
    func resumePane(_ id: PaneID, in sessionID: AxoSessionID) throws {
        guard let session = store.registry.sessions.first(where: { $0.id == sessionID }),
              let pane = session.panes.first(where: { $0.id == id }) else { throw WorkspaceFault.notFound }
        launchFailures.removeValue(forKey: id)
        try launch(pane, in: session)
        refreshSidebar(); showSelectedSession()
    }
    func activateSession(_ id: AxoSessionID) throws {
        try store.select(id)
        openSavedPanes(in: id)
        notifications?.dismiss(id)
        refreshSidebar(); showSelectedSession()
    }
    func stopBridgeHost() { bridgeHost?.stop(); bridgeHost = nil }
    @MainActor func shutdownVoice() {
        voiceKeyOwnsCapture = false
        voiceKeyGesture.clear()
        voiceGestureTimeoutTask?.cancel()
        voiceGestureTimeoutTask = nil
        if let voiceKeyMonitor { NSEvent.removeMonitor(voiceKeyMonitor) }
        voiceKeyMonitor = nil
        if let voiceApplicationResignObserver {
            NotificationCenter.default.removeObserver(voiceApplicationResignObserver)
        }
        voiceApplicationResignObserver = nil
        voiceCoordinator?.shutdown()
    }

    private func handleBridgeRequest(_ frame: [String: Any]) {
        guard let requestID = frame["id"] as? String, let type = frame["type"] as? String else { return }
        do {
            switch type {
            case "create_workspace":
                guard let name = frame["name"] as? String else { throw WorkspaceFault.invalidName }
                let receipt = try store.createWorkspace(name: name, commandID: requestID, kind: .project,
                                                        selectAfterCreation: false)
                refreshSidebar()
                bridgeHost?.reply(["type": "ack", "id": requestID, "disposition": "created",
                                   "workspaceId": receipt.workspaceID.rawValue.uuidString,
                                   "sessionId": receipt.sessionID.rawValue.uuidString])
            case "create_session":
                guard let name = frame["name"] as? String,
                      let workspaceText = frame["workspaceId"] as? String,
                      let workspaceUUID = UUID(uuidString: workspaceText) else { throw WorkspaceFault.notFound }
                let receipt = try store.createSession(workspaceID: WorkspaceID(workspaceUUID), name: name,
                                                       commandID: requestID, selectAfterCreation: false)
                refreshSidebar()
                bridgeHost?.reply(["type": "ack", "id": requestID, "disposition": "created",
                                   "workspaceId": receipt.workspaceID.rawValue.uuidString,
                                   "sessionId": receipt.sessionID.rawValue.uuidString])
            case "rename_workspace":
                guard let workspaceText = frame["workspaceId"] as? String,
                      let workspaceUUID = UUID(uuidString: workspaceText),
                      let name = frame["name"] as? String else { throw WorkspaceFault.conflict }
                try store.renameWorkspace(WorkspaceID(workspaceUUID), name: name)
                bridgeHost?.reply(["type": "ack", "id": requestID, "disposition": "updated"])
            case "rename_session":
                guard let sessionText = frame["sessionId"] as? String,
                      let sessionUUID = UUID(uuidString: sessionText),
                      let name = frame["name"] as? String else { throw WorkspaceFault.conflict }
                try store.renameSession(AxoSessionID(sessionUUID), name: name)
                bridgeHost?.reply(["type": "ack", "id": requestID, "disposition": "updated"])
            default: throw WorkspaceFault.notFound
            }
        } catch {
            bridgeHost?.reply(["type": "error", "id": requestID,
                               "message": error is WorkspaceFault && (error as? WorkspaceFault) == .conflict
                                ? "Workspace data changed. Refresh the catalog before retrying."
                                : "The Mac could not apply that workspace change."])
        }
    }

    private func writeBridgeBinding(_ binding: MacSessionBinding) throws {
        let url = bindingDirectory.appendingPathComponent(binding.paneID.rawValue.uuidString + ".json")
        let values: [String: String] = [
            "sessionId": binding.sessionID.rawValue.uuidString,
            "paneId": binding.paneID.rawValue.uuidString,
            "runtimeGeneration": binding.generation.uuidString,
            "capability": binding.capability.uuidString,
        ]
        let data = try JSONSerialization.data(withJSONObject: values)
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw WorkspaceFault.corruptStore
        }
    }
    private func openSavedPanes(in sessionID: AxoSessionID) {
        guard let session = store.registry.sessions.first(where: { $0.id == sessionID }) else { return }
        // Activation is execution intent; rendering, catalog reads, and title updates never launch work.
        for pane in session.panes where launchFailures[pane.id] == nil {
            do { try launch(pane, in: session) }
            catch { launchFailures[pane.id] = launchFailureMessage(error) }
        }
    }
    private func launchFailureMessage(_ error: Error) -> String {
        if let fault = error as? WorkspaceFault, fault == .capacity {
            return "The live terminal limit has been reached. Close a pane, then retry."
        }
        if let fault = error as? LaunchError, case .missingDirectory = fault {
            return "The saved working directory is missing. Restore it, then retry; Axo will not choose another directory."
        }
        return "The terminal could not start. Check its launch configuration, then retry."
    }
    var onTitle: ((String) -> Void)?
    var hasLiveProcesses: Bool { livePanes.values.contains { !$0.childExited } }

    private final class SidebarItem: NSObject {
        let workspace: WorkspaceRecord?
        let session: WorkSession?
        var children: [SidebarItem] = []
        let isSeparator: Bool
        let sectionTitle: String?
        var isDecoration: Bool { isSeparator || sectionTitle != nil }
        init(workspace: WorkspaceRecord) { self.workspace = workspace; self.session = nil; isSeparator = false; sectionTitle = nil }
        init(session: WorkSession) { self.workspace = nil; self.session = session; isSeparator = false; sectionTitle = nil }
        init(sectionTitle: String) { workspace = nil; session = nil; isSeparator = false; self.sectionTitle = sectionTitle }
        override init() { self.workspace = nil; self.session = nil; isSeparator = true; sectionTitle = nil }
    }

    @MainActor init(runtime: GhosttyRuntime, repository: String, storageRoot: URL? = nil,
                    launchOverride: ((PaneRecord, WorkSession) -> TerminalLaunch)? = nil) throws {
        self.runtime = runtime; self.repository = repository; self.launchOverride = launchOverride
        let support = storageRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Axo")
        scratchRoot = support.appendingPathComponent("Workspaces")
        sidebarStateURL = support.appendingPathComponent("window-layout.json")
        let savedWindowState = WorkspaceWindowState.load(from: sidebarStateURL)
        sidebarWidth = CGFloat(savedWindowState.sidebarWidth)
        sidebarCollapsed = savedWindowState.sidebarCollapsed
        stateRoot = support.appendingPathComponent("RuntimeStates")
        bridgeDirectory = support.appendingPathComponent("Bridge")
        bindingDirectory = bridgeDirectory.appendingPathComponent("Bindings")
        store = try WorkspaceStore(url: support.appendingPathComponent("workspaces.json"), scratchRoot: scratchRoot)
        super.init()
        let voice = MacVoiceCoordinator(historyURL: support.appendingPathComponent("voice-transcripts.json"))
        voiceCoordinator = voice
        voice.onActivityChanged = { [weak self] in self?.refreshSidebar() }
        voice.onTranscriptReady = { [weak self] target, text in
            self?.insertVoiceTranscript(for: target, text: text) ?? false
        }
        voice.onError = { NSSound.beep() }
        installVoiceKeyMonitor()
        configureSidebar()
        if launchOverride == nil {
            let config = URL(fileURLWithPath: repository).appendingPathComponent("local/relay.json")
            if FileManager.default.fileExists(atPath: config.path) {
                do {
                    let host = try BridgeHostProcess(repository: repository, config: config,
                                                     registry: support.appendingPathComponent("workspaces.json"),
                                                     socket: bridgeDirectory.appendingPathComponent("host.sock"),
                                                     bindings: bindingDirectory)
                    host.onRequest = { [weak self] frame in self?.handleBridgeRequest(frame) }
                    bridgeHost = host
                    try host.start()
                } catch {
                    fputs("Axo host broker could not start: \(error.localizedDescription)\n", stderr)
                }
            }
        }
        let firstLaunch = store.registry.workspaces.isEmpty
        if firstLaunch {
            _ = try store.createWorkspace(name: "Sessions", commandID: "prototype-import",
                                          initialDirectory: storageRoot == nil ? repository + "/local/playground" : nil,
                                          initialSessionFile: storageRoot == nil ? repository + "/local/playground/session.jsonl" : nil, kind: .standalone)
        }
        runtime.onAction = { [weak self] terminal, action in self?.handle(terminal: terminal, action: action) ?? false }
        // First legacy import cannot prove that an external Pi has released this file.
        // All later saved-session activations reopen lazily, without replaying any input.
        if firstLaunch, storageRoot == nil, let pane = selectedSession?.panes.first {
            launchFailures[pane.id] = "This imported conversation may still be open in the old Pi. Stop that Pi before retrying."
        }
        if let id = store.registry.selectedSession { openSavedPanes(in: id) }
        refreshSidebar(); showSelectedSession()
        if launchOverride == nil {
            notifications = MacSessionNotifications(isViewing: { [weak self] id in self?.isViewing(id) ?? false },
                                                    activate: { [weak self] destination in self?.activateNotification(destination) })
            stateObserver = MacSessionObserver(bindings: { [weak self] in
                guard let self else { return [] }
                return self.stateBindings.values.filter { self.livePanes[$0.paneID]?.childExited == false }
            }, receive: { [weak self] binding, snapshot in self?.receiveAgentState(snapshot, from: binding) })
        }
    }

    private var selectedSession: WorkSession? { store.registry.sessions.first { $0.id == store.registry.selectedSession } }
    private var focusedTerminal: TerminalView? {
        selectedSession?.focusedPane.flatMap { livePanes[$0] }
    }
    // Match Ghostty BaseTerminalController: key window AND selected surface AND first responder.
    func setFocus(_ focused: Bool) {
        for (id, terminal) in livePanes {
            let selected = selectedSession?.focusedPane == id
            terminal.setFocus(focused && selected && terminal.window?.isKeyWindow == true && terminal.window?.firstResponder === terminal)
        }
    }
    func restoreFocus() {
        guard let session = selectedSession, let pane = session.focusedPane else { return }
        moveFocus(to: pane, in: session.id)
    }
    private func moveFocus(to pane: PaneID, in sessionID: AxoSessionID, attempt: Int = 0) {
        // Ghostty.moveFocus uses bounded retry while SwiftUI reparents a retained view.
        // Unlike a generic delayed focus, also reject callbacks after selection changed.
        guard attempt < 4, selectedSession?.id == sessionID,
              selectedSession?.focusedPane == pane, let terminal = livePanes[pane] else { return }
        guard let window = terminal.window else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * pow(2, Double(attempt))) { [weak self] in
                self?.moveFocus(to: pane, in: sessionID, attempt: attempt + 1)
            }
            return
        }
        if let previous = window.firstResponder as? TerminalView, previous !== terminal { _ = previous.resignFirstResponder() }
        window.makeFirstResponder(terminal)
        setFocus(true)
    }
    func setWindowVisible(_ visible: Bool) {
        for (id, terminal) in livePanes {
            terminal.setVisible(visible && (selectedSession?.layout?.panes.contains(id) ?? false))
        }
    }

    @objc func newWorkspace(_ sender: Any?) {
        createWorkspace(initialDirectory: focusedTerminal?.workingDirectory ?? selectedSession?.directory)
    }
    private func requestWorkspace(initialDirectory: String?) -> WorkspaceCreationRequest? {
        if let workspaceRequestProvider { return workspaceRequestProvider(initialDirectory) }
        let panel = NSOpenPanel()
        panel.title = "Choose the project's main folder"
        panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true; panel.treatsFilePackagesAsDirectories = false
        if let initialDirectory, (try? requireDirectory(initialDirectory)) != nil {
            panel.directoryURL = URL(fileURLWithPath: initialDirectory)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let directory = url.standardizedFileURL.path
        let suggestedName = (try? WorkspaceStore.validName(url.lastPathComponent)) ?? "New project"
        guard let name = askName(title: "Name project", initial: suggestedName) else { return nil }
        return WorkspaceCreationRequest(directory: directory, name: name)
    }
    private func createWorkspace(initialDirectory: String?) {
        guard let request = requestWorkspace(initialDirectory: initialDirectory) else { return }
        perform {
            try requireDirectory(request.directory)
            let receipt = try store.createWorkspace(name: request.name, initialDirectory: request.directory)
            openSavedPanes(in: receipt.sessionID)
            refreshSidebar(); showSelectedSession()
        }
    }
    @objc func newSession(_ sender: Any?) {
        let clicked = sidebar.item(atRow: sidebar.selectedRow) as? SidebarItem
        guard let workspaceID = selectedSession?.workspaceID ?? clicked?.workspace?.id else { newStandaloneSession(sender); return }
        let directory = focusedTerminal?.workingDirectory ?? selectedSession?.directory ?? clicked?.workspace?.directory
        createSession(in: workspaceID, directory: directory)
    }
    private func createSession(in workspaceID: WorkspaceID, directory: String?) {
        perform {
            if let directory { try requireDirectory(directory) }
            let receipt = try store.createSession(workspaceID: workspaceID, name: "Untitled", initialDirectory: directory)
            openSavedPanes(in: receipt.sessionID)
            refreshSidebar(); showSelectedSession()
        }
    }
    @objc func newStandaloneSession(_ sender: Any?) {
        if let workspace = store.registry.workspaces.first(where: { $0.effectiveKind == .standalone && $0.isArchived != true }) {
            createSession(in: workspace.id, directory: nil)
        } else {
            perform {
                let receipt = try store.createWorkspace(name: "Sessions", kind: .standalone)
                openSavedPanes(in: receipt.sessionID); refreshSidebar(); showSelectedSession()
            }
        }
    }
    @objc private func showCreationMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let project = NSMenuItem(title: "New Project…", action: #selector(newWorkspace(_:)), keyEquivalent: "")
        let session = NSMenuItem(title: "New Session", action: #selector(newStandaloneSession(_:)), keyEquivalent: "")
        project.target = self; session.target = self; menu.addItem(project); menu.addItem(session)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }
    @MainActor @objc func showCommandPalette(_ sender: Any?) {
        let panel: NSPanel
        if let existing = commandPalette {
            panel = existing
        } else {
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Command Palette"
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            commandPalette = panel
        }
        panel.contentView = NSHostingView(rootView: MacCommandPaletteView(
            commands: paletteCommands(), close: { [weak panel] in panel?.orderOut(nil) }
        ))
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @MainActor private func paletteCommands() -> [MacPaletteCommand] {
        var commands = [
            paletteCommand("workspace.create", "New Workspace…", "Choose a project directory", "⌘N") { $0.newWorkspace(nil) },
            paletteCommand("session.create", "New Session…", "Create a session in the selected workspace", "⌘T") { $0.newSession(nil) },
            paletteCommand("settings.open", "Open Settings", "Keyboard shortcuts, voice, and notifications", "⌘,") { $0.showSettings(nil) },
            paletteCommand("voice.toggle", "Start or Stop Voice Dictation", "Capture speech into the focused terminal pane", nil) { $0.toggleVoiceDictation(nil) },
            paletteCommand("sidebar.toggle", "Toggle Sidebar", "Show or hide workspace navigation", "⌃⌘S") { $0.toggleSidebar(nil) },
            paletteCommand("pane.previous", "Previous Pane", "Focus the previous pane", "⌘[") { $0.previousPane(nil) },
            paletteCommand("pane.next", "Next Pane", "Focus the next pane", "⌘]") { $0.nextPane(nil) },
            paletteCommand("session.previous", "Previous Session", "Activate the previous session", "⌘{") { $0.previousSession(nil) },
            paletteCommand("session.next", "Next Session", "Activate the next session", "⌘}") { $0.nextSession(nil) },
            paletteCommand("workspace.previous", "Previous Workspace", "Activate the previous workspace", "⌘<") { $0.previousWorkspace(nil) },
            paletteCommand("workspace.next", "Next Workspace", "Activate the next workspace", "⌘>") { $0.nextWorkspace(nil) },
            paletteCommand("pane.split-right", "Split Right", "Add a shell pane to the right", "⌘D") { $0.splitRight(nil) },
            paletteCommand("pane.split-down", "Split Down", "Add a shell pane below", "⇧⌘D") { $0.splitDown(nil) },
            paletteCommand("pane.close", "Close Pane…", "Close the focused pane", "⌘W") { $0.closePane(nil) },
        ]
        if let selectedSession {
            commands.append(paletteCommand("session.rename", "Rename Current Session", selectedSession.name, nil) { $0.renameSession(nil) })
            if let workspace = store.registry.workspaces.first(where: { $0.id == selectedSession.workspaceID }) {
                commands.append(paletteCommand("workspace.rename", "Rename Current Workspace", workspace.name, nil) { $0.renameWorkspace(nil) })
            }
        }
        for workspace in store.registry.workspaces where workspace.isArchived != true {
            let workspaceSession = store.registry.sessions.first(where: { $0.workspaceID == workspace.id && $0.isArchived != true })
            let workspaceID = workspace.id
            if let workspaceSession {
                let sessionID = workspaceSession.id
                commands.append(paletteCommand("workspace.\(workspaceID.rawValue)", "Workspace: \(workspace.name)", "Activate its first session", nil) { controller in
                    controller.perform { try controller.activateSession(sessionID) }
                })
            }
        }
        let workspaces = Dictionary(uniqueKeysWithValues: store.registry.workspaces.map { ($0.id, $0) })
        for session in store.registry.sessions where session.isArchived != true {
            let sessionID = session.id
            let workspaceName = workspaces[session.workspaceID]?.name ?? "Workspace"
            commands.append(paletteCommand("session.\(sessionID.rawValue)", "Session: \(session.name)", workspaceName, nil) { controller in
                controller.perform { try controller.activateSession(sessionID) }
            })
            for pane in session.panes {
                let paneID = pane.id
                let paneName = pane.kind == .pi ? "Pi" : "Shell"
                commands.append(paletteCommand("pane.\(sessionID.rawValue).\(paneID.rawValue)", "Pane: \(paneName)", "\(session.name) — \(workspaceName)", nil) { controller in
                    controller.perform {
                        try controller.activateSession(sessionID)
                        controller.moveFocus(to: paneID, in: sessionID)
                    }
                })
            }
        }
        return commands
    }

    @MainActor private func paletteCommand(_ id: String, _ title: String, _ detail: String, _ shortcut: String?,
                                           action: @escaping @MainActor (WorkspaceController) -> Void) -> MacPaletteCommand {
        MacPaletteCommand(id: id, title: title, detail: detail, shortcut: shortcut, perform: { [weak self] in
            guard let self else { return }
            self.commandPalette?.orderOut(nil)
            action(self)
        })
    }

    @MainActor @objc func toggleVoiceDictation(_ sender: Any?) {
        toggleVoiceLock()
    }

    @MainActor private func installVoiceKeyMonitor() {
        let controller = WeakWorkspaceController(self)
        voiceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { event in
            let eventReference = MainActorEventReference(event)
            let result = MainActor.assumeIsolated {
                guard let controller = controller.value else { return MainActorEventResult(eventReference.event) }
                return MainActorEventResult(controller.handleVoiceKeyEvent(eventReference.event))
            }
            return result.event
        }
        voiceApplicationResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [controller] _ in
            MainActor.assumeIsolated { controller.value?.applicationResignedDuringVoiceGesture() }
        }
    }

    func handleSplitDownShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(MacVoiceKeyBinding.relevantModifierFlags)
        guard event.type == .keyDown, event.keyCode == 2, modifiers == [.command, .shift] else { return false }
        splitDown(nil)
        return true
    }

    @MainActor private func handleVoiceKeyEvent(_ event: NSEvent) -> NSEvent? {
        if handleSplitDownShortcut(event) { return nil }
        let binding = MacVoiceKeyBinding(
            rawValue: UserDefaults.standard.string(forKey: MacVoiceKeyBinding.settingsKey) ?? ""
        ) ?? .defaultValue
        let isTracked = voiceKeyGesture.isTracking(keyCode: event.keyCode)
        let isDown: Bool

        switch event.type {
        case .flagsChanged:
            guard binding.isModifierKey, binding.matches(keyCode: event.keyCode) else { return event }
            isDown = !isTracked
        case .keyDown:
            guard !binding.isModifierKey, binding.matches(keyCode: event.keyCode),
                  binding.matchesModifiers(event.modifierFlags) else { return event }
            isDown = true
        case .keyUp:
            guard isTracked else { return event }
            isDown = false
        default:
            return event
        }

        if isDown {
            guard binding.matches(keyCode: event.keyCode), binding.matchesModifiers(event.modifierFlags),
                  NSApp.isActive, let terminal = focusedTerminal,
                  terminal.window === NSApp.keyWindow, terminal.window?.firstResponder === terminal else {
                return event
            }
        }

        let result = voiceKeyGesture.handle(keyCode: event.keyCode, isDown: isDown, at: Date())
        scheduleVoiceGestureTimeout()
        performVoiceGestures(result.actions)
        return result.consumeEvent ? nil : event
    }

    @MainActor private func scheduleVoiceGestureTimeout() {
        voiceGestureTimeoutTask?.cancel()
        guard let deadline = voiceKeyGesture.timeoutDeadline else {
            voiceGestureTimeoutTask = nil
            return
        }
        let delay = max(0, deadline.timeIntervalSinceNow)
        voiceGestureTimeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            let result = self.voiceKeyGesture.expire(at: Date())
            self.performVoiceGestures(result.actions)
            self.scheduleVoiceGestureTimeout()
        }
    }

    @MainActor private func performVoiceGestures(_ actions: [MacVoiceGestureAction]) {
        for action in actions { performVoiceGesture(action) }
    }

    @MainActor private func performVoiceGesture(_ action: MacVoiceGestureAction) {
        switch action {
        case .beginHold:
            beginVoiceKeyCapture()
        case .endHold, .unlockRecording:
            finishVoiceKeyCapture()
        case .lockRecording:
            break // Keep the voice-key capture alive after release until it is explicitly unlocked.
        }
    }

    @MainActor private func beginVoiceKeyCapture() {
        guard let voiceCoordinator, !voiceCoordinator.isStarting, !voiceCoordinator.isRecording else { return }
        guard let target = focusedVoiceTarget() else {
            voiceCoordinator.report("Focus an open terminal pane before starting voice dictation.")
            return
        }
        voiceKeyOwnsCapture = true
        voiceCoordinator.startCapture(for: target)
    }

    @MainActor private func finishVoiceKeyCapture() {
        guard voiceKeyOwnsCapture else { return }
        voiceKeyOwnsCapture = false
        if voiceCoordinator?.isStarting == true { voiceCoordinator?.cancelCapture() }
        else if voiceCoordinator?.isRecording == true { voiceCoordinator?.stopCapture() }
    }

    @MainActor private func toggleVoiceLock() {
        guard let voiceCoordinator else { return }
        if voiceCoordinator.isStarting || voiceCoordinator.isRecording {
            voiceGestureTimeoutTask?.cancel()
            voiceGestureTimeoutTask = nil
            voiceKeyGesture.clear()
            voiceKeyOwnsCapture = false
            if voiceCoordinator.isStarting { voiceCoordinator.cancelCapture() }
            else { voiceCoordinator.stopCapture() }
        } else if let target = focusedVoiceTarget() {
            voiceKeyGesture.clear()
            voiceCoordinator.startCapture(for: target)
        } else {
            voiceCoordinator.report("Focus an open terminal pane before starting voice dictation.")
        }
    }

    @MainActor private func applicationResignedDuringVoiceGesture() {
        voiceGestureTimeoutTask?.cancel()
        voiceGestureTimeoutTask = nil
        let result = voiceKeyGesture.reset()
        performVoiceGestures(result.actions)
    }

    private func focusedVoiceTarget() -> MacVoiceTarget? {
        guard let session = selectedSession, let pane = session.focusedPane,
              let terminal = livePanes[pane], !terminal.childExited,
              let workspace = store.registry.workspaces.first(where: { $0.id == session.workspaceID }) else { return nil }
        return MacVoiceTarget(sessionID: session.id, paneID: pane, runtimeGeneration: terminal.runtimeGeneration,
                              workspaceName: workspace.name, sessionName: session.name)
    }

    private func canInsertVoiceDraft(_ target: MacVoiceTarget) -> Bool {
        guard let session = store.registry.sessions.first(where: { $0.id == target.sessionID }),
              session.panes.contains(where: { $0.id == target.paneID }),
              let terminal = livePanes[target.paneID] else { return false }
        return terminal.runtimeGeneration == target.runtimeGeneration && !terminal.childExited
    }

    @MainActor private func insertVoiceTranscript(for target: MacVoiceTarget, text: String) -> Bool {
        guard canInsertVoiceDraft(target), let terminal = livePanes[target.paneID],
              terminal.insertVoiceText(text) else {
            NSSound.beep()
            return false
        }
        return true
    }

    @objc func previousPane(_ sender: Any?) { navigate(.previous, scope: .pane) }
    @objc func nextPane(_ sender: Any?) { navigate(.next, scope: .pane) }
    @objc func previousSession(_ sender: Any?) { navigate(.previous, scope: .session) }
    @objc func nextSession(_ sender: Any?) { navigate(.next, scope: .session) }
    @objc func previousWorkspace(_ sender: Any?) { navigate(.previous, scope: .workspace) }
    @objc func nextWorkspace(_ sender: Any?) { navigate(.next, scope: .workspace) }
    @objc func splitRight(_ sender: Any?) { splitSelected(direction: .right) }
    @objc func splitDown(_ sender: Any?) { splitSelected(direction: .down) }
    @objc func closePane(_ sender: Any?) {
        guard let session = selectedSession, let paneID = session.focusedPane else { return }
        requestClose(paneID, sessionID: session.id, needsConfirmation: livePanes[paneID]?.childExited == false)
    }
    @objc func renameSession(_ sender: Any?) {
        let item = (sender as? NSMenuItem)?.representedObject as? SidebarItem
        guard let session = item?.session ?? selectedSession else { return }
        if nameProvider != nil {
            guard let name = askName(title: "Rename session", initial: session.name) else { return }
            perform { try store.renameSession(session.id, name: name); refreshSidebar(); updateTitle() }
        } else { beginRenaming(item ?? SidebarItem(session: session)) }
    }
    @objc func renameWorkspace(_ sender: Any?) {
        let item = (sender as? NSMenuItem)?.representedObject as? SidebarItem
        guard let workspace = item?.workspace ?? store.registry.workspaces.first(where: { $0.id == selectedSession?.workspaceID }) else { return }
        if nameProvider != nil {
            guard let name = askName(title: "Rename workspace", initial: workspace.name) else { return }
            perform { try store.renameWorkspace(workspace.id, name: name); refreshSidebar() }
        } else { beginRenaming(item ?? SidebarItem(workspace: workspace)) }
    }
    @objc private func renameClickedItem(_ sender: Any?) {
        guard let item = sidebar.item(atRow: sidebar.clickedRow) as? SidebarItem else { return }
        beginRenaming(item)
    }
    private func beginRenaming(_ target: SidebarItem) {
        let items = sidebarItems.flatMap { [$0] + $0.children }
        guard let current = items.first(where: { item in
            !item.isDecoration && ((target.session != nil && item.session?.id == target.session?.id) ||
                                 (target.workspace != nil && item.workspace?.id == target.workspace?.id))
        }), let row = sidebar.view(atColumn: 0, row: sidebar.row(forItem: current), makeIfNecessary: true) as? WorkspaceSidebarRow else { return }
        editingSidebar = true; row.beginRenaming()
    }
    private func finishRenaming(_ item: SidebarItem, name: String?) {
        editingSidebar = false
        if let name {
            perform {
                if let workspace = item.workspace { try store.renameWorkspace(workspace.id, name: name) }
                else if let session = item.session { try store.renameSession(session.id, name: name) }
            }
        }
        refreshSidebar(); updateTitle(); restoreFocus()
    }
    private func itemMenu(_ item: SidebarItem) -> NSMenu {
        let menu = NSMenu(); guard !item.isDecoration else { return menu }
        let options: [(String, Selector)] = [("Rename", item.workspace != nil ? #selector(renameWorkspace(_:)) : #selector(renameSession(_:))),
                                            ("Duplicate", #selector(duplicateItem(_:))), ("Remove", #selector(removeItem(_:)))]
        for (title, action) in options {
            let command = NSMenuItem(title: title, action: action, keyEquivalent: "")
            command.target = self; command.representedObject = item; menu.addItem(command)
        }
        return menu
    }
    @objc private func duplicateItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem else { return }
        perform {
            let id: AxoSessionID?
            if let workspace = item.workspace { id = try store.duplicateWorkspace(workspace.id) }
            else if let session = item.session { id = try store.duplicateSession(session.id) }
            else { return }
            if let id { openSavedPanes(in: id) }
            refreshSidebar(); showSelectedSession()
        }
    }
    @objc private func removeItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem, let window = view.window, closeConfirmation == nil else { return }
        let sessions = item.workspace.map { workspace in store.registry.sessions.filter { $0.workspaceID == workspace.id } } ?? item.session.map { [$0] } ?? []
        let alert = NSAlert(); alert.messageText = "Remove from the sidebar?"
        alert.informativeText = "This stops these sessions' app-owned processes. Saved Pi history and shared files are retained; nothing is deleted from disk or the cloud."
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel"); closeConfirmation = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }; self.closeConfirmation = nil
            guard response == .alertFirstButtonReturn else { return }
            self.perform {
                if let workspace = item.workspace { try self.store.archiveWorkspace(workspace.id) }
                else if let session = item.session { try self.store.archiveSession(session.id) }
                for session in sessions {
                    for pane in session.panes {
                        self.livePanes.removeValue(forKey: pane.id)?.removeFromSuperview()
                        self.paneHosts.removeValue(forKey: pane.id)?.subviews.forEach { $0.removeFromSuperview() }
                        self.launchFailures.removeValue(forKey: pane.id)
                        self.discardObservation(pane.id, sessionID: session.id)
                    }
                }
                self.refreshSidebar(); self.showSelectedSession()
            }
        }
    }
    @objc func toggleSidebar(_ sender: Any?) {
        if !sidebarCollapsed { sidebarWidth = max(CGFloat(WorkspaceWindowState.minimumSidebarWidth), sidebarContainer.frame.width) }
        sidebarCollapsed.toggle()
        sidebarMinimumWidth?.isActive = !sidebarCollapsed
        sidebarContainer.isHidden = sidebarCollapsed
        reopenSidebar.isHidden = !sidebarCollapsed
        view.adjustSubviews()
        view.setPosition(sidebarCollapsed ? 0 : sidebarWidth, ofDividerAt: 0)
        scheduleSidebarStateSave()
        restoreFocus()
    }
    private func navigate(_ direction: NavigationDirection, scope: NavigationScope) {
        switch scope {
        case .pane: navigatePane(direction)
        case .session: navigateSession(direction)
        case .workspace: navigateWorkspace(direction)
        }
    }

    private func navigatePane(_ direction: NavigationDirection) {
        guard let session = selectedSession, let panes = session.layout?.panes,
              panes.count > 1, let focusedPane = session.focusedPane,
              let currentIndex = panes.firstIndex(of: focusedPane) else { return }
        let step = direction == .previous ? -1 : 1
        let destination = panes[(currentIndex + step + panes.count) % panes.count]
        guard livePanes[destination] != nil else { return }
        perform { try store.updateSession(session.id) { $0.focusedPane = destination } }
        moveFocus(to: destination, in: session.id)
    }

    private func navigateSession(_ direction: NavigationDirection) {
        guard let session = selectedSession else { return }
        let sessions = store.registry.sessions.filter {
            $0.workspaceID == session.workspaceID && $0.isArchived != true
        }
        guard let currentIndex = sessions.firstIndex(where: { $0.id == session.id }), sessions.count > 1 else { return }
        let step = direction == .previous ? -1 : 1
        let destination = sessions[(currentIndex + step + sessions.count) % sessions.count]
        perform { try activateSession(destination.id) }
    }

    private func navigateWorkspace(_ direction: NavigationDirection) {
        guard let session = selectedSession else { return }
        let workspaces = store.registry.workspaces.filter { $0.isArchived != true }
        guard let currentIndex = workspaces.firstIndex(where: { $0.id == session.workspaceID }), workspaces.count > 1 else { return }
        let step = direction == .previous ? -1 : 1
        let destination = workspaces[(currentIndex + step + workspaces.count) % workspaces.count]
        guard let session = store.registry.sessions.first(where: {
            $0.workspaceID == destination.id && $0.isArchived != true
        }) else { return }
        perform { try activateSession(session.id) }
    }

    private func splitSelected(direction: SurfaceTree.NewDirection) {
        guard let session = selectedSession, let paneID = session.focusedPane else { return }
        split(sessionID: session.id, paneID: paneID, direction: direction)
    }
    private func split(sessionID: AxoSessionID, paneID: PaneID, direction: SurfaceTree.NewDirection) {
        perform {
            guard let original = store.registry.sessions.first(where: { $0.id == sessionID }),
                  let target = surfaceTree(in: original).find(id: paneID.rawValue) else { throw WorkspaceFault.notFound }
            let directory = livePanes[paneID]?.workingDirectory ?? original.directory
            try requireDirectory(directory)
            guard livePanes.count < 128 else { throw WorkspaceFault.capacity }
            let pane = PaneRecord(kind: .shell, directory: directory)
            let newHost = PaneHostView(id: pane.id)
            let changed = try surfaceTree(in: original).inserting(view: newHost, at: target.leftmostLeaf(), direction: direction)
            try store.updateSession(sessionID) { value in
                value.panes.append(pane); value.layout = changed.savedLayout(); value.focusedPane = pane.id
            }
            paneHosts[pane.id] = newHost
            guard let session = store.registry.sessions.first(where: { $0.id == sessionID }) else { throw WorkspaceFault.notFound }
            do { try launch(pane, in: session, inheriting: livePanes[paneID]?.surface) }
            catch { launchFailures[pane.id] = launchFailureMessage(error) }
            refreshSidebar(); showSelectedSession()
        }
    }
    private func launch(_ pane: PaneRecord, in session: WorkSession, inheriting: ghostty_surface_t? = nil) throws {
        if let existing = livePanes[pane.id] {
            guard existing.childExited else { return }
            livePanes.removeValue(forKey: pane.id)?.removeFromSuperview()
            discardObservation(pane.id, sessionID: session.id)
        }
        guard livePanes.count < 128 else { throw WorkspaceFault.capacity }
        if pane.kind == .pi {
            let runningAgents = store.registry.sessions.flatMap(\.panes).filter { $0.kind == .pi && livePanes[$0.id] != nil }.count
            guard runningAgents < 32 else { throw WorkspaceFault.capacity }
        }
        let directory = pane.directory ?? session.directory
        let generatedRoot = scratchRoot.appendingPathComponent(session.workspaceID.rawValue.uuidString)
            .appendingPathComponent(session.id.rawValue.uuidString)
        // Only the exact generated root may be recreated; missing project/shell directories require repair.
        if directory == generatedRoot.path {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try requireDirectory(directory)
        if pane.kind == .pi, session.piSessionFile == generatedRoot.appendingPathComponent("session.jsonl").path {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: session.piSessionFile).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var observation: MacSessionBinding?
        if pane.kind == .pi, launchOverride == nil {
            try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: bindingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            observation = MacSessionBinding(sessionID: session.id, paneID: pane.id, generation: UUID(), capability: UUID(),
                                            path: stateRoot.appendingPathComponent(pane.id.rawValue.uuidString + ".json").path)
            try writeBridgeBinding(observation!)
        }
        let launch: TerminalLaunch = launchOverride?(pane, session) ?? (pane.kind == .pi
            ? .pi(repository: repository, directory: directory, sessionFile: session.piSessionFile, observation: observation,
                  bridgeSocket: bridgeDirectory.appendingPathComponent("host.sock").path)
            : .shell(directory: directory))
        let terminal: TerminalView
        do { terminal = try TerminalView(runtime: runtime, launch: launch, inheriting: inheriting) }
        catch {
            if let observation { try? FileManager.default.removeItem(at: bindingDirectory.appendingPathComponent(observation.paneID.rawValue.uuidString + ".json")) }
            throw error
        }
        terminal.onFocus = { [weak self, weak terminal] in
            guard let self, let terminal, let (owner, id) = self.owner(of: terminal) else { return }
            if owner.focusedPane != id { self.perform { try self.store.updateSession(owner.id) { $0.focusedPane = id } } }
            DispatchQueue.main.async { [weak self] in self?.setFocus(true) }
        }
        terminal.onClose = { [weak self, weak terminal] alive in
            guard let self, let terminal, let (owner, id) = self.owner(of: terminal) else { return }
            self.requestClose(id, sessionID: owner.id, needsConfirmation: alive)
        }
        livePanes[pane.id] = terminal
        Task { @MainActor [weak self] in self?.voiceCoordinator?.destinationStateChanged() }
        if let observation {
            stateBindings[pane.id] = observation
            initialObservationDeadlines[pane.id] = Date().addingTimeInterval(10)
        }
        launchFailures.removeValue(forKey: pane.id)
    }
    private func requestClose(_ paneID: PaneID, sessionID: AxoSessionID, needsConfirmation: Bool) {
        guard needsConfirmation else { finishClose(paneID, sessionID: sessionID); return }
        guard let session = store.registry.sessions.first(where: { $0.id == sessionID }),
              closeConfirmation == nil, let window = view.window else { return }
        // Ghostty uses one asynchronous NSAlert sheet, not a fragile SwiftUI confirmation binding.
        let closesSession = session.panes.count == 1
        let alert = NSAlert()
        alert.messageText = closesSession ? "Close session and stop its process?" : "Close terminal and stop its process?"
        alert.informativeText = closesSession
            ? "This is the session’s last pane. Closing it removes the session from the sidebar. Saved Pi history and shared files are retained."
            : "Other sessions and splits keep running. The Pi conversation stays saved locally."
        alert.addButton(withTitle: closesSession ? "Close Session" : "Stop and close"); alert.addButton(withTitle: "Cancel")
        closeConfirmation = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.closeConfirmation = nil
            guard response == .alertFirstButtonReturn else { return }
            self.finishClose(paneID, sessionID: sessionID)
        }
    }
    private func finishClose(_ paneID: PaneID, sessionID: AxoSessionID) {
        guard let session = store.registry.sessions.first(where: { $0.id == sessionID }),
              let node = surfaceTree(in: session).find(id: paneID.rawValue) else { return }
        let closesSession = session.panes.count == 1
        let tree = surfaceTree(in: session)
        let nextPane = tree.root?.leftmostLeaf() === node.leftmostLeaf()
            ? tree.focusTarget(for: .next, from: node) : tree.focusTarget(for: .previous, from: node)
        let replacementSession = closesSession && store.registry.selectedSession == sessionID
            ? nextVisibleSession(excluding: sessionID, in: session.workspaceID) : nil
        perform {
            if closesSession {
                try store.archiveSession(sessionID)
                if let replacementSession { try store.select(replacementSession) }
            } else {
                try store.updateSession(sessionID) { value in
                    value.panes.removeAll { $0.id == paneID }
                    value.layout = tree.removing(node).savedLayout()
                    if value.focusedPane == paneID {
                        value.focusedPane = nextPane.map { PaneID($0.id) }.flatMap { $0 == paneID ? nil : $0 }
                    }
                }
            }
            livePanes.removeValue(forKey: paneID)?.removeFromSuperview()
            Task { @MainActor [weak self] in self?.voiceCoordinator?.destinationStateChanged() }
            paneHosts.removeValue(forKey: paneID)
            discardObservation(paneID, sessionID: sessionID)
            launchFailures.removeValue(forKey: paneID)
            refreshSidebar(); showSelectedSession()
        }
    }

    private func nextVisibleSession(excluding sessionID: AxoSessionID, in workspaceID: WorkspaceID) -> AxoSessionID? {
        let sessions = store.registry.sessions.filter { $0.id != sessionID && $0.isArchived != true }
        return sessions.first(where: { $0.workspaceID == workspaceID })?.id ?? sessions.first?.id
    }

    private func configureSidebar() {
        view.isVertical = true; view.dividerStyle = .thin; view.delegate = self
        sidebarContainer.material = .underWindowBackground; sidebarContainer.blendingMode = .withinWindow
        sidebarContainer.state = .followsWindowActiveState
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("navigation"))
        column.title = "Axo"; sidebar.addTableColumn(column); sidebar.outlineTableColumn = column
        sidebar.headerView = nil; sidebar.rowHeight = 28; sidebar.intercellSpacing = NSSize(width: 0, height: 2)
        sidebar.style = .sourceList; sidebar.selectionHighlightStyle = .regular
        sidebar.indentationPerLevel = 12; sidebar.backgroundColor = .clear
        sidebar.dataSource = self; sidebar.delegate = self
        sidebar.target = self; sidebar.doubleAction = #selector(renameClickedItem(_:))
        sidebar.isStandaloneSession = { [weak sidebar] value in
            (value as? SidebarItem)?.session != nil && sidebar?.parent(forItem: value) == nil
        }
        sidebar.itemMenu = { [weak self] value in
            guard let self, let item = value as? SidebarItem else { return NSMenu() }
            return self.itemMenu(item)
        }
        sidebar.setAccessibilityLabel("Workspaces and sessions")
        scroll.documentView = sidebar
        let heading = NSTextField(labelWithString: "Axo")
        heading.font = .systemFont(ofSize: 13, weight: .semibold); heading.textColor = .secondaryLabelColor
        let create = sidebarButton(symbol: "plus", label: "Create project or session", action: #selector(showCreationMenu(_:)))
        let collapse = sidebarButton(symbol: "sidebar.left", label: "Collapse sidebar", action: #selector(toggleSidebar(_:)))
        let settings = NSButton(title: "Settings", target: self, action: #selector(showSettings(_:)))
        settings.isBordered = false; settings.font = .systemFont(ofSize: 12); settings.contentTintColor = .secondaryLabelColor
        let headerLine = NSBox(), footerLine = NSBox(); headerLine.boxType = .separator; footerLine.boxType = .separator
        for child in [scroll, heading, create, collapse, settings, headerLine, footerLine] {
            child.translatesAutoresizingMaskIntoConstraints = false; sidebarContainer.addSubview(child)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor, constant: 16),
            heading.topAnchor.constraint(equalTo: sidebarContainer.topAnchor, constant: 14),
            create.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor, constant: -10),
            create.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            headerLine.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor, constant: 12),
            headerLine.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor, constant: -12),
            headerLine.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: headerLine.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: footerLine.topAnchor, constant: -8),
            footerLine.leadingAnchor.constraint(equalTo: headerLine.leadingAnchor), footerLine.trailingAnchor.constraint(equalTo: headerLine.trailingAnchor),
            footerLine.bottomAnchor.constraint(equalTo: collapse.topAnchor, constant: -10),
            settings.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor, constant: 12),
            settings.centerYAnchor.constraint(equalTo: collapse.centerYAnchor),
            collapse.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor, constant: -10),
            collapse.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor, constant: -10),
        ])
        reopenSidebar.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Show sidebar")
        reopenSidebar.isBordered = false; reopenSidebar.target = self; reopenSidebar.action = #selector(toggleSidebar(_:))
        reopenSidebar.toolTip = "Show sidebar"; reopenSidebar.setAccessibilityLabel("Show sidebar")
        reopenSidebar.isHidden = true
        view.addArrangedSubview(sidebarContainer); view.addArrangedSubview(content)
        sidebarMinimumWidth = sidebarContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: CGFloat(WorkspaceWindowState.minimumSidebarWidth))
        sidebarMinimumWidth?.isActive = !sidebarCollapsed
        sidebarContainer.widthAnchor.constraint(lessThanOrEqualToConstant: CGFloat(WorkspaceWindowState.maximumSidebarWidth)).isActive = true
        sidebarContainer.isHidden = sidebarCollapsed
        reopenSidebar.isHidden = !sidebarCollapsed
        view.setPosition(sidebarCollapsed ? 0 : sidebarWidth, ofDividerAt: 0)
    }
    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard splitView === view, dividerIndex == 0 else { return proposedPosition }
        guard !sidebarCollapsed else { return 0 }
        let available = splitView.bounds.width - splitView.dividerThickness - Self.minimumContentWidth
        let maximum = min(CGFloat(WorkspaceWindowState.maximumSidebarWidth), max(CGFloat(WorkspaceWindowState.minimumSidebarWidth), available))
        return min(max(CGFloat(WorkspaceWindowState.minimumSidebarWidth), proposedPosition), maximum)
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard splitView === view, splitView.arrangedSubviews.count == 2 else {
            splitView.adjustSubviews()
            return
        }
        let bounds = splitView.bounds
        let divider = splitView.dividerThickness
        let width: CGFloat
        if sidebarCollapsed {
            width = 0
        } else {
            width = min(sidebarWidth, max(0, bounds.width - divider - Self.minimumContentWidth))
        }
        let sidebarFrame = NSRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
        let contentFrame = NSRect(x: sidebarFrame.maxX + divider, y: bounds.minY,
                                  width: max(0, bounds.width - width - divider), height: bounds.height)
        sidebarContainer.frame = sidebarFrame
        content.frame = contentFrame
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard view.bounds.width >= 400, view.arrangedSubviews.count == 2 else { return }
        if !positionedSidebar {
            positionedSidebar = true
            view.setPosition(sidebarCollapsed ? 0 : sidebarWidth, ofDividerAt: 0)
            return
        }
        guard !sidebarCollapsed else { return }
        let width = sidebarContainer.frame.width
        guard width.isFinite, width >= CGFloat(WorkspaceWindowState.minimumSidebarWidth), abs(width - sidebarWidth) > 0.5 else { return }
        sidebarWidth = min(width, CGFloat(WorkspaceWindowState.maximumSidebarWidth))
        scheduleSidebarStateSave()
    }

    func saveWindowLayout() {
        sidebarStateSaveWork?.cancel()
        sidebarStateSaveWork = nil
        let state = WorkspaceWindowState(sidebarWidth: Double(sidebarWidth), sidebarCollapsed: sidebarCollapsed)
        do { try state.save(to: sidebarStateURL) }
        catch { fputs("Axo could not save window layout: \(error.localizedDescription)\n", stderr) }
    }

    private func scheduleSidebarStateSave() {
        sidebarStateSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sidebarStateSaveWork = nil
            self.saveWindowLayout()
        }
        sidebarStateSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    private func sidebarButton(symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.isBordered = false; button.toolTip = label; button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }
    private func refreshSidebar() {
        guard !editingSidebar else { return }
        refreshingSidebar = true
        defer { refreshingSidebar = false }
        let active = store.registry.workspaces.filter { $0.isArchived != true }
        let projects = active.filter { $0.effectiveKind == .project }.map { workspace in
            let item = SidebarItem(workspace: workspace)
            item.children = store.registry.sessions.filter { $0.workspaceID == workspace.id && $0.isArchived != true }.map(SidebarItem.init(session:))
            return item
        }
        let standaloneIDs = Set(active.filter { $0.effectiveKind == .standalone }.map(\.id))
        let sessions = store.registry.sessions.filter { standaloneIDs.contains($0.workspaceID) && $0.isArchived != true }.map(SidebarItem.init(session:))
        let workspaceSection = projects.isEmpty ? [] : [SidebarItem(sectionTitle: "Workspaces")] + projects
        let sessionSection = sessions.isEmpty ? [] : [SidebarItem(sectionTitle: "Sessions")] + sessions
        sidebarItems = workspaceSection + (!workspaceSection.isEmpty && !sessionSection.isEmpty ? [SidebarItem()] : []) + sessionSection
        sidebar.reloadData(); sidebar.expandItem(nil, expandChildren: true)
        for item in sidebarItems where item.workspace.map({ collapsedWorkspaces.contains($0.id) }) == true {
            sidebar.collapseItem(item)
        }
        for item in sidebarItems.flatMap({ [$0] + $0.children }) where item.session?.id == store.registry.selectedSession {
            let row = sidebar.row(forItem: item)
            if row >= 0 { sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
    }
    private func showSelectedSession() {
        for terminal in livePanes.values { terminal.setFocus(false); terminal.setVisible(false) }
        content.subviews.forEach { $0.removeFromSuperview() }
        defer {
            reopenSidebar.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(reopenSidebar)
            NSLayoutConstraint.activate([
                reopenSidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
                reopenSidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
                reopenSidebar.widthAnchor.constraint(equalToConstant: 24), reopenSidebar.heightAnchor.constraint(equalToConstant: 24),
            ])
        }
        updateTitle()
        guard let session = selectedSession else { return }
        splitHost = nil
        let body: NSView
        if session.layout != nil {
            let host = NSHostingView(rootView: splitView(in: session))
            splitHost = host; body = host
        } else {
            let button = NSButton(title: "All terminals closed — Open Pi", target: nil, action: nil)
            button.action = #selector(resumeEmptySession(_:)); button.target = self
            body = button
        }
        body.frame = content.bounds; body.autoresizingMask = [.width, .height]
        content.addSubview(body)
        setWindowVisible(view.window?.occlusionState.contains(.visible) ?? false)
        updateTitle()
        DispatchQueue.main.async { [weak self] in self?.restoreFocus() }
    }
    @objc private func resumeEmptySession(_ sender: Any?) {
        guard let session = selectedSession else { return }
        perform {
            let pane = PaneRecord(kind: .pi)
            try store.updateSession(session.id) { value in
                value.panes = [pane]; value.layout = .pane(pane.id); value.focusedPane = pane.id
            }
            openSavedPanes(in: session.id)
            refreshSidebar(); showSelectedSession()
        }
    }
    private func surfaceTree(in session: WorkSession) -> SurfaceTree {
        func node(_ layout: PaneLayout) -> SurfaceTree.Node {
            switch layout {
            case .pane(let id): return .leaf(view: paneHost(id, in: session))
            case .split(let axis, let fraction, let first, let second):
                return .split(.init(direction: axis == .horizontal ? .horizontal : .vertical,
                                    ratio: fraction, left: node(first), right: node(second)))
            }
        }
        return SurfaceTree(root: session.layout.map(node), zoomed: nil)
    }
    private func paneHost(_ id: PaneID, in session: WorkSession) -> PaneHostView {
        let host = paneHosts[id] ?? PaneHostView(id: id)
        paneHosts[id] = host
        if let terminal = livePanes[id] { host.show(terminal) }
        else {
            let message = launchFailures[id] ?? "This terminal has not been opened."
            host.show(TerminalLaunchFailureView(message: message) { [weak self] in
                guard let self, self.store.registry.sessions.contains(where: { $0.id == session.id && $0.panes.contains(where: { $0.id == id }) }) else { return }
                self.launchFailures.removeValue(forKey: id)
                self.openSavedPanes(in: session.id)
                self.refreshSidebar(); self.showSelectedSession()
            })
        }
        return host
    }
    private func splitView(in session: WorkSession) -> PaneSplitTreeView {
        PaneSplitTreeView(tree: surfaceTree(in: session), resize: { [weak self] node, ratio in
            guard let self, ratio.isFinite, self.selectedSession?.id == session.id,
                  let current = self.selectedSession else { return }
            let tree = self.surfaceTree(in: current)
            // Ratio changes preserve structural identity; an obsolete structural gesture is rejected.
            guard let target = self.matchingNode(node, in: tree.root) else { return }
            self.perform {
                let resized = try tree.replacing(node: target, with: target.resizing(to: min(0.9, max(0.1, ratio))))
                try self.saveTree(resized, in: current.id)
            }
        }, equalize: { [weak self] in self?.equalize(session.id) })
    }
    private func matchingNode(_ target: SurfaceTree.Node, in node: SurfaceTree.Node?) -> SurfaceTree.Node? {
        guard let node else { return nil }
        if node.structuralIdentity == target.structuralIdentity { return node }
        if case .split(let split) = node { return matchingNode(target, in: split.left) ?? matchingNode(target, in: split.right) }
        return nil
    }
    private func saveTree(_ tree: SurfaceTree, in sessionID: AxoSessionID) throws {
        try store.updateSession(sessionID) { $0.layout = tree.savedLayout() }
        if selectedSession?.id == sessionID, let current = selectedSession { splitHost?.rootView = splitView(in: current) }
    }
    private func equalize(_ sessionID: AxoSessionID) {
        perform {
            guard let current = store.registry.sessions.first(where: { $0.id == sessionID }) else { return }
            try saveTree(surfaceTree(in: current).equalized(), in: sessionID)
        }
    }
    private func updateTitle() { onTitle?(selectedSession.map { "Axo — " + $0.name } ?? "Axo") }
    private func requireDirectory(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), path.utf8.count <= 4_096, !path.contains("\u{0}"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LaunchError.missingDirectory
        }
    }
    private func askName(title: String, initial: String) -> String? {
        if let nameProvider { return nameProvider(title, initial) }
        let alert = NSAlert(); alert.messageText = title
        let field = NSTextField(string: initial); field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: title == "Name project" ? "Create Project" : "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation() }
        catch {
            let alert = NSAlert(); alert.messageText = "Axo could not complete this action"
            alert.informativeText = "\(error). Existing processes were not stopped; a failed launch remains stopped and can be retried."
            alert.runModal()
        }
    }

    private func owner(of terminal: TerminalView) -> (WorkSession, PaneID)? {
        guard let pane = livePanes.first(where: { $0.value === terminal })?.key,
              let session = store.registry.sessions.first(where: { $0.panes.contains(where: { $0.id == pane }) }) else { return nil }
        return (session, pane)
    }
    private func handle(terminal: TerminalView?, action: ghostty_action_s) -> Bool {
        // Copy borrowed C strings during the callback; creation/close is deferred to avoid reentering Ghostty.
        switch action.tag {
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            guard let terminal else { return false }
            let link = action.action.mouse_over_link
            guard link.len > 0, link.len <= 4_096, let pointer = link.url else {
                terminal.updateHoveredURL(nil)
                return true
            }
            let value = String(data: Data(bytes: pointer, count: Int(link.len)), encoding: .utf8)
            terminal.updateHoveredURL(value)
        case GHOSTTY_ACTION_OPEN_URL:
            let request = action.action.open_url
            guard request.len > 0, request.len <= 4_096, let pointer = request.url,
                  let value = String(data: Data(bytes: pointer, count: Int(request.len)), encoding: .utf8),
                  let url = TerminalView.validatedWebURL(value) else {
                NSSound.beep()
                return true
            }
            _ = NSWorkspace.shared.open(url)
        case GHOSTTY_ACTION_NEW_SPLIT:
            guard let terminal, let (session, pane) = owner(of: terminal) else { return false }
            let direction: SurfaceTree.NewDirection
            switch action.action.new_split {
            case GHOSTTY_SPLIT_DIRECTION_LEFT: direction = .left
            case GHOSTTY_SPLIT_DIRECTION_RIGHT: direction = .right
            case GHOSTTY_SPLIT_DIRECTION_UP: direction = .up
            case GHOSTTY_SPLIT_DIRECTION_DOWN: direction = .down
            default: return false
            }
            DispatchQueue.main.async { [weak self] in self?.split(sessionID: session.id, paneID: pane, direction: direction) }
        case GHOSTTY_ACTION_NEW_TAB:
            guard let terminal, let (session, _) = owner(of: terminal) else { return false }
            let directory = terminal.workingDirectory
            DispatchQueue.main.async { [weak self] in self?.createSession(in: session.workspaceID, directory: directory) }
        case GHOSTTY_ACTION_NEW_WINDOW:
            guard let terminal, owner(of: terminal) != nil else { return false }
            let directory = terminal.workingDirectory
            DispatchQueue.main.async { [weak self] in self?.createWorkspace(initialDirectory: directory) }
        case GHOSTTY_ACTION_SET_TITLE:
            if let title = action.action.set_title.title { terminal?.terminalTitle = String(String(cString: title).prefix(120)) }
            if let terminal { readSessionTitle(for: terminal) }
        case GHOSTTY_ACTION_PWD:
            if let pointer = action.action.pwd.pwd {
                let path = String(cString: pointer)
                if path.utf8.count <= 4_096, (try? requireDirectory(path)) != nil, let terminal {
                    terminal.workingDirectory = path
                    saveShellDirectory(path, for: terminal)
                }
            }
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            terminal?.childExited = true
            Task { @MainActor [weak self] in self?.voiceCoordinator?.destinationStateChanged() }
            if let terminal, let (session, pane) = owner(of: terminal) { discardObservation(pane, sessionID: session.id) }
            DispatchQueue.main.async { [weak self] in self?.refreshSidebar() }
        case GHOSTTY_ACTION_GOTO_SPLIT:
            guard let terminal, let (session, pane) = owner(of: terminal) else { return false }
            let direction: SurfaceTree.FocusDirection
            switch action.action.goto_split {
            case GHOSTTY_GOTO_SPLIT_PREVIOUS: direction = .previous
            case GHOSTTY_GOTO_SPLIT_NEXT: direction = .next
            case GHOSTTY_GOTO_SPLIT_UP: direction = .spatial(.up)
            case GHOSTTY_GOTO_SPLIT_DOWN: direction = .spatial(.down)
            case GHOSTTY_GOTO_SPLIT_LEFT: direction = .spatial(.left)
            case GHOSTTY_GOTO_SPLIT_RIGHT: direction = .spatial(.right)
            default: return false
            }
            let tree = surfaceTree(in: session)
            guard tree.isSplit, let node = tree.find(id: pane.rawValue),
                  let next = tree.focusTarget(for: direction, from: node), livePanes[PaneID(next.id)] != nil else { return false }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectedSession?.id == session.id else { return }
                self.perform { try self.store.updateSession(session.id) { $0.focusedPane = PaneID(next.id) } }
                self.moveFocus(to: PaneID(next.id), in: session.id)
            }
        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            guard let terminal, let (session, _) = owner(of: terminal), surfaceTree(in: session).isSplit else { return false }
            DispatchQueue.main.async { [weak self] in self?.equalize(session.id) }
        case GHOSTTY_ACTION_RESIZE_SPLIT:
            guard let terminal, let (session, pane) = owner(of: terminal) else { return false }
            let resize = action.action.resize_split
            let direction: SurfaceTree.Spatial.Direction
            switch resize.direction {
            case GHOSTTY_RESIZE_SPLIT_UP: direction = .up
            case GHOSTTY_RESIZE_SPLIT_DOWN: direction = .down
            case GHOSTTY_RESIZE_SPLIT_LEFT: direction = .left
            case GHOSTTY_RESIZE_SPLIT_RIGHT: direction = .right
            default: return false
            }
            let tree = surfaceTree(in: session)
            let bounds = CGRect(origin: .zero, size: tree.viewBounds())
            guard bounds.width > 0, bounds.height > 0, let node = tree.find(id: pane.rawValue),
                  (try? tree.resizing(node: node, by: resize.amount, in: direction, with: bounds)) != nil else { return false }
            DispatchQueue.main.async { [weak self] in
                guard let self, let current = self.store.registry.sessions.first(where: { $0.id == session.id }) else { return }
                let currentTree = self.surfaceTree(in: current)
                guard let currentNode = currentTree.find(id: pane.rawValue) else { return }
                self.perform {
                    let resized = try currentTree.resizing(node: currentNode, by: resize.amount, in: direction,
                                                           with: CGRect(origin: .zero, size: currentTree.viewBounds()))
                    try self.saveTree(resized, in: session.id)
                }
            }
        default: return false
        }
        return true
    }

    private func isViewing(_ sessionID: AxoSessionID) -> Bool {
        NSApp.isActive && selectedSession?.id == sessionID && view.window?.isKeyWindow == true && view.window?.isVisible == true
    }
    private func receiveAgentState(_ observation: MacSessionState?, from binding: MacSessionBinding) {
        guard stateBindings[binding.paneID]?.generation == binding.generation, livePanes[binding.paneID]?.childExited == false else { return }
        if let deadline = initialObservationDeadlines[binding.paneID], Date() >= deadline {
            initialObservationDeadlines.removeValue(forKey: binding.paneID); refreshSidebar()
        }
        guard let snapshot = observation else {
            if agentSnapshots.removeValue(forKey: binding.paneID) != nil { refreshSidebar() }
            return // Keep the receipt: recovering observation must not repeat an already reported episode.
        }
        guard let session = store.registry.sessions.first(where: { $0.id == binding.sessionID }),
              snapshot.matches(session: session.id, pane: binding.paneID, generation: binding.generation),
              snapshot.state == .detached || session.conversationID == nil || snapshot.conversationID == session.conversationID else { return }
        if session.conversationID == nil, let conversation = snapshot.conversationID {
            guard PiSessionTitle.readConversationID(from: session.piSessionFile) == conversation else { return }
            do { try store.updateSession(session.id) { $0.conversationID = conversation } }
            catch { return } // Reject duplicate/malformed conversation admission; never show another session's state.
        }
        var receipt = attentionReceipts[binding.paneID] ?? MacAttentionReceipt()
        let notify = receipt.observe(snapshot, isViewing: isViewing(session.id))
        let oldPresentation = agentSnapshots[binding.paneID].map { attentionReceipts[binding.paneID]?.presentation($0) ?? $0.state }
        attentionReceipts[binding.paneID] = receipt
        agentSnapshots[binding.paneID] = snapshot
        let finishedLoading = initialObservationDeadlines.removeValue(forKey: binding.paneID) != nil
        if finishedLoading || oldPresentation != receipt.presentation(snapshot) { refreshSidebar() }
        if notify { notifications?.notify(snapshot, binding: binding, session: session) }
        if isViewing(session.id) { notifications?.dismiss(session.id) }
    }
    private func discardObservation(_ pane: PaneID, sessionID: AxoSessionID) {
        if let binding = stateBindings.removeValue(forKey: pane) { try? FileManager.default.removeItem(atPath: binding.path) }
        try? FileManager.default.removeItem(at: bindingDirectory.appendingPathComponent(pane.rawValue.uuidString + ".json"))
        agentSnapshots.removeValue(forKey: pane); attentionReceipts.removeValue(forKey: pane)
        initialObservationDeadlines.removeValue(forKey: pane)
        notifications?.dismiss(sessionID)
    }
    private func activateNotification(_ destination: MacSessionNotifications.Destination) {
        guard let binding = stateBindings[destination.paneID], binding.sessionID == destination.sessionID,
              binding.generation == destination.generation, livePanes[destination.paneID]?.childExited == false,
              let snapshot = agentSnapshots[destination.paneID],
              snapshot.matches(session: destination.sessionID, pane: destination.paneID, generation: destination.generation),
              snapshot.conversationID == destination.conversationID,
              let session = store.registry.sessions.first(where: { $0.id == destination.sessionID && $0.isArchived != true }),
              session.conversationID == destination.conversationID else {
            let alert = NSAlert(); alert.messageText = "This notification belongs to an earlier run"
            alert.informativeText = "Open the saved session from the sidebar to inspect it. No work was restarted or submitted."
            alert.runModal(); return
        }
        perform {
            try store.updateSession(destination.sessionID) { $0.focusedPane = destination.paneID }
            try activateSession(destination.sessionID)
            view.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); restoreFocus()
        }
    }
    @objc func showSettings(_ sender: Any?) {
        guard let voiceCoordinator else { return }
        notifications?.showSettings(voiceCoordinator: voiceCoordinator)
    }

    private func saveShellDirectory(_ path: String, for terminal: TerminalView) {
        guard let (session, paneID) = owner(of: terminal),
              let pane = session.panes.first(where: { $0.id == paneID }), pane.kind == .shell,
              pane.directory != path else { return }
        do {
            try store.updateSession(session.id) { value in
                guard let index = value.panes.firstIndex(where: { $0.id == paneID }) else { throw WorkspaceFault.notFound }
                value.panes[index].directory = path
            }
        } catch { /* A failed metadata write must not disrupt the running shell. */ }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(previousPane(_:)), #selector(nextPane(_:)):
            return (selectedSession?.layout?.panes.count ?? 0) > 1
        case #selector(previousSession(_:)), #selector(nextSession(_:)):
            guard let session = selectedSession else { return false }
            return store.registry.sessions.filter { $0.workspaceID == session.workspaceID && $0.isArchived != true }.count > 1
        case #selector(previousWorkspace(_:)), #selector(nextWorkspace(_:)):
            return store.registry.workspaces.filter { $0.isArchived != true }.count > 1
        case #selector(splitRight(_:)), #selector(splitDown(_:)):
            return selectedSession?.focusedPane != nil && livePanes.count < 128
        case #selector(closePane(_:)):
            return selectedSession?.focusedPane != nil && closeConfirmation == nil
        case #selector(renameSession(_:)), #selector(renameWorkspace(_:)):
            return menuItem.representedObject is SidebarItem || selectedSession != nil
        default: return true
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarItem)?.children.count ?? sidebarItems.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarItem)?.children[index] ?? sidebarItems[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? SidebarItem)?.workspace != nil }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarItem else { return nil }
        if item.isSeparator { let line = NSBox(); line.boxType = .separator; return line }
        if let title = item.sectionTitle { return WorkspaceSidebarHeading(title: title) }
        let menu = itemMenu(item)
        let workspace = item.workspace != nil
        let running = item.session?.panes.contains { livePanes[$0.id] != nil && livePanes[$0.id]?.childExited == false } ?? false
        let piPane = item.session?.panes.first(where: { $0.kind == .pi })?.id
        let activity = piPane.flatMap { id -> MacAgentState? in
            if let snapshot = agentSnapshots[id] { return attentionReceipts[id]?.presentation(snapshot) ?? snapshot.state }
            return stateBindings[id] == nil ? nil : .detached
        }
        let voiceRecording = voiceCoordinator?.recordingTarget?.sessionID == item.session?.id
        return WorkspaceSidebarRow(name: item.workspace?.name ?? item.session?.name ?? "", workspace: workspace,
                                   running: running, activity: activity,
                                   loading: piPane.map { initialObservationDeadlines[$0] != nil } ?? false,
                                   voiceRecording: voiceRecording, actions: menu,
                                   finishRename: { [weak self] name in self?.finishRenaming(item, name: name) })
    }
    private func readSessionTitle(for terminal: TerminalView) {
        guard let (session, pane) = owner(of: terminal), session.effectiveNameSource == .untitled,
              session.panes.first(where: { $0.id == pane })?.kind == .pi else { return }
        guard pendingTitleReads.insert(pane).inserted else { deferredTitleReads.insert(pane); return }
        titleQueue.async { [weak self, weak terminal] in
            let title = PiSessionTitle.read(from: session.piSessionFile)
            DispatchQueue.main.async { [weak self, weak terminal] in
                guard let self else { return }
                self.pendingTitleReads.remove(pane)
                if self.deferredTitleReads.remove(pane) != nil, let terminal, self.livePanes[pane] === terminal {
                    self.readSessionTitle(for: terminal)
                }
                guard let terminal, self.livePanes[pane] === terminal, let title,
                      session.conversationID == nil || session.conversationID == title.conversationID else { return }
                do {
                    try self.store.applyAutomaticTitle(title.name, to: session.id)
                    self.refreshSidebar(); self.updateTitle()
                } catch { /* Naming is best-effort and must not interrupt the user's terminal. */ }
            }
        }
    }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { WorkspaceSidebarRowView() }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? SidebarItem)?.isDecoration != true }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? SidebarItem)?.sectionTitle != nil }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { (item as? SidebarItem)?.isSeparator == true ? 20 : 28 }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !refreshingSidebar, let item = notification.userInfo?["NSObject"] as? SidebarItem, let workspace = item.workspace else { return }
        collapsedWorkspaces.insert(workspace.id)
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !refreshingSidebar, let item = notification.userInfo?["NSObject"] as? SidebarItem, let workspace = item.workspace else { return }
        collapsedWorkspaces.remove(workspace.id)
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !refreshingSidebar, let item = sidebar.item(atRow: sidebar.selectedRow) as? SidebarItem else { return }
        let sessionID = item.session?.id ?? item.children.first?.session?.id
        guard let sessionID else { return }
        perform { try activateSession(sessionID) }
    }
}

@MainActor
private final class WeakWorkspaceController: @unchecked Sendable {
    weak var value: WorkspaceController?
    init(_ value: WorkspaceController) { self.value = value }
}

/// Local event monitors run synchronously on AppKit's main thread; keep the event boxed while asserting that actor boundary.
private final class MainActorEventReference: @unchecked Sendable {
    let event: NSEvent
    init(_ event: NSEvent) { self.event = event }
}

private final class MainActorEventResult: @unchecked Sendable {
    let event: NSEvent?
    init(_ event: NSEvent?) { self.event = event }
}

private final class TerminalLaunchFailureView: NSView {
    private let retry: () -> Void
    init(message: String, retry: @escaping () -> Void) {
        self.retry = retry; super.init(frame: .zero)
        let label = NSTextField(wrappingLabelWithString: message)
        label.alignment = .center; label.textColor = .secondaryLabelColor
        let button = NSButton(title: "Retry", target: self, action: #selector(start))
        let stack = NSStackView(views: [label, button]); stack.orientation = .vertical; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.85),
        ])
    }
    required init?(coder: NSCoder) { fatalError("Programmatic view only") }
    @objc private func start() { retry() }
}
