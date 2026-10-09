#if DEBUG
import AppKit
import AxoCore
import GhosttyKit

/// Isolated, non-Accessibility native smoke test. It launches synthetic shells, never Pi,
/// and uses a fresh registry rather than opening or relaunching the user's live app.
enum WorkspaceSelfTest {
    static func run(runtime: GhosttyRuntime, repository: String, installMenu: (WorkspaceController) -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axo-workspaces-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var launches: [PaneID: Int] = [:]
        let syntheticLaunch: (PaneRecord, WorkSession) -> TerminalLaunch = { pane, session in
            launches[pane.id, default: 0] += 1
            return TerminalLaunch(directory: pane.directory ?? session.directory,
                command: "/bin/sh -c 'printf AXO_SYNTHETIC_WORKSPACE; i=0; while sleep 1; do i=$((i+1)); printf \"\\033]0;Axo synthetic %s\\007\" \"$i\"; done'")
        }
        let controller = try WorkspaceController(runtime: runtime, repository: repository, storageRoot: root, launchOverride: syntheticLaunch)
        var namingPrompts = 0
        controller.nameProvider = { _, initial in namingPrompts += 1; return initial }
        installMenu(controller)
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1100, height: 750),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = controller.view
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        guard controller.hasLiveProcesses, let original = controller.registry.sessions.first,
              let firstPane = original.focusedPane, launches[firstPane] == 1 else { throw Failure.automaticRestart }
        try controller.activateSession(original.id)
        guard launches[firstPane] == 1 else { throw Failure.recreatedSurface }
        guard let firstTerminal = controller.terminal(for: firstPane), let surface = firstTerminal.surface else { throw Failure.missingSurface }
        let project = root.appendingPathComponent("Another project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        firstTerminal.workingDirectory = project.path
        try shortcut("t", keyCode: 17, window: window)
        guard controller.registry.sessions.count == 2, namingPrompts == 0,
              controller.registry.sessions[1].name == "Untitled",
              controller.registry.sessions[1].directory == project.path,
              controller.registry.sessions[1].piSessionFile.hasPrefix(root.path + "/Workspaces/") else { throw Failure.sessionCreation }
        window.contentView?.layoutSubtreeIfNeeded()
        let expandedWidth = controller.view.arrangedSubviews[0].frame.width
        let originalContentWidth = controller.view.arrangedSubviews[1].frame.width
        print("AXO_SIDEBAR_GEOMETRY: expanded \(expandedWidth), content \(originalContentWidth)")
        guard (180...240).contains(expandedWidth) else { throw Failure.sidebar }
        controller.toggleSidebar(nil); window.contentView?.layoutSubtreeIfNeeded(); pumpEvents()
        print("AXO_SIDEBAR_GEOMETRY: collapsed content \(controller.view.arrangedSubviews[1].frame.width)")
        guard controller.sidebarCollapsed, controller.terminal(for: firstPane) === firstTerminal,
              controller.view.arrangedSubviews[1].frame.width > originalContentWidth + 150 else { throw Failure.sidebar }
        controller.toggleSidebar(nil); window.contentView?.layoutSubtreeIfNeeded()
        print("AXO_SIDEBAR_GEOMETRY: restored \(controller.view.arrangedSubviews[0].frame.width)")
        guard !controller.sidebarCollapsed, abs(controller.view.arrangedSubviews[0].frame.width - expandedWidth) < 2 else { throw Failure.sidebar }
        try controller.activateSession(original.id)
        guard controller.terminal(for: firstPane) === firstTerminal, firstTerminal.surface == surface else { throw Failure.recreatedSurface }
        try shortcut("d", keyCode: 2, window: window)
        try shortcut("e", keyCode: 14, shift: true, window: window)
        guard let splitSession = controller.registry.sessions.first(where: { $0.id == original.id }),
              splitSession.panes.count == 3, splitSession.panes.map(\.kind) == [.pi, .shell, .shell],
              splitSession.layout?.panes.count == 3 else { throw Failure.splitCreation }
        let shellPane = try XCTPane(controller.registry.sessions.first(where: { $0.id == original.id })?.focusedPane)
        controller.terminal(for: shellPane)?.workingDirectory = project.path
        var projectRequests = 0
        controller.workspaceRequestProvider = { initialDirectory in
            guard initialDirectory == project.path else { return nil }
            projectRequests += 1
            return .init(directory: project.path, name: project.lastPathComponent)
        }
        try shortcut("n", keyCode: 45, window: window)
        guard controller.registry.workspaces.count == 2, controller.registry.sessions.count == 3,
              namingPrompts == 0, projectRequests == 1, controller.registry.sessions[2].directory == project.path,
              controller.registry.workspaces[1].directory == project.path,
              controller.registry.workspaces[1].name == project.lastPathComponent,
              controller.terminal(for: firstPane) === firstTerminal else { throw Failure.workspaceCreation }
        // A hidden Pi pane's title event reads its own bounded metadata, not the selected session's file.
        let metadata = "{\"type\":\"session\",\"id\":\"synthetic-conversation\"}\n{\"type\":\"session_info\",\"name\":\"Generated session title\"}\n"
        try Data(metadata.utf8).write(to: URL(fileURLWithPath: original.piSessionFile))
        controller.nameProvider = { title, _ in title == "Rename workspace" ? "Renamed playground" : "Manually named" }
        controller.renameWorkspace(nil); controller.renameSession(nil)
        guard controller.registry.workspaces[1].name == "Renamed playground",
              controller.registry.sessions[2].name == "Manually named",
              controller.registry.sessions[2].effectiveNameSource == .manual else { throw Failure.rename }
        try controller.activateSession(original.id)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        let text = try screenText(surface)
        guard text.contains("AXO_SYNTHETIC_WORKSPACE") else { throw Failure.missingOutput }
        guard controller.registry.sessions.first(where: { $0.id == original.id })?.name == "Generated session title",
              controller.registry.sessions[2].name == "Manually named" else { throw Failure.rename }
        window.contentView?.layoutSubtreeIfNeeded()
        guard let navigation = findOutline(in: controller.view), let standalone = findRow("Generated session title", in: navigation),
              let child = findRow("Manually named", in: navigation),
              let standaloneText = standalone.textField, let childText = child.textField,
              standalone.imageView != nil, imageCount(in: standalone) == 1 else { throw Failure.sidebar }
        let rootLeft = standaloneText.convert(standaloneText.bounds, to: navigation).minX
        let childLeft = childText.convert(childText.bounds, to: navigation).minX
        print("AXO_SIDEBAR_ROW_GEOMETRY: standalone text \(rootLeft), project child text \(childLeft)")
        guard childLeft >= rootLeft + navigation.indentationPerLevel * 1.5 else { throw Failure.sidebar }
        guard let lastPane = splitSession.panes.last?.id, let lastSurface = controller.terminal(for: lastPane)?.surface else { throw Failure.missingSurface }
        // Exercise the real C action callback rather than duplicating navigation in the test.
        bind("goto_split:up", to: lastSurface)
        pumpEvents()
        let upperRight = splitSession.panes[1].id
        guard controller.registry.sessions.first(where: { $0.id == original.id })?.focusedPane == upperRight else { throw Failure.spatialFocus }
        let beforeResize = controller.registry.sessions.first(where: { $0.id == original.id })?.layout
        bind("resize_split:down,40", to: lastSurface)
        pumpEvents()
        guard controller.registry.sessions.first(where: { $0.id == original.id })?.layout != beforeResize,
              controller.terminal(for: firstPane) === firstTerminal else { throw Failure.resize }
        controller.closePane(nil)
        pumpEvents()
        guard let sheet = window.attachedSheet else { throw Failure.closeConfirmation }
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        pumpEvents()
        guard controller.registry.sessions.first(where: { $0.id == original.id })?.panes.count == 3,
              controller.terminal(for: upperRight) != nil else { throw Failure.cancelledClose }
        let countsBeforeRestore = launches
        let restored = try WorkspaceController(runtime: runtime, repository: repository, storageRoot: root, launchOverride: syntheticLaunch)
        guard restored.registry.workspaces.count == 2, restored.registry.sessions.count == 3,
              restored.hasLiveProcesses, original.panes.allSatisfy({ restored.terminal(for: $0.id) != nil }),
              splitSession.panes.allSatisfy({ restored.terminal(for: $0.id)?.workingDirectory == ($0.directory ?? original.directory) }),
              splitSession.panes.allSatisfy({ launches[$0.id] == (countsBeforeRestore[$0.id] ?? 0) + 1 }),
              restored.registry.sessions.filter({ $0.id != original.id }).flatMap(\.panes).allSatisfy({ restored.terminal(for: $0.id) == nil }) else { throw Failure.automaticRestart }
        let restoredCounts = launches
        try restored.activateSession(original.id)
        guard launches == restoredCounts else { throw Failure.recreatedSurface }
        let next = restored.registry.sessions[1]
        try restored.activateSession(next.id)
        guard next.panes.allSatisfy({ restored.terminal(for: $0.id) != nil }) else { throw Failure.automaticRestart }
        restored.workspaceRequestProvider = { _ in nil }
        let stateBeforeCancel = restored.registry
        restored.newWorkspace(nil)
        guard restored.registry == stateBeforeCancel else { throw Failure.workspaceCreation }
        let failureRoot = root.appendingPathComponent("failure-test")
        let missing = failureRoot.appendingPathComponent("missing-project")
        let failureStore = try WorkspaceStore(url: failureRoot.appendingPathComponent("workspaces.json"),
                                               scratchRoot: failureRoot.appendingPathComponent("Workspaces"))
        let failedProject = try failureStore.createWorkspace(name: "Missing directory", initialDirectory: missing.path)
        let failedPi = try XCTPane(failureStore.registry.sessions[0].focusedPane)
        let survivingShell = try failureStore.addShell(sessionID: failedProject.sessionID, beside: failedPi, axis: .horizontal)
        try failureStore.updateSession(failedProject.sessionID) { value in
            guard let index = value.panes.firstIndex(where: { $0.id == survivingShell }) else { throw Failure.missingSurface }
            value.panes[index].directory = project.path
        }
        let failed = try WorkspaceController(runtime: runtime, repository: repository, storageRoot: failureRoot, launchOverride: syntheticLaunch)
        window.contentView = failed.view; window.contentView?.layoutSubtreeIfNeeded(); pumpEvents()
        guard failed.terminal(for: failedPi) == nil, failed.terminal(for: survivingShell) != nil,
              !FileManager.default.fileExists(atPath: missing.path), let retry = findButton("Retry", in: failed.view) else { throw Failure.launchRecovery }
        let failureCounts = launches
        try failed.activateSession(failedProject.sessionID)
        guard launches == failureCounts else { throw Failure.launchRecovery }
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        retry.performClick(nil)
        guard failed.terminal(for: failedPi)?.workingDirectory == missing.path,
              launches[failedPi] == 1, launches[survivingShell] == failureCounts[survivingShell] else { throw Failure.launchRecovery }
        failed.renameSession(nil)
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { throw Failure.inlineRename }
        editor.string = "Inline renamed"
        window.makeFirstResponder(nil); pumpEvents()
        guard failed.registry.sessions[0].name == "Inline renamed", failed.registry.sessions[0].effectiveNameSource == .manual else { throw Failure.inlineRename }
        guard let outline = findOutline(in: failed.view), let row = findRow("Inline renamed", in: outline), let context = row.menu,
              context.items.map(\.title) == ["Rename", "Duplicate", "Remove"] else { throw Failure.contextActions }
        context.performActionForItem(at: 1); pumpEvents()
        guard failed.registry.sessions.count == 2, let duplicate = failed.registry.sessions.last,
              duplicate.name == "Inline renamed copy", duplicate.id != failedProject.sessionID,
              duplicate.piSessionFile != failed.registry.sessions[0].piSessionFile,
              duplicate.panes.allSatisfy({ failed.terminal(for: $0.id) != nil }),
              let copiedRow = findRow(duplicate.name, in: outline), let copiedMenu = copiedRow.menu else { throw Failure.contextActions }
        copiedMenu.performActionForItem(at: 2); pumpEvents()
        guard let removal = window.attachedSheet else { throw Failure.contextActions }
        window.endSheet(removal, returnCode: .alertSecondButtonReturn); pumpEvents()
        guard failed.registry.sessions.last?.isArchived != true, failed.terminal(for: duplicate.panes[0].id) != nil else { throw Failure.contextActions }
        copiedMenu.performActionForItem(at: 2); pumpEvents()
        guard let confirmedRemoval = window.attachedSheet else { throw Failure.contextActions }
        window.endSheet(confirmedRemoval, returnCode: .alertFirstButtonReturn); pumpEvents()
        guard failed.registry.sessions.last?.isArchived == true, duplicate.panes.allSatisfy({ failed.terminal(for: $0.id) == nil }),
              failed.terminal(for: survivingShell) != nil else { throw Failure.contextActions }
        let badge = WorkspaceSidebarRow(name: "Working fixture", workspace: false, running: true, activity: .working,
                                       actions: NSMenu(), finishRename: { _ in })
        guard badge.accessibilityLabel()?.contains("Agent working") == true else { throw Failure.contextActions }
        print("AXO_WORKSPACE_SELF_TEST_PASSED: lazy automatic reopening, project folder/name intent and cancellation, saved shell directories, missing-directory recovery, sidebar collapse/reopen, native inline rename, context duplicate and confirmed/cancelled removal, working badge, retained surfaces, split navigation/resize")
    }
    private static func imageCount(in view: NSView) -> Int {
        (view is NSImageView ? 1 : 0) + view.subviews.reduce(0) { $0 + imageCount(in: $1) }
    }
    private static func findOutline(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        return view.subviews.compactMap { findOutline(in: $0) }.first
    }
    private static func findRow(_ name: String, in outline: NSOutlineView) -> WorkspaceSidebarRow? {
        for index in 0..<outline.numberOfRows {
            if let row = outline.view(atColumn: 0, row: index, makeIfNecessary: true) as? WorkspaceSidebarRow,
               row.textField?.stringValue == name { return row }
        }
        return nil
    }
    private static func findButton(_ title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.compactMap { findButton(title, in: $0) }.first
    }
    private static func XCTPane(_ pane: PaneID?) throws -> PaneID {
        guard let pane else { throw Failure.missingSurface }; return pane
    }
    private static func pumpEvents() {
        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
    private static func bind(_ action: String, to surface: ghostty_surface_t) {
        action.withCString { _ = ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
    }
    private static func shortcut(_ key: String, keyCode: UInt16, shift: Bool = false, window: NSWindow) throws {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                          modifierFlags: shift ? [.command, .shift] : .command,
                                          timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                          characters: shift ? key.uppercased() : key,
                                          charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode),
              NSApp.mainMenu?.performKeyEquivalent(with: event) == true else { throw Failure.unhandledShortcut }
    }
    private static func screenText(_ surface: ghostty_surface_t) throws -> String {
        var selection = ghostty_selection_s()
        selection.top_left = ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        selection.bottom_right = ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { throw Failure.missingOutput }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let bytes = text.text else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self)
    }
    enum Failure: Error { case inlineRename, contextActions, launchRecovery, sidebar, rename, missingSurface, sessionCreation, recreatedSurface, splitCreation, workspaceCreation, missingOutput, automaticRestart, unhandledShortcut, spatialFocus, resize, closeConfirmation, cancelledClose }
}
#endif
