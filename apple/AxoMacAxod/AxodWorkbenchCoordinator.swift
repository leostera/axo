import AppKit
import AxoCore
import AxoProtocol
import Darwin
import Observation
import SwiftUI
import UserNotifications

@MainActor @Observable
final class AxodWorkbenchCoordinator {
    private enum PreferenceKey {
        static let machineID = "Axo.axod.selection.machineID"
        static let workspaceID = "Axo.axod.selection.workspaceID"
        static let sessionID = "Axo.axod.selection.sessionID"
    }

    enum ConnectionState: Equatable {
        case starting
        case connected
        case disconnected
        case failed(String)
    }

    private(set) var connectionState: ConnectionState = .starting
    private(set) var machineID: UUID?
    private(set) var hostStatus: HostStatusResult?
    var onlineMessage: String {
        switch connectionState {
        case .starting: return "axo is starting"
        case .connected: return hostStatus?.cloud.isOnline == true ? "axo is online" : "axo is connected locally"
        case .disconnected, .failed: return "axo is offline"
        }
    }
    private(set) var workspaces: [WorkWorkspaceRecord] = []
    private(set) var sessions: [WorkSessionRecord] = []
    private(set) var runtimes: [TerminalSnapshot] = []
    private(set) var selectedWorkspaceID: UUID?
    private(set) var selectedSessionID: UUID?
    private(set) var nextWorkspaceCursor: WorkPageCursor?
    private(set) var nextSessionCursor: WorkPageCursor?
    private(set) var nextRuntimeID: UUID?
    private(set) var message = "Connecting to the Axod background service."
    let serviceLifecycle: AxodServiceLifecycle
    let setupPresentation: AxodSetupPresentation
    var showsSetup: Bool { !usesFixtureDaemon && !setupPresentation.enteredWorkbench }
    var setupStage: AxodSetupPolicy.Stage {
        let fact: AxodSetupPolicy.Connection
        if connectTask != nil || connectionState == .starting { fact = .checking }
        else if connectionState == .connected, let endpoint {
            fact = .loaded(MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration))
        } else { fact = .unavailable }
        return AxodSetupPolicy.stage(registration: serviceLifecycle.registration,
            availability: serviceLifecycle.availability, connection: fact)
    }
    var setupLoginStartup: Bool {
        get { setupPresentation.requestedLoginStartup ?? (serviceLifecycle.loginRegistration == .enabled || serviceLifecycle.loginRegistration == .requiresApproval) }
        set { setupPresentation.requestedLoginStartup = newValue }
    }
    var daemonServiceMessage: String { serviceLifecycle.failureMessage ?? serviceLifecycle.registration.message }
    var needsLoginItemsReview: Bool { serviceLifecycle.loginRegistration == .requiresApproval }
    var serviceReviewMessage: String {
        needsLoginItemsReview && !needsDaemonServiceReview
            ? "Opening the Axo menu-bar app at login needs macOS approval. The daemon registration is separate."
            : daemonServiceMessage
    }
    var needsDaemonServiceReview: Bool { !usesFixtureDaemon && serviceLifecycle.registration != .enabled }
    @ObservationIgnored private var usesFixtureDaemon = false
    private(set) var helperUpdateAvailable = false
    private(set) var serviceSetupFailure: String?
    var hasUnresolvedHelperHandoff: Bool {
        machineID.map { preferences.object(forKey: "Axo.axod.pendingUpgrade.\($0.uuidString)") != nil } ?? false
    }
    private(set) var chatTarget: PiChatTarget?
    private(set) var chatSnapshot: PiChatSnapshot?
    private(set) var chatEntries: [PiCanonicalProjection] = []
    let historyWindow = AxodChatHistoryWindow()
    @ObservationIgnored private var historyPageTask: Task<Void, Never>?
    var displayedChatEntries: [PiCanonicalProjection] { historyWindow.mode == .page ? (historyWindow.page?.entries ?? []) : chatEntries }
    let toolOutput = AxodToolOutput()
    @ObservationIgnored private var toolOutputTask: Task<Void, Never>?
    private(set) var chatStatusMessage = "Select an admitted Pi session to view its canonical conversation."

    @ObservationIgnored let preferences: UserDefaults
    @ObservationIgnored private var preferredMachineID: UUID?
    @ObservationIgnored private var preferredWorkspaceID: UUID?
    @ObservationIgnored private var preferredSessionID: UUID?
    @ObservationIgnored private var initialTerminalFocus: WorkSessionTarget?
    let terminalSurfaces = AxodTerminalSurfaces()
    let paneLayouts: AxodPaneLayouts
    private let rpc = AxoJSONRPCClient()
    private var stateDirectory: AxodStateDirectory?
    private var endpoint: LocalDaemonEndpoint?
    private var connection: AxoJSONRPCWebSocketConnection?
    private var operationGeneration = UUID()
    private var refreshGeneration = UUID()
    private var sessionLoadGeneration = UUID()
    private var chatLoadGeneration = UUID()
    private var chatObservationTask: Task<Void, Never>?
    private var hostObservationTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var serviceObservation: UUID?
#if DEBUG
    private let bundledDaemon = AxodBundledDaemon()
    func configureSelfTest(_ context: AxodAppSelfTest) { bundledDaemon.selfTest = context; usesFixtureDaemon = true }
    func stopSelfTestDaemon() async {
        // Cleanup remains runnable even when the app's diagnostic task is cancelled.
        let cleanup = Task { @MainActor in await self.bundledDaemon.stopSelfTestChild() }
        await cleanup.value
    }
#endif
    let voice: MacVoiceCoordinator
#if AXO_NATIVE_FIXTURE
    @ObservationIgnored private var fixtureAttachmentHelper: URL?
#endif
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var aboutWindow: NSWindow?
    @ObservationIgnored private var serviceSettingsWindow: NSWindow?
    private var catalogRevision: WorkRevision?

    func terminalLaunch(for snapshot: TerminalSnapshot, sessionID: UUID) throws -> TerminalLaunch {
        guard connectionState == .connected, let endpoint, let stateDirectory,
              snapshot.runtime.target.sessionId == sessionID,
              snapshot.runtime.hostGeneration == endpoint.hostGeneration,
              case .running = snapshot.process else { throw LaunchError.surfaceCreation }
        try stateDirectory.requireCurrentEndpoint(endpoint)
        let helper: URL
#if AXO_NATIVE_FIXTURE
        helper = fixtureAttachmentHelper ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/axod")
#else
        helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/axod")
#endif
        return try TerminalLaunch.attachment(root: stateDirectory.root, machineID: endpoint.machineId,
                                             runtime: snapshot.runtime, helper: helper)
    }

    init(preferences: UserDefaults = .standard, voiceHistoryURL: URL? = nil,
         serviceLifecycle: AxodServiceLifecycle? = nil) {
        self.serviceLifecycle = serviceLifecycle ?? .shared
        self.setupPresentation = AxodSetupPresentation(preferences: preferences)
        self.preferences = preferences
        self.paneLayouts = AxodPaneLayouts()
#if AXO_NATIVE_FIXTURE
        // Owned checks neither load live voice history nor request microphone access.
        self.voice = MacVoiceCoordinator()
#else
        self.voice = MacVoiceCoordinator(historyURL: voiceHistoryURL ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support/Axo/voice-transcripts.json"))
#endif
        preferredMachineID = UUID(uuidString: preferences.string(forKey: PreferenceKey.machineID) ?? "")
        preferredWorkspaceID = UUID(uuidString: preferences.string(forKey: PreferenceKey.workspaceID) ?? "")
        preferredSessionID = UUID(uuidString: preferences.string(forKey: PreferenceKey.sessionID) ?? "")
        terminalSurfaces.onMoveFocus = { [weak self] view, direction in
            guard let self, let window = view.window, NSApp.keyWindow === window,
                  window.firstResponder === view else { return false }
            return self.focusPane(direction, in: window)
        }
    }

    @discardableResult func beginFirstLaunchSetup() -> Bool {
        guard !usesFixtureDaemon, !setupPresentation.enteredWorkbench,
              preferences.object(forKey: AxodSetupPresentation.completionKey) == nil else { return false }
        serviceLifecycle.observeRegistration()
        guard serviceLifecycle.registration == .notRegistered else { return false }
        guard !Bundle.main.bundleURL.pathComponents.contains("AppTranslocation") else {
            serviceSetupFailure = "Move Axo to a permanent location and reopen it before registering its background service."
            return false
        }
        do {
            let directory = try AxodStateDirectory.prepare()
            try serviceLifecycle.registerForFirstLaunch(in: directory.root)
            return serviceLifecycle.registration == .enabled
        } catch {
            serviceSetupFailure = serviceLifecycle.failureMessage ?? error.localizedDescription
            return false
        }
    }

    func refreshSetupAfterActivation() {
        guard showsSetup, connectTask == nil, serviceLifecycle.operation == .idle else { return }
        serviceLifecycle.observeRegistration()
        if serviceLifecycle.registration == .enabled, connectionState != .connected { connect() }
    }

    func enableBackgroundService() {
        serviceSetupFailure = nil
        do {
            let directory = try AxodStateDirectory.prepare()
            try serviceLifecycle.enableAgent(in: directory.root)
            connect()
        } catch { serviceSetupFailure = error.localizedDescription }
    }

    func finishSetup() async {
        guard !setupPresentation.isFinishing, case .ready(let target) = setupStage else { return }
        setupPresentation.isFinishing = true
        defer { setupPresentation.isFinishing = false }
        setupPresentation.failure = nil
        let operation = operationGeneration
        if let requested = setupPresentation.requestedLoginStartup {
            guard await serviceLifecycle.setFrontendAtLogin(requested) else {
                setupPresentation.failure = serviceLifecycle.failureMessage ?? "Another service setting is still being changed. Wait for it before finishing setup."
                return
            }
        }
        guard operationGeneration == operation,
              setupPresentation.complete(captured: target, stage: setupStage) else {
            setupPresentation.failure = "The service changed during setup. Check its current readiness before opening Axo."
            return
        }
    }

    func openLoginItemsSettings() { serviceLifecycle.openApprovalSettings() }

    func showServiceSettingsWindow() {
        serviceLifecycle.observeRegistration()
        if let serviceSettingsWindow {
            serviceSettingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Background Service"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: AxodServiceSettingsView(coordinator: self))
        window.center()
        serviceSettingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func showSettingsWindow() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.contentViewController = NSHostingController(rootView: AxodSettingsView(coordinator: self))
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showAboutWindow() {
        if let aboutWindow {
            aboutWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 370),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "About Axo"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AxodAboutView(coordinator: self))
        window.center()
        aboutWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func notificationPreferenceChanged(_ enabled: Bool) {
        guard enabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func openNotificationSettings() {
        var components = URLComponents()
        components.scheme = "x-apple.systempreferences"
        components.path = "com.apple.Notifications-Settings.extension"
        components.queryItems = [URLQueryItem(name: "id", value: Bundle.main.bundleIdentifier)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    func connect() {
        guard connectTask == nil else { return }
        let operation = UUID()
        operationGeneration = operation
        let oldConnection = connection
        connection = nil
        endpoint = nil
        connectionState = .starting
        hostObservationTask?.cancel()
        hostStatus = nil
        message = "Validating Axo's private daemon state."
        connectTask = Task { [weak self] in
            guard let self else { return }
            await oldConnection?.close()
            await self.bootstrapAndConnect(operation: operation)
            guard self.operationGeneration == operation else { return }
            self.connectTask = nil
            if self.connectionState == .connected {
                self.setupPresentation.restoreIfKnownReady(self.setupStage)
            }
        }
    }

#if AXO_NATIVE_FIXTURE
    /// Compile-only isolation seam: absent from the shipped app. Rust owns the
    /// disposable daemon/root; this skips service registration, not protocol/UI paths.
    func connectOwnedFixture(root: URL, helper: URL) async throws {
        guard connection == nil else { throw AxodWorkbenchError.superseded }
        usesFixtureDaemon = true
        let directory = try AxodStateDirectory.openExisting(root: root)
        guard let discovered = try directory.readEndpoint() else { throw AxodWorkbenchError.startupTimedOut }
        stateDirectory = directory
        fixtureAttachmentHelper = helper
        let operation = UUID()
        operationGeneration = operation
        try await connect(to: discovered, stateDirectory: directory, operation: operation)
    }
#endif

    func disconnect() {
        operationGeneration = UUID()
        refreshGeneration = UUID()
        sessionLoadGeneration = UUID()
        connectTask?.cancel()
        connectTask = nil
        hostObservationTask?.cancel()
        hostStatus = nil
        let oldConnection = connection
        connection = nil
        endpoint = nil
        workspaces = []
        sessions = []
        runtimes = []
        catalogRevision = nil
        stopChatObservation()
        chatTarget = nil
        chatSnapshot = nil
        chatEntries = []
        selectedWorkspaceID = nil
        selectedSessionID = nil
        nextWorkspaceCursor = nil
        nextSessionCursor = nil
        nextRuntimeID = nil
        connectionState = .disconnected
        message = "Disconnected. The daemon and its work are left running."
        if let oldConnection { Task { await oldConnection.close() } }
    }

    func refresh(message completionMessage: String? = nil) {
        guard let connection, let endpoint else { return }
        let operation = operationGeneration
        let refresh = UUID()
        refreshGeneration = refresh
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.refreshFirstPages(
                    over: connection,
                    endpoint: endpoint,
                    operation: operation,
                    refresh: refresh
                )
                guard self.isCurrent(operation, refresh: refresh, connection: connection, endpoint: endpoint) else { return }
                self.message = completionMessage ?? "Showing daemon-owned work records and runtime metadata."
            } catch {
                self.connectionFailed(error, operation: operation, connection: connection)
            }
        }
    }

    func selectWorkspace(_ workspaceID: UUID?) {
        stopChatObservation()
        chatTarget = nil
        chatSnapshot = nil
        chatEntries = []
        selectedWorkspaceID = workspaceID
        selectedSessionID = nil
        preferredWorkspaceID = workspaceID
        preferredSessionID = nil
        saveSelection()
        nextSessionCursor = nil
        let load = UUID()
        sessionLoadGeneration = load
        guard let connection, let endpoint else { return }
        let operation = operationGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let catalog = try await self.fetchSessionCatalog(over: connection, endpoint: endpoint, operation: operation)
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint),
                      self.sessionLoadGeneration == load,
                      self.selectedWorkspaceID == workspaceID else { return }
                self.sessions = catalog.sessions
                self.catalogRevision = catalog.revision
                self.selectedSessionID = catalog.sessions.first(where: { $0.workspaceId == workspaceID })?.sessionId
                self.preferredWorkspaceID = workspaceID
                self.preferredSessionID = self.selectedSessionID
                self.nextSessionCursor = nil
                self.saveSelection()
                self.activateSelectedSession()
            } catch {
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint),
                      self.sessionLoadGeneration == load else { return }
                self.message = "Could not load this workspace's sessions. Refresh to reconcile the current revision."
            }
        }
    }

    /// Selecting a record changes only the metadata detail; it is never process-launch intent.
    func selectSession(_ sessionID: UUID) {
        guard let session = sessions.first(where: { $0.sessionId == sessionID }) else { return }
        sessionLoadGeneration = UUID()
        selectedWorkspaceID = session.workspaceId
        preferredWorkspaceID = session.workspaceId
        stopChatObservation()
        chatSnapshot = nil
        chatEntries = []
        selectedSessionID = sessionID
        preferredSessionID = sessionID
        saveSelection()
        activateSelectedSession()
    }

    var selectedSession: WorkSessionRecord? {
        sessions.first { $0.sessionId == selectedSessionID }
    }

    func presentationSnapshot(for session: WorkSessionRecord) -> TerminalSnapshot? {
        if let admitted = session.runtime { return admitted }
        guard let endpoint else { return nil }
        return runtimes.first {
            $0.runtime.hostGeneration == endpoint.hostGeneration &&
            $0.runtime.target.sessionId == session.sessionId &&
            $0.runtime.target.paneId == session.pi.paneId
        }
    }

    func preparePaneLayout(_ session: WorkSessionRecord) {
        guard selectedSessionID == session.sessionId, let machineID else { return }
        paneLayouts.observe(session, machineID: machineID)
    }

    func terminalBecameAvailable(_ key: TerminalLaunch.Key, in window: NSWindow) {
        guard let intent = initialTerminalFocus, let session = selectedSession,
              intent.machineId == key.machineID, intent.sessionId == key.sessionID,
              intent.hostGeneration == key.hostGeneration, session.sessionId == intent.sessionId,
              session.workspaceId == intent.workspaceId, session.shellPanes.first?.paneId == key.paneID,
              currentTerminalKey(key.paneID, in: session) == key,
              let presentation = terminalSurfaces.presentation(for: key), presentation.window === window else { return }
        initialTerminalFocus = nil
        // Do not interrupt an editor or a terminal the user chose during startup.
        if window.firstResponder is NSTextView || window.firstResponder is TerminalView { return }
        _ = window.makeFirstResponder(presentation.view)
    }

    func focusTerminal(_ key: TerminalLaunch.Key) {
        guard let session = selectedSession, session.sessionId == key.sessionID else { return }
        let snapshot = key.paneID == session.pi.paneId ? presentationSnapshot(for: session)
            : session.shellPanes.first(where: { $0.paneId == key.paneID })?.terminal
        guard let snapshot, let current = try? terminalLaunch(for: snapshot, sessionID: session.sessionId),
              current.key == key else { return }
        paneLayouts.focus(key.paneID, in: .init(machineID: key.machineID, sessionID: key.sessionID))
    }

    func capturePaneFocus(_ direction: AxodPaneFocusDirection, in window: NSWindow) -> AxodPaneFocus? {
        guard let view = window.firstResponder as? TerminalView, let source = terminalSurfaces.presentation(for: view),
              source.window === window, let session = selectedSession,
              currentTerminalKey(source.key.paneID, in: session) == source.key else { return nil }
        let identity = AxodPaneLayouts.Session(machineID: source.key.machineID, sessionID: session.sessionId)
        guard let move = paneLayouts.captureFocus(from: source.key.paneID, direction: direction, in: identity),
              let destinationKey = currentTerminalKey(move.destination, in: session),
              let destination = terminalSurfaces.presentation(for: destinationKey), destination.window === window,
              destination.viewportID == source.viewportID else { return nil }
        return AxodPaneFocus(move: move, source: source.key, destination: destinationKey, viewportID: source.viewportID, responderGeneration: source.view.focusGeneration, window: window)
    }
    @discardableResult func focusPane(_ direction: AxodPaneFocusDirection, in window: NSWindow) -> Bool {
        guard let request = capturePaneFocus(direction, in: window) else { return false }
        return applyPaneFocus(request)
    }
    @discardableResult func applyPaneFocus(_ request: AxodPaneFocus) -> Bool {
        guard let window = request.window, let session = selectedSession, paneLayouts.isCurrent(request.move),
              currentTerminalKey(request.source.paneID, in: session) == request.source,
              currentTerminalKey(request.destination.paneID, in: session) == request.destination,
              let source = terminalSurfaces.presentation(for: request.source), let destination = terminalSurfaces.presentation(for: request.destination),
              source.window === window, destination.window === window, window.firstResponder === source.view,
              source.view.focusGeneration == request.responderGeneration,
              source.viewportID == request.viewportID, destination.viewportID == request.viewportID else { return false }
        return window.makeFirstResponder(destination.view)
    }
    private func currentTerminalKey(_ paneID: UUID, in session: WorkSessionRecord) -> TerminalLaunch.Key? {
        let snapshot = paneID == session.pi.paneId ? presentationSnapshot(for: session)
            : session.shellPanes.first(where: { $0.paneId == paneID })?.terminal
        guard let snapshot else { return nil }
        return try? terminalLaunch(for: snapshot, sessionID: session.sessionId).key
    }

    func refreshChat() {
        guard let target = chatTarget, let connection, let endpoint,
              selectedSessionID == target.sessionId else { return }
        let readMode: PiReadMode
        switch selectedSession?.pi.admission {
        case .ready: readMode = .live
        case .stopped, .failed: readMode = .stopped
        default:
            chatStatusMessage = "This session is not in a readable Pi state."
            return
        }
        let operation = operationGeneration
        let load = UUID()
        chatLoadGeneration = load
        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.fetchChatSnapshot(
                    target: target, readMode: readMode, over: connection, endpoint: endpoint, operation: operation
                )
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint),
                      self.chatLoadGeneration == load, self.chatTarget == target else { return }
                try self.applyRecentChatSnapshot(snapshot)
                self.chatSnapshot = snapshot
                self.chatStatusMessage = "Showing Pi-owned canonical history. A dispatched message is not proof of execution."
                self.beginChatObservation(target: target, readMode: readMode, load: load, over: connection, endpoint: endpoint, operation: operation)
            } catch {
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint),
                      self.chatLoadGeneration == load else { return }
                self.chatStatusMessage = "The captured Pi history could not be read. Refresh to reconcile this exact session."
            }
        }
    }

    func showRecentChatHistory(source: AxodChatHistoryWindow.Source) {
        guard historyWindow.source == source else { return }
        historyWindow.showRecent()
        historyPageTask?.cancel()
    }

    func loadChatHistoryPage(snapshot: PiChatSnapshot, movement: AxodChatHistoryWindow.Movement, presentationID: UUID) {
        let source = AxodChatHistoryWindow.Source(target: snapshot.target, readMode: snapshot.readMode)
        guard historyWindow.source == source else { return }
        guard canReadSelectedChat(target: source.target, readMode: source.readMode) else { historyWindow.invalidateSource(); return }
        guard let connection, let endpoint, let ticket = historyWindow.begin(movement, presentationID: presentationID) else { return }
        let operation = operationGeneration
        historyPageTask = Task { [weak self] in
            guard let self else { return }
            defer { self.historyPageTask = nil }
            do {
                try Task.checkCancellation()
                try self.stateDirectory?.requireCurrentEndpoint(endpoint)
                let result = try await self.fetchChatHistory(target: source.target, readMode: source.readMode, cursor: ticket.cursor,
                    over: connection, endpoint: endpoint, operation: operation)
                try Task.checkCancellation()
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint),
                      self.canReadSelectedChat(target: source.target, readMode: source.readMode) else { self.historyWindow.fail(ticket, issue: .unavailable); return }
                try self.stateDirectory?.requireCurrentEndpoint(endpoint)
                self.historyWindow.complete(ticket, result: result)
            } catch {
                let issue: AxodChatHistoryWindow.Issue
                if case AxoJSONRPCClientError.remote(let code, _) = error, code == -32002 { issue = .headChanged }
                else { issue = error is CancellationError ? .unavailable : .failed }
                self.historyWindow.fail(ticket, issue: issue)
            }
        }
    }

    private func applyRecentChatSnapshot(_ snapshot: PiChatSnapshot) throws {
        guard snapshot.recentEntries.count <= 10,
              AxodChatHistoryWindow.fits(snapshot.recentEntries, bytes: AxodChatHistoryWindow.maximumRecentBytes) else {
            throw AxoProtocolValidationError.invalidResult(method: AxoProtocol.Method.getChat)
        }
        chatEntries = snapshot.recentEntries
        historyWindow.observe(snapshot)
    }

    func openToolOutput(entry: PiCanonicalProjection, snapshot: PiChatSnapshot) {
        guard let source = AxodToolOutput.Source(entry: entry, snapshot: snapshot),
              chatSnapshot?.target == snapshot.target, chatSnapshot?.readMode == snapshot.readMode,
              displayedChatEntries.contains(where: { $0.entryId == source.entryID && $0.toolCallId == source.toolCallID && $0.role == "toolResult" }),
              canReadToolOutput(source), let ticket = toolOutput.open(source) else { return }
        readToolOutput(ticket)
    }

    func loadToolOutput(source: AxodToolOutput.Source, movement: AxodToolOutput.Movement) {
        guard toolOutput.source == source else { return }
        guard canReadToolOutput(source) else { toolOutput.invalidateSource(); return }
        guard let ticket = toolOutput.begin(movement) else { return }
        readToolOutput(ticket)
    }

    func closeToolOutput() {
        toolOutput.close()
        toolOutputTask?.cancel()
    }

    private func canReadToolOutput(_ source: AxodToolOutput.Source) -> Bool {
        canReadSelectedChat(target: source.target, readMode: source.readMode)
    }
    private func canReadSelectedChat(target: PiChatTarget, readMode: PiReadMode) -> Bool {
        guard connectionState == .connected, let endpoint, let session = selectedSession,
              endpoint.machineId == target.machineId, endpoint.hostGeneration == target.hostGeneration,
              session.sessionId == target.sessionId, session.workspaceId == target.workspaceId,
              session.pi.paneId == target.paneId, session.pi.chatId == target.chatId,
              session.runtime?.runtime == target.runtime else { return false }
        switch (readMode, session.pi.admission) {
        case (.live, .ready), (.stopped, .stopped), (.stopped, .failed): return true
        default: return false
        }
    }

    private func readToolOutput(_ ticket: AxodToolOutput.Ticket) {
        guard let connection, let endpoint else { toolOutput.fail(ticket, issue: .unavailable); return }
        let operation = operationGeneration
        toolOutputTask = Task { [weak self] in
            guard let self else { return }
            defer { self.toolOutputTask = nil }
            do {
                try Task.checkCancellation()
                guard self.canReadToolOutput(ticket.source) else { throw CancellationError() }
                try self.stateDirectory?.requireCurrentEndpoint(endpoint)
                let value = try await connection.request(method: AxoProtocol.Method.getToolOutput, parameters: ticket.parameters)
                let page = try PiProtocolValidator.toolOutput(value, target: ticket.source.target, readMode: ticket.source.readMode,
                    entryId: ticket.source.entryID, toolCallId: ticket.source.toolCallID, offset: ticket.offset)
                try Task.checkCancellation()
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint), self.canReadToolOutput(ticket.source) else { self.toolOutput.fail(ticket, issue: .unavailable); return }
                try self.stateDirectory?.requireCurrentEndpoint(endpoint)
                self.toolOutput.complete(ticket, page: page)
            } catch {
                self.toolOutput.fail(ticket, issue: error is CancellationError ? .unavailable : .failed)
            }
        }
    }

    func loadMoreWorkspaces() {
        guard let cursor = nextWorkspaceCursor, let connection, let endpoint else { return }
        let operation = operationGeneration
        let refresh = refreshGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.fetchWorkspaces(
                    cursor: cursor,
                    over: connection,
                    endpoint: endpoint,
                    operation: operation
                )
                guard self.isCurrent(operation, refresh: refresh, connection: connection, endpoint: endpoint) else { return }
                self.workspaces.append(contentsOf: result.workspaces)
                self.nextWorkspaceCursor = result.next
            } catch {
                self.connectionFailed(error, operation: operation, connection: connection)
            }
        }
    }

    func loadMoreSessions() {
        guard let cursor = nextSessionCursor,
              let workspaceID = selectedWorkspaceID,
              let connection, let endpoint else { return }
        let operation = operationGeneration
        let load = sessionLoadGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.fetchSessions(
                    workspaceID: workspaceID,
                    cursor: cursor,
                    over: connection,
                    endpoint: endpoint,
                    operation: operation
                )
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint),
                      self.sessionLoadGeneration == load,
                      self.selectedWorkspaceID == workspaceID else { return }
                self.sessions.append(contentsOf: result.sessions)
                if self.selectedSessionID == nil {
                    self.selectedSessionID = result.sessions.first?.sessionId
                    self.preferredSessionID = self.selectedSessionID
                    self.saveSelection()
                    self.activateSelectedSession()
                }
                self.nextSessionCursor = result.next
            } catch {
                guard self.operationGeneration == operation,
                      self.sessionLoadGeneration == load else { return }
                self.message = "This session page is stale. Refresh the workspace before loading more."
            }
        }
    }

    func loadMoreRuntimes() {
        guard let after = nextRuntimeID, let connection, let endpoint else { return }
        let operation = operationGeneration
        let refresh = refreshGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.fetchRuntimes(
                    after: after,
                    over: connection,
                    endpoint: endpoint,
                    operation: operation
                )
                guard self.isCurrent(operation, refresh: refresh, connection: connection, endpoint: endpoint) else { return }
                self.runtimes.append(contentsOf: result.terminals)
                self.nextRuntimeID = result.next
            } catch {
                self.connectionFailed(error, operation: operation, connection: connection)
            }
        }
    }

    private func bootstrapAndConnect(operation: UUID) async {
        let observation = serviceLifecycle.beginObservation()
        serviceObservation = observation
        do {
            let directory: AxodStateDirectory
#if DEBUG
            if let context = bundledDaemon.selfTest {
                directory = try AxodStateDirectory.openExisting(root: context.state)
                try bundledDaemon.startSelfTest(in: directory)
            } else { directory = try AxodStateDirectory.prepare() }
#else
            directory = try AxodStateDirectory.prepare()
#endif
            try requireCurrent(operation)
            stateDirectory = directory
            try requireCurrent(operation)
            if !usesFixtureDaemon { try serviceLifecycle.requireEnabled() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            var delay = 100
            while ContinuousClock.now < deadline {
                try requireCurrent(operation)
                if let discovered = try directory.readEndpoint() {
                    do {
                        try await connect(to: discovered, stateDirectory: directory, operation: operation, readinessDeadline: deadline)
                        try requireCurrent(operation)
                        return
                    } catch AxodWorkbenchError.protocolMismatch { throw AxodWorkbenchError.protocolMismatch }
                    catch {
                        try requireCurrent(operation)
                        // Read-only discovery/negotiation retries. No register,
                        // unregister, spawn, handoff or command replay is reachable.
                    }
                }
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else { break }
                let jittered = min(2000, delay * Int.random(in: 80...120) / 100)
                try await Task.sleep(for: min(.milliseconds(jittered), remaining))
                delay = min(2000, delay * 2)
            }
            throw AxodWorkbenchError.startupTimedOut
        } catch {
            guard operationGeneration == operation else { return }
            serviceLifecycle.observedUnavailable(observation: observation)
            connectionState = .failed(error.localizedDescription)
            message = error.localizedDescription
        }
    }

    private func connect(
        to endpoint: LocalDaemonEndpoint,
        stateDirectory: AxodStateDirectory,
        operation: UUID,
        readinessDeadline: ContinuousClock.Instant? = nil
    ) async throws {
        try requireCurrent(operation)
        let connection = try rpc.openLocalWebSocket(endpoint: endpoint)
        self.endpoint = endpoint
        self.connection = connection
        do {
            let negotiation = try await connection.request(
                method: AxoProtocol.Method.negotiate,
                parameters: NegotiationParameters(), timeout: try readinessTimeout(until: readinessDeadline)
            )
            do { _ = try AxoProtocolResultValidator.localNegotiation(negotiation) }
            catch { throw AxodWorkbenchError.protocolMismatch }
            let source = MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration)
            let hostValue = try await connection.request(method: AxoProtocol.Method.getHost,
                parameters: HostGetParameters(target: source), timeout: try readinessTimeout(until: readinessDeadline))
            let status = try AxoProtocolResultValidator.host(hostValue, target: source)
            try requireCurrent(operation)
            try stateDirectory.requireCurrentEndpoint(endpoint)
#if DEBUG
            if bundledDaemon.selfTest != nil {
                guard status.daemonVersion == Bundle.main.infoDictionary?["AxoBundledAxodVersion"] as? String else {
                    throw AxoProtocolValidationError.invalidResult(method: AxoProtocol.Method.getHost)
                }
            }
#endif
            hostStatus = status
            updateHelperObservation(status)
            if let serviceObservation { serviceLifecycle.observedReady(source, observation: serviceObservation) }
            guard isCurrent(operation, connection: connection, endpoint: endpoint) else { throw AxodWorkbenchError.superseded }
            try stateDirectory.requireCurrentEndpoint(endpoint)

            let runtimes = try await fetchRuntimes(
                after: nil,
                over: connection,
                endpoint: endpoint,
                operation: operation
            )
            let workspaces = try await fetchWorkspaces(
                cursor: nil,
                over: connection,
                endpoint: endpoint,
                operation: operation
            )
            guard isCurrent(operation, connection: connection, endpoint: endpoint) else {
                throw AxodWorkbenchError.superseded
            }

            if preferredMachineID != endpoint.machineId {
                preferredWorkspaceID = nil
                preferredSessionID = nil
            }
            machineID = endpoint.machineId
            preferredMachineID = endpoint.machineId
            self.endpoint = endpoint
            self.connection = connection
            self.runtimes = runtimes.terminals
            self.nextRuntimeID = runtimes.next
            self.workspaces = workspaces.workspaces
            self.nextWorkspaceCursor = workspaces.next
            self.selectedWorkspaceID = preferredWorkspaceID.flatMap { savedID in
                workspaces.workspaces.first(where: { $0.workspaceId == savedID })?.workspaceId
            } ?? workspaces.workspaces.first?.workspaceId
            if preferredWorkspaceID != nil && selectedWorkspaceID != preferredWorkspaceID {
                preferredSessionID = nil
            }
            preferredWorkspaceID = selectedWorkspaceID
            self.sessions = []
            self.selectedSessionID = nil
            self.nextSessionCursor = nil
            connectionState = .connected
            observeHost(over: connection, endpoint: endpoint, operation: operation)
            message = "Connected to axod."
            await loadInitialSessions(selectedWorkspaceID, over: connection, endpoint: endpoint, operation: operation)
            try requireCurrent(operation)
        } catch {
            await connection.close()
            if self.connection === connection { self.connection = nil }
            if self.endpoint == endpoint { self.endpoint = nil }
            throw error
        }
    }

    private func refreshFirstPages(
        over connection: AxoJSONRPCWebSocketConnection,
        endpoint: LocalDaemonEndpoint,
        operation: UUID,
        refresh: UUID
    ) async throws {
        let runtimes = try await fetchRuntimes(after: nil, over: connection, endpoint: endpoint, operation: operation)
        let workspaces = try await fetchWorkspaces(cursor: nil, over: connection, endpoint: endpoint, operation: operation)
        guard isCurrent(operation, refresh: refresh, connection: connection, endpoint: endpoint) else { return }
        self.runtimes = runtimes.terminals
        nextRuntimeID = runtimes.next
        self.workspaces = workspaces.workspaces
        nextWorkspaceCursor = workspaces.next
        if let selectedWorkspaceID, !workspaces.workspaces.contains(where: { $0.workspaceId == selectedWorkspaceID }) {
            self.selectedWorkspaceID = workspaces.workspaces.first?.workspaceId
        }
        await loadInitialSessions(selectedWorkspaceID, over: connection, endpoint: endpoint, operation: operation)
    }

    private func loadInitialSessions(
        _ workspaceID: UUID?,
        over connection: AxoJSONRPCWebSocketConnection,
        endpoint: LocalDaemonEndpoint,
        operation: UUID
    ) async {
        guard isCurrent(operation, connection: connection, endpoint: endpoint),
              selectedWorkspaceID == workspaceID else { return }
        let load = UUID()
        sessionLoadGeneration = load
        do {
            let catalog = try await fetchSessionCatalog(over: connection, endpoint: endpoint, operation: operation)
            guard isCurrent(operation, connection: connection, endpoint: endpoint),
                  selectedWorkspaceID == workspaceID,
                  sessionLoadGeneration == load else { return }
            sessions = catalog.sessions
            catalogRevision = catalog.revision
            if let preferredSessionID, let preferred = catalog.sessions.first(where: { $0.sessionId == preferredSessionID }) {
                selectedSessionID = preferredSessionID
                selectedWorkspaceID = preferred.workspaceId
            } else {
                selectedSessionID = catalog.sessions.first(where: { $0.workspaceId == workspaceID })?.sessionId
            }
            preferredWorkspaceID = selectedWorkspaceID
            preferredSessionID = selectedSessionID
            nextSessionCursor = nil
            saveSelection()
            activateSelectedSession()
        } catch {
            guard operationGeneration == operation else { return }
            message = "Connected, but the selected workspace's session page could not be read."
        }
    }

    private func activateSelectedSession() {
        // An immutable tool entry is not a branch-page cursor. Keep its explicit reader
        // across metadata-only refresh while the full selected writer/read mode is unchanged.
        let preserveSnapshot = chatSnapshot.map {
            chatTarget == $0.target && canReadSelectedChat(target: $0.target, readMode: $0.readMode)
        } ?? false
        stopChatObservation(preservingToolOutput: toolOutput.source.map(canReadToolOutput) ?? false,
            preservingHistory: historyWindow.source.map { canReadSelectedChat(target: $0.target, readMode: $0.readMode) } ?? false)
        // Metadata-only refresh must not blank an unchanged rendered binding/editor.
        // A changed namespace/admission still clears it before any async read.
        if !preserveSnapshot { chatTarget = nil; chatSnapshot = nil; chatEntries = [] }
        guard let session = selectedSession, let endpoint else {
            stopChatObservation()
            chatTarget = nil
            chatSnapshot = nil
            chatEntries = []
            chatStatusMessage = "Select an admitted Pi session to view its canonical conversation."
            return
        }
        paneLayouts.observe(session, machineID: endpoint.machineId)
        switch session.pi.admission {
        case .notAdmitted:
            chatTarget = nil
            chatSnapshot = nil
            chatEntries = []
            chatStatusMessage = "This session has no admitted Pi conversation yet."
            return
        case .recoveryRequired:
            chatTarget = nil
            chatSnapshot = nil
            chatEntries = []
            chatStatusMessage = "Axod cannot prove the Pi writer stopped. Recovery is required before history or resume."
            return
        case .ready, .stopped, .failed:
            break
        }
        guard let chatID = session.pi.chatId, let runtime = session.runtime?.runtime else {
            chatTarget = nil
            chatSnapshot = nil
            chatEntries = []
            chatStatusMessage = "The admitted Pi binding/runtime is incomplete. No new chat was created."
            return
        }
        let target = PiChatTarget(
            machineId: endpoint.machineId,
            hostGeneration: endpoint.hostGeneration,
            workspaceId: session.workspaceId,
            sessionId: session.sessionId,
            paneId: session.pi.paneId,
            runtimeHostGeneration: runtime.hostGeneration,
            runtimeGeneration: runtime.runtimeGeneration,
            chatId: chatID
        )
        switch session.pi.admission {
        case .ready, .stopped, .failed:
            chatTarget = target
            refreshChat()
        case .notAdmitted, .recoveryRequired:
            return
        }
    }

    private func fetchChatSnapshot(
        target: PiChatTarget,
        readMode: PiReadMode,
        over connection: AxoJSONRPCWebSocketConnection,
        endpoint: LocalDaemonEndpoint,
        operation: UUID
    ) async throws -> PiChatSnapshot {
        let parameters = PiChatGetParameters(target: target, readMode: readMode)
        let value = try await connection.request(method: AxoProtocol.Method.getChat, parameters: parameters)
        let result = try PiProtocolValidator.chatGet(value, target: target, readMode: readMode)
        try requireCurrent(operation)
        try stateDirectory?.requireCurrentEndpoint(endpoint)
        return result
    }

    private func fetchChatHistory(
        target: PiChatTarget,
        readMode: PiReadMode,
        cursor: PiHistoryCursor?,
        over connection: AxoJSONRPCWebSocketConnection,
        endpoint: LocalDaemonEndpoint,
        operation: UUID
    ) async throws -> PiChatHistoryResult {
        let parameters = PiChatHistoryParameters(target: target, readMode: readMode, cursor: cursor)
        let value = try await connection.request(method: AxoProtocol.Method.getChatHistory, parameters: parameters)
        let result = try PiProtocolValidator.chatHistory(value, target: target, readMode: readMode, cursor: cursor)
        try requireCurrent(operation)
        try stateDirectory?.requireCurrentEndpoint(endpoint)
        return result
    }

    private func beginChatObservation(
        target: PiChatTarget,
        readMode: PiReadMode,
        load: UUID,
        over connection: AxoJSONRPCWebSocketConnection,
        endpoint: LocalDaemonEndpoint,
        operation: UUID
    ) {
        chatObservationTask?.cancel()
        chatObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                do {
                    let snapshot = try await self.fetchChatSnapshot(
                        target: target, readMode: readMode, over: connection, endpoint: endpoint, operation: operation
                    )
                    guard self.isCurrent(operation, connection: connection, endpoint: endpoint),
                          self.chatLoadGeneration == load, self.chatTarget == target else { return }
                    if self.chatSnapshot?.leafId != snapshot.leafId {
                        self.refreshChat()
                        return
                    }
                    try self.applyRecentChatSnapshot(snapshot)
                    self.chatSnapshot = snapshot
                } catch {
                    guard self.isCurrent(operation, connection: connection, endpoint: endpoint) else { return }
                    self.chatStatusMessage = "Live Pi refresh failed. No command was replayed."
                    return
                }
            }
        }
    }

    private func stopChatObservation(preservingToolOutput: Bool = false, preservingHistory: Bool = false) {
        if !preservingToolOutput { closeToolOutput() }
        if !preservingHistory { historyWindow.close(); historyPageTask?.cancel() }
        chatObservationTask?.cancel()
        chatObservationTask = nil
        chatLoadGeneration = UUID()
    }

    private func saveSelection() {
        guard let machineID else { return }
        preferredMachineID = machineID
        preferredWorkspaceID = selectedWorkspaceID
        preferences.set(machineID.uuidString, forKey: PreferenceKey.machineID)
        preferences.set(selectedWorkspaceID?.uuidString ?? "", forKey: PreferenceKey.workspaceID)
        preferences.set(selectedSessionID?.uuidString ?? "", forKey: PreferenceKey.sessionID)
    }

    private func fetchWorkspaces(
        cursor: WorkPageCursor?,
        over connection: AxoJSONRPCWebSocketConnection,
        endpoint: LocalDaemonEndpoint,
        operation: UUID
    ) async throws -> WorkspaceListResult {
        let target = MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration)
        let parameters = WorkspaceListParameters(target: target, cursor: cursor)
        try AxoProtocolWorkRequestValidator.validate(parameters)
        let value = try await connection.request(method: AxoProtocol.Method.listWorkspaces, parameters: parameters)
        let result = try AxoProtocolResultValidator.workspaceList(value, target: target, cursor: cursor)
        try requireCurrent(operation)
        try stateDirectory?.requireCurrentEndpoint(endpoint)
        return result
    }

    private struct SessionCatalog {
        let sessions: [WorkSessionRecord]
        let revision: WorkRevision
    }
    private func fetchSessionCatalog(over connection: AxoJSONRPCWebSocketConnection,
                                     endpoint: LocalDaemonEndpoint, operation: UUID) async throws -> SessionCatalog {
        var sessions: [WorkSessionRecord] = []
        var seen = Set<UUID>()
        var cursor: WorkPageCursor?
        var revision: WorkRevision?
        repeat {
            let page = try await fetchSessions(workspaceID: nil, cursor: cursor, over: connection,
                                               endpoint: endpoint, operation: operation)
            guard revision == nil || revision == page.revision,
                  sessions.count + page.sessions.count <= 1000,
                  page.sessions.allSatisfy({ seen.insert($0.sessionId).inserted }),
                  page.next == nil || !page.sessions.isEmpty else {
                throw AxoProtocolValidationError.invalidResult(method: AxoProtocol.Method.listSessions)
            }
            revision = page.revision
            sessions.append(contentsOf: page.sessions)
            cursor = page.next
        } while cursor != nil
        guard let revision else { throw AxoProtocolValidationError.invalidResult(method: AxoProtocol.Method.listSessions) }
        return SessionCatalog(sessions: sessions, revision: revision)
    }

    private func fetchSessions(
        workspaceID: UUID?,
        cursor: WorkPageCursor?,
        over connection: AxoJSONRPCWebSocketConnection,
        endpoint: LocalDaemonEndpoint,
        operation: UUID
    ) async throws -> SessionListResult {
        let target = MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration)
        let parameters = SessionListParameters(target: target, workspaceId: workspaceID, cursor: cursor)
        try AxoProtocolWorkRequestValidator.validate(parameters)
        let value = try await connection.request(method: AxoProtocol.Method.listSessions, parameters: parameters)
        let result = try AxoProtocolResultValidator.sessionList(
            value,
            target: target,
            workspaceID: workspaceID,
            cursor: cursor
        )
        try requireCurrent(operation)
        try stateDirectory?.requireCurrentEndpoint(endpoint)
        return result
    }

    private func fetchRuntimes(
        after: UUID?,
        over connection: AxoJSONRPCWebSocketConnection,
        endpoint: LocalDaemonEndpoint,
        operation: UUID
    ) async throws -> RuntimeListResult {
        let target = MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration)
        let value = try await connection.request(
            method: AxoProtocol.Method.listRuntimes,
            parameters: RuntimeListParameters(target: target, after: after)
        )
        let result = try AxoProtocolResultValidator.runtimeList(value, target: target)
        try requireCurrent(operation)
        try stateDirectory?.requireCurrentEndpoint(endpoint)
        return result
    }

    private func readinessTimeout(until deadline: ContinuousClock.Instant?) throws -> TimeInterval {
        guard let deadline else { return 2 }
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        guard seconds > 0 else { throw AxodWorkbenchError.startupTimedOut }
        return min(2, seconds)
    }

    private func updateHelperObservation(_ status: HostStatusResult) {
        // Build mismatch is metadata, not permission to freeze or replace work.
        // The negotiated protocol and each method's validator determine support.
        helperUpdateAvailable = status.daemonVersion != Bundle.main.infoDictionary?["AxoBundledAxodVersion"] as? String
    }

    private func isCurrent(
        _ operation: UUID,
        connection: AxoJSONRPCWebSocketConnection,
        endpoint: LocalDaemonEndpoint
    ) -> Bool {
        operationGeneration == operation && self.connection === connection && self.endpoint == endpoint
    }

    private func isCurrent(
        _ operation: UUID,
        refresh: UUID,
        connection: AxoJSONRPCWebSocketConnection,
        endpoint: LocalDaemonEndpoint
    ) -> Bool {
        isCurrent(operation, connection: connection, endpoint: endpoint) && refreshGeneration == refresh
    }

    private func observeHost(over connection: AxoJSONRPCWebSocketConnection, endpoint: LocalDaemonEndpoint, operation: UUID) {
        hostObservationTask?.cancel()
        hostObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let value = try await connection.request(method: AxoProtocol.Method.getHost, parameters: HostGetParameters(target: MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration)))
                    guard let self, self.isCurrent(operation, connection: connection, endpoint: endpoint) else { return }
                    try self.stateDirectory?.requireCurrentEndpoint(endpoint)
                    let status = try AxoProtocolResultValidator.host(value, target: MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration))
                    self.hostStatus = status
                    self.updateHelperObservation(status)
                    if let selected = self.selectedSessionID,
                       let record = self.sessions.first(where: { $0.sessionId == selected }) {
                        let destination = WorkSessionTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration,
                                                            workspaceId: record.workspaceId, sessionId: selected)
                        let metadata = try await connection.request(method: AxoProtocol.Method.getSession,
                                                                    parameters: SessionGetParameters(target: destination))
                        let updated = try AxoProtocolResultValidator.sessionGet(metadata, target: destination).session
                        guard self.isCurrent(operation, connection: connection, endpoint: endpoint) else { return }
                        try self.stateDirectory?.requireCurrentEndpoint(endpoint)
                        if let index = self.sessions.firstIndex(where: { $0.sessionId == selected }) {
                            self.sessions[index] = updated
                        }
                    }
                } catch {
                    guard let self, self.isCurrent(operation, connection: connection, endpoint: endpoint) else { return }
                    self.hostStatus = nil // Unknown/unavailable is never cloud-online.
                    if let rpcError = error as? AxoJSONRPCClientError {
                        switch rpcError {
                        case .disconnected, .outcomeUnknown:
                            self.connectionFailed(error, operation: operation, connection: connection)
                            return
                        default: break
                        }
                    }
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func connectionFailed(
        _ error: Error,
        operation: UUID,
        connection: AxoJSONRPCWebSocketConnection
    ) {
        guard operationGeneration == operation, self.connection === connection else { return }
#if AXO_NATIVE_FIXTURE
        let fault: String
        switch error {
        case AxoProtocolValidationError.invalidResult(let method):
            let allowed = [AxoProtocol.Method.listRuntimes, AxoProtocol.Method.listSessions, AxoProtocol.Method.listWorkspaces,
                AxoProtocol.Method.getSession, AxoProtocol.Method.getChat, AxoProtocol.Method.getChatHistory, AxoProtocol.Method.getHost]
            fault = allowed.contains(method) ? "InvalidResult(\(method))" : "InvalidResult"
        case AxoProtocolValidationError.staleHost: fault = "StaleHost"
        case AxoJSONRPCClientError.frameTooLarge: fault = "FrameTooLarge"
        case AxoJSONRPCClientError.pendingCallLimit: fault = "PendingCallLimit"
        case AxoJSONRPCClientError.disconnected: fault = "Disconnected"
        case AxoJSONRPCClientError.outcomeUnknown: fault = "OutcomeUnknown"
        case AxoJSONRPCClientError.remote(let code, _): fault = "RemoteCode(\(code))"
        case AxoJSONRPCClientError.malformedResponse: fault = "MalformedResponse"
        case AxoJSONRPCClientError.mismatchedResponseID: fault = "MismatchedResponseID"
        case AxodWorkbenchError.superseded: fault = "Superseded"
        default: fault = "Other"
        }
        fputs("Owned native control connection failure: class=\(fault) sessionCount=\(sessions.count) runtimeCount=\(runtimes.count)\n", stderr)
#endif
        self.connection = nil
        endpoint = nil
        hostObservationTask?.cancel()
        hostStatus = nil
        workspaces = []; sessions = []; runtimes = []
        nextWorkspaceCursor = nil; nextSessionCursor = nil; nextRuntimeID = nil
        selectedWorkspaceID = nil; selectedSessionID = nil
        stopChatObservation()
        chatTarget = nil; chatSnapshot = nil; chatEntries = []
        if let serviceObservation { serviceLifecycle.observedUnavailable(observation: serviceObservation) }
        connectionState = .failed("Local daemon connection lost")
        message = "Connection lost. Reconnect to inspect the daemon; no work was replayed."
        Task { await connection.close() }
    }

    private func requireCurrent(_ operation: UUID) throws {
        guard operationGeneration == operation else { throw AxodWorkbenchError.superseded }
    }
}

private enum AxodWorkbenchError: Error, LocalizedError {
    case protocolMismatch
    case superseded
    case startupTimedOut

    var errorDescription: String? {
        switch self {
        case .protocolMismatch: "The discovered daemon speaks an incompatible local protocol. It was left untouched."
        case .superseded: "A newer connection operation replaced this result."
        case .startupTimedOut: "The registered Axod service did not become ready. Check Background Service settings and startup diagnostics. Reconnect did not launch, replace, or restart any work."
        }
    }
}
