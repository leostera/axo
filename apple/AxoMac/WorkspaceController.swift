import AppKit
import AxoCore
import GhosttyKit
import SwiftUI

/// Owns surfaces independently of selected views. Switching never releases a process.
final class WorkspaceController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSplitViewDelegate, NSMenuItemValidation {
    typealias SurfaceTree = SplitTree<PaneHostView>
    let view = NSSplitView()
    private let sidebar = WorkspaceOutlineView()
    private var editingSidebar = false
    private let sidebarContainer = NSVisualEffectView()
    private let reopenSidebar = NSButton()
    private var sidebarMinimumWidth: NSLayoutConstraint?
    private var sidebarWidth: CGFloat = 210
    private var positionedSidebar = false
    private(set) var sidebarCollapsed = false
    private let titleQueue = DispatchQueue(label: "dev.leostera.axo.session-titles", qos: .utility)
    private var pendingTitleReads = Set<PaneID>()
    private var deferredTitleReads = Set<PaneID>()
    private let content = NSView()
    private let store: WorkspaceStore
    private let repository: String
    private let scratchRoot: URL
    private let stateRoot: URL
    private var stateBindings: [PaneID: MacSessionBinding] = [:]
    private var agentSnapshots: [PaneID: MacSessionState] = [:]
    private var attentionReceipts: [PaneID: MacAttentionReceipt] = [:]
    private var stateObserver: MacSessionObserver?
    private var notifications: MacSessionNotifications?
    private let runtime: GhosttyRuntime
    private var livePanes: [PaneID: TerminalView] = [:]
    private var launchFailures: [PaneID: String] = [:]
    private var paneHosts: [PaneID: PaneHostView] = [:]
    private var splitHost: NSHostingView<PaneSplitTreeView>?
    private var closeConfirmation: NSAlert?
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

    init(runtime: GhosttyRuntime, repository: String, storageRoot: URL? = nil,
         launchOverride: ((PaneRecord, WorkSession) -> TerminalLaunch)? = nil) throws {
        self.runtime = runtime; self.repository = repository; self.launchOverride = launchOverride
        // Finder normally activates the existing app. Also reject a second direct executable launch
        // before it writes registry state or automatically opens the same Pi files.
        if storageRoot == nil, NSRunningApplication.runningApplications(withBundleIdentifier: "dev.leostera.axo.mac")
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
            throw WorkspaceLaunchFault.otherAppRunning
        }
        let support = storageRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Axo")
        scratchRoot = support.appendingPathComponent("Workspaces")
        stateRoot = support.appendingPathComponent("RuntimeStates")
        store = try WorkspaceStore(url: support.appendingPathComponent("workspaces.json"), scratchRoot: scratchRoot)
        super.init()
        configureSidebar()
        let firstLaunch = store.registry.workspaces.isEmpty
        if firstLaunch {
            _ = try store.createWorkspace(name: "Playground", commandID: "prototype-import",
                                          initialDirectory: storageRoot == nil ? repository + "/local/playground" : nil,
                                          initialSessionFile: storageRoot == nil ? repository + "/local/playground/session.jsonl" : nil, kind: .playground)
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
                                                    testDestination: { [weak self] in self?.notificationTestDestination() },
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
        guard let workspaceID = selectedSession?.workspaceID ?? clicked?.workspace?.id else { newPlaygroundSession(sender); return }
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
    @objc func newPlaygroundSession(_ sender: Any?) {
        if let workspace = store.registry.workspaces.first(where: { $0.effectiveKind == .playground && $0.isArchived != true }) {
            createSession(in: workspace.id, directory: nil)
        } else {
            perform {
                let receipt = try store.createWorkspace(name: "Playground", kind: .playground)
                openSavedPanes(in: receipt.sessionID); refreshSidebar(); showSelectedSession()
            }
        }
    }
    @objc private func showCreationMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let project = NSMenuItem(title: "New Project…", action: #selector(newWorkspace(_:)), keyEquivalent: "")
        let playground = NSMenuItem(title: "New Playground Session", action: #selector(newPlaygroundSession(_:)), keyEquivalent: "")
        project.target = self; playground.target = self; menu.addItem(project); menu.addItem(playground)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }
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
        if !sidebarCollapsed { sidebarWidth = max(180, sidebarContainer.frame.width) }
        sidebarCollapsed.toggle()
        sidebarMinimumWidth?.isActive = !sidebarCollapsed
        sidebarContainer.isHidden = sidebarCollapsed
        reopenSidebar.isHidden = !sidebarCollapsed
        view.adjustSubviews()
        if !sidebarCollapsed { view.setPosition(sidebarWidth, ofDividerAt: 0) }
        restoreFocus()
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
            observation = MacSessionBinding(sessionID: session.id, paneID: pane.id, generation: UUID(),
                                            path: stateRoot.appendingPathComponent(pane.id.rawValue.uuidString + ".json").path)
        }
        let launch: TerminalLaunch = launchOverride?(pane, session) ?? (pane.kind == .pi
            ? .pi(repository: repository, directory: directory, sessionFile: session.piSessionFile, observation: observation)
            : .shell(directory: directory))
        let terminal = try TerminalView(runtime: runtime, launch: launch, inheriting: inheriting)
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
        if let observation { stateBindings[pane.id] = observation }
        launchFailures.removeValue(forKey: pane.id)
    }
    private func requestClose(_ paneID: PaneID, sessionID: AxoSessionID, needsConfirmation: Bool) {
        guard needsConfirmation else { finishClose(paneID, sessionID: sessionID); return }
        // Ghostty uses one asynchronous NSAlert sheet, not a fragile SwiftUI confirmation binding.
        guard closeConfirmation == nil, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Close terminal and stop its process?"
        alert.informativeText = "Other sessions and splits keep running. The Pi conversation stays saved locally."
        alert.addButton(withTitle: "Stop and close"); alert.addButton(withTitle: "Cancel")
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
        let tree = surfaceTree(in: session)
        let next = tree.root?.leftmostLeaf() === node.leftmostLeaf()
            ? tree.focusTarget(for: .next, from: node) : tree.focusTarget(for: .previous, from: node)
        perform {
            try store.updateSession(sessionID) { value in
                value.panes.removeAll { $0.id == paneID }
                value.layout = tree.removing(node).savedLayout()
                if value.focusedPane == paneID { value.focusedPane = next.map { PaneID($0.id) }.flatMap { $0 == paneID ? nil : $0 } }
            }
            livePanes.removeValue(forKey: paneID)?.removeFromSuperview()
            paneHosts.removeValue(forKey: paneID)
            discardObservation(paneID, sessionID: sessionID)
            launchFailures.removeValue(forKey: paneID)
            refreshSidebar(); showSelectedSession()
        }
    }

    private func configureSidebar() {
        view.isVertical = true; view.dividerStyle = .thin; view.delegate = self
        sidebarContainer.material = .sidebar; sidebarContainer.blendingMode = .behindWindow
        sidebarContainer.state = .followsWindowActiveState
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("navigation"))
        column.title = "Axo"; sidebar.addTableColumn(column); sidebar.outlineTableColumn = column
        sidebar.headerView = nil; sidebar.rowHeight = 28; sidebar.intercellSpacing = NSSize(width: 0, height: 2)
        sidebar.style = .sourceList; sidebar.indentationPerLevel = 12; sidebar.backgroundColor = .clear
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
        let create = sidebarButton(symbol: "plus", label: "Create project or playground session", action: #selector(showCreationMenu(_:)))
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
        sidebarMinimumWidth = sidebarContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        sidebarMinimumWidth?.isActive = true
        view.setPosition(sidebarWidth, ofDividerAt: 0)
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        // NSSplitView has zero bounds during construction; position only after the window lays it out.
        guard !positionedSidebar, view.bounds.width >= 400, view.arrangedSubviews.count == 2 else { return }
        positionedSidebar = true
        view.setPosition(sidebarWidth, ofDividerAt: 0)
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
        let playgroundIDs = Set(active.filter { $0.effectiveKind == .playground }.map(\.id))
        let playgrounds = store.registry.sessions.filter { playgroundIDs.contains($0.workspaceID) && $0.isArchived != true }.map(SidebarItem.init(session:))
        let workspaceSection = projects.isEmpty ? [] : [SidebarItem(sectionTitle: "Workspaces")] + projects
        let sessionSection = playgrounds.isEmpty ? [] : [SidebarItem(sectionTitle: "Sessions")] + playgrounds
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
        if oldPresentation != receipt.presentation(snapshot) { refreshSidebar() }
        if notify { notifications?.notify(snapshot, binding: binding) }
        if isViewing(session.id) { notifications?.dismiss(session.id) }
    }
    private func discardObservation(_ pane: PaneID, sessionID: AxoSessionID) {
        if let binding = stateBindings.removeValue(forKey: pane) { try? FileManager.default.removeItem(atPath: binding.path) }
        agentSnapshots.removeValue(forKey: pane); attentionReceipts.removeValue(forKey: pane)
        notifications?.dismiss(sessionID, includingTests: true)
    }
    private func notificationTestDestination() -> MacSessionNotifications.Destination? {
        guard let session = selectedSession, session.isArchived != true,
              let pane = session.panes.first(where: { $0.kind == .pi }), livePanes[pane.id]?.childExited == false,
              let binding = stateBindings[pane.id], let snapshot = agentSnapshots[pane.id],
              snapshot.matches(session: session.id, pane: pane.id, generation: binding.generation),
              let conversation = snapshot.conversationID, session.conversationID == conversation else { return nil }
        return .init(sessionID: session.id, paneID: pane.id, generation: binding.generation, conversationID: conversation)
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
    @objc func showSettings(_ sender: Any?) { notifications?.showSettings() }

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
        return WorkspaceSidebarRow(name: item.workspace?.name ?? item.session?.name ?? "", workspace: workspace, running: running, activity: activity, actions: menu,
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

private enum WorkspaceLaunchFault: LocalizedError {
    case otherAppRunning
    var errorDescription: String? { "Axo is already running. Use its existing window, or quit it before opening another copy." }
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
