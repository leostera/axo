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
        static let pendingStartPrefix = "Axo.axod.pendingStart."
        static let pendingChatPrefix = "Axo.axod.pendingChat."
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
    private(set) var pendingChatCommandId: UUID?
    private(set) var pendingPiStartCommandID: UUID?
    var workEditor: AxodWorkEditorContext?
    private var activeCreationContext: AxodWorkEditorContext?
    private(set) var isEditingWork = false
    private(set) var activeWorkRename: AxodWorkRename?
    var isRenamingWork: Bool { activeWorkRename != nil }
    private(set) var workEditMessage = "Create a session and start your ambient Pi."
    private(set) var emptyStartupMessage: String?
    private(set) var createdSessionForEditor: WorkSessionRecord?
    private(set) var pendingWorkCommandID: UUID?
    private(set) var pendingWorkIsUnreadable = false
    private(set) var sessionDeletionConfirmation: AxodSessionDeletion?
    var canEditWork: Bool { connectionState == .connected && !isEditingWork && !isRenamingWork && pendingWorkCommandID == nil && !pendingWorkIsUnreadable && sessionDeletionConfirmation == nil && !hasPendingSessionDeletion }
    private var hasPendingSessionDeletion: Bool { machineID.map { preferences.object(forKey: pendingDeletionKey($0)) != nil } ?? false }
    private(set) var isStartingPi = false
    private(set) var isSendingPiMessage = false
    private var piMutationGeneration: UUID?
    let chatDrafts = AxodChatDrafts(requiresPersistence: true)
    private(set) var isReconcilingPiCommand = false

    @ObservationIgnored let preferences: UserDefaults
    @ObservationIgnored private var preferredMachineID: UUID?
    @ObservationIgnored private var preferredWorkspaceID: UUID?
    @ObservationIgnored private var preferredSessionID: UUID?
    @ObservationIgnored private var initialTerminalFocus: WorkSessionTarget?
    let terminalSurfaces = AxodTerminalSurfaces()
    let shellCreation: AxodShellCreation
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
        self.shellCreation = AxodShellCreation(preferences: preferences)
        self.paneLayouts = AxodPaneLayouts(preferences: preferences)
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
        if requestedEmptyLaunch && !consumedEmptyLaunch {
            requestedEmptyLaunch = false
            consumedEmptyLaunch = true
            finishInitialConnection(operation: operation, allowEmptyLaunch: true)
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

    @ObservationIgnored private var consumedEmptyLaunch = false
    @ObservationIgnored private var requestedEmptyLaunch = false

    func connect(createInitialSession: Bool = false) {
        if createInitialSession { requestedEmptyLaunch = true }
        guard connectTask == nil else { return }
        let allowEmptyLaunch = requestedEmptyLaunch && !consumedEmptyLaunch
        let operation = UUID()
        operationGeneration = operation
        let oldConnection = connection
        connection = nil
        endpoint = nil
        activeWorkRename = nil
        isEditingWork = false
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
                if !self.showsSetup {
                    if allowEmptyLaunch { self.consumedEmptyLaunch = true; self.requestedEmptyLaunch = false }
                    self.finishInitialConnection(operation: operation, allowEmptyLaunch: allowEmptyLaunch)
                }
            }
        }
    }

    private func finishInitialConnection(operation: UUID, allowEmptyLaunch: Bool) {
        guard allowEmptyLaunch, operationGeneration == operation, connectionState == .connected else { return }
        if canEditWork, workspaces.isEmpty, sessions.isEmpty, runtimes.isEmpty,
           nextWorkspaceCursor == nil, nextSessionCursor == nil, nextRuntimeID == nil,
           let revision = catalogRevision, let endpoint,
           !AxodEmptyStartupPolicy.hasPendingIntent(in: preferences, machineID: endpoint.machineId),
           !chatDrafts.blocksAutomaticStartup, !chatDrafts.hasPending(machineID: endpoint.machineId) {
            let context = AxodWorkEditorContext(kind: .session(workspaceID: nil),
                target: MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration),
                revision: revision, authority: .emptyAppLaunch)
            createdSessionForEditor = nil
            activeCreationContext = context
            emptyStartupMessage = "Creating an empty-startup session. No work will be replayed."
            createWork(context, name: "New Session", directory: nil)
        } else if sessions.isEmpty, workspaces.isEmpty, let endpoint,
                  AxodEmptyStartupPolicy.hasPendingIntent(in: preferences, machineID: endpoint.machineId) ||
                  chatDrafts.blocksAutomaticStartup || chatDrafts.hasPending(machineID: endpoint.machineId) {
            emptyStartupMessage = "Automatic startup was not sent: saved unresolved intent or unavailable draft storage requires reconciliation. Existing data and work were preserved."
        }
    }

#if AXO_NATIVE_FIXTURE
    /// Compile-only isolation seam: absent from the shipped app. Rust owns the
    /// disposable daemon/root; this skips service registration, not protocol/UI paths.
    func connectOwnedFixture(root: URL, helper: URL, appLaunch: Bool = false) async throws {
        guard connection == nil else { throw AxodWorkbenchError.superseded }
        usesFixtureDaemon = true
        let directory = try AxodStateDirectory.openExisting(root: root)
        guard let discovered = try directory.readEndpoint() else { throw AxodWorkbenchError.startupTimedOut }
        stateDirectory = directory
        fixtureAttachmentHelper = helper
        let operation = UUID()
        operationGeneration = operation
        let allowed = appLaunch && !consumedEmptyLaunch
        if appLaunch { consumedEmptyLaunch = true }
        try await connect(to: discovered, stateDirectory: directory, operation: operation)
        finishInitialConnection(operation: operation, allowEmptyLaunch: allowed)
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
        activeWorkRename = nil
        isEditingWork = false
        catalogRevision = nil
        stopChatObservation()
        chatTarget = nil
        chatSnapshot = nil
        chatEntries = []
        pendingChatCommandId = nil
        selectedWorkspaceID = nil
        selectedSessionID = nil
        nextWorkspaceCursor = nil
        nextSessionCursor = nil
        nextRuntimeID = nil
        connectionState = .disconnected
        message = "Disconnected. The daemon and its work are left running."
        if let oldConnection { Task { await oldConnection.close() } }
    }

    func showCreationMenu() {
        let menu = NSMenu()
        let workspace = menu.addItem(withTitle: "New Workspace…", action: #selector(newWorkspace), keyEquivalent: "")
        workspace.target = self
        workspace.isEnabled = canEditWork
        let session = menu.addItem(withTitle: "New Session…", action: #selector(newSession), keyEquivalent: "")
        session.target = self
        session.isEnabled = canEditWork
        let projectSession = menu.addItem(withTitle: "New Session in Workspace…", action: #selector(newWorkspaceSession), keyEquivalent: "")
        projectSession.target = self
        projectSession.isEnabled = canEditWork && selectedWorkspaceID != nil
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func beginWorkRename(workspace: WorkWorkspaceRecord) -> AxodWorkRename? {
        guard canEditWork, let endpoint, let revision = catalogRevision,
              workspaces.contains(where: { $0.workspaceId == workspace.workspaceId && $0.name == workspace.name }) else { return nil }
        let source = MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration)
        let context = AxodWorkRename(source: source, operation: operationGeneration, revision: revision,
            destination: .workspace(WorkWorkspaceTarget(machineId: source.machineId, hostGeneration: source.hostGeneration, workspaceId: workspace.workspaceId)))
        activeWorkRename = context
        return context
    }

    func beginWorkRename(session: WorkSessionRecord) -> AxodWorkRename? {
        guard canEditWork, let endpoint, let revision = catalogRevision,
              let current = sessions.first(where: { $0.sessionId == session.sessionId && $0.workspaceId == session.workspaceId && $0.name == session.name && $0.manualName == session.manualName }) else { return nil }
        guard current.manualName != nil else {
            message = "The running helper cannot protect manual session names yet. Rename needs a separately coordinated safe helper update."
            return nil
        }
        let source = MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration)
        let context = AxodWorkRename(source: source, operation: operationGeneration, revision: revision,
            destination: .session(WorkSessionTarget(machineId: source.machineId, hostGeneration: source.hostGeneration,
                workspaceId: session.workspaceId, sessionId: session.sessionId)))
        activeWorkRename = context
        return context
    }

    func finishWorkRename(_ context: AxodWorkRename, name: String?) {
        guard activeWorkRename?.id == context.id else { return }
        activeWorkRename = nil
        guard let enteredName = name else { message = "Rename cancelled."; return }
        guard canEditWork, context.operation == operationGeneration, let connection, let endpoint,
              endpoint.machineId == context.source.machineId, endpoint.hostGeneration == context.source.hostGeneration else {
            message = "The rename source changed. Nothing was renamed; reopen the row editor."
            return
        }
        let name = enteredName.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = UUID()
        isEditingWork = true
        Task { [weak self] in
            guard let self else { return }
            defer { if self.operationGeneration == context.operation { self.isEditingWork = false } }
            do {
                let result = try await context.dispatch(name: name, command: command, connection: connection) {
                    guard self.isCurrent(context.operation, connection: connection, endpoint: endpoint),
                          self.pendingWorkCommandID == nil,
                          self.preferences.object(forKey: self.pendingWorkKey(context.source.machineId)) == nil else { throw CancellationError() }
                    try self.stateDirectory?.requireCurrentEndpoint(endpoint)
                    self.savePendingWork(command, machineID: context.source.machineId)
                }
                guard self.isCurrent(context.operation, connection: connection, endpoint: endpoint) else { return }
                try self.stateDirectory?.requireCurrentEndpoint(endpoint)
                self.clearPendingWork(command, machineID: context.source.machineId)
                let committedRevision = context.revision.rawValue + 1
                if (self.catalogRevision?.rawValue ?? 0) <= committedRevision {
                    self.catalogRevision = WorkRevision(rawValue: committedRevision)
                    switch result {
                    case .workspace(let record):
                        if let index = self.workspaces.firstIndex(where: { $0.workspaceId == record.workspaceId }) { self.workspaces[index] = record }
                    case .session(let record):
                        if let index = self.sessions.firstIndex(where: { $0.sessionId == record.sessionId && $0.workspaceId == record.workspaceId }) {
                            let previous = self.sessions[index]
                            self.sessions[index] = record
                            if self.selectedSessionID == record.sessionId,
                               previous.pi.admission != record.pi.admission || previous.pi.chatId != record.pi.chatId ||
                               previous.pi.paneId != record.pi.paneId || previous.runtime?.runtime != record.runtime?.runtime {
                                self.activateSelectedSession()
                            }
                        }
                    }
                }
                self.message = "Name saved. Pi's canonical conversation title remains separate."
            } catch {
                guard self.isCurrent(context.operation, connection: connection, endpoint: endpoint) else { return }
                if self.pendingWorkCommandID == command {
                    if case AxoJSONRPCClientError.remote(let code, _) = error,
                       [-32601, -32602, -32002, -32006, -32007, -32010].contains(code) {
                        do { try self.stateDirectory?.requireCurrentEndpoint(endpoint) }
                        catch { self.message = "The private endpoint changed. The original rename remains saved for read-only reconciliation."; return }
                        self.clearPendingWork(command, machineID: context.source.machineId)
                        self.refresh(message: "Rename was rejected or the catalog changed. This request changed no name. Reopen the row editor after the catalog refresh.")
                    } else {
                        self.message = "Rename outcome unknown. Reconcile the original command; it will not be replayed."
                    }
                } else {
                    self.refresh(message: "Name is invalid or its source changed. Use 1–80 Unicode characters without control characters. Nothing was renamed.")
                }
            }
        }
    }

    func captureSessionDeletion(_ ids: Set<UUID>) -> AxodSessionDeletion? {
        guard canEditWork, (1...32).contains(ids.count), let endpoint, let revision = catalogRevision else { return nil }
        let records = sessions.filter { ids.contains($0.sessionId) }.sorted { $0.sessionId.uuidString < $1.sessionId.uuidString }
        guard records.count == ids.count else { return nil }
        let parameters = SessionDeletionParameters(target: MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration),
            commandId: UUID(), sessions: records.map { SessionAddress(workspaceId: $0.workspaceId, sessionId: $0.sessionId) }, expectedRevision: revision)
        return AxodSessionDeletion(operation: operationGeneration, parameters: parameters, names: records.map(\.displayName))
    }

    func confirmSessionDeletion(_ context: AxodSessionDeletion, in window: NSWindow) {
        guard canEditWork, context.operation == operationGeneration, let endpoint,
              context.parameters.target == MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration),
              catalogRevision == context.parameters.expectedRevision else { message = "The deletion source changed. Reopen the session menu."; return }
        sessionDeletionConfirmation = context
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = context.names.count == 1 ? "Delete “\(context.names[0])”?" : "Delete \(context.names.count) Sessions?"
        alert.informativeText = "This stops Pi and every shell in these sessions, including running commands, and removes the sessions from Axo. Conversation histories and drafts remain on disk."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.sessionDeletionConfirmation?.id == context.id else { return }
            self.sessionDeletionConfirmation = nil
            guard response == .alertFirstButtonReturn else { self.message = "Deletion cancelled. Nothing was stopped."; return }
            self.deleteSessions(context)
        }
    }

    private func deleteSessions(_ context: AxodSessionDeletion) {
        let parameters = context.parameters
        guard canEditWork, context.operation == operationGeneration, let connection, let endpoint,
              parameters.target == MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration),
              catalogRevision == parameters.expectedRevision,
              parameters.sessions.allSatisfy({ address in sessions.contains { $0.sessionId == address.sessionId && $0.workspaceId == address.workspaceId } }) else {
            message = "The confirmed deletion source changed. Nothing was stopped; reopen the session menu."; return
        }
        isEditingWork = true
        Task { [weak self] in
            guard let self else { return }
            defer { if self.operationGeneration == context.operation { self.isEditingWork = false } }
            var saved = false
            do {
                try self.stateDirectory?.requireCurrentEndpoint(endpoint)
                let data = try JSONEncoder().encode(parameters)
                guard data.count <= 8192 else { throw AxoProtocolValidationError.invalidParameters(method: AxoProtocol.Method.deleteSessions) }
                let value = try JSONDecoder().decode(JSONValue.self, from: data)
                _ = try AxoProtocolResultValidator.sessionDeletionParameters(value)
                self.preferences.set(data, forKey: self.pendingDeletionKey(parameters.target.machineId))
                self.savePendingWork(parameters.commandId, machineID: parameters.target.machineId)
                saved = true
                let response = try await connection.request(method: AxoProtocol.Method.deleteSessions, parameters: parameters)
                let result = try AxoProtocolResultValidator.sessionDeletion(response, parameters: parameters)
                guard self.isCurrent(context.operation, connection: connection, endpoint: endpoint) else { return }
                try self.stateDirectory?.requireCurrentEndpoint(endpoint)
                guard result.receipt.revision != nil else {
                    self.message = "Deletion is awaiting exact runtime completion. Reconcile the original command; it will not be replayed."; return
                }
                self.applySessionDeletion(result.receipt)
            } catch {
                guard self.isCurrent(context.operation, connection: connection, endpoint: endpoint) else { return }
                if saved {
                    if case AxoJSONRPCClientError.remote(let code, _) = error,
                       [-32601, -32602, -32002, -32006, -32007, -32009, -32010].contains(code) {
                        do { try self.stateDirectory?.requireCurrentEndpoint(endpoint) } catch { return }
                        self.clearPendingWork(parameters.commandId, machineID: parameters.target.machineId)
                        self.refresh(message: code == -32009 ? "Deletion refused: a session requires durable runtime recovery. No uncertain process was signaled." : "Deletion was rejected before stopping work. Refresh and reopen the session menu.")
                    } else { self.message = "Deletion outcome unknown. The exact original command is saved for reconciliation, never replay." }
                } else { self.message = "Deletion could not be prepared. Nothing was stopped." }
            }
        }
    }

    private func pendingDeletionKey(_ machineID: UUID) -> String { "Axo.axod.pendingDeletion." + machineID.uuidString }
    private func savedSessionDeletion(_ machineID: UUID) -> SessionDeletionParameters? {
        guard let data = preferences.data(forKey: pendingDeletionKey(machineID)), data.count <= 8192,
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let parameters = try? AxoProtocolResultValidator.sessionDeletionParameters(value), parameters.target.machineId == machineID else { return nil }
        return parameters
    }
    private func applySessionDeletion(_ receipt: SessionDeletionReceipt) {
        guard let revision = receipt.revision else { return }
        let removed = Set(receipt.intent.sessions.map(\.sessionId))
        clearPendingWork(receipt.commandId, machineID: receipt.intent.target.machineId)
        terminalSurfaces.releaseDeletedSessions(receipt)
        sessions.removeAll { removed.contains($0.sessionId) }
        if (catalogRevision?.rawValue ?? 0) <= revision.rawValue { catalogRevision = revision }
        if selectedSessionID.map(removed.contains) == true {
            stopChatObservation(); chatTarget = nil; chatSnapshot = nil; chatEntries = []
            selectedSessionID = nil; preferredSessionID = nil
            if let next = sessions.first(where: { $0.workspaceId == selectedWorkspaceID }) ?? sessions.first { selectSession(next.sessionId) }
            else { saveSelection() }
        }
        message = "Sessions deleted. Conversation histories and drafts were retained."
        refresh()
    }

    @objc func newWorkspace() { prepareWorkEditor(.workspace) }
    @objc func newSession() { prepareWorkEditor(.session(workspaceID: selectedWorkspaceID)) }
    @objc func newWorkspaceSession() {
        guard let workspaceID = selectedWorkspaceID else { return }
        prepareWorkEditor(.session(workspaceID: workspaceID))
    }

    private func prepareWorkEditor(_ kind: AxodWorkEditorContext.Kind) {
        guard canEditWork, workEditor == nil, let connection, let endpoint else { return }
        let operation = operationGeneration
        let target = MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration)
        isEditingWork = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.fetchWorkspaces(cursor: nil, over: connection, endpoint: endpoint, operation: operation)
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint) else { return }
                try self.stateDirectory?.requireCurrentEndpoint(endpoint)
                self.createdSessionForEditor = nil
                self.workEditMessage = "A workspace starts its first session in the selected folder. A standalone session starts in your home folder."
                let context = AxodWorkEditorContext(kind: kind, target: target, revision: page.revision)
                self.activeCreationContext = context
                self.isEditingWork = false
                switch kind {
                case .workspace: self.workEditor = context
                case .session: self.createWork(context, name: "New Session", directory: nil)
                }
            } catch {
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint) else { return }
                self.isEditingWork = false
                self.message = "Could not read the current work revision. No work was created."
            }
        }
    }

    func createWork(_ context: AxodWorkEditorContext, name: String, directory: LocalDirectoryPath?) {
        guard canEditWork, createdSessionForEditor == nil, (workEditor?.id ?? activeCreationContext?.id) == context.id, let connection, let endpoint,
              endpoint.machineId == context.target.machineId, endpoint.hostGeneration == context.target.hostGeneration else { return }
        let operation = operationGeneration
        let command = UUID()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingWork = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isEditingWork = false }
            do {
                try self.stateDirectory?.requireCurrentEndpoint(endpoint)
                let selection = try await self.dispatchWorkCreation(context, name: name, directory: directory,
                                                                  command: command, over: connection)
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint) else { return }
                try self.stateDirectory?.requireCurrentEndpoint(endpoint)
                self.clearPendingWork(command, machineID: context.target.machineId)
                // The immediately displayed creation must not borrow the empty startup revision.
                self.catalogRevision = WorkRevision(rawValue: max(self.catalogRevision?.rawValue ?? 0, context.revision.rawValue + 1))
                let session: WorkSessionRecord
                switch selection {
                case .workspace(let workspace, let first):
                    self.workspaces.append(workspace)
                    session = first
                case .session(let record): session = record
                }
                self.sessions.append(session)
                self.workEditor = nil
                self.activeCreationContext = nil
                self.selectedWorkspaceID = session.workspaceId
                self.selectedSessionID = session.sessionId
                self.initialTerminalFocus = WorkSessionTarget(machineId: context.target.machineId, hostGeneration: context.target.hostGeneration,
                    workspaceId: session.workspaceId, sessionId: session.sessionId)
                self.preferredWorkspaceID = session.workspaceId
                self.preferredSessionID = session.sessionId
                self.saveSelection()
                if context.authority == .emptyAppLaunch { self.emptyStartupMessage = nil }
                self.workEditMessage = "Session created. Starting its independent terminals…"
                // Reserve the startup UI immediately. Shell admission is committed first;
                // its process remains independent while Pi starts and waits for readiness.
                self.isStartingPi = true
                let shell = await self.shellCreation.start(session: session, source: context.target, send: { parameters in
                        try await connection.request(method: AxoProtocol.Method.addShellPane, parameters: parameters)
                }) {
                    guard self.isCurrent(operation, connection: connection, endpoint: endpoint),
                          let directory = self.stateDirectory else { throw CancellationError() }
                    try directory.requireCurrentEndpoint(endpoint)
                }
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint) else { return }
                if let shell, let index = self.sessions.firstIndex(where: { $0.sessionId == session.sessionId && $0.workspaceId == session.workspaceId }) {
                    let existing = self.sessions[index]
                    self.sessions[index] = WorkSessionRecord(sessionId: existing.sessionId, workspaceId: existing.workspaceId,
                        name: existing.name, nameSource: existing.nameSource, pi: existing.pi, runtime: existing.runtime,
                        shellPanes: existing.shellPanes.filter { $0.paneId != shell.paneId } + [shell], manualName: existing.manualName)
                    self.paneLayouts.observe(self.sessions[index], machineID: context.target.machineId)
                }
                let ready = await self.startCreatedSession(session, target: context.target, over: connection,
                                                          endpoint: endpoint, operation: operation)
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint),
                      self.selectedSessionID == session.sessionId else { return }
                self.isStartingPi = false
                if ready {
                    self.workEditor = nil
                    self.createdSessionForEditor = nil
                    self.message = "Session created and Pi is ready."
                    self.refresh()
                } else {
                    self.workEditMessage = self.chatStatusMessage
                    self.message = self.chatStatusMessage
                }
            } catch {
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint) else { return }
                if let pending = self.pendingWorkCommandID {
                    if case AxoJSONRPCClientError.remote(let code, _) = error, [-32601, -32602, -32002, -32006, -32007, -32010].contains(code) {
                        self.clearPendingWork(pending, machineID: context.target.machineId)
                        switch code {
                        case -32601:
                            self.workEditMessage = "The running daemon does not support this creation method. Its older registered helper must be upgraded; this workspace was not created."
                        case -32602:
                            self.workEditMessage = "The selected folder is unavailable or has changed. Choose the folder again; no work was created."
                        case -32002, -32007:
                            self.workEditMessage = "The work catalog or connection changed. Cancel and reopen this editor for the current revision."
                        case -32006:
                            self.workEditMessage = "The daemon's work-record capacity is full. No work was created."
                        default:
                            self.workEditMessage = "The daemon rejected creation. No work was created."
                        }
                    } else {
                        self.workEditMessage = "Outcome unknown. Reconcile the saved command; do not submit it again."
                    }
                } else {
                    self.workEditMessage = "The name or request is invalid. No command was dispatched."
                }
                if context.authority == .emptyAppLaunch { self.emptyStartupMessage = self.workEditMessage }
                self.message = self.workEditMessage
            }
        }
    }

    private enum CreatedWorkSelection {
        case workspace(WorkWorkspaceRecord, WorkSessionRecord)
        case session(WorkSessionRecord)
    }

    private func dispatchWorkCreation(_ context: AxodWorkEditorContext, name: String, directory: LocalDirectoryPath?,
                                      command: UUID, over connection: AxoJSONRPCWebSocketConnection) async throws -> CreatedWorkSelection {
        if context.authority == .emptyAppLaunch {
            guard case .session(workspaceID: nil) = context.kind,
                  !AxodEmptyStartupPolicy.hasPendingIntent(in: preferences, machineID: context.target.machineId),
                  !chatDrafts.blocksAutomaticStartup, !chatDrafts.hasPending(machineID: context.target.machineId) else {
                throw AxoProtocolValidationError.invalidParameters(method: AxoProtocol.Method.createEmptyStartupSession)
            }
            let parameters = EmptyStartupSessionParameters(target: context.target, commandId: command,
                expectedRevision: context.revision, name: name)
            try AxoProtocolWorkRequestValidator.validate(parameters)
            savePendingWork(command, machineID: context.target.machineId)
            let value = try await connection.request(method: AxoProtocol.Method.createEmptyStartupSession, parameters: parameters)
            let result = try AxoProtocolResultValidator.emptyStartupSession(value, parameters: parameters)
            return .session(result.session)
        }
        switch context.kind {
        case .workspace:
            guard let directory else { throw AxoProtocolValidationError.invalidParameters(method: AxoProtocol.Method.createLocalWorkspace) }
            let parameters = LocalWorkspaceCreateParameters(target: context.target, commandId: command,
                expectedRevision: context.revision, directoryPath: directory, name: name, initialSessionName: "New Session")
            try AxoProtocolWorkRequestValidator.validate(parameters)
            savePendingWork(command, machineID: context.target.machineId)
            let value = try await connection.request(method: AxoProtocol.Method.createLocalWorkspace, parameters: parameters)
            let result = try AxoProtocolResultValidator.localWorkspaceCreate(value, target: context.target,
                expectedRevision: context.revision, name: name, initialSessionName: "New Session")
            guard let first = result.session else { throw AxoProtocolValidationError.invalidResult(method: AxoProtocol.Method.createLocalWorkspace) }
            return .workspace(result.workspace, first)
        case .session(let workspaceID):
            let target = WorkSessionDestination(machineId: context.target.machineId, hostGeneration: context.target.hostGeneration, workspaceId: workspaceID)
            let parameters = SessionCreateParameters(target: target, commandId: command, expectedRevision: context.revision, name: name)
            try AxoProtocolWorkRequestValidator.validate(parameters)
            savePendingWork(command, machineID: context.target.machineId)
            let value = try await connection.request(method: AxoProtocol.Method.createSession, parameters: parameters)
            let result = try AxoProtocolResultValidator.sessionCreate(value, target: target, expectedRevision: context.revision, name: name)
            return .session(result.session)
        }
    }

    func reconcilePendingWork() {
        guard !isEditingWork, let command = pendingWorkCommandID, let connection, let endpoint else { return }
        let operation = operationGeneration
        let target = MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration)
        isEditingWork = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isEditingWork = false }
            do {
                let value = try await connection.request(method: AxoProtocol.Method.getCommand, parameters: CommandGetParameters(target: target, commandId: command))
                let result = try AxoProtocolResultValidator.commandGet(value, target: target)
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint) else { return }
                try self.stateDirectory?.requireCurrentEndpoint(endpoint)
                if case .deletion(let receipt) = result.receipt {
                    guard let original = self.savedSessionDeletion(target.machineId), original.commandId == command,
                          receipt.commandId == command, receipt.intent == original.intent else {
                        self.workEditMessage = "The deletion receipt does not match its saved intent. It was preserved; nothing was replayed."; return
                    }
                    guard receipt.revision != nil else { self.workEditMessage = "Deletion still awaits exact runtime completion. The original command was not replayed."; return }
                    self.applySessionDeletion(receipt)
                    return
                }
                guard self.preferences.object(forKey: self.pendingDeletionKey(target.machineId)) == nil else {
                    self.workEditMessage = "No matching deletion receipt was found. Its original intent remains saved, without replay."; return
                }
                guard case .work(let committed) = result.receipt else {
                    self.workEditMessage = "No committed work receipt was found. The unresolved command was not replayed."
                    return
                }
                switch committed.record {
                case .workspace(let workspace):
                    self.preferredWorkspaceID = workspace.workspaceId
                    self.preferredSessionID = nil
                case .session(let session):
                    self.preferredWorkspaceID = session.workspaceId
                    self.preferredSessionID = session.sessionId
                case .workspaceSession(let pair):
                    self.preferredWorkspaceID = pair.workspace.workspaceId
                    self.preferredSessionID = pair.session.sessionId
                }
                self.clearPendingWork(command, machineID: target.machineId)
                self.workEditor = nil
                self.message = "Original work command confirmed; refreshing the catalog without replay or Pi launch."
                self.refresh()
            } catch {
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint) else { return }
                self.workEditMessage = "Reconciliation unavailable. The original command remains saved."
            }
        }
    }

    private func pendingWorkKey(_ machineID: UUID) -> String { "Axo.axod.pendingWork." + machineID.uuidString }
    private func savePendingWork(_ command: UUID, machineID: UUID) {
        preferences.set(command.uuidString, forKey: pendingWorkKey(machineID))
        pendingWorkCommandID = command
    }
    private func clearPendingWork(_ command: UUID, machineID: UUID) {
        guard preferences.string(forKey: pendingWorkKey(machineID)) == command.uuidString else { return }
        if let deletion = savedSessionDeletion(machineID), deletion.commandId == command { preferences.removeObject(forKey: pendingDeletionKey(machineID)) }
        preferences.removeObject(forKey: pendingWorkKey(machineID))
        if self.machineID == machineID { pendingWorkCommandID = nil }
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
        pendingChatCommandId = nil
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

    private func observeStartingTerminal(session: WorkSessionRecord, endpoint: LocalDaemonEndpoint,
                                         operation: UUID, control: AxoJSONRPCWebSocketConnection) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self, let directory = self.stateDirectory else { return }
            let source = MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration)
            do {
                try directory.requireCurrentEndpoint(endpoint)
                let observer = try self.rpc.openLocalWebSocket(endpoint: endpoint)
                defer { Task { await observer.close() } }
                let negotiation = try await observer.request(method: AxoProtocol.Method.negotiate, parameters: NegotiationParameters())
                _ = try AxoProtocolResultValidator.localNegotiation(negotiation)
                while !Task.isCancelled {
                    var after: UUID?
                    var cursors = Set<UUID>()
                    for _ in 0..<20 {
                        let value = try await observer.request(method: AxoProtocol.Method.listRuntimes,
                            parameters: RuntimeListParameters(target: source, after: after))
                        let page = try AxoProtocolResultValidator.runtimeList(value, target: source)
                        guard !Task.isCancelled, self.isCurrent(operation, connection: control, endpoint: endpoint) else { return }
                        try directory.requireCurrentEndpoint(endpoint)
                        if let snapshot = page.terminals.first(where: {
                            $0.runtime.hostGeneration == source.hostGeneration &&
                            $0.runtime.target.sessionId == session.sessionId &&
                            $0.runtime.target.paneId == session.pi.paneId
                        }) {
                            self.runtimes.removeAll { $0.runtime.target.paneId == session.pi.paneId }
                            self.runtimes.append(snapshot)
                            break
                        }
                        guard let next = page.next, cursors.insert(next).inserted else { break }
                        after = next
                    }
                    try await Task.sleep(for: .milliseconds(200))
                }
            } catch {
                // Read-only observer failure never retries a start or changes its receipt.
            }
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

    var canSplitPane: Bool {
        guard connectionState == .connected,
              let session = selectedSession, let machineID,
              session.shellPanes.count + 1 < AxodPaneLayouts.maximumPanes else { return false }
        switch shellStartupState(for: session.sessionId) {
        case .starting?, .unresolved?, .unavailable?: return false
        case .ready?, .rejected?, nil: break
        }
        return paneLayouts.canSplit(.init(machineID: machineID, sessionID: session.sessionId))
    }

    @objc func splitRight(_ sender: Any?) { splitPane(.right) }
    @objc func splitDown(_ sender: Any?) { splitPane(.down) }

    /// One captured action; startup, restoration and catalog observation never call this.
    func splitPane(_ direction: AxodPaneSplitDirection) {
        guard let session = selectedSession, let endpoint, let control = connection,
              let directory = stateDirectory else { return }
        preparePaneLayout(session)
        guard canSplitPane else { return }
        let identity = AxodPaneLayouts.Session(machineID: endpoint.machineId, sessionID: session.sessionId)
        let anchor = paneLayouts.focusedPanes[identity] ?? session.pi.paneId
        guard anchor == session.pi.paneId || session.shellPanes.contains(where: { $0.paneId == anchor }) else { return }
        let source = MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration)
        let parameters = ShellPaneAddParameters(target: WorkSessionTarget(machineId: source.machineId,
            hostGeneration: source.hostGeneration, workspaceId: session.workspaceId, sessionId: session.sessionId), commandId: UUID())
        guard (try? directory.requireCurrentEndpoint(endpoint)) != nil,
              let placement = paneLayouts.capture(parameters: parameters, anchor: anchor, direction: direction) else { return }
        let operation = operationGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                guard self.isCurrent(operation, connection: control, endpoint: endpoint) else { throw CancellationError() }
                try directory.requireCurrentEndpoint(endpoint)
                // Separate control peer: a Pi admission wait must not block an explicit shell split.
                let peer = try self.rpc.openLocalWebSocket(endpoint: endpoint)
                defer { Task { await peer.close() } }
                let negotiation = try await peer.request(method: AxoProtocol.Method.negotiate, parameters: NegotiationParameters())
                _ = try AxoProtocolResultValidator.localNegotiation(negotiation)
                let pane = await self.shellCreation.start(session: session, source: source, commandID: parameters.commandId, send: { pending in
                    try await peer.request(method: AxoProtocol.Method.addShellPane, parameters: pending)
                }) {
                    guard self.isCurrent(operation, connection: control, endpoint: endpoint) else { throw CancellationError() }
                    try directory.requireCurrentEndpoint(endpoint)
                }
                guard self.isCurrent(operation, connection: control, endpoint: endpoint) else { return }
                if self.shellStartupState(for: session.sessionId) == .ready, let pane {
                    self.paneLayouts.commit(placement, paneID: pane.paneId)
                } else if self.shellStartupState(for: session.sessionId) == .rejected {
                    self.paneLayouts.finishKnownCommand(placement)
                }
                if let pane, let index = self.sessions.firstIndex(where: { $0.sessionId == session.sessionId }) {
                    let current = self.sessions[index]
                    self.sessions[index] = WorkSessionRecord(sessionId: current.sessionId, workspaceId: current.workspaceId,
                        name: current.name, nameSource: current.nameSource, pi: current.pi, runtime: current.runtime,
                        shellPanes: current.shellPanes.filter { $0.paneId != pane.paneId } + [pane], manualName: current.manualName)
                }
                self.refresh()
            } catch {
                // No pane command was dispatched: open/negotiation failed. A saved
                // shell hint, if one exists, remains owned by ShellCreation instead.
                self.paneLayouts.noDispatch(placement)
            }
        }
    }

    func shellStartupState(for sessionID: UUID) -> AxodShellCreation.State? {
        guard let machineID else { return nil }
        return shellCreation.states[.init(machineID: machineID, sessionID: sessionID)]
    }

    func reconcileSelectedShell() {
        guard let session = selectedSession, let endpoint, let connection else { return }
        let operation = operationGeneration
        let source = MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration)
        Task { [weak self] in
            guard let self else { return }
            let identity = AxodPaneLayouts.Session(machineID: source.machineId, sessionID: session.sessionId)
            let receipt = await self.shellCreation.reconcile(session: session, source: source,
                parameters: self.paneLayouts.pendingParameters(identity), lookup: { parameters in
                try await connection.request(method: AxoProtocol.Method.getCommand, parameters: parameters)
            }) {
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint),
                      let directory = self.stateDirectory else { throw CancellationError() }
                try directory.requireCurrentEndpoint(endpoint)
            }
            guard self.isCurrent(operation, connection: connection, endpoint: endpoint) else { return }
            if let receipt {
                self.paneLayouts.adopt(receipt, in: .init(machineID: source.machineId, sessionID: session.sessionId))
            }
            self.refresh()
        }
    }

    /// Creation is explicit launch intent. Catalog reads and restoration never call this.
    private func startCreatedSession(_ session: WorkSessionRecord, target: MachineTarget,
                                     over connection: AxoJSONRPCWebSocketConnection,
                                     endpoint: LocalDaemonEndpoint, operation: UUID) async -> Bool {
        let destination = PiSessionTarget(machineId: target.machineId, hostGeneration: target.hostGeneration,
            workspaceId: session.workspaceId, sessionId: session.sessionId, paneId: session.pi.paneId)
        let key = pendingStartKey(machineID: target.machineId, sessionID: session.sessionId)
        guard preferences.data(forKey: key) == nil else {
            chatStatusMessage = "A previous start is unresolved. Reconcile it; no second start was sent."
            return false
        }
        let pending = PendingPiStart(target: destination, commandId: UUID(), persistence: .fresh)
        do { preferences.set(try JSONEncoder().encode(pending), forKey: key) }
        catch {
            chatStatusMessage = "The session was created, but its start intent could not be saved. No Pi start was sent."
            return false
        }
        pendingPiStartCommandID = pending.commandId
        isStartingPi = true
        let observer = observeStartingTerminal(session: session, endpoint: endpoint, operation: operation, control: connection)
        defer { observer.cancel(); isStartingPi = false }
        do {
            try stateDirectory?.requireCurrentEndpoint(endpoint)
            let value = try await connection.request(method: AxoProtocol.Method.startSession,
                parameters: PiSessionStartParameters(target: destination, commandId: pending.commandId, persistence: .fresh))
            let result = try PiProtocolValidator.sessionStart(value, target: destination,
                commandId: pending.commandId, persistence: .fresh)
            guard isCurrent(operation, connection: connection, endpoint: endpoint), selectedSessionID == session.sessionId else { return false }
            try stateDirectory?.requireCurrentEndpoint(endpoint)
            switch result.receipt.disposition {
            case .prepared:
                chatStatusMessage = "Session created; Pi start remains uncertain. Reconcile the saved start, do not create another session."
            case .rejected(let code):
                preferences.removeObject(forKey: key)
                pendingPiStartCommandID = nil
                chatStatusMessage = "Session created, but Pi startup was rejected before execution (\(code)). Open the session to retry its start."
            case .dispatched:
                guard result.admission == .ready, let chat = result.chat else {
                    chatStatusMessage = "Session created; Pi did not confirm readiness. Reconcile its saved start before retrying."
                    return false
                }
                preferences.removeObject(forKey: key)
                pendingPiStartCommandID = nil
                chatTarget = chat
                chatStatusMessage = "Pi is ready."
                return true
            }
        } catch {
            guard isCurrent(operation, connection: connection, endpoint: endpoint), selectedSessionID == session.sessionId else { return false }
            if let code = Self.knownNoEffectCode(error) {
                preferences.removeObject(forKey: key)
                pendingPiStartCommandID = nil
                chatStatusMessage = code == -32003
                    ? "Session created, but the running daemon cannot launch Pi. It needs the current app's adapter and local launch policy; ambient Pi must be installed. No execution was started."
                    : "Session created, but Pi start was rejected before execution (\(code)). Open the session to retry its start."
            } else {
                chatStatusMessage = "Session created; Pi start outcome is unknown. Its saved command must be reconciled before any new start."
            }
        }
        return false
    }

    func startOrResumePi() {
        guard connectionState == .connected, let session = selectedSession,
              let connection, let endpoint else { return }
        let target = PiSessionTarget(
            machineId: endpoint.machineId,
            hostGeneration: endpoint.hostGeneration,
            workspaceId: session.workspaceId,
            sessionId: session.sessionId,
            paneId: session.pi.paneId
        )

        let pendingKey = pendingStartKey(machineID: endpoint.machineId, sessionID: session.sessionId)
        let pending: PendingPiStart
        if let data = preferences.data(forKey: pendingKey) {
            guard let decoded = try? JSONDecoder().decode(PendingPiStart.self, from: data),
                  decoded.target.workspaceId == target.workspaceId,
                  decoded.target.sessionId == target.sessionId,
                  decoded.target.paneId == target.paneId else {
                chatStatusMessage = "A previous start intent could not be validated. No new start was sent."
                return
            }
            guard decoded.target == target else {
                pendingPiStartCommandID = decoded.commandId
                reconcilePendingPiStart()
                return
            }
            pending = decoded
        } else {
            let persistence: PiPersistence
            switch session.pi.admission {
            case .notAdmitted:
                persistence = .fresh
            case .stopped, .failed:
                guard let chatId = session.pi.chatId, let runtime = session.runtime?.runtime else {
                    chatStatusMessage = "This stopped Pi session is missing its exact resume binding. No new chat was created."
                    return
                }
                persistence = .resume(chatId: chatId, previousRuntime: runtime)
            case .ready:
                chatStatusMessage = "This session already has an admitted Pi runtime. Refresh its chat instead of starting another."
                activateSelectedSession()
                return
            case .recoveryRequired:
                chatStatusMessage = "Axod cannot prove this Pi writer is safe to resume. Recovery is required; no new runtime was started."
                return
            }
            pending = PendingPiStart(target: target, commandId: UUID(), persistence: persistence)
            do { preferences.set(try JSONEncoder().encode(pending), forKey: pendingKey) }
            catch {
                chatStatusMessage = "The start reconciliation ID could not be saved. No start was sent."
                return
            }
        }

        let parameters = PiSessionStartParameters(
            target: pending.target,
            commandId: pending.commandId,
            persistence: pending.persistence
        )
        let operation = operationGeneration
        isStartingPi = true
        pendingPiStartCommandID = pending.commandId
        chatStatusMessage = "Submitting an explicit \(pending.persistence == .fresh ? "fresh" : "exact resume") request to axod."
        Task { [weak self] in
            guard let self else { return }
            defer { self.isStartingPi = false }
            do {
                let value = try await connection.request(method: AxoProtocol.Method.startSession, parameters: parameters)
                let result = try PiProtocolValidator.sessionStart(
                    value, target: pending.target, commandId: pending.commandId, persistence: pending.persistence
                )
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint),
                      self.selectedSessionID == pending.target.sessionId else { return }
                switch result.receipt.disposition {
                case .prepared:
                    self.chatStatusMessage = "Start remains prepared or uncertain. Reconcile this same command; do not create another start."
                case .rejected(let code):
                    self.preferences.removeObject(forKey: pendingKey)
                    self.pendingPiStartCommandID = nil
                    self.chatStatusMessage = "Axod rejected the start before dispatch (\(code)). No Pi execution was confirmed."
                case .dispatched:
                    self.preferences.removeObject(forKey: pendingKey)
                    self.pendingPiStartCommandID = nil
                    self.chatStatusMessage = result.admission == .ready
                        ? "Pi is admitted to the captured Axod session."
                        : "The start disposition is recorded; Pi admission is \(result.admission.rawValue)."
                    self.refresh()
                    if let chat = result.chat, result.admission == .ready {
                        self.chatTarget = chat
                        self.refreshChat()
                    }
                }
            } catch {
                guard self.operationGeneration == operation,
                      self.selectedSessionID == pending.target.sessionId else { return }
                if let code = Self.knownNoEffectCode(error) {
                    self.preferences.removeObject(forKey: pendingKey)
                    self.pendingPiStartCommandID = nil
                    self.chatStatusMessage = "Axod rejected the Pi start before dispatch (\(code)). No execution was started."
                } else {
                    self.pendingPiStartCommandID = pending.commandId
                    self.chatStatusMessage = "Pi start outcome may be unknown. Its command ID is retained; reconcile it before any new start."
                }
            }
        }
    }

    func reconcilePendingPiStart() {
        guard let session = selectedSession, let endpoint, let connection else { return }
        let key = pendingStartKey(machineID: endpoint.machineId, sessionID: session.sessionId)
        guard let data = preferences.data(forKey: key),
              let pending = try? JSONDecoder().decode(PendingPiStart.self, from: data) else {
            chatStatusMessage = "No validated pending start intent is available to reconcile."
            return
        }
        let target = MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration)
        let parameters = CommandGetParameters(target: target, commandId: pending.commandId)
        let operation = operationGeneration
        isReconcilingPiCommand = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isReconcilingPiCommand = false }
            do {
                let value = try await connection.request(method: AxoProtocol.Method.getCommand, parameters: parameters)
                let result = try AxoProtocolResultValidator.commandGet(value, target: target)
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint),
                      self.selectedSessionID == pending.target.sessionId else { return }
                guard case .pi(let receipt)? = result.receipt,
                      receipt.commandId == pending.commandId,
                      receipt.intent == .start(target: pending.target, persistence: pending.persistence) else {
                    self.chatStatusMessage = "No matching durable Pi start receipt is visible yet. It was not replayed."
                    return
                }
                switch receipt.disposition {
                case .prepared:
                    self.chatStatusMessage = "Axod still records this start as prepared. Its outcome is uncertain; no retry was sent."
                case .rejected(let code):
                    self.preferences.removeObject(forKey: key)
                    self.pendingPiStartCommandID = nil
                    self.chatStatusMessage = "The original start was rejected before dispatch (\(code))."
                case .dispatched:
                    self.preferences.removeObject(forKey: key)
                    self.pendingPiStartCommandID = nil
                    self.chatStatusMessage = "The original start was dispatched. Refreshing Axod's session binding; dispatch is not Pi-turn completion."
                    self.refresh()
                }
            } catch {
                guard self.operationGeneration == operation,
                      self.selectedSessionID == pending.target.sessionId else { return }
                self.chatStatusMessage = "Could not reconcile the original start receipt. No start was repeated."
            }
        }
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

    func submitChatDraft(snapshot: PiChatSnapshot) {
        guard snapshot.readMode == .live, snapshot.admission == .ready,
              !snapshot.recovery, snapshot.uiWaits == 0, snapshot.question == nil,
              let current = chatSnapshot, chatTarget == snapshot.target,
              current.target == snapshot.target, current.readMode == .live,
              current.admission == .ready, !current.recovery, current.uiWaits == 0, current.question == nil,
              current.busy == snapshot.busy, current.interactionId == snapshot.interactionId,
              !isSendingPiMessage, connectionState == .connected else {
            chatStatusMessage = "The captured Pi conversation changed or is unavailable. The draft was preserved; nothing was sent."
            return
        }
        guard let draft = chatDrafts.capture(for: snapshot.target, operation: snapshot.busy ? .sendSteeringMessage : .sendMessage) else { return }
        sendPiMutation(
            operation: snapshot.busy ? .sendSteeringMessage : .sendMessage,
            interactionID: snapshot.busy ? snapshot.interactionId : nil,
            questionID: nil, optionID: nil, text: draft.text, draft: draft
        )
    }

    func cancelChatTurn(snapshot captured: PiChatSnapshot) {
        guard captured.readMode == .live, !captured.recovery, captured.busy,
              chatTarget == captured.target, chatSnapshot?.interactionId == captured.interactionId else {
            chatStatusMessage = "The captured Pi interaction changed. Nothing was cancelled."
            return
        }
        guard let snapshot = chatSnapshot, snapshot.busy,
              let interactionID = snapshot.interactionId,
              snapshot.readMode == .live, !snapshot.recovery else {
            chatStatusMessage = "There is no captured Pi interaction to cancel."
            return
        }
        sendPiMutation(operation: .cancelTurn, interactionID: interactionID, questionID: nil, optionID: nil, text: nil)
    }

    func answerChatQuestion(_ question: PiQuestion, option: PiQuestionOption, snapshot captured: PiChatSnapshot) {
        guard captured.readMode == .live, captured.question == question,
              chatTarget == captured.target,
              let snapshot = chatSnapshot, snapshot.target == captured.target, snapshot.readMode == .live,
              snapshot.question == question, snapshot.interactionId == question.interactionId,
              question.options.contains(option) else {
            chatStatusMessage = "The Pi question changed before the answer was sent. Refresh and choose again."
            return
        }
        sendPiMutation(
            operation: .answerQuestion, interactionID: question.interactionId,
            questionID: question.id, optionID: option.id, text: nil
        )
    }

    func reconcilePendingPiCommand() {
        guard !isSendingPiMessage, !isReconcilingPiCommand, let endpoint, let connection, let session = selectedSession,
              let pending = readPendingChatCommand(machineID: endpoint.machineId, sessionID: session.sessionId) else {
            chatStatusMessage = "No pending Pi command is available for reconciliation."
            return
        }
        let target = MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration)
        let parameters = CommandGetParameters(target: target, commandId: pending.commandId)
        let operation = operationGeneration
        isReconcilingPiCommand = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isReconcilingPiCommand = false }
            do {
                let value = try await connection.request(method: AxoProtocol.Method.getCommand, parameters: parameters)
                let result = try AxoProtocolResultValidator.commandGet(value, target: target)
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint),
                      self.selectedSessionID == pending.target.sessionId else { return }
                try self.stateDirectory?.requireCurrentEndpoint(endpoint)
                guard case .pi(let receipt)? = result.receipt,
                      receipt.commandId == pending.commandId,
                      receipt.intent == .chat(target: pending.target, operation: pending.operation) else {
                    self.chatStatusMessage = "No matching durable Pi command receipt is visible. It was not replayed."
                    return
                }
                guard await self.resolveChatDraft(receipt: receipt) else {
                    self.chatStatusMessage = "The receipt is known, but the draft update could not be saved. The original hint and text were preserved; do not resend."
                    return
                }
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint),
                      self.selectedSessionID == pending.target.sessionId else { return }
                try self.stateDirectory?.requireCurrentEndpoint(endpoint)
                switch receipt.disposition {
                case .prepared:
                    self.chatStatusMessage = "The original Pi command is still prepared or uncertain. It was not replayed."
                case .rejected(let code):
                    self.clearPendingChatCommand(pending)
                    self.pendingChatCommandId = nil
                    self.chatStatusMessage = "The original Pi command was rejected before dispatch (\(code))."
                case .dispatched:
                    self.clearPendingChatCommand(pending)
                    self.pendingChatCommandId = nil
                    self.chatStatusMessage = "The Pi public API acknowledged dispatch. This does not prove execution; refreshing canonical history."
                    self.refreshChat()
                }
            } catch {
                guard self.operationGeneration == operation,
                      self.selectedSessionID == pending.target.sessionId else { return }
                self.chatStatusMessage = "Could not reconcile the original Pi command. It was not repeated."
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
            // Draft safety is independent of service approval. Opening setup must
            // still load saved tickets and allow a safe normal quit before enabling.
            await chatDrafts.openStorage(in: directory.root)
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
            await chatDrafts.openStorage(in: stateDirectory.root)
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
            let savedWork = preferences.string(forKey: pendingWorkKey(endpoint.machineId))
            pendingWorkCommandID = savedWork.flatMap(UUID.init(uuidString:))
            pendingWorkIsUnreadable = preferences.object(forKey: pendingWorkKey(endpoint.machineId)) != nil && pendingWorkCommandID == nil
            if preferences.object(forKey: pendingDeletionKey(endpoint.machineId)) != nil {
                if let deletion = savedSessionDeletion(endpoint.machineId), pendingWorkCommandID == nil || pendingWorkCommandID == deletion.commandId {
                    pendingWorkCommandID = deletion.commandId
                    if preferences.object(forKey: pendingWorkKey(endpoint.machineId)) == nil { preferences.set(deletion.commandId.uuidString, forKey: pendingWorkKey(endpoint.machineId)) }
                } else { pendingWorkIsUnreadable = true }
            }
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
            pendingPiStartCommandID = nil
            pendingChatCommandId = nil
            chatStatusMessage = "Select an admitted Pi session to view its canonical conversation."
            return
        }
        shellCreation.restore(session: session, machineID: endpoint.machineId)
        paneLayouts.observe(session, machineID: endpoint.machineId)
        let startKey = pendingStartKey(machineID: endpoint.machineId, sessionID: session.sessionId)
        pendingPiStartCommandID = (preferences.data(forKey: startKey)
            .flatMap { try? JSONDecoder().decode(PendingPiStart.self, from: $0) })?.commandId
        let pending = readPendingChatCommand(machineID: endpoint.machineId, sessionID: session.sessionId)
        pendingChatCommandId = pending?.commandId

        switch session.pi.admission {
        case .notAdmitted:
            chatTarget = nil
            chatSnapshot = nil
            chatEntries = []
            chatStatusMessage = "This session has no Pi conversation yet. Start Pi explicitly to create one."
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
            pendingChatCommandId = readPendingChatCommand(machineID: endpoint.machineId, sessionID: session.sessionId)?.commandId
            refreshChat()
        case .notAdmitted, .recoveryRequired:
            return
        }
    }

    private func sendPiMutation(
        operation: PiChatOperation,
        interactionID: UUID?,
        questionID: UUID?,
        optionID: UUID?,
        text: String?,
        draft: AxodChatDrafts.Submission? = nil
    ) {
        guard let target = chatTarget, let endpoint, let connection, let directory = stateDirectory,
              chatSnapshot?.readMode == .live, !isSendingPiMessage else {
            if let draft { chatDrafts.resolve(commandID: draft.commandID, target: draft.target, outcome: .rejected) }
            return
        }
        if let draft, draft.target != target || draft.operation != operation {
            chatDrafts.resolve(commandID: draft.commandID, target: draft.target, outcome: .rejected)
            return
        }
        let key = pendingChatKey(machineID: endpoint.machineId, sessionID: target.sessionId)
        if preferences.object(forKey: key) != nil {
            if let draft { chatDrafts.resolve(commandID: draft.commandID, target: draft.target, outcome: .rejected) }
            pendingChatCommandId = readPendingChatCommand(machineID: endpoint.machineId, sessionID: target.sessionId)?.commandId
            chatStatusMessage = "A prior Pi command may have an unknown outcome. Reconcile it before sending another."
            return
        }
        let pending = PendingPiCommand(target: target, commandId: draft?.commandID ?? UUID(), operation: operation)
        let request: AxodPiMutationRequest
        do {
            request = try AxodPiMutationRequest(target: target, commandID: pending.commandId, operation: operation,
                                               interactionID: interactionID, questionID: questionID, optionID: optionID, text: text)
        } catch {
            if let draft { chatDrafts.resolve(commandID: draft.commandID, target: draft.target, outcome: .rejected) }
            chatStatusMessage = "The Pi command parameters exceeded supported text/transport bounds or were invalid. The draft was preserved; nothing was sent."
            return
        }
        let pendingData: Data
        do { pendingData = try JSONEncoder().encode(pending) }
        catch {
            if let draft { chatDrafts.resolve(commandID: draft.commandID, target: draft.target, outcome: .rejected) }
            chatStatusMessage = "The Pi command identity could not be saved. Nothing was sent."
            return
        }
        pendingChatCommandId = pending.commandId
        let operationID = operationGeneration
        let mutationGeneration = UUID()
        piMutationGeneration = mutationGeneration
        isSendingPiMessage = true
        chatStatusMessage = "Submitting the captured Pi command."

        Task { [weak self] in
            guard let self else { return }
            defer {
                if self.piMutationGeneration == mutationGeneration {
                    self.piMutationGeneration = nil
                    self.isSendingPiMessage = false
                }
            }
            if let draft, !(await self.chatDrafts.persist(draft)) {
                self.chatDrafts.resolve(commandID: draft.commandID, target: draft.target, outcome: .rejected)
                if self.chatTarget == target {
                    self.pendingChatCommandId = nil
                    self.chatStatusMessage = "The captured draft could not be saved safely. Its text was preserved; nothing was sent."
                }
                return
            }
            // Storage is not permission: recheck the captured operation/peer and
            // private endpoint after its await, before creating a dispatch hint.
            guard !Task.isCancelled, self.isCurrent(operationID, connection: connection, endpoint: endpoint) else {
                if let draft { self.chatDrafts.resolve(commandID: draft.commandID, target: draft.target, outcome: .rejected) }
                self.clearPendingChatCommand(pending)
                return
            }
            do {
                // This check is before any request bytes are submitted. Failure
                // releases only the exact local hint; it is not execution replay.
                do { try directory.requireCurrentEndpoint(endpoint) }
                catch {
                    self.chatDrafts.resolve(commandID: pending.commandId, target: target, outcome: .rejected)
                    self.clearPendingChatCommand(pending)
                    if self.chatTarget == target {
                        self.pendingChatCommandId = nil
                        self.chatStatusMessage = "The private local endpoint changed. The draft was preserved; nothing was sent."
                    }
                    return
                }
                guard self.preferences.object(forKey: key) == nil else {
                    self.chatDrafts.resolve(commandID: pending.commandId, target: target, outcome: .rejected)
                    if self.chatTarget == target {
                        self.pendingChatCommandId = self.readPendingChatCommand(machineID: target.machineId, sessionID: target.sessionId)?.commandId
                        self.chatStatusMessage = "A prior Pi hint appeared before dispatch. Existing data and the draft were preserved; nothing was sent."
                    }
                    return
                }
                self.preferences.set(pendingData, forKey: key)
                let value = try await connection.request(method: request.method, parameters: request.parameters)
                let result = try PiProtocolValidator.mutation(
                    value, target: target, commandId: pending.commandId, operation: operation, method: request.method
                )
                guard self.isCurrent(operationID, connection: connection, endpoint: endpoint) else { return }
                try directory.requireCurrentEndpoint(endpoint)
                guard await self.resolveChatDraft(receipt: result.receipt) else {
                    self.chatStatusMessage = "The original Pi receipt is known, but its draft update could not be saved. The original hint and text were preserved; do not resend."
                    return
                }
                guard self.isCurrent(operationID, connection: connection, endpoint: endpoint) else { return }
                do { try directory.requireCurrentEndpoint(endpoint) }
                catch {
                    if self.chatTarget == target {
                        self.chatStatusMessage = "The original receipt was validated, but the private endpoint changed. Its hint remains for read-only reconciliation; nothing was replayed."
                    }
                    return
                }
                guard self.chatTarget == target else { return }
                switch result.receipt.disposition {
                case .prepared:
                    self.chatStatusMessage = "The Pi command is prepared or uncertain. Reconcile it; do not resend."
                case .rejected(let code):
                    self.clearPendingChatCommand(pending)
                    self.pendingChatCommandId = nil
                    self.chatStatusMessage = "Pi rejected the command before dispatch (\(code))."
                case .dispatched:
                    self.clearPendingChatCommand(pending)
                    self.pendingChatCommandId = nil
                    self.chatStatusMessage = "Pi's public API acknowledged dispatch; execution is not inferred. Refreshing canonical history."
                    self.refreshChat()
                }
            } catch {
                guard self.isCurrent(operationID, connection: connection, endpoint: endpoint) else { return }
                let noEffectCode = Self.knownNoEffectCode(error)
                if noEffectCode != nil {
                    guard await self.chatDrafts.settle(commandID: pending.commandId, target: target, outcome: .rejected) else {
                        self.chatStatusMessage = "The known no-effect result could not be saved with the draft. Original data was preserved; nothing was replayed."
                        return
                    }
                    guard self.isCurrent(operationID, connection: connection, endpoint: endpoint) else { return }
                    do { try directory.requireCurrentEndpoint(endpoint) } catch { return }
                }
                guard self.chatTarget == target else { return }
                if let code = noEffectCode {
                    self.clearPendingChatCommand(pending)
                    self.pendingChatCommandId = nil
                    self.chatStatusMessage = "Pi rejected the command before dispatch (\(code))."
                } else {
                    self.pendingChatCommandId = pending.commandId
                    self.chatStatusMessage = "The Pi command outcome may be unknown. Its command ID is retained; reconcile before sending again."
                }
            }
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

    private func readPendingChatCommand(machineID: UUID, sessionID: UUID) -> PendingPiCommand? {
        let key = pendingChatKey(machineID: machineID, sessionID: sessionID)
        if let object = preferences.object(forKey: key) {
            guard let data = object as? Data, let pending = try? JSONDecoder().decode(PendingPiCommand.self, from: data),
                  pending.target.machineId == machineID, pending.target.sessionId == sessionID else { return nil }
            return pending
        }
        guard let target = chatTarget, target.machineId == machineID, target.sessionId == sessionID,
              let saved = chatDrafts.pending(for: target) else { return nil }
        // An archive ticket enables only original read-only receipt lookup, not
        // dispatch. It also covers a crash between archive save and hint save.
        return PendingPiCommand(target: saved.target, commandId: saved.commandID, operation: saved.operation)
    }

    private func pendingStartKey(machineID: UUID, sessionID: UUID) -> String {
        PreferenceKey.pendingStartPrefix + machineID.uuidString + "." + sessionID.uuidString
    }

    private func pendingChatKey(machineID: UUID, sessionID: UUID) -> String {
        PreferenceKey.pendingChatPrefix + machineID.uuidString + "." + sessionID.uuidString
    }

    private func clearPendingChatCommand(_ expected: PendingPiCommand) {
        let key = pendingChatKey(machineID: expected.target.machineId, sessionID: expected.target.sessionId)
        guard let data = preferences.object(forKey: key) as? Data,
              let saved = try? JSONDecoder().decode(PendingPiCommand.self, from: data),
              saved.commandId == expected.commandId, saved.target == expected.target,
              saved.operation == expected.operation else { return }
        preferences.removeObject(forKey: pendingChatKey(machineID: expected.target.machineId, sessionID: expected.target.sessionId))
    }

    private func resolveChatDraft(receipt: PiCommandReceipt) async -> Bool {
        guard case .chat(let target, let operation) = receipt.intent else { return false }
        guard operation == .sendMessage || operation == .sendSteeringMessage else { return true }
        if let captured = chatDrafts.pending(for: target), captured.commandID == receipt.commandId,
           captured.operation != operation { return false }
        let outcome: AxodChatDrafts.Outcome
        switch receipt.disposition {
        case .prepared: outcome = .unknown
        case .rejected: outcome = .rejected
        case .dispatched: outcome = .dispatched
        }
        return await chatDrafts.settle(commandID: receipt.commandId, target: target, outcome: outcome)
    }

    private static func knownNoEffectCode(_ error: Error) -> Int? {
        guard case AxoJSONRPCClientError.remote(let code, _) = error else { return nil }
        switch code {
        case -32601, -32602, -32001, -32002, -32003, -32005, -32006, -32007, -32009, -32010:
            return code
        default:
            return nil
        }
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
                    if !self.isEditingWork, let selected = self.selectedSessionID,
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
