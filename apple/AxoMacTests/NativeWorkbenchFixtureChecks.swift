import AppKit
import AxoCore
import AxoProtocol
import GhosttyKit
import SwiftUI

/// Owned AppKit/production coordinator + views, not Finder/service/live acceptance.
@main
struct NativeWorkbenchFixtureChecks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var finished = false
        var success = false
        Task { @MainActor in
            do { try await check(); success = true }
            catch {
                if case Failure.missing(let stage) = error {
                    fputs("Owned native workbench check failed: stage=\(stage)\n", stderr)
                } else {
                    fputs("Owned native workbench check failed: class=Other\n", stderr)
                }
            }
            finished = true
        }
        let deadline = Date().addingTimeInterval(CommandLine.arguments.last == "chat" ? 75 : 40)
        while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        if !finished || !success { exit(1) }
    }

    @MainActor private static func check() async throws {
        precondition(CommandLine.arguments.count == 5)
        guard let canonical = realpath(CommandLine.arguments[1], nil) else { throw Failure.missing("owned canonical root") }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        free(canonical)
        let helper = URL(fileURLWithPath: CommandLine.arguments[2])
        let home = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        guard let mode = Mode(rawValue: CommandLine.arguments[4]) else { throw Failure.missing("known fixture mode") }
        let began = Date()
        let crashSuite = "Axo.NativeWorkbenchCrashFixture.\(home.deletingLastPathComponent().lastPathComponent)"
        let suite = mode == .draftCrash ? crashSuite : "Axo.NativeWorkbenchFixture.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let coordinator = AxodWorkbenchCoordinator(preferences: preferences)
        if mode == .draftCrash || mode == .draftRecover {
            defer { coordinator.disconnect(); coordinator.voice.shutdown() }
            if mode == .draftRecover {
                // This exact synthetic suite belongs to the preceding owned
                // killed child. No production preference namespace is removed.
                defer { UserDefaults(suiteName: crashSuite)?.removePersistentDomain(forName: crashSuite) }
                try await checkDraftRecovery(coordinator: coordinator, root: root, helper: helper, home: home,
                                             preferences: preferences, mode: mode)
            } else {
                try await checkDraftRecovery(coordinator: coordinator, root: root, helper: helper, home: home,
                                             preferences: preferences, mode: mode)
            }
            return
        }
        func phase(_ name: String) {
            fputs("Native fixture phase=\(name) elapsedMs=\(Int(Date().timeIntervalSince(began) * 1000)) starting=\(coordinator.isStartingPi) admission=\(coordinator.selectedSession?.pi.admission.rawValue ?? "none")\n", stderr)
        }
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1280, height: 780),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: AxodWorkbenchView(coordinator: coordinator).defaultAppStorage(preferences))
        defer {
            coordinator.disconnect()
            coordinator.voice.shutdown()
            window.close()
        }
        if mode == .pending {
            let directory = try AxodStateDirectory.openExisting(root: root)
            guard let endpoint = try directory.readEndpoint() else { throw Failure.missing("owned endpoint") }
            let key = "Axo.axod.pendingShellAdd.\(endpoint.machineId.uuidString).\(UUID().uuidString)"
            let opaque = Data([0xff, 0x00, 0x80])
            preferences.set(opaque, forKey: key)
            try await coordinator.connectOwnedFixture(root: root, helper: helper, appLaunch: true)
            precondition(coordinator.sessions.isEmpty && coordinator.runtimes.isEmpty && coordinator.workEditor == nil)
            precondition(!coordinator.isStartingPi && !coordinator.isEditingWork && coordinator.emptyStartupMessage != nil)
            precondition(preferences.data(forKey: key) == opaque)
            coordinator.disconnect()
            try await coordinator.connectOwnedFixture(root: root, helper: helper, appLaunch: true)
            precondition(coordinator.sessions.isEmpty && coordinator.runtimes.isEmpty && !coordinator.isEditingWork)
            precondition(preferences.data(forKey: key) == opaque)
            print("PASS: owned native pending opaque machine hint blocks empty-startup; reconnect leaves hint/work untouched; not live acceptance")
            return
        }
        if mode == .panes { try await checkControlBurst(root: root) }
        try await coordinator.connectOwnedFixture(root: root, helper: helper, appLaunch: mode == .automatic || mode == .storage)
        if mode == .storage {
            precondition(coordinator.sessions.isEmpty && coordinator.runtimes.isEmpty && !coordinator.isStartingPi)
            precondition(coordinator.emptyStartupMessage != nil && coordinator.chatDrafts.blocksAutomaticStartup && !coordinator.chatDrafts.canEdit)
            let opaque = try Data(contentsOf: root.appendingPathComponent("chat-drafts/drafts.bin"))
            precondition(opaque == Data("opaque-owned-draft".utf8))
            print("PASS: owned native opaque draft storage blocks automatic empty startup and editor dispatch, preserves original bytes; explicit creation remains separate")
        }
        if mode != .automatic {
            precondition(coordinator.sessions.isEmpty && coordinator.canEditWork)
            precondition(NSApp.sendAction(#selector(AxodWorkbenchCoordinator.newSession), to: coordinator, from: NSMenuItem()))
        }
        try await wait("committed selection and shell PTY") {
            coordinator.selectedSession?.shellPanes.first?.terminal != nil
        }
        phase("shell-record")
        guard let session = coordinator.selectedSession, let shell = session.shellPanes.first,
              let snapshot = shell.terminal else { throw Failure.missing("captured shell") }
        precondition(coordinator.workEditor == nil, "Creation introduced a naming/progress modal")
        precondition(session.workspaceId == nil)
        let shellLaunch = try coordinator.terminalLaunch(for: snapshot, sessionID: session.sessionId)
        let shellView = try coordinator.terminalSurfaces.view(for: shellLaunch)
        try await wait("shell hosted by actual production workbench view") { shellView.superview != nil && shellView.window === window }
        phase("shell-hosted")
        if mode != .unavailable {
            try await wait("Pi extension delaying admission") {
                FileManager.default.fileExists(atPath: home.appendingPathComponent("native-pi-starting").path)
            }
            phase("pi-marker")
            precondition(coordinator.isStartingPi && coordinator.selectedSession?.pi.admission != .ready)
            try await wait("left captured PTY during pending Pi admission") {
                coordinator.presentationSnapshot(for: session) != nil
            }
            phase("pi-observed")
            let piSnapshot = coordinator.presentationSnapshot(for: session)!
            let piLaunch = try coordinator.terminalLaunch(for: piSnapshot, sessionID: session.sessionId)
            let piView = try coordinator.terminalSurfaces.view(for: piLaunch)
            try await wait("Pi-left surface hosted before admission") { piView.superview != nil && piView.window === window }
            try await wait("Pi-left frontend attached to daemon PTY before admission") {
                coordinator.presentationSnapshot(for: session)?.attached == true
            }
            let shellFrame = shellView.convert(shellView.bounds, to: window.contentView)
            let piFrame = piView.convert(piView.bounds, to: window.contentView)
            phase("pi-hosted")
            precondition(shellFrame.width > 0 && shellFrame.height > 0 && piFrame.width > 0 && piFrame.height > 0)
            precondition(shellFrame.minX > piFrame.minX, "Default Pi-left/shell-right geometry was reversed")
            precondition(piView !== shellView && piLaunch.key != shellLaunch.key)
        }
        // View containment is not proof that its transport child is ready.
        try await wait("shell output on actual native surface") {
            visibleText(shellView).contains("axo-native-shell-prompt")
        }
        precondition(shellView.inputEnabled && !shellView.childExited)
        // One intentional synthetic command, never resent after unknown input.
        precondition(window.makeFirstResponder(shellView))
        shellView.insertText("printf native-shell-ready > \"$HOME/native-shell-ready\"", replacementRange: NSRange(location: NSNotFound, length: 0))
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        shellView.keyDown(with: enter)
        do {
            try await wait("shell effect through actual native input") {
                (try? Data(contentsOf: home.appendingPathComponent("native-shell-ready"))) == Data("native-shell-ready".utf8)
            }
        } catch {
            let text = visibleText(shellView)
            let diagnosticURL = root.appendingPathComponent("frontend-\(snapshot.runtime.runtimeGeneration.uuidString).stderr")
            let handle = try? FileHandle(forReadingFrom: diagnosticURL)
            let recorded = (try? handle?.read(upToCount: 4096)) ?? Data()
            try? handle?.close()
            let daemonHandle = try? FileHandle(forReadingFrom: root.deletingLastPathComponent().appendingPathComponent("daemon.stderr"))
            let daemonRecord = (try? daemonHandle?.read(upToCount: 4096)) ?? Data()
            try? daemonHandle?.close()
            let diagnostic = (text + String(decoding: recorded + daemonRecord, as: UTF8.self)).filter { !$0.isWhitespace }
            let classes = [
                "InvalidDiscovery", "Offline", "Protocol", "Capacity", "geometry exceeds", "handshake",
                "Rejected", "screen recovery", "Invalid argument", "Interrupted", "Input/output error",
                "Unexpected", "Timeout", "deadline", "unknown", "closed", "sequence",
                "OutputBinding", "OutputOffset", "OutputBytes", "InputWithoutPending", "InputReceipt",
                "ResizeWithoutPending", "ResizeReceipt", "ExitReceipt", "UnexpectedAttached", "EventJson",
                "WebsocketFrame", "PresentationClosed", "QueueCapacity", "InvalidFrame", "OutputFailed", "ReceiverReleased", "TransportUnavailable", "DaemonStopping",
                "FrontendInputEof", "FrontendSignal", "DaemonExited", "rejected", "InvalidRequest", "StaleHost",
                "StaleRuntime", "StaleAttachment", "NotFound", "Conflict", "AlreadyAttached", "NotRunning",
                "RecoveryRequired", "LaunchFailed", "StorageFailed", "InputBlocked", "InvalidSize", "InvalidTransition",
                "CommandJson", "UnsupportedCommandFrame", "SocketEnded", "RateLimit", "CreditLimit", "WriteUnknown", "OtherIo",
            ].filter { diagnostic.contains($0.filter { !$0.isWhitespace }) }
            fputs("Owned shell input diagnostic: frontendExited=\(shellView.childExited) inputEnabled=\(shellView.inputEnabled) commandEcho=\(text.contains("printf native-shell-ready")) visibleBytes=\(text.utf8.count) staticClasses=\(classes)\n", stderr)
            throw error
        }
        phase("shell-effect")
        if mode != .unavailable {
            guard coordinator.isStartingPi && coordinator.selectedSession?.pi.admission != .ready else {
                throw Failure.missing("shell effect before Pi admission")
            }
            try await wait("public Pi admission and catalog refresh complete") {
                !coordinator.isStartingPi && !coordinator.isEditingWork && coordinator.selectedSession?.pi.admission == .ready
            }
            phase("pi-finished")
            guard coordinator.selectedSession?.pi.admission == .ready else {
                throw Failure.missing("Pi admission did not become ready")
            }
        } else {
            try await wait("Pi unavailability reported") { !coordinator.isStartingPi && !coordinator.isEditingWork }
            precondition(coordinator.selectedSession?.pi.admission != .ready)
            precondition(coordinator.workEditor == nil)
        }
        if mode == .draftExit {
            // An intentional bounded foreground job in the same owned shell
            // runtime, not a detached descendant or restore-time command.
            precondition(window.makeFirstResponder(shellView) && shellView.inputEnabled)
            shellView.insertText("exec /bin/sh -c 'umask 077; i=0; while [ $i -lt 800 ]; do printf . >> native-draft-heartbeat; i=$((i+1)); sleep 0.1; done'", replacementRange: NSRange(location: NSNotFound, length: 0))
            let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            shellView.keyDown(with: enter)
            try await wait("actual shell work before native client exit") {
                ((try? Data(contentsOf: home.appendingPathComponent("native-draft-heartbeat")).count) ?? 0) > 0
            }
        }
        if mode == .panes {
            try await checkSplits(coordinator: coordinator, window: window, home: home, session: session, shell: shell, shellView: shellView)
        }
        if mode == .chat {
            try await checkChat(coordinator: coordinator, window: window, home: home, shellView: shellView)
        }
        if mode == .chat {
            let saved = await coordinator.chatDrafts.flush()
            precondition(saved)
        }
        let draftTarget = coordinator.chatTarget
        let retainedDraft = draftTarget.map { coordinator.chatDrafts.text(for: $0) }
        // Native reload/reselection preserves the exact frontend/surface. It is
        // not a new writer, and retained rendering is not a VT recovery claim.
        let originalSession = coordinator.selectedSessionID
        let layoutIdentity = AxodPaneLayouts.Session(machineID: coordinator.machineID!, sessionID: session.sessionId)
        let savedLayout = coordinator.paneLayouts.trees[layoutIdentity].flatMap { AxodPaneLayoutPersistence.write($0, session: layoutIdentity) }
        coordinator.selectSession(session.sessionId)
        coordinator.refresh()
        try await Task.sleep(for: .milliseconds(300))
        precondition(coordinator.selectedSessionID == originalSession)
        let reselected = try coordinator.terminalSurfaces.view(for: shellLaunch)
        precondition(reselected === shellView)
        coordinator.disconnect()
        try await coordinator.connectOwnedFixture(root: root, helper: helper, appLaunch: mode == .automatic)
        phase("reconnected")
        fputs("Native fixture catalogCount=\(coordinator.sessions.count) selected=\(coordinator.selectedSessionID != nil) loadFailed=\(coordinator.message == "Connected, but the selected workspace's session page could not be read.")\n", stderr)
        try await wait("reconnected original selection") { coordinator.selectedSessionID == originalSession }
        precondition(coordinator.sessions.count == 1 && coordinator.workEditor == nil)
        let reconnected = try coordinator.terminalSurfaces.view(for: shellLaunch)
        precondition(reconnected === shellView)
        precondition(coordinator.selectedSession?.shellPanes.first(where: { $0.paneId == shell.paneId })?.runtime == snapshot.runtime)
        precondition(!coordinator.isStartingPi, "Restoration/reconnect dispatched another start")
        if mode == .chat, let draftTarget {
            precondition(retainedDraft == "preserved after actual steering")
            precondition(coordinator.chatDrafts.text(for: draftTarget) == retainedDraft)
        }
        for pane in coordinator.selectedSession?.shellPanes ?? [] {
            if let snapshot = pane.terminal, let launch = try? coordinator.terminalLaunch(for: snapshot, sessionID: session.sessionId) {
                try coordinator.terminalSurfaces.view(for: launch).detachPresentation()
            }
        }
        if let current = coordinator.selectedSession, let pi = coordinator.presentationSnapshot(for: current),
           let launch = try? coordinator.terminalLaunch(for: pi, sessionID: current.sessionId) {
            try coordinator.terminalSurfaces.view(for: launch).detachPresentation()
        }
        // A fresh launch coordinator reads the retained catalog; existing work
        // never becomes permission for another automatic creation or Pi start.
        let restored = AxodWorkbenchCoordinator(preferences: preferences)
        defer { restored.disconnect(); restored.voice.shutdown() }
        try await restored.connectOwnedFixture(root: root, helper: helper, appLaunch: true)
        precondition(restored.selectedSessionID == originalSession && restored.sessions.count == 1)
        precondition(restored.selectedSession?.shellPanes.first(where: { $0.paneId == shell.paneId })?.runtime == snapshot.runtime)
        precondition(!restored.isStartingPi && !restored.isEditingWork && restored.workEditor == nil)
        if mode == .chat, let draftTarget {
            try await wait("fresh coordinator canonical chat/draft recovery") { restored.chatSnapshot?.target == draftTarget }
            precondition(restored.selectedSession?.manualName == true && restored.selectedSession?.displayName == "Daily work")
            precondition(restored.selectedSession?.pi.title == "Axo Workbench")
            precondition(restored.chatDrafts.text(for: draftTarget) == "preserved after actual steering")
            // The fixture knows this new ticket was never sent. Across another
            // fresh coordinator it must remain unresolved, not gain replay permission.
            let ticket = restored.chatDrafts.capture(for: draftTarget)!
            let durable = await restored.chatDrafts.persist(ticket)
            precondition(durable)
            restored.disconnect()
            let pending = AxodWorkbenchCoordinator(preferences: preferences)
            defer { pending.disconnect(); pending.voice.shutdown() }
            try await pending.connectOwnedFixture(root: root, helper: helper, appLaunch: true)
            try await wait("fresh coordinator original archive ticket") { pending.chatSnapshot?.target == draftTarget }
            precondition(pending.pendingChatCommandId == ticket.commandID)
            precondition(pending.chatDrafts.text(for: draftTarget) == "preserved after actual steering")
            precondition(pending.chatDrafts.capture(for: draftTarget) == nil)
            pending.reconcilePendingPiCommand()
            try await wait("original unknown ticket read-only receipt lookup") {
                !pending.isReconcilingPiCommand && pending.chatStatusMessage == "No matching durable Pi command receipt is visible. It was not replayed."
            }
            precondition(pending.pendingChatCommandId == ticket.commandID && pending.chatDrafts.pending(for: draftTarget)?.commandID == ticket.commandID)
            precondition(pending.chatDrafts.text(for: draftTarget) == "preserved after actual steering" && !pending.isStartingPi)
            print("PASS: owned fresh native coordinators recover editable text and exact original unresolved ticket; actual original receipt lookup remains unknown without hint recreation, replay or new model call")
        }
        if mode == .storage {
            precondition(restored.chatDrafts.blocksAutomaticStartup && !restored.chatDrafts.canEdit)
            let opaque = try Data(contentsOf: root.appendingPathComponent("chat-drafts/drafts.bin"))
            precondition(opaque == Data("opaque-owned-draft".utf8))
        }
        if mode == .panes {
            let identity = AxodPaneLayouts.Session(machineID: restored.machineID!, sessionID: session.sessionId)
            precondition(restored.selectedSession?.shellPanes.count == 3 && restored.paneLayouts.trees[identity]?.count == 4)
            let restoredLayout = restored.paneLayouts.trees[identity].flatMap { AxodPaneLayoutPersistence.write($0, session: identity) }
            precondition(savedLayout != nil && restoredLayout == savedLayout)
        }
        if mode == .draftExit {
            try await wait("original native draft-exit binding") { restored.chatSnapshot?.admission == .ready }
            guard let target = restored.chatTarget else { throw Failure.missing("original draft-exit target") }
            precondition(restored.chatDrafts.edit(exitDraftText, for: target))
            let saved = await restored.chatDrafts.prepareToQuit()
            precondition(saved && !restored.chatDrafts.canEdit && restored.chatDrafts.text(for: target) == exitDraftText)
            print("PASS: owned native client normal process exit follows production draft quit-cache barrier; not actual application-delegate/Cmd+Q/IME acceptance")
        }
        print("PASS: owned production native creation, immediate selection/no modal, captured PTY surfaces, independent shell input, retained restoration/reconnect/later-launch (\(mode.rawValue)); not Finder/service/live acceptance")
    }

    private static let exitDraftText = "owned unsent draft after normal exit 🦊\nsecond line"
    private static let crashDraftText = "owned original draft before forced client crash 🦊\nsecond line"
    @MainActor private static func checkDraftRecovery(coordinator: AxodWorkbenchCoordinator, root: URL, helper: URL,
                                                     home: URL, preferences: UserDefaults, mode: Mode) async throws {
        try await coordinator.connectOwnedFixture(root: root, helper: helper, appLaunch: true)
        try await wait("existing owned Pi binding after native process exit") { coordinator.chatSnapshot?.admission == .ready }
        guard let target = coordinator.chatTarget else { throw Failure.missing("recovered native draft target") }
        precondition(coordinator.sessions.count == 1 && coordinator.runtimes.count == 2 && !coordinator.isStartingPi)
        let key = "Axo.axod.pendingChat.\(target.machineId.uuidString).\(target.sessionId.uuidString)"
        precondition(preferences.object(forKey: key) == nil)
        if mode == .draftCrash {
            precondition(coordinator.chatDrafts.text(for: target) == exitDraftText)
            precondition(coordinator.chatDrafts.pending(for: target) == nil)
            precondition(coordinator.chatDrafts.edit(crashDraftText, for: target))
            guard let original = coordinator.chatDrafts.capture(for: target) else { throw Failure.missing("owned pre-hint crash ticket") }
            let saved = await coordinator.chatDrafts.persist(original)
            precondition(saved && preferences.object(forKey: key) == nil)
            let temporary = home.appendingPathComponent(".native-draft-ready-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: temporary.path, contents: Data("ready".utf8), attributes: [.posixPermissions: 0o600]) else {
                throw Failure.missing("owned crash checkpoint marker")
            }
            try FileManager.default.moveItem(at: temporary, to: home.appendingPathComponent("native-draft-crash-ready"))
            // Rust kills only this owned native client after the durable archive
            // boundary. No Pi dispatch/hint/termination or process adoption.
            while true { try await Task.sleep(for: .seconds(1)) }
        }
        precondition(coordinator.chatDrafts.text(for: target) == crashDraftText)
        guard let original = coordinator.chatDrafts.pending(for: target) else { throw Failure.missing("original ticket after client crash") }
        precondition(original.target == target && original.operation == .sendMessage)
        precondition(coordinator.pendingChatCommandId == original.commandID && coordinator.chatDrafts.capture(for: target) == nil)
        coordinator.reconcilePendingPiCommand()
        try await wait("read-only original lookup after actual native client crash") {
            !coordinator.isReconcilingPiCommand && coordinator.chatStatusMessage == "No matching durable Pi command receipt is visible. It was not replayed."
        }
        precondition(coordinator.chatDrafts.text(for: target) == crashDraftText)
        precondition(coordinator.chatDrafts.pending(for: target)?.commandID == original.commandID && coordinator.pendingChatCommandId == original.commandID)
        precondition(preferences.object(forKey: key) == nil && !coordinator.isStartingPi)
        print("PASS: separate fresh native process restores saved text/original pre-hint crash ticket, preserves unknown on actual lookup without hint/message replay; not lost dispatched reply or power-loss proof")
    }

    @MainActor private static func checkChat(coordinator: AxodWorkbenchCoordinator, window: NSWindow,
                                           home: URL, shellView: TerminalView) async throws {
        coordinator.refreshChat()
        try await wait("native canonical chat ready") {
            coordinator.chatSnapshot?.admission == .ready && coordinator.chatSnapshot?.busy == false
        }
        guard var ready = coordinator.chatSnapshot else { throw Failure.missing("captured native chat") }
        let target = ready.target
        let originalPi = coordinator.selectedSession?.runtime?.runtime
        guard let selected = coordinator.selectedSession, let content = window.contentView else { throw Failure.missing("rename source") }
        var views: [NSView] = [content]
        var index = 0
        var renameRow: WorkspaceSidebarRow?
        while index < views.count && index < 256 {
            let view = views[index]; index += 1
            if let row = view as? WorkspaceSidebarRow, row.textField?.stringValue == selected.displayName { renameRow = row; break }
            views.append(contentsOf: view.subviews)
        }
        guard let renameRow, let action = renameRow.menu?.items.first(where: { $0.title == "Rename…" }), action.isEnabled else {
            throw Failure.missing("native sidebar rename action")
        }
        precondition(NSApp.sendAction(#selector(WorkspaceSidebarRow.renameFromMenu(_:)), to: renameRow, from: action))
        precondition(coordinator.isRenamingWork)
        guard let editor = renameRow.textField?.currentEditor() as? NSTextView else { throw Failure.missing("native inline rename field editor") }
        editor.insertText("Daily work", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        precondition(window.makeFirstResponder(nil))
        do {
            try await wait("native inline rename receipt and protected catalog") {
                !coordinator.isEditingWork && !coordinator.isRenamingWork && coordinator.pendingWorkCommandID == nil &&
                coordinator.selectedSession?.manualName == true && coordinator.selectedSession?.displayName == "Daily work"
            }
        } catch {
            let matching = coordinator.selectedSession?.displayName == "Daily work"
            let rejected = coordinator.message.hasPrefix("Rename was rejected")
            let invalid = coordinator.message.hasPrefix("Name is invalid")
            let unknown = coordinator.message.hasPrefix("Rename outcome unknown")
            print("Owned rename diagnostic: editing=\(coordinator.isEditingWork) field=\(coordinator.isRenamingWork) pending=\(coordinator.pendingWorkCommandID != nil) protected=\(coordinator.selectedSession?.manualName == true) matching=\(matching) rejected=\(rejected) invalid=\(invalid) unknown=\(unknown)")
            throw error
        }
        precondition(coordinator.selectedSession?.runtime?.runtime == originalPi)
        try await wait("selected conversation ready after metadata rename") { coordinator.chatSnapshot?.target == target && coordinator.chatSnapshot?.busy == false }
        guard let current = coordinator.chatSnapshot else { throw Failure.missing("same conversation after rename") }
        ready = current
        precondition(coordinator.chatDrafts.edit("TITLE_AND_ACTUAL_TOOL", for: target))
        coordinator.submitChatDraft(snapshot: ready)
        precondition(coordinator.isSendingPiMessage && coordinator.pendingChatCommandId != nil)
        coordinator.chatDrafts.edit("edited during real normal submission", for: target)
        try await wait("native normal receipt and actual Pi tool/history") {
            !coordinator.isSendingPiMessage && coordinator.pendingChatCommandId == nil &&
            coordinator.chatSnapshot?.busy == false &&
            coordinator.chatEntries.contains(where: { $0.role == "assistant" && $0.text.contains("Actual public RPC tool complete") }) &&
            (try? Data(contentsOf: home.appendingPathComponent("marker.txt"))) == Data("Pi-owned-tool".utf8)
        }
        precondition(coordinator.chatDrafts.text(for: target) == "edited during real normal submission")
        coordinator.refresh()
        try await wait("normal-turn canonical title in native catalog") { coordinator.selectedSession?.pi.title == "Axo Workbench" }
        precondition(coordinator.selectedSession?.displayName == "Daily work" && coordinator.selectedSession?.manualName == true)
        print("PASS: owned native inline sidebar rename, durable protected name, later actual Pi canonical title kept separately, unchanged Pi/shell execution")
        guard let historySnapshot = coordinator.chatSnapshot else { throw Failure.missing("canonical history source") }
        let historySource = AxodChatHistoryWindow.Source(target: historySnapshot.target, readMode: historySnapshot.readMode)
        coordinator.loadChatHistoryPage(snapshot: historySnapshot, movement: .beginning, presentationID: coordinator.historyWindow.presentationID)
        try await wait("canonical history beginning page") { !coordinator.historyWindow.isLoading && coordinator.historyWindow.page != nil }
        guard let beginning = coordinator.historyWindow.page, let nextCursor = beginning.next else { throw Failure.missing("multi-page canonical history") }
        let renderedBeginning = coordinator.historyWindow.presentationID
        precondition(beginning.entries.count <= 50 && coordinator.displayedChatEntries == beginning.entries && coordinator.chatEntries.count <= 10)
        coordinator.loadChatHistoryPage(snapshot: historySnapshot, movement: .next, presentationID: renderedBeginning)
        try await wait("canonical history next page") { !coordinator.historyWindow.isLoading && coordinator.historyWindow.pageCursor == nextCursor }
        guard let following = coordinator.historyWindow.page else { throw Failure.missing("canonical history following page") }
        precondition(Set(beginning.entries.map(\.entryId)).isDisjoint(with: Set(following.entries.map(\.entryId))))
        precondition(coordinator.displayedChatEntries.count <= 50 && coordinator.displayedChatEntries == following.entries)
        coordinator.loadChatHistoryPage(snapshot: historySnapshot, movement: .previous, presentationID: coordinator.historyWindow.presentationID)
        try await wait("canonical history previous page") { !coordinator.historyWindow.isLoading && coordinator.historyWindow.page == beginning }
        precondition(coordinator.historyWindow.previous.isEmpty)
        coordinator.loadChatHistoryPage(snapshot: historySnapshot, movement: .next, presentationID: renderedBeginning)
        precondition(!coordinator.historyWindow.isLoading && coordinator.historyWindow.page == beginning)
        coordinator.showRecentChatHistory(source: historySource)
        precondition(coordinator.historyWindow.mode == .recent && coordinator.historyWindow.page == nil && coordinator.displayedChatEntries.count <= 10)
        print("PASS: owned native bounded canonical history beginning/next/previous/recent navigation, authoritative entry order, no gaps mixed into live entries and stale rendered-page ABA refusal")
        try await wait("rendered canonical tool source after catalog observation") {
            coordinator.chatSnapshot != nil && coordinator.chatEntries.contains(where: { $0.role == "toolResult" && $0.toolName == "bash" })
        }
        guard let toolSnapshot = coordinator.chatSnapshot,
              let output = coordinator.chatEntries.first(where: { $0.role == "toolResult" && $0.toolName == "bash" }),
              let toolSource = AxodToolOutput.Source(entry: output, snapshot: toolSnapshot) else { throw Failure.missing("recorded tool detail source") }
        precondition(output.truncated)
        coordinator.openToolOutput(entry: output, snapshot: toolSnapshot)
        try await wait("first canonical tool output page") { !coordinator.toolOutput.isLoading && coordinator.toolOutput.page?.offset == 0 }
        guard let first = coordinator.toolOutput.page, let next = first.nextOffset else { throw Failure.missing("bounded canonical first page") }
        precondition(first.totalBytes == 15000 && first.text.utf8.count <= 8192 && first.text.hasPrefix("λ界"))
        coordinator.loadToolOutput(source: toolSource, movement: .next)
        try await wait("next canonical UTF-8 tool output page") { !coordinator.toolOutput.isLoading && coordinator.toolOutput.page?.offset == next }
        guard let last = coordinator.toolOutput.page else { throw Failure.missing("bounded canonical last page") }
        precondition(last.nextOffset == nil && first.text + last.text == String(repeating: "λ界", count: 3000))
        coordinator.loadToolOutput(source: toolSource, movement: .previous)
        try await wait("previous canonical tool output page") { !coordinator.toolOutput.isLoading && coordinator.toolOutput.page?.offset == 0 }
        precondition(coordinator.toolOutput.page == first && coordinator.selectedSession?.runtime?.runtime == originalPi)
        coordinator.closeToolOutput()
        precondition(coordinator.toolOutput.source == nil && coordinator.toolOutput.page == nil)
        print("PASS: owned native canonical tool reader pages actual Pi Unicode output forward/backward with exact byte offsets, one bounded page and unchanged execution")
        try await wait("canonical chat reload after title catalog refresh") {
            coordinator.chatSnapshot?.target == target && coordinator.chatSnapshot?.busy == false
        }
        guard let settled = coordinator.chatSnapshot, settled.target == target else { throw Failure.missing("native settled source") }
        coordinator.chatDrafts.edit("ASK_OWNED_QUESTION", for: target)
        coordinator.submitChatDraft(snapshot: settled)
        try await wait("native question and unchanged draft acknowledged") {
            !coordinator.isSendingPiMessage && coordinator.pendingChatCommandId == nil && coordinator.chatSnapshot?.question != nil
        }
        precondition(coordinator.chatDrafts.text(for: target).isEmpty)
        guard let waiting = coordinator.chatSnapshot, let question = waiting.question,
              let option = question.options.first else { throw Failure.missing("captured native owned question") }
        coordinator.chatDrafts.edit("must stay local during owned question", for: target)
        coordinator.submitChatDraft(snapshot: waiting)
        precondition(!coordinator.isSendingPiMessage && coordinator.pendingChatCommandId == nil)
        precondition(coordinator.chatDrafts.text(for: target) == "must stay local during owned question")
        try await shellEffect(shellView, window: window, home: home, marker: "native-question-shell")
        precondition(coordinator.chatSnapshot?.question?.id == question.id)
        coordinator.answerChatQuestion(question, option: option, snapshot: waiting)
        try await wait("native offered answer and canonical settlement") {
            !coordinator.isSendingPiMessage && coordinator.pendingChatCommandId == nil &&
            coordinator.chatSnapshot?.busy == false && coordinator.chatSnapshot?.question == nil &&
            coordinator.chatEntries.contains(where: { $0.toolName == "axo_ask" && $0.text == "User chose: Allow" })
        }
        coordinator.answerChatQuestion(question, option: option, snapshot: waiting)
        precondition(!coordinator.isSendingPiMessage && coordinator.pendingChatCommandId == nil)
        precondition(coordinator.chatDrafts.text(for: target) == "must stay local during owned question")

        guard let idle = coordinator.chatSnapshot else { throw Failure.missing("native cancel source") }
        coordinator.chatDrafts.edit("BLOCK_PUBLIC_STREAM", for: target)
        coordinator.submitChatDraft(snapshot: idle)
        try await wait("native active cancellable interaction") {
            !coordinator.isSendingPiMessage && coordinator.pendingChatCommandId == nil &&
            coordinator.chatSnapshot?.busy == true && coordinator.chatSnapshot?.interactionId != nil
        }
        // Only controlled public-Pi progress, never run/binding authority. The
        // addressed interaction remains the typed snapshot, not a marker file.
        try await wait("owned first provider stream consumed by public Pi observer") {
            (try? Data(contentsOf: home.appendingPathComponent("native-provider-stream-5"))) == Data("started".utf8)
        }
        guard let active = coordinator.chatSnapshot else { throw Failure.missing("native active source") }
        coordinator.cancelChatTurn(snapshot: active)
        try await wait("native cancellation acknowledged and settled") {
            !coordinator.isSendingPiMessage && coordinator.pendingChatCommandId == nil && coordinator.chatSnapshot?.busy == false
        }
        coordinator.cancelChatTurn(snapshot: active)
        precondition(!coordinator.isSendingPiMessage && coordinator.pendingChatCommandId == nil)

        guard let afterCancel = coordinator.chatSnapshot else { throw Failure.missing("native steering source") }
        coordinator.chatDrafts.edit("BLOCK_PUBLIC_STREAM", for: target)
        coordinator.submitChatDraft(snapshot: afterCancel)
        try await wait("native active steerable interaction") {
            !coordinator.isSendingPiMessage && coordinator.pendingChatCommandId == nil &&
            coordinator.chatSnapshot?.busy == true && coordinator.chatSnapshot?.interactionId != nil
        }
        try await wait("owned second provider stream consumed by public Pi observer") {
            (try? Data(contentsOf: home.appendingPathComponent("native-provider-stream-6"))) == Data("started".utf8)
        }
        guard let steering = coordinator.chatSnapshot else { throw Failure.missing("native captured steering") }
        coordinator.chatDrafts.edit("NATIVE_STEER_TOOL", for: target)
        coordinator.submitChatDraft(snapshot: steering)
        precondition(coordinator.isSendingPiMessage && coordinator.pendingChatCommandId != nil)
        coordinator.chatDrafts.edit("preserved after actual steering", for: target)
        do {
            try await wait("native steering receipt and actual subsequent tool", seconds: 24) {
                !coordinator.isSendingPiMessage && coordinator.pendingChatCommandId == nil &&
                coordinator.chatSnapshot?.busy == false &&
                (try? Data(contentsOf: home.appendingPathComponent("native-steer-marker.txt"))) == Data("Native-steered".utf8)
            }
        } catch {
            let marker = FileManager.default.fileExists(atPath: home.appendingPathComponent("native-steer-marker.txt").path)
            let canonicalInput = coordinator.chatEntries.contains(where: { $0.role == "user" && $0.text.contains("NATIVE_STEER_TOOL") })
            fputs("Owned native steering diagnostic: sending=\(coordinator.isSendingPiMessage) pending=\(coordinator.pendingChatCommandId != nil) busy=\(coordinator.chatSnapshot?.busy == true) recovery=\(coordinator.chatSnapshot?.recovery == true) marker=\(marker) canonicalInput=\(canonicalInput)\n", stderr)
            throw error
        }
        precondition(coordinator.chatDrafts.text(for: target) == "preserved after actual steering")
        precondition(coordinator.selectedSession?.runtime?.runtime == originalPi)
        precondition(coordinator.selectedSession?.shellPanes.count == 1 && !shellView.childExited && shellView.inputEnabled)
        print("PASS: owned production native chat actions, actual Pi tool/title/history, original draft revision, owned question with usable shell, offered/stale answer, captured cancel/steer and exact runtime survival; not real OS composer/IME or deployed/phone acceptance")
    }

    @MainActor private static func checkControlBurst(root: URL) async throws {
        let directory = try AxodStateDirectory.openExisting(root: root)
        guard let endpoint = try directory.readEndpoint() else { throw Failure.missing("burst endpoint") }
        let peer = try AxoJSONRPCClient().openLocalWebSocket(endpoint: endpoint)
        defer { Task { await peer.close() } }
        let negotiation = try await peer.request(method: AxoProtocol.Method.negotiate, parameters: NegotiationParameters())
        _ = try AxoProtocolResultValidator.localNegotiation(negotiation)
        let source = MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration)
        var completed = 0
        do {
            for _ in 0..<24 {
                let value = try await peer.request(method: AxoProtocol.Method.listRuntimes, parameters: RuntimeListParameters(target: source))
                let result = try AxoProtocolResultValidator.runtimeList(value, target: source)
                precondition(result.terminals.isEmpty)
                completed += 1
            }
        } catch { throw Failure.missing("read-only control burst after \(completed) replies") }
        let commandID = UUID()
        let creation = SessionCreateParameters(target: WorkSessionDestination(machineId: source.machineId,
            hostGeneration: source.hostGeneration, workspaceId: nil), commandId: commandID,
            expectedRevision: WorkRevision(rawValue: 0)!, name: "Cancelled queued fixture metadata")
        let cancelled = Task { try await peer.request(method: AxoProtocol.Method.createSession, parameters: creation) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw Failure.missing("queued cancellation was not observed")
        } catch AxoJSONRPCClientError.outcomeUnknown { /* Conservative outcome; never replay. */ }
        try await Task.sleep(for: .milliseconds(250))
        let lookup = try await peer.request(method: AxoProtocol.Method.getCommand,
            parameters: CommandGetParameters(target: source, commandId: commandID))
        let command = try AxoProtocolResultValidator.commandGet(lookup, target: source)
        precondition(command.receipt == nil)
        let catalog = try await peer.request(method: AxoProtocol.Method.listSessions, parameters: SessionListParameters(target: source))
        let page = try AxoProtocolResultValidator.sessionList(catalog, target: source, workspaceID: nil)
        precondition(page.sessions.isEmpty)
        print("PASS: owned read-only control burst preserves original command/ack rate bounds; observed queued cancellation has no late metadata dispatch or receipt")
    }

    @MainActor private static func checkSplits(coordinator: AxodWorkbenchCoordinator, window: NSWindow, home: URL,
                                              session: WorkSessionRecord, shell: ShellPaneRecord, shellView: TerminalView) async throws {
        let originalPi = coordinator.selectedSession?.runtime?.runtime
        precondition(originalPi != nil)
        let identity = AxodPaneLayouts.Session(machineID: coordinator.machineID!, sessionID: session.sessionId)
        precondition(window.makeFirstResponder(shellView))
        precondition(coordinator.paneLayouts.focusedPanes[identity] == shell.paneId && coordinator.canSplitPane)
        precondition(NSApp.sendAction(#selector(AxodWorkbenchCoordinator.splitRight(_:)), to: coordinator, from: NSMenuItem()))
        try await wait("explicit right split committed") { coordinator.selectedSession?.shellPanes.count == 2 }
        guard let right = coordinator.selectedSession?.shellPanes.first(where: { $0.paneId != shell.paneId }),
              let rightSnapshot = right.terminal else { throw Failure.missing("right captured shell") }
        let rightLaunch = try coordinator.terminalLaunch(for: rightSnapshot, sessionID: session.sessionId)
        let rightView = try coordinator.terminalSurfaces.view(for: rightLaunch)
        try await wait("right split native surface and output") {
            rightView.window === window && visibleText(rightView).contains("axo-native-shell-prompt")
        }
        precondition(shellView.window === window && !shellView.childExited && !rightView.childExited)
        let shellFrame = shellView.convert(shellView.bounds, to: window.contentView)
        let rightFrame = rightView.convert(rightView.bounds, to: window.contentView)
        precondition(shellFrame.width > 0 && rightFrame.width > 0 && rightFrame.midX > shellFrame.midX)
        try await shellEffect(rightView, window: window, home: home, marker: "native-pane-right")
        precondition(coordinator.paneLayouts.focusedPanes[identity] == right.paneId && coordinator.canSplitPane)
        precondition(NSApp.sendAction(#selector(AxodWorkbenchCoordinator.splitDown(_:)), to: coordinator, from: NSMenuItem()))
        try await wait("explicit down split committed") { coordinator.selectedSession?.shellPanes.count == 3 }
        guard let down = coordinator.selectedSession?.shellPanes.first(where: { $0.paneId != shell.paneId && $0.paneId != right.paneId }),
              let downSnapshot = down.terminal else { throw Failure.missing("down captured shell") }
        let downLaunch = try coordinator.terminalLaunch(for: downSnapshot, sessionID: session.sessionId)
        let downView = try coordinator.terminalSurfaces.view(for: downLaunch)
        try await wait("down split native surface and output") {
            downView.window === window && visibleText(downView).contains("axo-native-shell-prompt")
        }
        let topFrame = rightView.convert(rightView.bounds, to: window.contentView)
        let downFrame = downView.convert(downView.bounds, to: window.contentView)
        precondition(topFrame.height > 0 && downFrame.height > 0 && abs(topFrame.midX - downFrame.midX) < 2)
        precondition(window.contentView!.isFlipped ? downFrame.midY > topFrame.midY : downFrame.midY < topFrame.midY)
        try await shellEffect(downView, window: window, home: home, marker: "native-pane-down")
        guard let upward = coordinator.capturePaneFocus(.up, in: window) else { throw Failure.missing("captured upward native pane focus") }
        precondition(upward.destination.paneID == right.paneId && coordinator.applyPaneFocus(upward))
        precondition(window.firstResponder === rightView && coordinator.focusPane(.down, in: window))
        precondition(window.firstResponder === downView && !coordinator.applyPaneFocus(upward)) // Focus ABA.
        precondition(coordinator.focusPane(.left, in: window) && window.firstResponder === shellView)
        guard let staleLayout = coordinator.capturePaneFocus(.right, in: window),
              case .split(let originalRoot)? = coordinator.paneLayouts.trees[identity]?.root else { throw Failure.missing("captured focus geometry") }
        coordinator.paneLayouts.resize(coordinator.paneLayouts.trees[identity]!.root!, ratio: 0.6, in: identity, generation: coordinator.paneLayouts.generations[identity]!)
        coordinator.paneLayouts.resize(coordinator.paneLayouts.trees[identity]!.root!, ratio: originalRoot.ratio, in: identity, generation: coordinator.paneLayouts.generations[identity]!)
        precondition(!coordinator.applyPaneFocus(staleLayout) && window.firstResponder === shellView)
        do {
            try await wait("Pi focus target after geometry reflow") { coordinator.capturePaneFocus(.left, in: window) != nil }
        } catch {
            let record = coordinator.selectedSession!
            if let piSnapshot = coordinator.presentationSnapshot(for: record), let launch = try? coordinator.terminalLaunch(for: piSnapshot, sessionID: record.sessionId) {
                let cached = coordinator.terminalSurfaces.cachedView(for: launch.key)
                let shown = coordinator.terminalSurfaces.presentation(for: launch.key)
                fputs("Pane-focus diagnostic: cached=\(cached != nil) surface=\(cached?.surface != nil) ended=\(cached?.childExited ?? false) hosted=\(cached?.window === window) presentation=\(shown != nil) sourceShell=\(window.firstResponder === shellView) logicalShell=\(coordinator.paneLayouts.focusedPanes[identity] == shell.paneId)\n", stderr)
            }
            throw error
        }
        precondition(coordinator.focusPane(.left, in: window))
        guard let piPresentation = coordinator.terminalSurfaces.presentation(for: window.firstResponder as! TerminalView) else { throw Failure.missing("focused Pi presentation") }
        precondition(piPresentation.key.paneID == session.pi.paneId && !coordinator.focusPane(.left, in: window))
        precondition(coordinator.focusPane(.next, in: window) && window.firstResponder === shellView)
        precondition(coordinator.focusPane(.previous, in: window) && window.firstResponder === piPresentation.view)
        let beforeEditor = coordinator.capturePaneFocus(.right, in: window)!
        let editor = NSTextView(frame: .zero)
        window.contentView!.addSubview(editor)
        precondition(window.makeFirstResponder(editor) && !coordinator.focusPane(.right, in: window))
        precondition(window.firstResponder === editor && window.makeFirstResponder(piPresentation.view))
        precondition(!coordinator.applyPaneFocus(beforeEditor) && window.makeFirstResponder(shellView))
        editor.removeFromSuperview()
        let competing = AxodTerminalHostView()
        competing.install(launch: rightLaunch, surfaces: coordinator.terminalSurfaces, inputEnabled: true, viewportID: UUID(), onFocus: {})
        precondition(rightView.window === window && competing.subviews.allSatisfy { $0 !== rightView })
        print("PASS: owned native spatial/previous/next first-responder pane focus, Pi/shell destinations, focus/layout ABA refusal, non-terminal focus and competing viewport preservation; not real OS shortcuts/multiwindow acceptance")
        precondition(coordinator.selectedSession?.runtime?.runtime == originalPi)
        precondition(Set(coordinator.selectedSession!.shellPanes.compactMap { $0.runtime?.runtimeGeneration }).count == 3)
        precondition(!shellView.childExited && !rightView.childExited && !downView.childExited)
        print("PASS: owned production right/down split selectors, exact focused anchors, fresh independent PTYs, native geometry/input, sibling Pi and retained surfaces; not real OS shortcut/multiwindow acceptance")
    }

    @MainActor private static func shellEffect(_ view: TerminalView, window: NSWindow, home: URL, marker: String) async throws {
        precondition(window.makeFirstResponder(view) && view.inputEnabled)
        view.insertText("printf \(marker) > \"$HOME/\(marker)\"", replacementRange: NSRange(location: NSNotFound, length: 0))
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        view.keyDown(with: enter)
        try await wait("one native split shell effect") {
            (try? Data(contentsOf: home.appendingPathComponent(marker))) == Data(marker.utf8)
        }
    }

    /// Bounded synthetic screen predicates only; never printed or used as Pi admission.
    @MainActor private static func visibleText(_ view: TerminalView) -> String {
        guard let surface = view.surface else { return "" }
        var selection = ghostty_selection_s()
        selection.top_left.tag = GHOSTTY_POINT_VIEWPORT
        selection.top_left.coord = GHOSTTY_POINT_COORD_TOP_LEFT
        selection.bottom_right.tag = GHOSTTY_POINT_VIEWPORT
        selection.bottom_right.coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len <= 65536 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }

    @MainActor private static func wait(_ stage: String, seconds: TimeInterval = 12, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() {
            guard Date() < deadline else { throw Failure.missing(stage) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private enum Mode: String {
        case delayed, unavailable, automatic, pending, panes, chat, storage
        case draftExit = "draft-exit", draftCrash = "draft-crash", draftRecover = "draft-recover"
    }
    private enum Failure: Error { case missing(String) }
}
