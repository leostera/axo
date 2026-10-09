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
        let controller = try WorkspaceController(runtime: runtime, repository: repository, storageRoot: root) { _, session in
            TerminalLaunch(directory: session.directory,
                           command: "/bin/sh -c 'printf AXO_SYNTHETIC_WORKSPACE; i=0; while sleep 1; do i=$((i+1)); printf \"\\033]0;Axo synthetic %s\\007\" \"$i\"; done'")
        }
        var namingPrompts = 0
        controller.nameProvider = { _, initial in namingPrompts += 1; return initial }
        installMenu(controller)
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1100, height: 750),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = controller.view
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        guard !controller.hasLiveProcesses, let original = controller.registry.sessions.first,
              let firstPane = original.focusedPane else { throw Failure.automaticRestart }
        try controller.resumePane(firstPane, in: original.id)
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
        try controller.selectSession(original.id)
        guard controller.terminal(for: firstPane) === firstTerminal, firstTerminal.surface == surface else { throw Failure.recreatedSurface }
        try shortcut("d", keyCode: 2, window: window)
        try shortcut("e", keyCode: 14, shift: true, window: window)
        guard let splitSession = controller.registry.sessions.first(where: { $0.id == original.id }),
              splitSession.panes.count == 3, splitSession.panes.map(\.kind) == [.pi, .shell, .shell],
              splitSession.layout?.panes.count == 3 else { throw Failure.splitCreation }
        let shellPane = try XCTPane(controller.registry.sessions.first(where: { $0.id == original.id })?.focusedPane)
        controller.terminal(for: shellPane)?.workingDirectory = project.path
        try shortcut("n", keyCode: 45, window: window)
        guard controller.registry.workspaces.count == 2, controller.registry.sessions.count == 3,
              namingPrompts == 0, controller.registry.sessions[2].directory == project.path,
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
        try controller.selectSession(original.id)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        let text = try screenText(surface)
        guard text.contains("AXO_SYNTHETIC_WORKSPACE") else { throw Failure.missingOutput }
        guard controller.registry.sessions.first(where: { $0.id == original.id })?.name == "Generated session title",
              controller.registry.sessions[2].name == "Manually named" else { throw Failure.rename }
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
        let restored = try WorkspaceController(runtime: runtime, repository: repository, storageRoot: root)
        guard restored.registry.workspaces.count == 2, restored.registry.sessions.count == 3,
              !restored.hasLiveProcesses else { throw Failure.automaticRestart }
        print("AXO_WORKSPACE_SELF_TEST_PASSED: immediate creation, focused cwd, private session storage, sidebar collapse/reopen, manual renames, split axes, retained live output, spatial focus, keyboard resize, cancelled close, durable stopped restore")
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
    enum Failure: Error { case sidebar, rename, missingSurface, sessionCreation, recreatedSurface, splitCreation, workspaceCreation, missingOutput, automaticRestart, unhandledShortcut, spatialFocus, resize, closeConfirmation, cancelledClose }
}
#endif
