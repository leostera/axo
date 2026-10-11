import AppKit
import AxoCore
import AxoProtocol
import Darwin
import Observation
import ServiceManagement
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

    private static let axodAgentPlistName = "dev.leostera.axo.axod.plist"

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
    private(set) var startupMessage = "Registering Axo to open at login."
    private(set) var daemonServiceMessage = "Registering the bundled axod service."
    private(set) var needsLoginItemsReview = false
    private(set) var needsDaemonServiceReview = false
    private(set) var needsLegacyDaemonReplacement = false
    private(set) var isUpgradingDaemon = false
    private(set) var chatTarget: PiChatTarget?
    private(set) var chatSnapshot: PiChatSnapshot?
    private(set) var chatEntries: [PiCanonicalProjection] = []
    private(set) var nextChatCursor: PiHistoryCursor?
    private(set) var chatStatusMessage = "Select an admitted Pi session to view its canonical conversation."
    private(set) var pendingChatCommandId: UUID?
    private(set) var pendingPiStartCommandID: UUID?
    var workEditor: AxodWorkEditorContext?
    private var activeCreationContext: AxodWorkEditorContext?
    private(set) var isEditingWork = false
    private(set) var workEditMessage = "Create a session and start your ambient Pi."
    private(set) var createdSessionForEditor: WorkSessionRecord?
    private(set) var pendingWorkCommandID: UUID?
    private(set) var pendingWorkIsUnreadable = false
    var canEditWork: Bool { connectionState == .connected && !isEditingWork && !isUpgradingDaemon && !needsLegacyDaemonReplacement && pendingWorkCommandID == nil && !pendingWorkIsUnreadable }
    private(set) var isStartingPi = false
    private(set) var isSendingPiMessage = false
    private(set) var isReconcilingPiCommand = false

    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var preferredMachineID: UUID?
    @ObservationIgnored private var preferredWorkspaceID: UUID?
    @ObservationIgnored private var preferredSessionID: UUID?
    let terminalSurfaces = AxodTerminalSurfaces()
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
    let voice = MacVoiceCoordinator(historyURL: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support/Axo/voice-transcripts.json"))
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var aboutWindow: NSWindow?
    private var catalogRevision: WorkRevision?
    private var didCheckStartupRegistration = false
    private var didCheckDaemonService = false

    func terminalLaunch(for snapshot: TerminalSnapshot, sessionID: UUID) throws -> TerminalLaunch {
        guard connectionState == .connected, let endpoint, let stateDirectory,
              snapshot.runtime.target.sessionId == sessionID,
              snapshot.runtime.hostGeneration == endpoint.hostGeneration,
              case .running = snapshot.process else { throw LaunchError.surfaceCreation }
        try stateDirectory.requireCurrentEndpoint(endpoint)
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/axod")
        return try TerminalLaunch.attachment(root: stateDirectory.root, machineID: endpoint.machineId,
                                             runtime: snapshot.runtime, helper: helper)
    }

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        preferredMachineID = UUID(uuidString: preferences.string(forKey: PreferenceKey.machineID) ?? "")
        preferredWorkspaceID = UUID(uuidString: preferences.string(forKey: PreferenceKey.workspaceID) ?? "")
        preferredSessionID = UUID(uuidString: preferences.string(forKey: PreferenceKey.sessionID) ?? "")
    }

    func registerForStartup() {
        guard !didCheckStartupRegistration else { return }
        didCheckStartupRegistration = true
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled:
            startupMessage = "Axo is registered to open at login."
        case .notRegistered:
            do {
                try service.register()
                updateStartupMessage(for: service.status)
            } catch {
                updateStartupMessage(for: service.status, registrationFailed: true)
                startupMessage = "Axo could not register for login startup: \(error.localizedDescription)"
            }
        case .requiresApproval:
            updateStartupMessage(for: service.status)
        case .notFound:
            do {
                try service.register()
                updateStartupMessage(for: service.status)
            } catch {
                startupMessage = "Axo could not register for login startup: \(error.localizedDescription)"
                needsLoginItemsReview = true
            }
        @unknown default:
            startupMessage = "Axo's login startup status is unavailable."
            needsLoginItemsReview = true
        }
    }

    func registerDaemonService() {
        guard !didCheckDaemonService else { return }
        didCheckDaemonService = true
        do {
            // Create and validate the shared private root before launchd can start axod.
            stateDirectory = try AxodStateDirectory.prepare()
        } catch {
            daemonServiceMessage = error.localizedDescription
            needsDaemonServiceReview = true
            return
        }

        let service = SMAppService.agent(plistName: Self.axodAgentPlistName)
        switch service.status {
        case .enabled:
            updateDaemonServiceMessage(for: service.status)
        case .notRegistered:
            do {
                try service.register()
                updateDaemonServiceMessage(for: service.status)
            } catch {
                updateDaemonServiceMessage(for: service.status, registrationFailed: true)
                daemonServiceMessage = "Axo could not register the axod LaunchAgent: \(error.localizedDescription)"
            }
        case .requiresApproval:
            updateDaemonServiceMessage(for: service.status)
        case .notFound:
            do {
                try service.register()
                updateDaemonServiceMessage(for: service.status)
            } catch {
                daemonServiceMessage = "Axo could not register the axod LaunchAgent: \(error.localizedDescription)"
                needsDaemonServiceReview = true
            }
        @unknown default:
            daemonServiceMessage = "The axod LaunchAgent status is unavailable."
            needsDaemonServiceReview = true
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
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

    private func updateDaemonServiceMessage(for status: SMAppService.Status, registrationFailed: Bool = false) {
        switch status {
        case .enabled:
            daemonServiceMessage = "Bundled axod is registered as a per-user LaunchAgent."
            needsDaemonServiceReview = false
        case .requiresApproval:
            daemonServiceMessage = "Approve the axod background service in System Settings Login Items."
            needsDaemonServiceReview = true
        case .notRegistered:
            daemonServiceMessage = registrationFailed
                ? "Axo could not register the axod background service. Review Login Items in System Settings."
                : "The axod background service is not registered."
            needsDaemonServiceReview = true
        case .notFound:
            daemonServiceMessage = "The bundled axod LaunchAgent plist was not found."
            needsDaemonServiceReview = true
        @unknown default:
            daemonServiceMessage = "The axod LaunchAgent status is unavailable."
            needsDaemonServiceReview = true
        }
    }

    private func updateStartupMessage(for status: SMAppService.Status, registrationFailed: Bool = false) {
        switch status {
        case .enabled:
            startupMessage = "Axo is registered to open at login."
            needsLoginItemsReview = false
        case .requiresApproval:
            startupMessage = "Approve Axo in System Settings to open it automatically at login."
            needsLoginItemsReview = true
        case .notRegistered:
            startupMessage = registrationFailed
                ? "Axo could not register for login startup. Review Login Items in System Settings."
                : "Axo is not registered to open at login."
            needsLoginItemsReview = true
        case .notFound:
            startupMessage = "Axo's app bundle was not found for login startup."
            needsLoginItemsReview = true
        @unknown default:
            startupMessage = "Axo's login startup status is unavailable."
            needsLoginItemsReview = true
        }
    }

    func connect(createInitialSession: Bool = false) {
        guard connectTask == nil, !isUpgradingDaemon else { return }
        guard SMAppService.agent(plistName: Self.axodAgentPlistName).status != .requiresApproval else {
            connectionState = .failed(daemonServiceMessage)
            message = daemonServiceMessage
            return
        }
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
            if createInitialSession, self.operationGeneration == operation, self.canEditWork,
               self.workspaces.isEmpty, self.sessions.isEmpty, self.runtimes.isEmpty,
               let revision = self.catalogRevision, let endpoint = self.endpoint {
                let context = AxodWorkEditorContext(kind: .session(workspaceID: nil),
                    target: MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration), revision: revision)
                self.createdSessionForEditor = nil
                self.activeCreationContext = context
                self.createWork(context, name: "New Session", directory: nil)
            }
            if self.operationGeneration == operation { self.connectTask = nil }
        }
    }

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
        nextChatCursor = nil
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

    @objc func newWorkspace() { prepareWorkEditor(.workspace) }
    @objc func newSession() { prepareWorkEditor(.session(workspaceID: nil)) }
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
                self.preferredWorkspaceID = session.workspaceId
                self.preferredSessionID = session.sessionId
                self.saveSelection()
                self.workEditMessage = "Session created. Starting Pi…"
                let ready = await self.startCreatedSession(session, target: context.target, over: connection,
                                                          endpoint: endpoint, operation: operation)
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint),
                      self.selectedSessionID == session.sessionId else { return }
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
        preferences.removeObject(forKey: pendingWorkKey(machineID))
        if self.machineID == machineID { pendingWorkCommandID = nil }
    }

    func refresh() {
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
                self.message = "Showing daemon-owned work records and runtime metadata."
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
        nextChatCursor = nil
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
        nextChatCursor = nil
        selectedSessionID = sessionID
        preferredSessionID = sessionID
        saveSelection()
        activateSelectedSession()
    }

    var selectedSession: WorkSessionRecord? {
        sessions.first { $0.sessionId == selectedSessionID }
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
        defer { isStartingPi = false }
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
        guard connectionState == .connected, !isUpgradingDaemon, let session = selectedSession,
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
                let history = try await self.fetchChatHistory(
                    target: target, readMode: readMode, cursor: nil, over: connection, endpoint: endpoint, operation: operation
                )
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint),
                      self.chatLoadGeneration == load, self.chatTarget == target else { return }
                self.chatSnapshot = snapshot
                self.chatEntries = Self.merging(history.entries, snapshot.recentEntries)
                self.nextChatCursor = history.next
                self.chatStatusMessage = "Showing Pi-owned canonical history. A dispatched message is not proof of execution."
                self.beginChatObservation(target: target, readMode: readMode, load: load, over: connection, endpoint: endpoint, operation: operation)
            } catch {
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint),
                      self.chatLoadGeneration == load else { return }
                self.chatStatusMessage = "The captured Pi history could not be read. Refresh to reconcile this exact session."
            }
        }
    }

    func loadMoreChatHistory() {
        guard let target = chatTarget, let cursor = nextChatCursor,
              let snapshot = chatSnapshot, let connection, let endpoint else { return }
        let operation = operationGeneration
        let load = chatLoadGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.fetchChatHistory(
                    target: target, readMode: snapshot.readMode, cursor: cursor,
                    over: connection, endpoint: endpoint, operation: operation
                )
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint),
                      self.chatLoadGeneration == load, self.chatTarget == target else { return }
                self.chatEntries = Self.merging(self.chatEntries, page.entries)
                self.nextChatCursor = page.next
            } catch {
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint),
                      self.chatLoadGeneration == load, self.chatTarget == target else { return }
                self.chatStatusMessage = "The history cursor is stale. Refresh the selected chat before loading more."
            }
        }
    }

    func sendChatMessage(_ text: String) {
        guard let snapshot = chatSnapshot, snapshot.admission == .ready, snapshot.readMode == .live,
              !snapshot.busy, !snapshot.recovery, snapshot.uiWaits == 0, snapshot.question == nil else {
            chatStatusMessage = "Pi is not ready for a normal message. Refresh its state; no message was sent."
            return
        }
        sendPiMutation(operation: .sendMessage, interactionID: nil, questionID: nil, optionID: nil, text: text)
    }

    func steerChat(_ text: String) {
        guard let snapshot = chatSnapshot, snapshot.busy,
              let interactionID = snapshot.interactionId,
              snapshot.readMode == .live, !snapshot.recovery,
              snapshot.uiWaits == 0, snapshot.question == nil else {
            chatStatusMessage = "No steerable Pi interaction is currently captured."
            return
        }
        sendPiMutation(operation: .sendSteeringMessage, interactionID: interactionID, questionID: nil, optionID: nil, text: text)
    }

    func cancelChatTurn() {
        guard let snapshot = chatSnapshot, snapshot.busy,
              let interactionID = snapshot.interactionId,
              snapshot.readMode == .live, !snapshot.recovery else {
            chatStatusMessage = "There is no captured Pi interaction to cancel."
            return
        }
        sendPiMutation(operation: .cancelTurn, interactionID: interactionID, questionID: nil, optionID: nil, text: nil)
    }

    func answerChatQuestion(_ question: PiQuestion, option: PiQuestionOption) {
        guard let snapshot = chatSnapshot, snapshot.readMode == .live,
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
        guard let endpoint, let connection, let session = selectedSession,
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
                guard case .pi(let receipt)? = result.receipt,
                      receipt.commandId == pending.commandId,
                      receipt.intent == .chat(target: pending.target, operation: pending.operation) else {
                    self.chatStatusMessage = "No matching durable Pi command receipt is visible. It was not replayed."
                    return
                }
                switch receipt.disposition {
                case .prepared:
                    self.chatStatusMessage = "The original Pi command is still prepared or uncertain. It was not replayed."
                case .rejected(let code):
                    self.clearPendingChatCommand(machineID: endpoint.machineId, sessionID: session.sessionId)
                    self.pendingChatCommandId = nil
                    self.chatStatusMessage = "The original Pi command was rejected before dispatch (\(code))."
                case .dispatched:
                    self.clearPendingChatCommand(machineID: endpoint.machineId, sessionID: session.sessionId)
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
        do {
            let stateDirectory = try AxodStateDirectory.prepare()
            try requireCurrent(operation)
            self.stateDirectory = stateDirectory

            let previous = try stateDirectory.readEndpoint()
            var repairedRegistration = false
            if let previous {
                do {
                    try await connect(to: previous, stateDirectory: stateDirectory, operation: operation)
                    try await upgradeConnectedDaemon(in: stateDirectory, operation: operation)
                    return
                } catch AxodWorkbenchError.protocolMismatch {
                    throw AxodWorkbenchError.protocolMismatch
                } catch {
                    try requireCurrent(operation)
                    // A live owner is not a stale-file problem and must never be unregistered here.
                    guard try await repairOwnerlessDaemonService(in: stateDirectory, operation: operation) else { throw error }
                    repairedRegistration = true
                }
            }

            let discovered: LocalDaemonEndpoint
            do {
                discovered = try await waitForEndpoint(in: stateDirectory, replacing: previous, operation: operation)
            } catch {
                guard !repairedRegistration,
                      try await repairOwnerlessDaemonService(in: stateDirectory, operation: operation) else { throw error }
                discovered = try await waitForEndpoint(in: stateDirectory, replacing: previous, operation: operation)
            }
            try await connect(to: discovered, stateDirectory: stateDirectory, operation: operation)
            try await upgradeConnectedDaemon(in: stateDirectory, operation: operation)
        } catch {
            guard operationGeneration == operation else { return }
            connectionState = .failed(error.localizedDescription)
            message = error.localizedDescription
        }
    }

    private func upgradeConnectedDaemon(in stateDirectory: AxodStateDirectory, operation: UUID) async throws {
        guard !isUpgradingDaemon, let connection, let endpoint, Bundle.main.bundleIdentifier == "dev.leostera.axo.mac" else { return }
        isUpgradingDaemon = true
        defer { isUpgradingDaemon = false }
        let decision = try await AxodDaemonUpgrade.prepare(over: connection, endpoint: endpoint, preferences: preferences,
            info: Bundle.main.infoDictionary ?? [:], validate: {
                try self.requireCurrent(operation)
                try stateDirectory.requireCurrentEndpoint(endpoint)
            })
        switch decision {
        case .keepCurrent: needsLegacyDaemonReplacement = false
        case .legacyAwaitingSafeStop:
            needsLegacyDaemonReplacement = true
            daemonServiceMessage = "Automatic helper update is waiting for the older daemon to stop safely. This version cannot prove an idle handoff; running or uncertain work is preserved."
        case .deferredActiveWork:
            needsLegacyDaemonReplacement = false
            daemonServiceMessage = "Helper update deferred: an owned runtime is still running or its completion is uncertain. Your work was left untouched."
        case .quiesced:
            try await replaceDaemonRegistration(in: stateDirectory, replacing: endpoint, operation: operation)
        }
    }

    private func replaceDaemonRegistration(in stateDirectory: AxodStateDirectory, replacing previous: LocalDaemonEndpoint,
                                            operation: UUID) async throws {
        try requireCurrent(operation)
        try stateDirectory.requireCurrentEndpoint(previous)
        connectionState = .starting
        hostObservationTask?.cancel()
        hostStatus = nil
        message = "Installing this app’s axod helper. Work and Pi history are preserved."
        let service = SMAppService.agent(plistName: Self.axodAgentPlistName)
        // An unstructured MainActor task completes the captured registration operation
        // even if the connect task is canceled after unregistering the old job.
        let registration = Task { @MainActor in
            try await service.unregister()
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            var absence: AxodOwnerAbsenceLease?
            repeat {
                absence = try AxodOwnerAbsenceLease.acquire(in: stateDirectory.root)
                if absence != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            } while ContinuousClock.now < deadline
            guard let absence else { throw AxodWorkbenchError.startupTimedOut }
            defer { absence.release() }
            absence.release()
            try service.register()
        }
        try await registration.value
        try requireCurrent(operation)
        let oldConnection = connection
        connection = nil
        await oldConnection?.close()
        let fresh = try await waitForEndpoint(in: stateDirectory, replacing: previous, operation: operation)
        try await connect(to: fresh, stateDirectory: stateDirectory, operation: operation)
        guard let connection else { throw AxodWorkbenchError.startupTimedOut }
        let target = MachineTarget(machineId: fresh.machineId, hostGeneration: fresh.hostGeneration)
        let value = try await connection.request(method: AxoProtocol.Method.getHost, parameters: HostGetParameters(target: target))
        try requireCurrent(operation)
        try stateDirectory.requireCurrentEndpoint(fresh)
        let running = try AxoProtocolResultValidator.host(value, target: target)
        guard running.daemonVersion == Bundle.main.infoDictionary?["AxoBundledAxodVersion"] as? String else {
            throw AxoProtocolValidationError.invalidResult(method: AxoProtocol.Method.getHost)
        }
        preferences.removeObject(forKey: AxodDaemonUpgrade.pendingKey(fresh.machineId))
        needsLegacyDaemonReplacement = false
        daemonServiceMessage = "The current bundled axod helper is running."
    }

    private func repairOwnerlessDaemonService(in stateDirectory: AxodStateDirectory, operation: UUID) async throws -> Bool {
        try requireCurrent(operation)
        let service = SMAppService.agent(plistName: Self.axodAgentPlistName)
        guard Bundle.main.bundleIdentifier == "dev.leostera.axo.mac" else { return false }
        let needsRemoval: Bool
        switch service.status {
        case .enabled, .notFound: needsRemoval = true
        case .notRegistered: needsRemoval = false
        case .requiresApproval: return false
        @unknown default: return false
        }
        guard let absence = try AxodOwnerAbsenceLease.acquire(in: stateDirectory.root) else { return false }
        defer { absence.release() }
        message = "Repairing the stopped axod service registration for this app bundle."
        if needsRemoval { try await service.unregister() }
        // Finish the captured registration repair even if a newer connect supersedes its UI.
        // Registration may launch immediately. Release only after the old job is removed.
        absence.release()
        try service.register()
        try requireCurrent(operation)
        updateDaemonServiceMessage(for: service.status)
        return true
    }

    private func connect(
        to endpoint: LocalDaemonEndpoint,
        stateDirectory: AxodStateDirectory,
        operation: UUID
    ) async throws {
        try requireCurrent(operation)
        let connection = try rpc.openLocalWebSocket(endpoint: endpoint)
        self.endpoint = endpoint
        self.connection = connection
        do {
            let negotiation = try await connection.request(
                method: AxoProtocol.Method.negotiate,
                parameters: NegotiationParameters()
            )
            do { _ = try AxoProtocolResultValidator.localNegotiation(negotiation) }
            catch { throw AxodWorkbenchError.protocolMismatch }
            try requireCurrent(operation)
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
            pendingWorkIsUnreadable = savedWork != nil && pendingWorkCommandID == nil
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
        stopChatObservation()
        chatTarget = nil
        chatSnapshot = nil
        chatEntries = []
        nextChatCursor = nil
        guard let session = selectedSession, let endpoint else {
            stopChatObservation()
            chatTarget = nil
            chatSnapshot = nil
            chatEntries = []
            nextChatCursor = nil
            pendingPiStartCommandID = nil
            pendingChatCommandId = nil
            chatStatusMessage = "Select an admitted Pi session to view its canonical conversation."
            return
        }
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
            nextChatCursor = nil
            chatStatusMessage = "This session has no Pi conversation yet. Start Pi explicitly to create one."
            return
        case .recoveryRequired:
            chatTarget = nil
            chatSnapshot = nil
            chatEntries = []
            nextChatCursor = nil
            chatStatusMessage = "Axod cannot prove the Pi writer stopped. Recovery is required before history or resume."
            return
        case .ready, .stopped, .failed:
            break
        }
        guard let chatID = session.pi.chatId, let runtime = session.runtime?.runtime else {
            chatTarget = nil
            chatSnapshot = nil
            chatEntries = []
            nextChatCursor = nil
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
        case .ready:
            chatTarget = target
            refreshChat()
        case .stopped, .failed:
            chatTarget = target
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
        text: String?
    ) {
        guard let target = chatTarget, let endpoint, let connection,
              chatSnapshot?.readMode == .live else { return }
        let key = pendingChatKey(machineID: endpoint.machineId, sessionID: target.sessionId)
        if preferences.data(forKey: key) != nil {
            pendingChatCommandId = readPendingChatCommand(machineID: endpoint.machineId, sessionID: target.sessionId)?.commandId
            chatStatusMessage = "A prior Pi command may have an unknown outcome. Reconcile it before sending another."
            return
        }
        let pending = PendingPiCommand(target: target, commandId: UUID(), operation: operation)
        do { preferences.set(try JSONEncoder().encode(pending), forKey: key) }
        catch {
            chatStatusMessage = "The Pi command identity could not be saved. Nothing was sent."
            return
        }
        pendingChatCommandId = pending.commandId
        let operationID = operationGeneration
        isSendingPiMessage = true
        chatStatusMessage = "Submitting the captured Pi command."

        Task { [weak self] in
            guard let self else { return }
            defer { self.isSendingPiMessage = false }
            do {
                let value: JSONValue
                let method: String
                switch operation {
                case .sendMessage:
                    guard let text, PiProtocolValidator.validMessageText(text) else {
                        throw AxoProtocolValidationError.invalidParameters(method: AxoProtocol.Method.sendChatMessage)
                    }
                    let parameters = PiChatTextParameters(target: target, commandId: pending.commandId, text: text)
                    method = AxoProtocol.Method.sendChatMessage
                    value = try await connection.request(method: method, parameters: parameters)
                case .sendSteeringMessage:
                    guard let interactionID, interactionID != UUID(), let text,
                          PiProtocolValidator.validMessageText(text) else {
                        throw AxoProtocolValidationError.invalidParameters(method: AxoProtocol.Method.sendChatSteeringMessage)
                    }
                    let parameters = PiChatSteeringParameters(
                        target: target, commandId: pending.commandId, interactionId: interactionID, text: text
                    )
                    method = AxoProtocol.Method.sendChatSteeringMessage
                    value = try await connection.request(method: method, parameters: parameters)
                case .cancelTurn:
                    guard let interactionID, interactionID != UUID() else {
                        throw AxoProtocolValidationError.invalidParameters(method: AxoProtocol.Method.cancelChatTurn)
                    }
                    let parameters = PiChatCancelParameters(target: target, commandId: pending.commandId, interactionId: interactionID)
                    method = AxoProtocol.Method.cancelChatTurn
                    value = try await connection.request(method: method, parameters: parameters)
                case .answerQuestion:
                    guard let interactionID, interactionID != UUID(), let questionID, questionID != UUID(),
                          let optionID, optionID != UUID() else {
                        throw AxoProtocolValidationError.invalidParameters(method: AxoProtocol.Method.answerChatQuestion)
                    }
                    let parameters = PiChatAnswerParameters(
                        target: target, commandId: pending.commandId, interactionId: interactionID,
                        questionId: questionID, optionId: optionID
                    )
                    method = AxoProtocol.Method.answerChatQuestion
                    value = try await connection.request(method: method, parameters: parameters)
                case .setViewing:
                    throw AxoProtocolValidationError.invalidParameters(method: AxoProtocol.Method.setChatViewing)
                }
                let result = try PiProtocolValidator.mutation(
                    value, target: target, commandId: pending.commandId, operation: operation, method: method
                )
                guard self.isCurrent(operationID, connection: connection, endpoint: endpoint),
                      self.chatTarget == target else { return }
                switch result.receipt.disposition {
                case .prepared:
                    self.chatStatusMessage = "The Pi command is prepared or uncertain. Reconcile it; do not resend."
                case .rejected(let code):
                    self.clearPendingChatCommand(machineID: endpoint.machineId, sessionID: target.sessionId)
                    self.pendingChatCommandId = nil
                    self.chatStatusMessage = "Pi rejected the command before dispatch (\(code))."
                case .dispatched:
                    self.clearPendingChatCommand(machineID: endpoint.machineId, sessionID: target.sessionId)
                    self.pendingChatCommandId = nil
                    self.chatStatusMessage = "Pi's public API acknowledged dispatch; execution is not inferred. Refreshing canonical history."
                    self.refreshChat()
                }
            } catch {
                guard self.operationGeneration == operationID,
                      self.selectedSessionID == target.sessionId else { return }
                if let code = Self.knownNoEffectCode(error) {
                    self.clearPendingChatCommand(machineID: endpoint.machineId, sessionID: target.sessionId)
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
                    self.chatSnapshot = snapshot
                    self.chatEntries = Self.merging(self.chatEntries, snapshot.recentEntries)
                } catch {
                    guard self.isCurrent(operation, connection: connection, endpoint: endpoint) else { return }
                    self.chatStatusMessage = "Live Pi refresh failed. No command was replayed."
                    return
                }
            }
        }
    }

    private func stopChatObservation() {
        chatObservationTask?.cancel()
        chatObservationTask = nil
        chatLoadGeneration = UUID()
    }

    private func readPendingChatCommand(machineID: UUID, sessionID: UUID) -> PendingPiCommand? {
        let key = pendingChatKey(machineID: machineID, sessionID: sessionID)
        guard let data = preferences.data(forKey: key),
              let pending = try? JSONDecoder().decode(PendingPiCommand.self, from: data),
              pending.target.machineId == machineID, pending.target.sessionId == sessionID else { return nil }
        return pending
    }

    private func pendingStartKey(machineID: UUID, sessionID: UUID) -> String {
        PreferenceKey.pendingStartPrefix + machineID.uuidString + "." + sessionID.uuidString
    }

    private func pendingChatKey(machineID: UUID, sessionID: UUID) -> String {
        PreferenceKey.pendingChatPrefix + machineID.uuidString + "." + sessionID.uuidString
    }

    private func clearPendingChatCommand(machineID: UUID, sessionID: UUID) {
        preferences.removeObject(forKey: pendingChatKey(machineID: machineID, sessionID: sessionID))
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

    private static func merging(
        _ older: [PiCanonicalProjection],
        _ newer: [PiCanonicalProjection]
    ) -> [PiCanonicalProjection] {
        var positions: [String: Int] = [:]
        var merged: [PiCanonicalProjection] = []
        for entry in older + newer {
            if let position = positions[entry.entryId] {
                merged[position] = entry
            } else {
                positions[entry.entryId] = merged.count
                merged.append(entry)
            }
        }
        return merged
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

    private func waitForEndpoint(
        in stateDirectory: AxodStateDirectory,
        replacing previous: LocalDaemonEndpoint?,
        operation: UUID
    ) async throws -> LocalDaemonEndpoint {
        for _ in 0..<100 {
            try requireCurrent(operation)
            if let endpoint = try stateDirectory.readEndpoint(), endpoint != previous { return endpoint }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AxodWorkbenchError.startupTimedOut
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
                    self.hostStatus = try AxoProtocolResultValidator.host(value, target: MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration))
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
                    if self.connectTask == nil, !self.isUpgradingDaemon, !self.isEditingWork,
                       self.hostStatus?.daemonVersion != Bundle.main.infoDictionary?["AxoBundledAxodVersion"] as? String,
                       let directory = self.stateDirectory {
                        // A separate task survives cancellation of this observation loop during handoff.
                        Task { [weak self] in
                            guard let self else { return }
                            do { try await self.upgradeConnectedDaemon(in: directory, operation: operation) }
                            catch {
                                guard self.operationGeneration == operation else { return }
                                self.daemonServiceMessage = "Automatic helper update could not be confirmed. Its captured handoff will be reconciled; no work was replayed."
                            }
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
        self.connection = nil
        endpoint = nil
        hostObservationTask?.cancel()
        hostStatus = nil
        workspaces = []; sessions = []; runtimes = []
        nextWorkspaceCursor = nil; nextSessionCursor = nil; nextRuntimeID = nil
        selectedWorkspaceID = nil; selectedSessionID = nil
        stopChatObservation()
        chatTarget = nil; chatSnapshot = nil; chatEntries = []; nextChatCursor = nil
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
        case .startupTimedOut: "The registered axod LaunchAgent did not publish a fresh discovery endpoint in time."
        }
    }
}
