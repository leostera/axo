import AppKit
import AxoCore
import GhosttyKit
import SwiftUI

/// Owns surfaces independently of selected views. Switching never releases a process.
final class WorkspaceController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSplitViewDelegate, NSMenuItemValidation {
    typealias SurfaceTree = SplitTree<PaneHostView>
    let view = NSSplitView()
    private let sidebar = NSOutlineView()
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
    private let runtime: GhosttyRuntime
    private var livePanes: [PaneID: TerminalView] = [:]
    private var paneHosts: [PaneID: PaneHostView] = [:]
    private var splitHost: NSHostingView<PaneSplitTreeView>?
    private var closeConfirmation: NSAlert?
    private var sidebarItems: [SidebarItem] = []
    private var refreshingSidebar = false
    private var collapsedWorkspaces = Set<WorkspaceID>()
    private let launchOverride: ((PaneRecord, WorkSession) -> TerminalLaunch)?
    var nameProvider: ((String, String) -> String?)?
    var registry: WorkspaceRegistry { store.registry }
    func terminal(for pane: PaneID) -> TerminalView? { livePanes[pane] }
    func resumePane(_ id: PaneID, in sessionID: AxoSessionID) throws {
        guard let session = store.registry.sessions.first(where: { $0.id == sessionID }),
              let pane = session.panes.first(where: { $0.id == id }) else { throw WorkspaceFault.notFound }
        try launch(pane, in: session)
    }
    func selectSession(_ id: AxoSessionID) throws { try store.select(id); refreshSidebar(); showSelectedSession() }
    var onTitle: ((String) -> Void)?
    var hasLiveProcesses: Bool { livePanes.values.contains { !$0.childExited } }

    private final class SidebarItem: NSObject {
        let workspace: WorkspaceRecord?
        let session: WorkSession?
        var children: [SidebarItem] = []
        init(workspace: WorkspaceRecord) { self.workspace = workspace; self.session = nil }
        init(session: WorkSession) { self.workspace = nil; self.session = session }
    }

    init(runtime: GhosttyRuntime, repository: String, storageRoot: URL? = nil,
         launchOverride: ((PaneRecord, WorkSession) -> TerminalLaunch)? = nil) throws {
        self.runtime = runtime; self.repository = repository; self.launchOverride = launchOverride
        let support = storageRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Axo")
        scratchRoot = support.appendingPathComponent("Workspaces")
        store = try WorkspaceStore(url: support.appendingPathComponent("workspaces.json"), scratchRoot: scratchRoot)
        super.init()
        configureSidebar()
        let firstLaunch = store.registry.workspaces.isEmpty
        if firstLaunch {
            _ = try store.createWorkspace(name: "Playground", commandID: "prototype-import",
                                          initialDirectory: storageRoot == nil ? repository + "/local/playground" : nil,
                                          initialSessionFile: storageRoot == nil ? repository + "/local/playground/session.jsonl" : nil)
        }
        runtime.onAction = { [weak self] terminal, action in self?.handle(terminal: terminal, action: action) ?? false }
        refreshSidebar()
        showSelectedSession()
        // Even a newly imported prototype stays stopped: its JSONL may still be owned
        // by the old running app/Pi. Metadata import is not live-process adoption.
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
        createWorkspace(directory: focusedTerminal?.workingDirectory ?? selectedSession?.directory)
    }
    private func createWorkspace(directory: String?) {
        perform {
            if let directory { try requireDirectory(directory) }
            let name = directory.flatMap { try? WorkspaceStore.validName(URL(fileURLWithPath: $0).lastPathComponent) } ?? "New workspace"
            let receipt = try store.createWorkspace(name: name, initialDirectory: directory)
            refreshSidebar(); showSelectedSession()
            if let session = store.registry.sessions.first(where: { $0.id == receipt.sessionID }), let pane = session.panes.first {
                try launch(pane, in: session)
            }
        }
    }
    @objc func newSession(_ sender: Any?) {
        guard let workspaceID = selectedSession?.workspaceID else { newWorkspace(sender); return }
        createSession(in: workspaceID, directory: focusedTerminal?.workingDirectory ?? selectedSession?.directory)
    }
    private func createSession(in workspaceID: WorkspaceID, directory: String?) {
        perform {
            if let directory { try requireDirectory(directory) }
            let receipt = try store.createSession(workspaceID: workspaceID, name: "Untitled", initialDirectory: directory)
            refreshSidebar(); showSelectedSession()
            if let session = store.registry.sessions.first(where: { $0.id == receipt.sessionID }), let pane = session.panes.first {
                try launch(pane, in: session)
            }
        }
    }
    @objc func splitRight(_ sender: Any?) { splitSelected(direction: .right) }
    @objc func splitDown(_ sender: Any?) { splitSelected(direction: .down) }
    @objc func closePane(_ sender: Any?) {
        guard let session = selectedSession, let paneID = session.focusedPane else { return }
        requestClose(paneID, sessionID: session.id, needsConfirmation: livePanes[paneID]?.childExited == false)
    }
    @objc func renameSession(_ sender: Any?) {
        let session = (sender as? NSMenuItem)?.representedObject as? SidebarItem
        guard let session = session?.session ?? selectedSession,
              let name = askName(title: "Rename session", initial: session.name) else { return }
        perform { try store.renameSession(session.id, name: name); refreshSidebar(); updateTitle() }
    }
    @objc func renameWorkspace(_ sender: Any?) {
        let item = (sender as? NSMenuItem)?.representedObject as? SidebarItem
        guard let workspace = item?.workspace ?? store.registry.workspaces.first(where: { $0.id == selectedSession?.workspaceID }),
              let name = askName(title: "Rename workspace", initial: workspace.name) else { return }
        perform { try store.renameWorkspace(workspace.id, name: name); refreshSidebar() }
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
            let pane = PaneRecord(kind: .shell)
            let newHost = PaneHostView(id: pane.id)
            let changed = try surfaceTree(in: original).inserting(view: newHost, at: target.leftmostLeaf(), direction: direction)
            try store.updateSession(sessionID) { value in
                value.panes.append(pane); value.layout = changed.savedLayout(); value.focusedPane = pane.id
            }
            paneHosts[pane.id] = newHost
            guard let session = store.registry.sessions.first(where: { $0.id == sessionID }) else { throw WorkspaceFault.notFound }
            try launch(pane, in: session, shellDirectory: directory, inheriting: livePanes[paneID]?.surface)
        }
    }
    private func launch(_ pane: PaneRecord, in session: WorkSession, shellDirectory: String? = nil, inheriting: ghostty_surface_t? = nil) throws {
        guard livePanes[pane.id] == nil, livePanes.count < 128 else { throw WorkspaceFault.capacity }
        if pane.kind == .pi {
            let runningAgents = store.registry.sessions.flatMap(\.panes).filter { $0.kind == .pi && livePanes[$0.id] != nil }.count
            guard runningAgents < 32 else { throw WorkspaceFault.capacity }
        }
        let directory = shellDirectory ?? session.directory
        // Create only generated scratch directories. Missing imported/project directories require repair.
        if directory.hasPrefix(scratchRoot.path + "/") {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try requireDirectory(directory)
        if pane.kind == .pi, session.piSessionFile.hasPrefix(scratchRoot.path + "/") {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: session.piSessionFile).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let launch: TerminalLaunch = launchOverride?(pane, session) ?? (pane.kind == .pi
            ? .pi(repository: repository, directory: directory, sessionFile: session.piSessionFile)
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
        if selectedSession?.id == session.id { showSelectedSession() }
        refreshSidebar()
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
        sidebar.setAccessibilityLabel("Workspaces and sessions")
        scroll.documentView = sidebar
        let heading = NSTextField(labelWithString: "Axo")
        heading.font = .systemFont(ofSize: 13, weight: .semibold); heading.textColor = .secondaryLabelColor
        let create = sidebarButton(symbol: "plus", label: "New workspace", action: #selector(newWorkspace(_:)))
        let collapse = sidebarButton(symbol: "sidebar.left", label: "Collapse sidebar", action: #selector(toggleSidebar(_:)))
        for child in [scroll, heading, create, collapse] {
            child.translatesAutoresizingMaskIntoConstraints = false; sidebarContainer.addSubview(child)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor, constant: 16),
            heading.topAnchor.constraint(equalTo: sidebarContainer.topAnchor, constant: 14),
            create.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor, constant: -10),
            create.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: collapse.topAnchor, constant: -8),
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
        refreshingSidebar = true
        defer { refreshingSidebar = false }
        sidebarItems = store.registry.workspaces.map { workspace in
            let item = SidebarItem(workspace: workspace)
            item.children = store.registry.sessions.filter { $0.workspaceID == workspace.id }.map(SidebarItem.init(session:))
            return item
        }
        sidebar.reloadData(); sidebar.expandItem(nil, expandChildren: true)
        for item in sidebarItems where item.workspace.map({ collapsedWorkspaces.contains($0.id) }) == true {
            sidebar.collapseItem(item)
        }
        for item in sidebarItems.flatMap(\.children) where item.session?.id == store.registry.selectedSession {
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
        guard let session = selectedSession else { return }
        splitHost = nil
        let body: NSView
        if session.layout != nil {
            let host = NSHostingView(rootView: splitView(in: session))
            splitHost = host; body = host
        } else {
            let button = NSButton(title: "Resume Pi", target: nil, action: nil)
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
            if let updated = selectedSession { try launch(pane, in: updated) }
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
        else if host.subviews.isEmpty {
            host.show(StoppedPaneView(title: session.panes.first(where: { $0.id == id })?.kind == .pi ? "Resume Pi" : "Open shell") { [weak self] in
                guard let self, let current = self.store.registry.sessions.first(where: { $0.id == session.id }),
                      let pane = current.panes.first(where: { $0.id == id }) else { return }
                self.perform { try self.launch(pane, in: current) }
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
        alert.accessoryView = field; alert.addButton(withTitle: "Create / Save"); alert.addButton(withTitle: "Cancel")
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
            DispatchQueue.main.async { [weak self] in self?.createWorkspace(directory: directory) }
        case GHOSTTY_ACTION_SET_TITLE:
            if let title = action.action.set_title.title { terminal?.terminalTitle = String(String(cString: title).prefix(120)) }
            if let terminal { readSessionTitle(for: terminal) }
        case GHOSTTY_ACTION_PWD:
            if let pointer = action.action.pwd.pwd {
                let path = String(cString: pointer)
                if path.utf8.count <= 4_096, (try? requireDirectory(path)) != nil { terminal?.workingDirectory = path }
            }
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            terminal?.childExited = true
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
        let menu = NSMenu()
        let workspace = item.workspace != nil
        let rename = NSMenuItem(title: workspace ? "Rename Workspace…" : "Rename Session…",
                                action: workspace ? #selector(renameWorkspace(_:)) : #selector(renameSession(_:)), keyEquivalent: "")
        rename.target = self; rename.representedObject = item; menu.addItem(rename)
        let running = item.session?.panes.contains { livePanes[$0.id] != nil && livePanes[$0.id]?.childExited == false } ?? false
        return WorkspaceSidebarRow(name: item.workspace?.name ?? item.session?.name ?? "", workspace: workspace, running: running, actions: menu)
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
        perform { try store.select(sessionID); showSelectedSession() }
    }
}

private final class StoppedPaneView: NSView {
    private let resume: () -> Void
    init(title: String, resume: @escaping () -> Void) {
        self.resume = resume; super.init(frame: .zero)
        let button = NSButton(title: title, target: self, action: #selector(start))
        button.translatesAutoresizingMaskIntoConstraints = false; addSubview(button)
        NSLayoutConstraint.activate([button.centerXAnchor.constraint(equalTo: centerXAnchor), button.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("Programmatic view only") }
    @objc private func start() { resume() }
}
