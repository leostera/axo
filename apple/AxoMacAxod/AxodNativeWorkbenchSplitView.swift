import AppKit
import AxoCore
import AxoProtocol
import SwiftUI

struct AxodNativeWorkbenchSplitView: NSViewRepresentable {
    let workbench: AxodWorkbenchCoordinator
    let workspaces: [CentralWorkspace]
    let sessions: [CentralSession]
    let sessionDisplayNames: [UUID: String]
    let selectedWorkspaceID: UUID?
    let selectedSessionID: UUID?
    @Binding var sidebarCollapsed: Bool
    let detail: AnyView

    func makeCoordinator() -> SidebarController {
        SidebarController(
            workbench: workbench,
            sidebarCollapsed: $sidebarCollapsed
        )
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.makeView(detail: detail)
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(
            workbench: workbench,
            workspaces: workspaces,
            sessions: sessions,
            sessionDisplayNames: sessionDisplayNames,
            selectedWorkspaceID: selectedWorkspaceID,
            selectedSessionID: selectedSessionID,
            sidebarCollapsed: $sidebarCollapsed,
            detail: detail
        )
    }

    @MainActor
    final class SidebarController: NSObject, NSSplitViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
        private final class Item: NSObject {
            var workspace: CentralWorkspace?
            var session: CentralSession?
            let heading: String?
            var children: [Item] = []

            init(heading: String) {
                self.workspace = nil
                self.session = nil
                self.heading = heading
            }

            var isDivider = false

            init(divider: Void) {
                self.workspace = nil
                self.session = nil
                self.heading = nil
                self.isDivider = true
            }

            init(workspace: CentralWorkspace) {
                self.workspace = workspace
                self.session = nil
                self.heading = nil
            }

            init(session: CentralSession) {
                self.workspace = nil
                self.session = session
                self.heading = nil
            }
        }

        private struct Snapshot: Equatable {
            let machineID: UUID?
            let storeGeneration: UUID?
            let workspaces: [CentralWorkspace]
            let sessions: [CentralSession]
            let selectedWorkspaceID: UUID?
            let selectedSessionID: UUID?
            let sessionDisplayNames: [UUID: String]
        }

        private static let sidebarWidthKey = "Axo.axod.sidebarWidth"
        private let rootView = NSView()
        private let splitView = NSSplitView()
        private let sidebarContainer = NSVisualEffectView()
        private let expandedSidebar = NSView()
        private lazy var compactSidebar = AxodCompactSidebarView(
            onSelect: { [weak self] destination in
                switch destination {
                case .workspace(let id): self?.workbench.selectWorkspace(id)
                case .session(let id): self?.workbench.selectSession(id)
                }
            },
            onExpand: { [weak self] in self?.sidebarCollapsed.wrappedValue = false }
        )
        private let content = NSView()
        private let outline = WorkspaceOutlineView()
        private let detailHost: NSHostingView<AnyView>
        private let preferences: UserDefaults
        private var sidebarMinimumWidth: NSLayoutConstraint?
        private var compactSidebarWidth: NSLayoutConstraint?
        private var displayedCollapsed: Bool?
        private var sidebarWidth: CGFloat
        private var positionedSidebar = false
        private var sidebarItems: [Item] = []
        private var lastSnapshot: Snapshot?
        private var refreshingSidebar = false
        private var sidebarSelection = AxodSidebarSelection()
        private var sessionDisplayNames: [UUID: String] = [:]
        private var workbench: AxodWorkbenchCoordinator
        private var sidebarCollapsed: Binding<Bool>
        private var sidebarStateSaveWork: DispatchWorkItem?

        init(
            workbench: AxodWorkbenchCoordinator,
            sidebarCollapsed: Binding<Bool>
        ) {
            self.workbench = workbench
            self.preferences = workbench.preferences
            self.sidebarCollapsed = sidebarCollapsed
            self.sidebarWidth = Self.validatedSidebarWidth(
                storedValue: workbench.preferences.object(forKey: Self.sidebarWidthKey) as? NSNumber
            )
            self.detailHost = NSHostingView(rootView: AnyView(EmptyView()))
            super.init()
        }

        func makeView(detail: AnyView) -> NSView {
            configureSidebar()
            detailHost.rootView = detail
            detailHost.identifier = NSUserInterfaceItemIdentifier("Axo.SessionDetail")
            detailHost.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(detailHost)
            NSLayoutConstraint.activate([
                detailHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                detailHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                detailHost.topAnchor.constraint(equalTo: content.topAnchor),
                detailHost.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])

            splitView.isVertical = true
            splitView.dividerStyle = .thin
            splitView.delegate = self
            splitView.translatesAutoresizingMaskIntoConstraints = false
            splitView.addArrangedSubview(sidebarContainer)
            splitView.addArrangedSubview(content)
            rootView.addSubview(splitView)
            NSLayoutConstraint.activate([
                splitView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
                splitView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
                splitView.topAnchor.constraint(equalTo: rootView.topAnchor),
                splitView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            ])

            setSidebarCollapsed(sidebarCollapsed.wrappedValue)
            return rootView
        }

#if AXO_NATIVE_FIXTURE
        var fixtureOutline: NSOutlineView { outline }
        func fixtureSessionRows() -> [(id: UUID, row: Int)] {
            sidebarItems.flatMap { [$0] + $0.children }.compactMap { item in
                guard let session = item.session else { return nil }
                let row = outline.row(forItem: item)
                return row >= 0 ? (session.sessionId, row) : nil
            }
        }
        func fixtureSessionNames() -> [UUID: String] {
            Dictionary(uniqueKeysWithValues: fixtureSessionRows().compactMap { entry in
                guard let row = outline.view(atColumn: 0, row: entry.row, makeIfNecessary: true) as? WorkspaceSidebarRow,
                      let name = row.textField?.stringValue else { return nil }
                return (entry.id, name)
            })
        }
        func fixtureWorkspaceItem(_ id: UUID) -> Any? { sidebarItems.first { $0.workspace?.workspaceId == id } }
        func fixtureExpanded(_ id: UUID) -> Bool {
            guard let item = fixtureWorkspaceItem(id) else { return false }
            return outline.isItemExpanded(item)
        }
        func fixtureSelectedSessionIDs() -> Set<UUID> {
            Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Item)?.session?.sessionId })
        }
        func fixtureSelectionDidChange() {
            outlineViewSelectionDidChange(Notification(name: NSOutlineView.selectionDidChangeNotification, object: outline))
        }
#endif

        func update(
            workbench: AxodWorkbenchCoordinator,
            workspaces: [CentralWorkspace],
            sessions: [CentralSession],
            sessionDisplayNames: [UUID: String],
            selectedWorkspaceID: UUID?,
            selectedSessionID: UUID?,
            sidebarCollapsed: Binding<Bool>,
            detail: AnyView
        ) {
            self.workbench = workbench
            self.sidebarCollapsed = sidebarCollapsed
            self.sessionDisplayNames = sessionDisplayNames
            detailHost.rootView = detail
            refreshSidebar(
                workspaces: workspaces,
                sessions: sessions,
                sessionDisplayNames: sessionDisplayNames,
                selectedWorkspaceID: selectedWorkspaceID,
                selectedSessionID: selectedSessionID
            )
            setSidebarCollapsed(sidebarCollapsed.wrappedValue)
        }

        private func configureSidebar() {
            sidebarContainer.material = .underWindowBackground
            sidebarContainer.blendingMode = .withinWindow
            sidebarContainer.state = .followsWindowActiveState
            for child in [expandedSidebar, compactSidebar] {
                child.translatesAutoresizingMaskIntoConstraints = false
                sidebarContainer.addSubview(child)
                NSLayoutConstraint.activate([
                    child.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
                    child.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
                    child.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
                    child.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
                ])
            }

            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false

            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("navigation"))
            column.title = "Axo"
            outline.addTableColumn(column)
            outline.outlineTableColumn = column
            outline.headerView = nil
            outline.rowHeight = 28
            outline.intercellSpacing = NSSize(width: 0, height: 2)
            outline.style = .sourceList
            outline.selectionHighlightStyle = .regular
            outline.allowsMultipleSelection = true
            outline.allowsEmptySelection = true
            outline.indentationPerLevel = 12
            outline.backgroundColor = .clear
            outline.dataSource = self
            outline.delegate = self
            outline.itemMenu = { [weak self] item in
                guard let self else { return NSMenu() }
                let row = self.outline.row(forItem: item)
                guard let menu = (self.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? WorkspaceSidebarRow)?.menu else { return NSMenu() }
                let clickedIsSelected = self.outline.selectedRowIndexes.contains(row)
                menu.items.first(where: { $0.action == #selector(WorkspaceSidebarRow.renameFromMenu(_:)) })?.isEnabled =
                    !clickedIsSelected || self.outline.selectedRowIndexes.count == 1
                return menu
            }
            outline.reclaimsOutlineGutter = { value in
                guard let item = value as? Item else { return false }
                return item.heading != nil || item.isDivider || item.session?.workspaceId == nil && item.session != nil
            }
            outline.setAccessibilityLabel("Workspaces and sessions")
            scroll.documentView = outline

            let collapse = sidebarButton(symbol: "sidebar.left", label: "Collapse sidebar", action: #selector(collapseSidebar(_:)))
            for child in [scroll, collapse] {
                child.translatesAutoresizingMaskIntoConstraints = false
                expandedSidebar.addSubview(child)
            }
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: expandedSidebar.topAnchor, constant: 12),
                scroll.leadingAnchor.constraint(equalTo: expandedSidebar.leadingAnchor, constant: 6),
                scroll.trailingAnchor.constraint(equalTo: expandedSidebar.trailingAnchor, constant: -6),
                scroll.bottomAnchor.constraint(equalTo: collapse.topAnchor, constant: -12),
                collapse.trailingAnchor.constraint(equalTo: expandedSidebar.trailingAnchor, constant: -10),
                collapse.bottomAnchor.constraint(equalTo: expandedSidebar.bottomAnchor, constant: -10),
            ])

            sidebarMinimumWidth = sidebarContainer.widthAnchor.constraint(
                greaterThanOrEqualToConstant: CGFloat(WorkspaceWindowState.minimumSidebarWidth)
            )
            sidebarMinimumWidth?.isActive = true
            compactSidebarWidth = sidebarContainer.widthAnchor.constraint(equalToConstant: AxodCompactSidebarView.width)
            sidebarContainer.widthAnchor.constraint(
                lessThanOrEqualToConstant: CGFloat(WorkspaceWindowState.maximumSidebarWidth)
            ).isActive = true
        }

        private func refreshSidebar(
            workspaces: [CentralWorkspace],
            sessions incomingSessions: [CentralSession],
            sessionDisplayNames: [UUID: String],
            selectedWorkspaceID: UUID?,
            selectedSessionID: UUID?
        ) {
            let storeChanged = lastSnapshot?.storeGeneration != workbench.catalog?.source.storeGeneration
            if storeChanged { sidebarSelection = AxodSidebarSelection() }
            let orderedIDs = sidebarSelection.order(machineID: workbench.machineID, incoming: incomingSessions.map(\.sessionId))
            let records = incomingSessions.reduce(into: [UUID: CentralSession]()) { $0[$1.sessionId] = $1 }
            let sessions = orderedIDs.compactMap { records[$0] }
            let snapshot = Snapshot(
                machineID: workbench.machineID,
                storeGeneration: workbench.catalog?.source.storeGeneration,
                workspaces: workspaces,
                sessions: sessions,
                selectedWorkspaceID: selectedWorkspaceID,
                selectedSessionID: selectedSessionID,
                sessionDisplayNames: sessionDisplayNames
            )
            let previousSnapshot = lastSnapshot
            guard snapshot != previousSnapshot else { return }
            let sameRows = previousSnapshot.map { previous in
                previous.machineID == snapshot.machineID && previous.storeGeneration == snapshot.storeGeneration &&
                previous.workspaces.map(\.workspaceId) == workspaces.map(\.workspaceId) &&
                previous.sessions.count == sessions.count &&
                zip(previous.sessions, sessions).allSatisfy { before, after in
                    before.sessionId == after.sessionId && before.workspaceId == after.workspaceId
                }
            } ?? false
            lastSnapshot = snapshot
            refreshCompactSidebar(snapshot)
            sidebarSelection.observe(machineID: snapshot.machineID, available: Set(sessions.map(\.sessionId)),
                displayedSessionID: selectedSessionID)
            let expandedWorkspaces = storeChanged ? Set<UUID>() : Set(sidebarItems.compactMap { item in
                outline.isItemExpanded(item) ? item.workspace?.workspaceId : nil
            })

            refreshingSidebar = true
            defer { refreshingSidebar = false }
            if sameRows {
                // Do not reset the native range anchor on title/runtime observations.
                // Keep tree items alive and reload changed cells, not the whole outline.
                let currentWorkspaces = workspaces.reduce(into: [UUID: CentralWorkspace]()) { $0[$1.workspaceId] = $1 }
                let currentSessions = sessions.reduce(into: [UUID: CentralSession]()) { $0[$1.sessionId] = $1 }
                for item in sidebarItems.flatMap({ [$0] + $0.children }) {
                    let workspace = item.workspace.flatMap { currentWorkspaces[$0.workspaceId] }
                    let session = item.session.flatMap { currentSessions[$0.sessionId] }
                    let previousName = item.session.flatMap { previousSnapshot?.sessionDisplayNames[$0.sessionId] }
                    let currentName = session.map { sessionDisplayNames[$0.sessionId] ?? $0.name }
                    guard workspace != item.workspace || session != item.session || previousName != currentName else { continue }
                    item.workspace = workspace
                    item.session = session
                    outline.reloadItem(item)
                }
            } else {
                sidebarItems = [Item(heading: "Workspaces")]
                for workspace in workspaces {
                    let item = Item(workspace: workspace)
                    item.children = sessions
                        .filter { $0.workspaceId == workspace.workspaceId }
                        .map(Item.init(session:))
                    sidebarItems.append(item)
                }
                sidebarItems.append(Item(divider: ()))
                sidebarItems.append(Item(heading: "Sessions"))
                sidebarItems.append(contentsOf: sessions.filter { $0.workspaceId == nil }.map(Item.init(session:)))
                outline.reloadData()
            }
            for item in sidebarItems {
                guard let workspaceID = item.workspace?.workspaceId else { continue }
                if expandedWorkspaces.contains(workspaceID) || workspaceID == selectedWorkspaceID ||
                    item.children.contains(where: { $0.session.map { sidebarSelection.sessionIDs.contains($0.sessionId) } ?? false }) {
                    outline.expandItem(item)
                }
            }
            let selectedRows = IndexSet(sidebarItems.flatMap { [$0] + $0.children }.compactMap { item in
                let selected = item.session.map { sidebarSelection.sessionIDs.contains($0.sessionId) } ??
                    (selectedSessionID == nil && item.workspace?.workspaceId == selectedWorkspaceID && selectedWorkspaceID != nil)
                let row = outline.row(forItem: item)
                return selected && row >= 0 ? row : nil
            })
            if outline.selectedRowIndexes != selectedRows {
                outline.selectRowIndexes(selectedRows, byExtendingSelection: false)
            }
        }

        private func refreshCompactSidebar(_ snapshot: Snapshot) {
            let items = snapshot.workspaces.flatMap { workspace -> [AxodCompactSidebarView.Item] in
                let selected = workspace.workspaceId == snapshot.selectedWorkspaceID
                let workspaceItem = AxodCompactSidebarView.Item(
                    destination: .workspace(workspace.workspaceId), name: workspace.name, selected: selected
                )
                guard selected else { return [workspaceItem] }
                return [workspaceItem] + snapshot.sessions
                    .filter { $0.workspaceId == workspace.workspaceId }
                    .map { AxodCompactSidebarView.Item(destination: .session($0.sessionId),
                                                       name: snapshot.sessionDisplayNames[$0.sessionId] ?? $0.name,
                                                       selected: $0.sessionId == snapshot.selectedSessionID) }
            }
            let standalone = snapshot.sessions.filter { $0.workspaceId == nil }
                .map { AxodCompactSidebarView.Item(destination: .session($0.sessionId),
                                                   name: snapshot.sessionDisplayNames[$0.sessionId] ?? $0.name,
                                                   selected: $0.sessionId == snapshot.selectedSessionID) }
            compactSidebar.update(items: standalone + items)
        }

        private func setSidebarCollapsed(_ collapsed: Bool) {
            guard displayedCollapsed != collapsed else { return }
            displayedCollapsed = collapsed
            expandedSidebar.isHidden = collapsed
            compactSidebar.isHidden = !collapsed
            compactSidebarWidth?.isActive = false
            sidebarMinimumWidth?.constant = collapsed ? AxodCompactSidebarView.width : CGFloat(WorkspaceWindowState.minimumSidebarWidth)
            compactSidebarWidth?.isActive = collapsed
            // Initial mounting has no viewport yet; let the first real resize position it.
            guard splitView.bounds.width > 0 else { return }
            splitView.setPosition(collapsed ? AxodCompactSidebarView.width : sidebarWidth, ofDividerAt: 0)
            splitView.adjustSubviews()
        }

        func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            guard splitView === self.splitView, dividerIndex == 0 else { return proposedPosition }
            guard !sidebarCollapsed.wrappedValue else { return AxodCompactSidebarView.width }
            let available = splitView.bounds.width - splitView.dividerThickness - 200
            let minimum = CGFloat(WorkspaceWindowState.minimumSidebarWidth)
            let maximum = min(CGFloat(WorkspaceWindowState.maximumSidebarWidth), max(minimum, available))
            return min(max(minimum, proposedPosition), maximum)
        }

        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
            guard splitView === self.splitView, splitView.arrangedSubviews.count == 2 else {
                splitView.adjustSubviews()
                return
            }
            let bounds = splitView.bounds
            let divider = splitView.dividerThickness
            let width: CGFloat
            if sidebarCollapsed.wrappedValue {
                width = AxodCompactSidebarView.width
            } else {
                width = min(sidebarWidth, max(0, bounds.width - divider - 200))
            }
            let sidebarFrame = NSRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
            let contentFrame = NSRect(x: sidebarFrame.maxX + divider, y: bounds.minY,
                                      width: max(0, bounds.width - width - divider), height: bounds.height)
            sidebarContainer.frame = sidebarFrame
            content.frame = contentFrame
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard splitView.bounds.width >= 400, splitView.arrangedSubviews.count == 2 else { return }
            if !positionedSidebar {
                positionedSidebar = true
                splitView.setPosition(sidebarCollapsed.wrappedValue ? AxodCompactSidebarView.width : sidebarWidth, ofDividerAt: 0)
                return
            }
            guard !sidebarCollapsed.wrappedValue else { return }
            let width = sidebarContainer.frame.width
            guard width.isFinite,
                  width >= CGFloat(WorkspaceWindowState.minimumSidebarWidth),
                  abs(width - sidebarWidth) > 0.5 else { return }
            sidebarWidth = min(width, CGFloat(WorkspaceWindowState.maximumSidebarWidth))
            scheduleSidebarStateSave()
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let item = item as? Item else { return sidebarItems.count }
            return item.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let item = item as? Item else { return sidebarItems[index] }
            return item.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let item = item as? Item else { return false }
            return item.workspace != nil && !item.children.isEmpty
        }

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            false // Headings are custom rows; AppKit must not add section chrome.
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let item = item as? Item else { return false }
            return item.workspace != nil || item.session != nil
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let item = item as? Item else { return 28 }
            return item.isDivider ? 24 : item.heading != nil ? 32 : 28
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let row = WorkspaceSidebarRowView()
            if let session = (item as? Item)?.session {
                row.setAccessibilityIdentifier("session-row.\(session.sessionId.uuidString.lowercased())")
            } else if let workspace = (item as? Item)?.workspace {
                row.setAccessibilityIdentifier("workspace-row.\(workspace.workspaceId.uuidString.lowercased())")
            }
            return row
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item value: Any) -> NSView? {
            guard let item = value as? Item else { return nil }
            if item.isDivider {
                let container = NSView()
                let line = NSBox()
                line.boxType = .separator
                line.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(line)
                NSLayoutConstraint.activate([
                    line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
                    line.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
                    line.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                ])
                return container
            }
            if let heading = item.heading {
                let row = WorkspaceSidebarHeading(title: heading)
                row.textField?.font = .systemFont(ofSize: 13, weight: .bold)
                row.textField?.textColor = .labelColor
                row.textField?.setAccessibilityIdentifier("Axo.Sidebar.Heading.\(heading.lowercased())")
                return row
            }
            let actions = NSMenu()
            actions.autoenablesItems = false
            if let workspace = item.workspace {
                let row = WorkspaceSidebarRow(
                    name: workspace.name,
                    workspace: true,
                    running: false,
                    actions: actions,
                    rename: renameBehavior(for: item)
                )
                let rename = NSMenuItem(title: "Rename…", action: #selector(WorkspaceSidebarRow.renameFromMenu(_:)), keyEquivalent: "")
                rename.target = row
                actions.addItem(rename)
                row.textField?.font = .systemFont(ofSize: 13)
                row.textField?.setAccessibilityIdentifier("workspace.\(workspace.workspaceId.uuidString.lowercased())")
                return row
            }
            if let session = item.session {
                let running: Bool
                if case .running? = workbench.sessionView(session.sessionId)?.panes.first(where: { $0.desired.role == .pi })?.terminal?.process { running = true }
                else { running = false }
                let row = WorkspaceSidebarRow(
                    name: sessionDisplayNames[session.sessionId] ?? session.name,
                    workspace: false,
                    running: running,
                    actions: actions,
                    rename: renameBehavior(for: item)
                )
                let rename = NSMenuItem(title: "Rename…", action: #selector(WorkspaceSidebarRow.renameFromMenu(_:)), keyEquivalent: "")
                rename.target = row
                actions.addItem(rename)
                // This glyph identifies a session; it does not claim agent busy state.
                row.imageView?.image = NSImage(systemSymbolName: "hammer", accessibilityDescription: "Session")
                row.imageView?.contentTintColor = .secondaryLabelColor
                row.imageView?.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                row.textField?.setAccessibilityIdentifier("session.\(session.sessionId.uuidString.lowercased())")
                return row
            }
            return nil
        }

        private func renameBehavior(for item: Item) -> WorkspaceSidebarRow.Rename {
            var capture: CentralRenameCapture?
            return WorkspaceSidebarRow.Rename(begin: { [weak self] in
                guard let self else { return false }
                do {
                    if let workspace = item.workspace {
                        capture = try self.workbench.prepareWorkspaceRename(workspace.workspaceId)
                    } else if let session = item.session {
                        capture = try self.workbench.prepareSessionRename(session.sessionId)
                    } else { return false }
                    return capture != nil
                } catch { return false }
            }, finish: { [weak self] name in
                guard let self, let renameCapture = capture else { return }
                self.workbench.finishRename(renameCapture, name: name)
                capture = nil
            })
        }

        func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
            let sessionRows = IndexSet(proposedSelectionIndexes.filter { (outline.item(atRow: $0) as? Item)?.session != nil })
            if !sessionRows.isEmpty { return sessionRows }
            let workspaceRows = proposedSelectionIndexes.filter { (outline.item(atRow: $0) as? Item)?.workspace != nil }
            return workspaceRows.first.map { IndexSet(integer: $0) } ?? []
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !refreshingSidebar else { return }
            let items = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? Item }
            let sessionIDs = Set(items.compactMap { $0.session?.sessionId })
            sidebarSelection.select(sessionIDs)
            if !sessionIDs.isEmpty {
                // Adding a range does not replace the active detail or move terminal focus.
                if let active = workbench.selectedSessionID, sessionIDs.contains(active) { return }
                let clicked = (outline.item(atRow: outline.clickedRow) as? Item)?.session?.sessionId
                if let destination = clicked.flatMap({ sessionIDs.contains($0) ? $0 : nil }) ?? items.first?.session?.sessionId {
                    workbench.selectSession(destination)
                }
            } else if let workspace = items.first?.workspace {
                workbench.selectWorkspace(workspace.workspaceId)
            }
        }


        @objc private func collapseSidebar(_ sender: Any?) {
            sidebarCollapsed.wrappedValue = true
        }

        private func sidebarButton(symbol: String, label: String, action: Selector) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
            button.isBordered = false
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            return button
        }

        private func scheduleSidebarStateSave() {
            sidebarStateSaveWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.sidebarStateSaveWork = nil
                self.preferences.set(Double(self.sidebarWidth), forKey: Self.sidebarWidthKey)
            }
            sidebarStateSaveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        private static func validatedSidebarWidth(storedValue: NSNumber?) -> CGFloat {
            let candidate = storedValue?.doubleValue ?? WorkspaceWindowState.defaultSidebarWidth
            guard candidate.isFinite, candidate >= WorkspaceWindowState.minimumSidebarWidth else {
                return CGFloat(WorkspaceWindowState.defaultSidebarWidth)
            }
            return CGFloat(min(candidate, WorkspaceWindowState.maximumSidebarWidth))
        }
    }
}
