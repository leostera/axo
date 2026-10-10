#if DEBUG
import AppKit
import AxoCore
import AxoVoice
import GhosttyKit

/// Isolated, non-Accessibility native smoke test. It launches synthetic shells, never Pi,
/// and uses a fresh registry rather than opening or relaunching the user's live app.
@MainActor
enum WorkspaceSelfTest {
    static func run(runtime: GhosttyRuntime, repository: String, installMenu: (WorkspaceController) -> Void) throws {
        guard TerminalView.validatedWebURL("https://example.com/path") != nil,
              TerminalView.validatedWebURL("javascript:alert(1)") == nil,
              TerminalView.validatedWebURL("file:///etc/passwd") == nil,
              TerminalView.validatedWebURL("https://user:password@example.com") == nil else { throw Failure.unsafeURL }
        try testVoiceKeyGestures()
        try testVoiceOperations()
        try testNotificationPreview()
        try testWindowStatePersistence()
        try testClosingLastPane(runtime: runtime, repository: repository)
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
        guard let workspaceMenu = NSApp.mainMenu?.items.compactMap({ $0.submenu }).first(where: { $0.title == "Workspace" }),
              let splitDownItem = workspaceMenu.items.first(where: { $0.title == "Split Down" }),
              splitDownItem.keyEquivalent.isEmpty else { throw Failure.unhandledShortcut }
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1100, height: 750),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = controller.view
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try shortcut("p", keyCode: 35, shift: true, window: window)
        pumpEvents()
        guard let palette = NSApp.windows.first(where: { $0.title == "Command Palette" }), palette.isVisible else { throw Failure.palette }
        palette.orderOut(nil)
        window.makeKeyAndOrderFront(nil)
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
        let secondSessionID = controller.registry.sessions[1].id
        try shortcut("{", keyCode: 33, shift: true, window: window)
        guard controller.registry.selectedSession == original.id else { throw Failure.sessionNavigation }
        try shortcut("}", keyCode: 30, shift: true, window: window)
        guard controller.registry.selectedSession == secondSessionID else { throw Failure.sessionNavigation }
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
        guard controller.splitView(controller.view, constrainSplitPosition: 500, ofSubviewAt: 0) == 300 else {
            throw Failure.sidebar
        }
        let originalWindowSize = window.contentView?.frame.size ?? .zero
        window.setContentSize(NSSize(width: originalWindowSize.width + 200, height: originalWindowSize.height))
        window.contentView?.layoutSubtreeIfNeeded(); pumpEvents()
        guard abs(controller.view.arrangedSubviews[0].frame.width - expandedWidth) < 2 else { throw Failure.sidebar }
        window.setContentSize(originalWindowSize)
        window.contentView?.layoutSubtreeIfNeeded(); pumpEvents()
        try controller.activateSession(original.id)
        guard controller.terminal(for: firstPane) === firstTerminal, firstTerminal.surface == surface else { throw Failure.recreatedSurface }
        try shortcut("d", keyCode: 2, window: window)
        controller.splitDown(nil)
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
        try shortcut("<", keyCode: 43, shift: true, window: window)
        guard controller.registry.selectedSession == original.id else { throw Failure.workspaceNavigation }
        try shortcut(">", keyCode: 47, shift: true, window: window)
        guard controller.registry.selectedSession == controller.registry.sessions[2].id else { throw Failure.workspaceNavigation }
        // A hidden Pi pane's title event reads its own bounded metadata, not the selected session's file.
        let metadata = "{\"type\":\"session\",\"id\":\"synthetic-conversation\"}\n{\"type\":\"session_info\",\"name\":\"Generated session title\"}\n"
        try Data(metadata.utf8).write(to: URL(fileURLWithPath: original.piSessionFile))
        controller.nameProvider = { title, _ in title == "Rename workspace" ? "Renamed project" : "Manually named" }
        controller.renameWorkspace(nil); controller.renameSession(nil)
        guard controller.registry.workspaces[1].name == "Renamed project",
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
        var headings = Set<String>()
        for index in 0..<navigation.numberOfRows {
            if let heading = navigation.view(atColumn: 0, row: index, makeIfNecessary: true) as? WorkspaceSidebarHeading,
               let title = heading.textField?.stringValue, let item = navigation.item(atRow: index) {
                guard !controller.outlineView(navigation, shouldSelectItem: item), navigation.parent(forItem: item) == nil,
                      imageCount(in: heading) == 0 else { throw Failure.sidebar }
                headings.insert(title)
            }
        }
        guard headings == ["Workspaces", "Sessions"], navigation.selectedRow >= 0,
              navigation.rowView(atRow: navigation.selectedRow, makeIfNecessary: true) is WorkspaceSidebarRowView else { throw Failure.sidebar }
        let rootLeft = standaloneText.convert(standaloneText.bounds, to: navigation).minX
        let childLeft = childText.convert(childText.bounds, to: navigation).minX
        print("AXO_SIDEBAR_ROW_GEOMETRY: standalone text \(rootLeft), project child text \(childLeft)")
        guard childLeft >= rootLeft + navigation.indentationPerLevel * 1.5 else { throw Failure.sidebar }
        guard let orderedPanes = splitSession.layout?.panes, orderedPanes.count == 3,
              let lastPane = orderedPanes.last, let lastSurface = controller.terminal(for: lastPane)?.surface else { throw Failure.missingSurface }
        try shortcut("]", keyCode: 30, window: window)
        guard controller.registry.sessions.first(where: { $0.id == original.id })?.focusedPane == orderedPanes[0] else { throw Failure.paneNavigation }
        try shortcut("[", keyCode: 33, window: window)
        guard controller.registry.sessions.first(where: { $0.id == original.id })?.focusedPane == lastPane else { throw Failure.paneNavigation }
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
              restored.registry.sessions.first(where: { $0.id == original.id })?.layout == controller.registry.sessions.first(where: { $0.id == original.id })?.layout,
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
        let recordingRow = WorkspaceSidebarRow(name: "Recording fixture", workspace: false, running: true,
                                               voiceRecording: true, actions: NSMenu(), finishRename: { _ in })
        guard badge.accessibilityLabel()?.contains("Agent working") == true,
              recordingRow.accessibilityLabel()?.contains("Recording voice") == true,
              recordingRow.imageView?.contentTintColor == .systemRed else { throw Failure.contextActions }
        let loading = WorkspaceSidebarRow(name: "Loading fixture", workspace: false, running: true, activity: .detached, loading: true,
                                         actions: NSMenu(), finishRename: { _ in })
        let unavailable = WorkspaceSidebarRow(name: "Unavailable fixture", workspace: false, running: true, activity: .detached,
                                             actions: NSMenu(), finishRename: { _ in })
        guard loading.imageView == nil, loading.accessibilityLabel()?.contains("Loading agent status") == true,
              findSpinner(in: loading)?.style == .spinning,
              unavailable.imageView?.contentTintColor == .tertiaryLabelColor,
              unavailable.imageView?.toolTip == "Agent status unavailable", findSpinner(in: unavailable) == nil else { throw Failure.sidebar }
        print("AXO_WORKSPACE_SELF_TEST_PASSED: configurable voice-key push-to-talk and lock/unlock gestures, automatic target-bound transcript insertion, sidebar recording indicator, native selection, safe URL policy, navigation, lifecycle, split navigation/resize")
    }
    private static func findSpinner(in view: NSView) -> NSProgressIndicator? {
        if let spinner = view as? NSProgressIndicator { return spinner }
        return view.subviews.compactMap { findSpinner(in: $0) }.first
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
    private static func testVoiceKeyGestures() throws {
        var gesture = MacVoiceKeyGesture()
        let start = Date(timeIntervalSince1970: 10)
        guard gesture.handle(keyCode: 61, isDown: true, at: start) == .consume(.beginHold),
              gesture.handle(keyCode: 61, isDown: false, at: start.addingTimeInterval(0.6)) == .consume(.endHold) else {
            throw Failure.voiceGesture
        }

        let firstTap = start.addingTimeInterval(2)
        guard gesture.handle(keyCode: 61, isDown: true, at: firstTap) == .consume(.beginHold),
              gesture.handle(keyCode: 61, isDown: false, at: firstTap.addingTimeInterval(0.05)) == .consume(),
              gesture.handle(keyCode: 61, isDown: true, at: firstTap.addingTimeInterval(0.2)) == .consume(),
              gesture.handle(keyCode: 61, isDown: false, at: firstTap.addingTimeInterval(0.25)) == .consume(.lockRecording) else {
            throw Failure.voiceGesture
        }

        let unlock = firstTap.addingTimeInterval(1)
        guard gesture.handle(keyCode: 61, isDown: true, at: unlock) == .consume(),
              gesture.handle(keyCode: 61, isDown: false, at: unlock.addingTimeInterval(0.05)) == .consume(),
              gesture.handle(keyCode: 61, isDown: true, at: unlock.addingTimeInterval(0.2)) == .consume(),
              gesture.handle(keyCode: 61, isDown: false, at: unlock.addingTimeInterval(0.25)) == .consume(.unlockRecording) else {
            throw Failure.voiceGesture
        }

        let tap = unlock.addingTimeInterval(1)
        _ = gesture.handle(keyCode: 61, isDown: true, at: tap)
        _ = gesture.handle(keyCode: 61, isDown: false, at: tap.addingTimeInterval(0.05))
        let timeout = gesture.expire(at: tap.addingTimeInterval(MacVoiceKeyBinding.gestureInterval + 0.1))
        guard timeout == .consume(.endHold) else { throw Failure.voiceGesture }

        let defaultKey = MacVoiceKeyBinding(rawValue: MacVoiceKeyBinding.defaultValue.rawValue)
        let shortcut = MacVoiceKeyBinding.capture(keyCode: 49, modifiers: [.command], name: "Space")
        guard defaultKey == .defaultValue, defaultKey?.title == "Right Option",
              defaultKey?.matches(keyCode: 61) == true, defaultKey?.matches(keyCode: 58) == false,
              MacVoiceKeyBinding.capture(keyCode: 58, modifiers: .option, name: "Option") == nil,
              shortcut?.title == "⌘Space", shortcut?.matches(keyCode: 49) == true,
              shortcut?.matchesModifiers(.command) == true,
              MacVoiceKeyBinding(rawValue: "key:999:0:QQ==") == nil else { throw Failure.voiceGesture }
    }

    @MainActor private static func testVoiceOperations() throws {
        let recorder = SelfTestVoiceRecorder()
        let voice = MacVoiceCoordinator(recorder: recorder, makeTranscriber: { SelfTestTranscriber(delay: .milliseconds(900)) })
        var insertions: [(MacVoiceTarget, String)] = []
        voice.onTranscriptReady = { target, text in
            insertions.append((target, text))
            return true
        }
        let first = MacVoiceTarget(sessionID: AxoSessionID(), paneID: PaneID(), runtimeGeneration: UUID(), workspaceName: "Project A", sessionName: "Session A")
        let second = MacVoiceTarget(sessionID: AxoSessionID(), paneID: PaneID(), runtimeGeneration: UUID(), workspaceName: "Project B", sessionName: "Session B")
        voice.startCapture(for: first)
        try waitUntil { voice.isRecording }
        voice.stopCapture()
        guard voice.transcriptions.count == 1, voice.transcriptions[0].target == first else { throw Failure.voiceTarget }
        voice.startCapture(for: second)
        try waitUntil { voice.isRecording }
        guard voice.transcriptions.count == 1, voice.recordingTarget == second else { throw Failure.voiceConcurrency }
        voice.stopCapture()
        try waitUntil { voice.transcripts.count == 2 }
        guard insertions.contains(where: { $0.0 == first && $0.1 == "transcript one" }),
              insertions.contains(where: { $0.0 == second && $0.1 == "transcript two" }),
              voice.transcripts.allSatisfy({ $0.insertion == .inserted }) else { throw Failure.voiceTarget }
        voice.shutdown()
    }

    private static func testNotificationPreview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axo-notification-preview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let conversation = UUID().uuidString
        let entries: [[String: Any]] = [
            ["type": "session", "id": conversation],
            ["type": "message", "message": ["role": "assistant", "stopReason": "toolUse",
                "content": [["type": "text", "text": "Intermediate tool setup"]]]],
            ["type": "message", "message": ["role": "assistant", "stopReason": "stop",
                "content": [["type": "thinking", "text": "Private reasoning"],
                            ["type": "text", "text": String(repeating: "R", count: 200)]]]],
        ]
        let data = try entries.map { try JSONSerialization.data(withJSONObject: $0) }
            .map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
        let path = root.appendingPathComponent("session.jsonl")
        try Data(data.utf8).write(to: path)
        guard let preview = MacNotificationPreview.read(from: path.path, conversationID: conversation),
              preview == String(repeating: "R", count: 180),
              MacNotificationPreview.read(from: path.path, conversationID: UUID().uuidString) == nil else {
            throw Failure.notificationPreview
        }
        let privateCopy = MacNotificationCopy.make(sessionName: "Research", reason: .result,
                                                   preview: preview, includePreview: false)
        let previewCopy = MacNotificationCopy.make(sessionName: "Research", reason: .result,
                                                   preview: preview, includePreview: true)
        guard privateCopy.title == "Research", privateCopy.body != preview,
              previewCopy.title == "Research", previewCopy.body == preview,
              MacNotificationCopy.make(sessionName: "Research", reason: .question,
                                       preview: preview, includePreview: true).body != preview else {
            throw Failure.notificationPreview
        }
    }

    private static func testWindowStatePersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axo-window-state-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("window-layout.json")
        let state = WorkspaceWindowState(sidebarWidth: 287.5, sidebarCollapsed: true)
        guard WorkspaceWindowState(sidebarWidth: 500).sidebarWidth == WorkspaceWindowState.maximumSidebarWidth else {
            throw Failure.windowLayout
        }
        try state.save(to: url)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        guard WorkspaceWindowState.load(from: url) == state, permissions == 0o600 else { throw Failure.windowLayout }
        try Data("invalid state".utf8).write(to: url)
        guard WorkspaceWindowState.load(from: url) == WorkspaceWindowState() else { throw Failure.windowLayout }
    }

    private static func testClosingLastPane(runtime: GhosttyRuntime, repository: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axo-close-last-pane-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = root.appendingPathComponent("Workspaces")
        let store = try WorkspaceStore(url: root.appendingPathComponent("workspaces.json"), scratchRoot: scratch)
        let workspace = try store.createWorkspace(name: "Close test")
        let closing = try store.createSession(workspaceID: workspace.workspaceID, name: "Last pane")
        let controller = try WorkspaceController(runtime: runtime, repository: repository, storageRoot: root) { pane, session in
            TerminalLaunch(directory: pane.directory ?? session.directory, command: "/bin/sh -c 'sleep 30'")
        }
        defer { controller.shutdownVoice() }
        guard let paneID = controller.registry.sessions.first(where: { $0.id == closing.sessionID })?.focusedPane,
              let survivorPane = controller.registry.sessions.first(where: { $0.id == workspace.sessionID })?.focusedPane,
              let terminal = controller.terminal(for: paneID) else { throw Failure.lastPaneClose }
        terminal.childExited = true
        controller.closePane(nil)
        guard controller.registry.sessions.first(where: { $0.id == closing.sessionID })?.isArchived == true,
              controller.registry.selectedSession == workspace.sessionID,
              controller.terminal(for: paneID) == nil,
              controller.terminal(for: survivorPane) == nil else { throw Failure.lastPaneClose }
    }

    private static func waitUntil(_ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline && !predicate() {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard predicate() else { throw Failure.voiceTimeout }
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
    enum Failure: Error { case inlineRename, contextActions, launchRecovery, sidebar, rename, missingSurface, sessionCreation, sessionNavigation, workspaceNavigation, paneNavigation, unsafeURL, palette, voiceGesture, voiceTarget, voiceConcurrency, voiceTimeout, recreatedSurface, splitCreation, workspaceCreation, missingOutput, automaticRestart, unhandledShortcut, spatialFocus, resize, closeConfirmation, cancelledClose, lastPaneClose, windowLayout, notificationPreview }
}

#if DEBUG
@MainActor
private final class SelfTestVoiceRecorder: VoiceRecording {
    var onFinished: (() -> Void)?
    var onInterrupted: (() -> Void)?
    private var nextRecording = 0
    private var audioURL: URL?

    func requestPermission() async -> Bool { true }
    func start() throws {
        nextRecording += 1
        let text = nextRecording == 1 ? "transcript one" : "transcript two"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("axo-voice-self-test-\(UUID()).txt")
        try Data(text.utf8).write(to: url)
        audioURL = url
    }
    func stop() throws -> URL {
        guard let audioURL else { throw VoicePromptError.recorderUnavailable }
        self.audioURL = nil
        return audioURL
    }
    func cancel() {
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        audioURL = nil
    }
}

private actor SelfTestTranscriber: LocalSpeechTranscribing {
    let delay: Duration
    init(delay: Duration) { self.delay = delay }
    func prepare(progress: @escaping @Sendable (VoiceModelProgress) -> Void) async throws {
        progress(.init(fraction: 1, detail: "Synthetic speech model ready"))
    }
    func transcribe(_ audioURL: URL) async throws -> String {
        try await Task.sleep(for: delay)
        return try String(contentsOf: audioURL, encoding: .utf8)
    }
    func unload() async {}
}
#endif
#endif
