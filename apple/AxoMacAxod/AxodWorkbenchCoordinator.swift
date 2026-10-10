import AppKit
import AxoCore
import AxoProtocol
import Darwin
import Observation
import ServiceManagement
import SwiftUI

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
    private(set) var chatTarget: PiChatTarget?
    private(set) var chatSnapshot: PiChatSnapshot?
    private(set) var chatEntries: [PiCanonicalProjection] = []
    private(set) var nextChatCursor: PiHistoryCursor?
    private(set) var chatStatusMessage = "Select an admitted Pi session to view its canonical conversation."
    private(set) var pendingChatCommandId: UUID?
    private(set) var pendingPiStartCommandID: UUID?
    private(set) var isStartingPi = false
    private(set) var isSendingPiMessage = false
    private(set) var isReconcilingPiCommand = false

    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var preferredMachineID: UUID?
    @ObservationIgnored private var preferredWorkspaceID: UUID?
    @ObservationIgnored private var preferredSessionID: UUID?
    private let rpc = AxoJSONRPCClient()
    private var stateDirectory: AxodStateDirectory?
    private var endpoint: LocalDaemonEndpoint?
    private var connection: AxoJSONRPCWebSocketConnection?
    private var operationGeneration = UUID()
    private var refreshGeneration = UUID()
    private var sessionLoadGeneration = UUID()
    private var chatLoadGeneration = UUID()
    private var chatObservationTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var settingsWindow: NSWindow?
    private var didCheckStartupRegistration = false
    private var didCheckDaemonService = false

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
        window.contentView = NSHostingView(rootView: AxodSettingsView(coordinator: self))
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    func connect() {
        guard connectTask == nil else { return }
        guard SMAppService.agent(plistName: Self.axodAgentPlistName).status == .enabled else {
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
        message = "Validating Axo's private daemon state."
        connectTask = Task { [weak self] in
            guard let self else { return }
            await oldConnection?.close()
            await self.bootstrapAndConnect(operation: operation)
            if self.operationGeneration == operation { self.connectTask = nil }
        }
    }

    func disconnect() {
        operationGeneration = UUID()
        refreshGeneration = UUID()
        sessionLoadGeneration = UUID()
        connectTask?.cancel()
        connectTask = nil
        let oldConnection = connection
        connection = nil
        endpoint = nil
        workspaces = []
        sessions = []
        runtimes = []
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
        sessions = []
        nextSessionCursor = nil
        let load = UUID()
        sessionLoadGeneration = load
        guard let workspaceID, let connection, let endpoint else { return }
        let operation = operationGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.fetchSessions(
                    workspaceID: workspaceID,
                    cursor: nil,
                    over: connection,
                    endpoint: endpoint,
                    operation: operation
                )
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint),
                      self.sessionLoadGeneration == load,
                      self.selectedWorkspaceID == workspaceID else { return }
                self.sessions = result.sessions
                self.selectedSessionID = result.sessions.first?.sessionId
                self.preferredWorkspaceID = workspaceID
                self.preferredSessionID = self.selectedSessionID
                self.nextSessionCursor = result.next
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
        guard sessions.contains(where: { $0.sessionId == sessionID }) else { return }
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
            if let previous {
                do {
                    try await connect(to: previous, stateDirectory: stateDirectory, operation: operation)
                    return
                } catch AxodWorkbenchError.protocolMismatch {
                    throw AxodWorkbenchError.protocolMismatch
                } catch {
                    try requireCurrent(operation)
                    message = "The discovered endpoint is stale. Waiting for the registered Axod service to publish its current boot."
                }
            }

            let discovered = try await waitForEndpoint(
                in: stateDirectory,
                replacing: previous,
                operation: operation
            )
            try await connect(to: discovered, stateDirectory: stateDirectory, operation: operation)
        } catch {
            guard operationGeneration == operation else { return }
            connectionState = .failed(error.localizedDescription)
            message = error.localizedDescription
        }
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
            if selectedWorkspaceID != preferredWorkspaceID {
                preferredSessionID = nil
            }
            preferredWorkspaceID = selectedWorkspaceID
            self.sessions = []
            self.selectedSessionID = nil
            self.nextSessionCursor = nil
            connectionState = .connected
            message = "Connected to the local axod LaunchAgent. Legacy workspaces and Pi histories were not imported or changed."
            if let workspaceID = selectedWorkspaceID {
                await loadInitialSessions(workspaceID, over: connection, endpoint: endpoint, operation: operation)
            } else {
                saveSelection()
            }
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
        if let selectedWorkspaceID,
           workspaces.workspaces.contains(where: { $0.workspaceId == selectedWorkspaceID }) {
            await loadInitialSessions(selectedWorkspaceID, over: connection, endpoint: endpoint, operation: operation)
        } else {
            self.selectedWorkspaceID = workspaces.workspaces.first?.workspaceId
            sessions = []
            selectedSessionID = nil
            nextSessionCursor = nil
            if let selectedWorkspaceID {
                await loadInitialSessions(selectedWorkspaceID, over: connection, endpoint: endpoint, operation: operation)
            } else {
                saveSelection()
            }
        }
    }

    private func loadInitialSessions(
        _ workspaceID: UUID,
        over connection: AxoJSONRPCWebSocketConnection,
        endpoint: LocalDaemonEndpoint,
        operation: UUID
    ) async {
        guard isCurrent(operation, connection: connection, endpoint: endpoint),
              selectedWorkspaceID == workspaceID else { return }
        let load = UUID()
        sessionLoadGeneration = load
        do {
            let result = try await fetchSessions(
                workspaceID: workspaceID,
                cursor: nil,
                over: connection,
                endpoint: endpoint,
                operation: operation
            )
            guard isCurrent(operation, connection: connection, endpoint: endpoint),
                  selectedWorkspaceID == workspaceID,
                  sessionLoadGeneration == load else { return }
            sessions = result.sessions
            if preferredWorkspaceID == workspaceID,
               let preferredSessionID,
               result.sessions.contains(where: { $0.sessionId == preferredSessionID }) {
                selectedSessionID = preferredSessionID
            } else {
                selectedSessionID = result.sessions.first?.sessionId
            }
            preferredWorkspaceID = workspaceID
            preferredSessionID = selectedSessionID
            nextSessionCursor = result.next
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

    private func fetchSessions(
        workspaceID: UUID,
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

    private func connectionFailed(
        _ error: Error,
        operation: UUID,
        connection: AxoJSONRPCWebSocketConnection
    ) {
        guard operationGeneration == operation, self.connection === connection else { return }
        self.connection = nil
        endpoint = nil
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
