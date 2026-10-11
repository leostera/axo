import AppKit
import AxoProtocol
import SwiftUI

struct AxodNativeWorkbenchSplitView: NSViewRepresentable {
    let workbench: AxodWorkbenchCoordinator
    let workspaces: [WorkWorkspaceRecord]
    let sessions: [WorkSessionRecord]
    let selectedWorkspaceID: UUID?
    let selectedSessionID: UUID?
    @Binding var sidebarCollapsed: Bool
    let detail: AnyView
    let openSettings: () -> Void
    let createWork: () -> Void

    func makeCoordinator() -> SidebarController {
        SidebarController(
            workbench: workbench,
            sidebarCollapsed: $sidebarCollapsed,
            openSettings: openSettings,
            createWork: createWork
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
            selectedWorkspaceID: selectedWorkspaceID,
            selectedSessionID: selectedSessionID,
            sidebarCollapsed: $sidebarCollapsed,
            detail: detail,
            openSettings: openSettings,
            createWork: createWork
        )
    }

    @MainActor
    final class SidebarController: NSObject, NSSplitViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
        private final class Item: NSObject {
            let workspace: WorkWorkspaceRecord?
            let session: WorkSessionRecord?
            let heading: String?
            var children: [Item] = []

            init(heading: String) {
                self.workspace = nil
                self.session = nil
                self.heading = heading
            }

            init(workspace: WorkWorkspaceRecord) {
                self.workspace = workspace
                self.session = nil
                self.heading = nil
            }

            init(session: WorkSessionRecord) {
                self.workspace = nil
                self.session = session
                self.heading = nil
            }
        }

        private struct Snapshot: Equatable {
            let workspaces: [WorkWorkspaceRecord]
            let sessions: [WorkSessionRecord]
            let selectedWorkspaceID: UUID?
            let selectedSessionID: UUID?
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
            onExpand: { [weak self] in self?.sidebarCollapsed.wrappedValue = false },
            onCreate: { [weak self] in self?.createWork() }
        )
        private let content = NSView()
        private let outline = WorkspaceOutlineView()
        private let detailHost: NSHostingView<AnyView>
        private let preferences = UserDefaults.standard
        private var sidebarMinimumWidth: NSLayoutConstraint?
        private var compactSidebarWidth: NSLayoutConstraint?
        private var displayedCollapsed: Bool?
        private var sidebarWidth: CGFloat
        private var positionedSidebar = false
        private var sidebarItems: [Item] = []
        private var lastSnapshot: Snapshot?
        private var refreshingSidebar = false
        private var workbench: AxodWorkbenchCoordinator
        private var sidebarCollapsed: Binding<Bool>
        private var openSettings: () -> Void
        private var createWork: () -> Void
        private var sidebarStateSaveWork: DispatchWorkItem?

        init(
            workbench: AxodWorkbenchCoordinator,
            sidebarCollapsed: Binding<Bool>,
            openSettings: @escaping () -> Void,
            createWork: @escaping () -> Void
        ) {
            self.workbench = workbench
            self.sidebarCollapsed = sidebarCollapsed
            self.openSettings = openSettings
            self.createWork = createWork
            self.sidebarWidth = Self.validatedSidebarWidth(
                storedValue: UserDefaults.standard.object(forKey: Self.sidebarWidthKey) as? NSNumber
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

        func update(
            workbench: AxodWorkbenchCoordinator,
            workspaces: [WorkWorkspaceRecord],
            sessions: [WorkSessionRecord],
            selectedWorkspaceID: UUID?,
            selectedSessionID: UUID?,
            sidebarCollapsed: Binding<Bool>,
            detail: AnyView,
            openSettings: @escaping () -> Void,
            createWork: @escaping () -> Void
        ) {
            self.workbench = workbench
            self.sidebarCollapsed = sidebarCollapsed
            self.openSettings = openSettings
            self.createWork = createWork
            detailHost.rootView = detail
            refreshSidebar(
                workspaces: workspaces,
                sessions: sessions,
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
            outline.indentationPerLevel = 12
            outline.backgroundColor = .clear
            outline.dataSource = self
            outline.delegate = self
            outline.itemMenu = { [weak self] item in
                guard let self else { return NSMenu() }
                let row = self.outline.row(forItem: item)
                return (self.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? WorkspaceSidebarRow)?.menu ?? NSMenu()
            }
            outline.setAccessibilityLabel("Workspaces and sessions")
            scroll.documentView = outline

            let heading = NSTextField(labelWithString: "Axo")
            heading.font = .systemFont(ofSize: 13, weight: .semibold)
            heading.textColor = .secondaryLabelColor
            let create = sidebarButton(symbol: "plus", label: "Create workspace or session", action: #selector(createWorkspaceOrSession(_:)))
            let collapse = sidebarButton(symbol: "sidebar.left", label: "Collapse sidebar", action: #selector(collapseSidebar(_:)))
            let settings = NSButton(title: "Settings", target: self, action: #selector(showSettings(_:)))
            settings.isBordered = false
            settings.font = .systemFont(ofSize: 12)
            settings.contentTintColor = .secondaryLabelColor
            let headerLine = NSBox()
            let footerLine = NSBox()
            headerLine.boxType = .separator
            footerLine.boxType = .separator

            for child in [scroll, heading, create, collapse, settings, headerLine, footerLine] {
                child.translatesAutoresizingMaskIntoConstraints = false
                expandedSidebar.addSubview(child)
            }
            NSLayoutConstraint.activate([
                heading.leadingAnchor.constraint(equalTo: expandedSidebar.leadingAnchor, constant: 16),
                heading.topAnchor.constraint(equalTo: expandedSidebar.topAnchor, constant: 14),
                create.trailingAnchor.constraint(equalTo: expandedSidebar.trailingAnchor, constant: -10),
                create.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
                headerLine.leadingAnchor.constraint(equalTo: expandedSidebar.leadingAnchor, constant: 12),
                headerLine.trailingAnchor.constraint(equalTo: expandedSidebar.trailingAnchor, constant: -12),
                headerLine.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
                scroll.topAnchor.constraint(equalTo: headerLine.bottomAnchor, constant: 8),
                scroll.leadingAnchor.constraint(equalTo: expandedSidebar.leadingAnchor, constant: 6),
                scroll.trailingAnchor.constraint(equalTo: expandedSidebar.trailingAnchor, constant: -6),
                scroll.bottomAnchor.constraint(equalTo: footerLine.topAnchor, constant: -8),
                footerLine.leadingAnchor.constraint(equalTo: headerLine.leadingAnchor),
                footerLine.trailingAnchor.constraint(equalTo: headerLine.trailingAnchor),
                footerLine.bottomAnchor.constraint(equalTo: collapse.topAnchor, constant: -10),
                settings.leadingAnchor.constraint(equalTo: expandedSidebar.leadingAnchor, constant: 12),
                settings.centerYAnchor.constraint(equalTo: collapse.centerYAnchor),
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
            workspaces: [WorkWorkspaceRecord],
            sessions: [WorkSessionRecord],
            selectedWorkspaceID: UUID?,
            selectedSessionID: UUID?
        ) {
            // Preserve the live field editor while Pi titles/catalog observations change.
            guard !workbench.isRenamingWork else { return }
            let snapshot = Snapshot(
                workspaces: workspaces,
                sessions: sessions,
                selectedWorkspaceID: selectedWorkspaceID,
                selectedSessionID: selectedSessionID
            )
            guard snapshot != lastSnapshot else { return }
            lastSnapshot = snapshot
            refreshCompactSidebar(snapshot)

            sidebarItems = [Item(heading: "Standalone Sessions")]
            sidebarItems.append(contentsOf: sessions.filter { $0.workspaceId == nil }.map(Item.init(session:)))
            sidebarItems.append(Item(heading: "Workspaces"))
            for workspace in workspaces {
                let item = Item(workspace: workspace)
                item.children = sessions
                    .filter { $0.workspaceId == workspace.workspaceId }
                    .map(Item.init(session:))
                sidebarItems.append(item)
            }

            refreshingSidebar = true
            defer { refreshingSidebar = false }
            outline.reloadData()
            if let selectedWorkspaceID,
               let item = sidebarItems.first(where: { $0.workspace?.workspaceId == selectedWorkspaceID }) {
                outline.expandItem(item)
            }

            let selectedItem = sidebarItems
                .flatMap { [$0] + $0.children }
                .first {
                    (selectedSessionID != nil && $0.session?.sessionId == selectedSessionID) ||
                    (selectedSessionID == nil && selectedWorkspaceID != nil && $0.workspace?.workspaceId == selectedWorkspaceID)
                }
            if let selectedItem {
                let row = outline.row(forItem: selectedItem)
                if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            } else {
                outline.deselectAll(nil)
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
                    .map { AxodCompactSidebarView.Item(destination: .session($0.sessionId), name: $0.name,
                                                       selected: $0.sessionId == snapshot.selectedSessionID) }
            }
            let standalone = snapshot.sessions.filter { $0.workspaceId == nil }
                .map { AxodCompactSidebarView.Item(destination: .session($0.sessionId), name: $0.name,
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
            (item as? Item)?.heading != nil
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? Item)?.heading == nil
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            (item as? Item)?.heading == nil ? 28 : 20
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            WorkspaceSidebarRowView()
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item value: Any) -> NSView? {
            guard let item = value as? Item else { return nil }
            if let heading = item.heading { return WorkspaceSidebarHeading(title: heading) }
            let actions = NSMenu()
            actions.autoenablesItems = false
            var rename: AxodWorkRename?
            if let workspace = item.workspace {
                let row = WorkspaceSidebarRow(
                    name: workspace.name,
                    workspace: true,
                    running: false,
                    actions: actions,
                    canBeginRename: { [weak workbench = workbench] in rename = workbench?.beginWorkRename(workspace: workspace); return rename != nil },
                    finishRename: { [weak workbench = workbench] name in if let rename { workbench?.finishWorkRename(rename, name: name) } }
                )
                addRenameAction(to: row, menu: actions, enabled: workbench.canEditWork)
                return row
            }
            if let session = item.session {
                let running: Bool
                if case .running? = session.runtime?.process { running = true }
                else { running = false }
                let row = WorkspaceSidebarRow(
                    name: session.displayName,
                    workspace: false,
                    running: running,
                    actions: actions,
                    canBeginRename: { [weak workbench = workbench] in rename = workbench?.beginWorkRename(session: session); return rename != nil },
                    finishRename: { [weak workbench = workbench] name in if let rename { workbench?.finishWorkRename(rename, name: name) } }
                )
                addRenameAction(to: row, menu: actions, enabled: workbench.canEditWork && session.manualName != nil)
                return row
            }
            return nil
        }

        private func addRenameAction(to row: WorkspaceSidebarRow, menu: NSMenu, enabled: Bool) {
            let action = menu.addItem(withTitle: "Rename…", action: #selector(WorkspaceSidebarRow.renameFromMenu(_:)), keyEquivalent: "")
            action.target = row
            action.isEnabled = enabled
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !refreshingSidebar,
                  outline.selectedRow >= 0,
                  let item = outline.item(atRow: outline.selectedRow) as? Item else { return }
            if let session = item.session {
                workbench.selectSession(session.sessionId)
            } else if let workspace = item.workspace {
                workbench.selectWorkspace(workspace.workspaceId)
            }
        }

        @objc private func showSettings(_ sender: Any?) { openSettings() }
        @objc private func createWorkspaceOrSession(_ sender: Any?) { createWork() }

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
