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
            catch { fputs("Owned native workbench check failed: \(error)\n", stderr) }
            finished = true
        }
        let deadline = Date().addingTimeInterval(40)
        while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        if !finished || !success { exit(1) }
    }

    @MainActor private static func check() async throws {
        precondition(CommandLine.arguments.count == 5)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let helper = URL(fileURLWithPath: CommandLine.arguments[2])
        let home = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        guard let mode = Mode(rawValue: CommandLine.arguments[4]) else { throw Failure.missing("known fixture mode") }
        let began = Date()
        let suite = "Axo.NativeWorkbenchFixture.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let coordinator = AxodWorkbenchCoordinator(preferences: preferences)
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
        try await coordinator.connectOwnedFixture(root: root, helper: helper, appLaunch: mode == .automatic)
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
        if mode == .panes {
            try await checkSplits(coordinator: coordinator, window: window, home: home, session: session, shell: shell, shellView: shellView)
        }
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
        if mode == .panes {
            let identity = AxodPaneLayouts.Session(machineID: restored.machineID!, sessionID: session.sessionId)
            precondition(restored.selectedSession?.shellPanes.count == 3 && restored.paneLayouts.trees[identity]?.count == 4)
            let restoredLayout = restored.paneLayouts.trees[identity].flatMap { AxodPaneLayoutPersistence.write($0, session: identity) }
            precondition(savedLayout != nil && restoredLayout == savedLayout)
        }
        print("PASS: owned production native creation, immediate selection/no modal, captured PTY surfaces, independent shell input, retained restoration/reconnect/later-launch (\(mode.rawValue)); not Finder/service/live acceptance")
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

    @MainActor private static func wait(_ stage: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !predicate() {
            guard Date() < deadline else { throw Failure.missing(stage) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private enum Mode: String { case delayed, unavailable, automatic, pending, panes }
    private enum Failure: Error { case missing(String) }
}
