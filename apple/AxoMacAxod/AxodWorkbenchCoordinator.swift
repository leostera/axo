import AppKit
import AxoCore
import AxoProtocol
import Foundation
import Observation
import SwiftUI
import UserNotifications

/// Presentation and addressed central reads. No catalog fallback, frontend
/// admission, preference-hint recovery or daemon supervision is reachable here.
@MainActor @Observable final class AxodWorkbenchCoordinator {
    enum ConnectionState: Equatable { case starting, connected, disconnected, failed(String) }
    private enum PreferenceKey {
        static let machine = "Axo.central.selection.machine"
        static let store = "Axo.central.selection.store"
        static let workspace = "Axo.central.selection.workspace"
        static let session = "Axo.central.selection.session"
    }
    private(set) var connectionState: ConnectionState = .starting
    private(set) var catalog: CentralCatalog?
    var workspaces: [CentralWorkspace] { catalog?.workspaces ?? [] }
    var sessions: [CentralSession] { catalog?.sessions.map(\.session) ?? [] }
    var runtimes: [TerminalSnapshot] { catalog?.terminals ?? [] }
    var machineID: UUID? { catalog?.source.machine.machineId }
    private(set) var selectedWorkspaceID: UUID?
    private(set) var selectedSessionID: UUID?
    private(set) var selectedPiObservation: CentralPiObservation?
    private(set) var selectedPiResponse: CentralResponse?
    private(set) var selectedPiState: CentralPiLiveState?
    private(set) var selectedPiHistory: CentralPiHistoryPage?
    private(set) var selectedPiReadUnavailable = false
    @ObservationIgnored private var selectedPiTarget: CentralPiBindingTarget?
    @ObservationIgnored private var piReadGeneration = UUID()
    var selectedSession: CentralSession? { sessions.first { $0.sessionId == selectedSessionID } }
    var sidebarSessionNames: [UUID: String] {
        guard let catalog else { return [:] }
        return Dictionary(uniqueKeysWithValues: catalog.sessions.map { view in
            let session = view.session
            return (session.sessionId, CentralSessionDisplayName.resolve(
                catalogName: session.name,
                manualName: session.manualName,
                sessionId: session.sessionId,
                workspaceId: session.workspaceId,
                selectedSessionId: selectedSessionID,
                source: catalog.source,
                revision: catalog.revision,
                piResponse: selectedPiResponse,
                piReadUnavailable: selectedPiReadUnavailable
            ))
        })
    }
    func displayName(for session: CentralSession) -> String {
        CentralSessionDisplayName.resolve(
            catalogName: session.name,
            manualName: session.manualName,
            sessionId: session.sessionId,
            workspaceId: session.workspaceId,
            selectedSessionId: selectedSessionID,
            source: catalog?.source,
            revision: catalog?.revision,
            piResponse: selectedPiResponse,
            piReadUnavailable: selectedPiReadUnavailable
        )
    }
    private(set) var hostStatus: HostStatusResult?
    private(set) var helperUpdateAvailable = false
    private(set) var message = "Connecting to the Axod background service."
    private(set) var serviceSetupFailure: String?
    let serviceLifecycle: AxodServiceLifecycle
    let setupPresentation: AxodSetupPresentation
    let paneLayouts = AxodPaneLayouts()
    let terminalSurfaces = AxodTerminalSurfaces()
    let inputBuffers = CentralInputBuffers()
    let creations = CentralCreations()
    let renames = CentralRenames()
    let voice: MacVoiceCoordinator
    @ObservationIgnored let preferences: UserDefaults
    @ObservationIgnored private var endpoint: LocalDaemonEndpoint?
    @ObservationIgnored private var directory: AxodStateDirectory?
    @ObservationIgnored private var connection: AxoJSONRPCWebSocketConnection?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var aboutWindow: NSWindow?
    @ObservationIgnored private var serviceSettingsWindow: NSWindow?
    private let rpc = AxoJSONRPCClient()
    private var operation = UUID()
    private var refreshGeneration = UUID()
    private var catalogLoadGeneration = UUID()
    private var reconcilingCreation: UUID?
    @ObservationIgnored private var reconcilingPiInputs = Set<UUID>()
    @ObservationIgnored private var nextPiInputReconciliation: UUID?
    @ObservationIgnored private var reconcilingRename: UUID?
    private var creationRevisionFloor: (source: CentralSource, revision: CentralRevision)?
    private var serviceObservation: UUID?
    private var usesFixtureDaemon = false
#if AXO_NATIVE_FIXTURE
    @ObservationIgnored private var fixtureAttachmentHelper: URL?
#endif
    init(preferences: UserDefaults = .standard, voiceHistoryURL: URL? = nil, serviceLifecycle: AxodServiceLifecycle? = nil) {
        self.preferences = preferences
        self.serviceLifecycle = serviceLifecycle ?? .shared
        setupPresentation = AxodSetupPresentation(preferences: preferences)
#if AXO_NATIVE_FIXTURE
        voice = MacVoiceCoordinator()
#else
        voice = MacVoiceCoordinator(historyURL: voiceHistoryURL ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support/Axo/voice-transcripts.json"))
#endif
        terminalSurfaces.onMoveFocus = { [weak self] view, direction in
            guard let self, let window = view.window, NSApp.keyWindow === window, window.firstResponder === view else { return false }
            return self.focusPane(direction, in: window)
        }
    }
    var onlineMessage: String {
        guard connectionState == .connected else { return "axo is offline" }
        return hostStatus?.cloud.isOnline == true ? "axo is online" : "axo is connected locally"
    }
    var showsSetup: Bool { !usesFixtureDaemon && !setupPresentation.enteredWorkbench }
    var setupStage: AxodSetupPolicy.Stage {
        let fact: AxodSetupPolicy.Connection
        if connectTask != nil || connectionState == .starting { fact = .checking }
        else if connectionState == .connected, let endpoint { fact = .loaded(.init(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration)) }
        else { fact = .unavailable }
        return AxodSetupPolicy.stage(registration: serviceLifecycle.registration, availability: serviceLifecycle.availability, connection: fact)
    }
    var setupLoginStartup: Bool {
        get { setupPresentation.requestedLoginStartup ?? (serviceLifecycle.loginRegistration == .enabled || serviceLifecycle.loginRegistration == .requiresApproval) }
        set { setupPresentation.requestedLoginStartup = newValue }
    }
    var daemonServiceMessage: String { serviceLifecycle.failureMessage ?? serviceLifecycle.registration.message }
    var needsLoginItemsReview: Bool { serviceLifecycle.loginRegistration == .requiresApproval }
    var needsDaemonServiceReview: Bool { !usesFixtureDaemon && serviceLifecycle.registration != .enabled }
    var serviceReviewMessage: String { needsLoginItemsReview && !needsDaemonServiceReview ? "Opening the Axo menu-bar app at login needs macOS approval. The daemon registration is separate." : daemonServiceMessage }
    var hasUnresolvedHelperHandoff: Bool {
        machineID.map { preferences.object(forKey: "Axo.axod.pendingUpgrade.\($0.uuidString)") != nil } ?? false
    }
    @discardableResult func beginFirstLaunchSetup() -> Bool {
        guard !usesFixtureDaemon, !setupPresentation.enteredWorkbench, preferences.object(forKey: AxodSetupPresentation.completionKey) == nil else { return false }
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
        } catch { serviceSetupFailure = serviceLifecycle.failureMessage ?? error.localizedDescription; return false }
    }
    func refreshSetupAfterActivation() {
        guard showsSetup, connectTask == nil, serviceLifecycle.operation == .idle else { return }
        serviceLifecycle.observeRegistration()
        if serviceLifecycle.registration == .enabled, connectionState != .connected { connect() }
    }
    func enableBackgroundService() {
        serviceSetupFailure = nil
        do { let directory = try AxodStateDirectory.prepare(); try serviceLifecycle.enableAgent(in: directory.root); connect() }
        catch { serviceSetupFailure = error.localizedDescription }
    }
    func finishSetup() async {
        guard !setupPresentation.isFinishing, case .ready(let target) = setupStage else { return }
        setupPresentation.isFinishing = true
        defer { setupPresentation.isFinishing = false }
        setupPresentation.failure = nil
        let captured = operation
        if let requested = setupPresentation.requestedLoginStartup {
            guard await serviceLifecycle.setFrontendAtLogin(requested) else {
                setupPresentation.failure = serviceLifecycle.failureMessage ?? "Another service setting is still being changed. Wait for it before finishing setup."
                return
            }
        }
        guard captured == operation, setupPresentation.complete(captured: target, stage: setupStage) else {
            setupPresentation.failure = "The service changed during setup. Check its current readiness before opening Axo."
            return
        }
    }
    func openLoginItemsSettings() { serviceLifecycle.openApprovalSettings() }
    func showServiceSettingsWindow() {
        serviceLifecycle.observeRegistration()
        if let serviceSettingsWindow { serviceSettingsWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Background Service"; window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: AxodServiceSettingsView(coordinator: self))
        window.center(); serviceSettingsWindow = window; window.makeKeyAndOrderFront(nil)
    }
    func showSettingsWindow() {
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 520), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Settings"; window.isReleasedWhenClosed = false; window.toolbarStyle = .unified
        window.contentViewController = NSHostingController(rootView: AxodSettingsView(coordinator: self))
        window.center(); settingsWindow = window; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func showAboutWindow() {
        if let aboutWindow { aboutWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 370), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "About Axo"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AxodAboutView(coordinator: self))
        window.center(); aboutWindow = window; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func notificationPreferenceChanged(_ enabled: Bool) {
        guard enabled else { return }; UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    func openNotificationSettings() {
        var components = URLComponents(); components.scheme = "x-apple.systempreferences"; components.path = "com.apple.Notifications-Settings.extension"
        components.queryItems = [.init(name: "id", value: Bundle.main.bundleIdentifier)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
    func connect() {
        guard connectTask == nil else { return }
        let captured = UUID()
        operation = captured
        let old = connection
        connection = nil
        endpoint = nil
        catalog = nil
        clearSelectedPi()
        hostStatus = nil
        observationTask?.cancel()
        connectionState = .starting
        connectTask = Task { [weak self] in
            guard let self else { return }
            await old?.close()
            await self.discoverAndConnect(operation: captured)
            guard self.operation == captured else { return }
            self.connectTask = nil
            if self.connectionState == .connected { self.setupPresentation.restoreIfKnownReady(self.setupStage) }
        }
    }
    private func discoverAndConnect(operation captured: UUID) async {
        let observation = serviceLifecycle.beginObservation()
        serviceObservation = observation
        do {
            let directory = try AxodStateDirectory.prepare()
            self.directory = directory
            if !usesFixtureDaemon { try serviceLifecycle.requireEnabled() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            var delay = 100
            while ContinuousClock.now < deadline {
                guard captured == operation else { throw AxodWorkbenchError.superseded }
                if let endpoint = try directory.readEndpoint() {
                    do {
                        try await connect(to: endpoint, operation: captured, deadline: deadline)
                        return
                    }
                    catch AxodWorkbenchError.protocolMismatch { throw AxodWorkbenchError.protocolMismatch }
                    catch { guard captured == operation else { throw AxodWorkbenchError.superseded } }
                }
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else { break }
                try await Task.sleep(for: min(.milliseconds(min(2000, delay * Int.random(in: 80...120) / 100)), remaining))
                delay = min(2000, delay * 2)
            }
            throw AxodWorkbenchError.startupTimedOut
        } catch {
            guard captured == operation else { return }
            serviceLifecycle.observedUnavailable(observation: observation)
            connectionState = .failed(error.localizedDescription)
            message = error.localizedDescription
        }
    }
    private func connect(to endpoint: LocalDaemonEndpoint, operation captured: UUID, deadline: ContinuousClock.Instant? = nil) async throws {
        guard captured == operation else { throw AxodWorkbenchError.superseded }
        let peer = try rpc.openLocalWebSocket(endpoint: endpoint)
        self.connection = peer
        self.endpoint = endpoint
        do {
            let rawNegotiation = try await peer.request(method: AxoProtocol.Method.negotiate, parameters: NegotiationParameters(), timeout: timeout(deadline))
            do { _ = try AxoProtocolResultValidator.localNegotiation(rawNegotiation) }
            catch { throw AxodWorkbenchError.protocolMismatch }
            let machine = MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration)
            let bootstrap = try await perform(CentralRequest.bootstrap(machine: machine), peer: peer, endpoint: endpoint, operation: captured, deadline: deadline)
            let loaded = try await loadCatalog(source: bootstrap.source, peer: peer, endpoint: endpoint, operation: captured, deadline: deadline)
            let value = try await peer.request(method: AxoProtocol.Method.getHost, parameters: HostGetParameters(target: machine), timeout: timeout(deadline))
            let host = try AxoProtocolResultValidator.host(value, target: machine)
            try requireCurrent(captured, peer: peer, endpoint: endpoint)
            publish(loaded, restoringSelection: true)
            hostStatus = host
            helperUpdateAvailable = host.daemonVersion != Bundle.main.infoDictionary?["AxoBundledAxodVersion"] as? String
            if let serviceObservation { serviceLifecycle.observedReady(machine, observation: serviceObservation) }
            connectionState = .connected
            message = "Connected to axod."
            observe(peer: peer, endpoint: endpoint, operation: captured)
            if let ticket = creations.pendingTicket {
                Task { await self.reconcileCreation(ticket, peer: peer, endpoint: endpoint, operation: captured) }
            }
        } catch {
            await peer.close()
            if connection === peer { connection = nil; self.endpoint = nil }
            throw error
        }
    }
#if AXO_NATIVE_FIXTURE
    /// The test harness owns the fixture service; this seam neither launches nor repairs it.
    func connectOwnedFixture(root: URL, helper: URL) async throws {
        guard connection == nil else { throw AxodWorkbenchError.superseded }
        usesFixtureDaemon = true
        fixtureAttachmentHelper = helper
        let directory = try AxodStateDirectory.openExisting(root: root)
        self.directory = directory
        guard let endpoint = try directory.readEndpoint() else { throw AxodWorkbenchError.startupTimedOut }
        let captured = UUID()
        operation = captured
        try await connect(to: endpoint, operation: captured)
    }
#endif
    private func perform(_ request: CentralRequest, peer: AxoJSONRPCWebSocketConnection, endpoint: LocalDaemonEndpoint, operation captured: UUID, deadline: ContinuousClock.Instant? = nil) async throws -> CentralResponse {
        try requireCurrent(captured, peer: peer, endpoint: endpoint)
        let raw = try await peer.request(method: request.method, parameters: request.parameters, timeout: timeout(deadline))
        try requireCurrent(captured, peer: peer, endpoint: endpoint)
        return try request.parseResult(raw)
    }
    private func loadCatalog(source: CentralSource, peer: AxoJSONRPCWebSocketConnection, endpoint: LocalDaemonEndpoint, operation captured: UUID, deadline: ContinuousClock.Instant? = nil) async throws -> CentralCatalog {
        let load = UUID()
        catalogLoadGeneration = load
        let loaded = try await CentralCatalogLoader.load(source: source) { request in
            try await self.perform(request, peer: peer, endpoint: endpoint, operation: captured, deadline: deadline)
        }
        guard catalogLoadGeneration == load else { throw AxodWorkbenchError.superseded }
        return loaded
    }
    private func publish(_ loaded: CentralCatalog, restoringSelection: Bool = false) {
        if let floor = creationRevisionFloor {
            if floor.source != loaded.source { creationRevisionFloor = nil }
            else if loaded.revision >= floor.revision { creationRevisionFloor = nil }
        }
        let previous = catalog
        if let previous, previous.source == loaded.source, loaded.revision < previous.revision { return }
        if previous?.source != loaded.source || previous?.revision != loaded.revision { clearSelectedPi() }
        catalog = loaded
        let previousSelection = selectedSessionID
        if restoringSelection,
           preferences.string(forKey: PreferenceKey.machine) == loaded.source.machine.machineId.uuidString,
           preferences.string(forKey: PreferenceKey.store) == loaded.source.storeGeneration.uuidString {
            selectedSessionID = UUID(uuidString: preferences.string(forKey: PreferenceKey.session) ?? "")
            selectedWorkspaceID = UUID(uuidString: preferences.string(forKey: PreferenceKey.workspace) ?? "")
        } else if let previous, previous.source != loaded.source { selectedSessionID = nil; selectedWorkspaceID = nil }
        if let selectedSession { selectedWorkspaceID = selectedSession.workspaceId }
        else {
            if !workspaces.contains(where: { $0.workspaceId == selectedWorkspaceID }) { selectedWorkspaceID = workspaces.first?.workspaceId }
            selectedSessionID = sessions.first(where: { $0.workspaceId == selectedWorkspaceID })?.sessionId
        }
        if previousSelection != selectedSessionID { clearSelectedPi() }
        if let view = selectedSessionView { paneLayouts.observe(view, source: loaded.source) }
        saveSelection()
    }
    private func observe(peer: AxoJSONRPCWebSocketConnection, endpoint: LocalDaemonEndpoint, operation captured: UUID) {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, let source = self.catalog?.source else { return }
                do {
                    let loaded = try await self.loadCatalog(source: source, peer: peer, endpoint: endpoint, operation: captured)
                    try self.requireCurrent(captured, peer: peer, endpoint: endpoint)
                    guard self.catalog?.source == source else { return }
                    self.publish(loaded)
                    let value = try await peer.request(method: AxoProtocol.Method.getHost, parameters: HostGetParameters(target: source.machine))
                    try self.requireCurrent(captured, peer: peer, endpoint: endpoint)
                    self.hostStatus = try AxoProtocolResultValidator.host(value, target: source.machine)
                    await self.refreshSelectedPi()
                    await self.reconcilePendingPiInputs()
                    await self.reconcilePendingRename()
                } catch {
                    guard self.operation == captured, self.connection === peer else { return }
                    // A failed bounded read never publishes a partial catalog or
                    // infers runtime completion. It cannot authorize a new writer.
                    self.hostStatus = nil
                    if Self.lostAuthority(error) { self.connectionFailed(peer: peer); return }
                }
            }
        }
    }
    func refresh(message completionMessage: String? = nil) {
        guard let source = catalog?.source, let peer = connection, let endpoint else { return }
        let captured = operation, generation = UUID(); refreshGeneration = generation
        Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.loadCatalog(source: source, peer: peer, endpoint: endpoint, operation: captured)
                try self.requireCurrent(captured, peer: peer, endpoint: endpoint)
                guard self.refreshGeneration == generation, self.catalog?.source == source else { return }
                self.publish(loaded); self.message = completionMessage ?? "Central metadata refreshed."
                if let ticket = self.creations.pendingTicket {
                    await self.reconcileCreation(ticket, peer: peer, endpoint: endpoint, operation: captured)
                }
            } catch {
                guard self.operation == captured, self.connection === peer else { return }
                if Self.lostAuthority(error) { self.connectionFailed(peer: peer) }
            }
        }
    }
    var canCreate: Bool {
        guard connectionState == .connected, let catalog, !creations.hasPending else { return false }
        if let floor = creationRevisionFloor, floor.source == catalog.source, catalog.revision < floor.revision { return false }
        return true
    }
    var canCreateSession: Bool {
        guard canCreate else { return false }
        let workspace: UUID?
        if let selectedSession { workspace = selectedSession.workspaceId }
        else { workspace = selectedWorkspaceID }
        return workspace.map { id in workspaces.contains { $0.workspaceId == id && $0.lifecycle == .open } } ?? true
    }
    func createSession() {
        guard canCreateSession, let catalog else { return }
        let workspace: UUID?
        if let selectedSession { workspace = selectedSession.workspaceId }
        else { workspace = selectedWorkspaceID }
        if let workspace, !workspaces.contains(where: { $0.workspaceId == workspace && $0.lifecycle == .open }) { return }
        do {
            let ticket = try creations.captureSession(source: catalog.source, revision: catalog.revision, workspaceId: workspace)
            submitCreation(ticket)
        } catch { message = "A new session could not be reserved. No client-side start was attempted." }
    }
    func createWorkspace(name: String, directoryPath: String) {
        guard canCreate, let catalog else { return }
        do {
            let ticket = try creations.captureWorkspace(source: catalog.source, revision: catalog.revision, name: name, directoryPath: directoryPath)
            submitCreation(ticket)
        } catch { message = "Workspace selection is invalid or another creation is unresolved." }
    }
    private func submitCreation(_ ticket: CentralCreationTicket) {
        guard let peer = connection, let endpoint else {
            try? creations.abandonBeforeSubmission(ticket)
            return
        }
        let request: CentralRequest
        do { request = try creations.beginSubmission(ticket) }
        catch { try? creations.abandonBeforeSubmission(ticket); return }
        let captured = operation
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.perform(request, peer: peer, endpoint: endpoint, operation: captured)
                let result = try self.creations.acknowledgeSubmission(ticket, response: response)
                await self.finishCreation(result, peer: peer, endpoint: endpoint, operation: captured)
            } catch {
                await self.reconcileCreation(ticket, peer: peer, endpoint: endpoint, operation: captured)
            }
        }
    }
    private func reconcileCreation(_ ticket: CentralCreationTicket, peer: AxoJSONRPCWebSocketConnection, endpoint: LocalDaemonEndpoint, operation captured: UUID) async {
        guard captured == operation, connection === peer, let source = catalog?.source,
              reconcilingCreation == nil else { return }
        let command = ticket.commandId
        reconcilingCreation = command
        defer { if reconcilingCreation == command { reconcilingCreation = nil } }
        do {
            let request = try creations.reconciliation(ticket, source: source)
            let response = try await perform(request, peer: peer, endpoint: endpoint, operation: captured)
            let result = try creations.acknowledgeReconciliation(ticket, source: source, response: response)
            await finishCreation(result, peer: peer, endpoint: endpoint, operation: captured)
        } catch {
            // Lookup is read-only. Missing or unavailable originals retain the
            // fence; no second creation request or client startup is attempted.
            message = "Creation outcome is unresolved. Reconnect or refresh to observe its original operation."
        }
    }
    private func finishCreation(_ result: CentralCreationResolution, peer: AxoJSONRPCWebSocketConnection, endpoint: LocalDaemonEndpoint, operation captured: UUID) async {
        guard case .accepted(let creation) = result, captured == operation, connection === peer,
              let source = catalog?.source else { return }
        creationRevisionFloor = (source, creation.revision)
        let sessionID = creation.sessionId
        let workspaceID = creation.workspaceId
        do {
            let loaded = try await loadCatalog(source: source, peer: peer, endpoint: endpoint, operation: captured)
            try requireCurrent(captured, peer: peer, endpoint: endpoint)
            guard loaded.sessions.contains(where: { $0.session.sessionId == sessionID && $0.session.workspaceId == workspaceID }) else {
                message = "The accepted graph is reserved and still materializing. Its original operation was not repeated."
                publish(loaded)
                return
            }
            publish(loaded)
            selectSession(sessionID)
            message = "Central session graph reserved; availability is reported by Axod."
        } catch {
            if Self.lostAuthority(error) { connectionFailed(peer: peer) }
            else { message = "The accepted graph is reserved. Refresh to observe its current availability." }
        }
    }
    func selectWorkspace(_ id: UUID?) {
        guard id == nil || workspaces.contains(where: { $0.workspaceId == id }) else { return }
        let nextSessionID = sessions.first(where: { $0.workspaceId == id })?.sessionId
        if selectedSessionID != nextSessionID { clearSelectedPi() }
        selectedWorkspaceID = id; selectedSessionID = nextSessionID
        if let view = selectedSessionView, let source = catalog?.source { paneLayouts.observe(view, source: source) }
        saveSelection()
    }
    func selectSession(_ id: UUID) {
        guard let session = sessions.first(where: { $0.sessionId == id }) else { return }
        if selectedSessionID != id { clearSelectedPi() }
        selectedSessionID = id; selectedWorkspaceID = session.workspaceId
        if let view = selectedSessionView, let source = catalog?.source { paneLayouts.observe(view, source: source) }
        saveSelection()
    }
    func refreshSelectedPi() async {
        guard let session = selectedSession, let source = catalog?.source, let catalogRevision = catalog?.revision,
              let peer = connection, let endpoint else { return }
        let sessionID = session.sessionId
        let capturedOperation = operation
        let generation = UUID()
        piReadGeneration = generation
        do {
            let request = try CentralRequest.observePi(source: source, workspaceId: session.workspaceId, sessionId: sessionID)
            let observed = try await perform(request, peer: peer, endpoint: endpoint, operation: capturedOperation)
            guard piReadIsCurrent(generation, sessionID: sessionID, source: source, revision: catalogRevision, operation: capturedOperation, peer: peer) else { return }
            guard case .piObservation(let observation) = observed.payload else { throw AxodWorkbenchError.protocolMismatch }
            selectedPiObservation = observation
            selectedPiResponse = observed
            selectedPiReadUnavailable = false
            switch observation {
            case .notAdmitted:
                selectedPiTarget = nil
                selectedPiState = nil
                selectedPiHistory = nil
            case .stopped(let target):
                selectedPiState = nil
                if selectedPiTarget != target || selectedPiHistory == nil {
                    selectedPiTarget = target
                    let request = try CentralRequest.piHistory(target: target, readMode: .stopped, collection: .branch)
                    let history = try await perform(request, peer: peer, endpoint: endpoint, operation: capturedOperation)
                    guard piReadIsCurrent(generation, sessionID: sessionID, source: source, revision: catalogRevision, operation: capturedOperation, peer: peer),
                          case .piHistory(let page) = history.payload else { return }
                    selectedPiHistory = page
                }
            case .live(let target, _):
                if selectedPiTarget != target {
                    selectedPiTarget = target
                    selectedPiState = nil
                    selectedPiHistory = nil
                }
                let snapshotRequest = try CentralRequest.piSnapshot(target: target)
                let snapshot = try await perform(snapshotRequest, peer: peer, endpoint: endpoint, operation: capturedOperation)
                guard piReadIsCurrent(generation, sessionID: sessionID, source: source, revision: catalogRevision, operation: capturedOperation, peer: peer),
                      case .piSnapshot(let snapshotTarget, let state) = snapshot.payload, snapshotTarget == target else { return }
                selectedPiState = state
                let historyRequest = try CentralRequest.piHistory(target: target, readMode: .live, collection: .branch)
                let history = try await perform(historyRequest, peer: peer, endpoint: endpoint, operation: capturedOperation)
                guard piReadIsCurrent(generation, sessionID: sessionID, source: source, revision: catalogRevision, operation: capturedOperation, peer: peer),
                      case .piHistory(let page) = history.payload else { return }
                selectedPiHistory = page
            }
        } catch {
            guard piReadIsCurrent(generation, sessionID: sessionID, source: source, revision: catalogRevision, operation: capturedOperation, peer: peer) else { return }
            selectedPiReadUnavailable = true
        }
    }
    private func piReadIsCurrent(_ generation: UUID, sessionID: UUID, source: CentralSource, revision: CentralRevision, operation capturedOperation: UUID, peer: AxoJSONRPCWebSocketConnection) -> Bool {
        piReadGeneration == generation && selectedSessionID == sessionID && catalog?.source == source && catalog?.revision == revision && operation == capturedOperation && connection === peer
    }
    private func clearSelectedPi() {
        piReadGeneration = UUID()
        selectedPiObservation = nil
        selectedPiResponse = nil
        selectedPiState = nil
        selectedPiHistory = nil
        selectedPiReadUnavailable = false
        selectedPiTarget = nil
    }
    func prepareWorkspaceRename(_ workspaceId: UUID) throws -> CentralRenameCapture {
        guard connectionState == .connected, let catalog,
              let workspace = catalog.workspaces.first(where: { $0.workspaceId == workspaceId }) else {
            throw CentralRenameIssue.invalidTicket
        }
        return try renames.prepareWorkspace(source: catalog.source, revision: catalog.revision,
                                            workspaceId: workspaceId, currentName: workspace.name)
    }
    func prepareSessionRename(_ sessionId: UUID) throws -> CentralRenameCapture {
        guard connectionState == .connected, let view = sessionView(sessionId), let catalog else {
            throw CentralRenameIssue.invalidTicket
        }
        return try renames.prepareSession(source: catalog.source, revision: catalog.revision,
            workspaceId: view.session.workspaceId, sessionId: sessionId, currentName: view.session.name)
    }
    func finishRename(_ capture: CentralRenameCapture, name: String?) {
        guard let name, name != capture.originalName else {
            do { try renames.abandon(capture) }
            catch { message = "The captured Rename editor could not be released." }
            return
        }
        do { dispatchRename(try renames.capture(capture, name: name)) }
        catch { message = "Rename could not be captured against the current central revision." }
    }
    private func dispatchRename(_ ticket: CentralRenameTicket) {
        guard let peer = connection, let endpoint else {
            do { try renames.abandonBeforeSubmission(ticket) }
            catch { message = "Rename remains reserved and was not submitted."; return }
            message = "Rename was not submitted because the central connection is unavailable."
            return
        }
        let request: CentralRequest
        do { request = try renames.beginSubmission(ticket) }
        catch {
            do { try renames.abandonBeforeSubmission(ticket) }
            catch { message = "The Rename reservation remains fenced and was not submitted."; return }
            message = "Rename was not submitted. No replacement command was sent."
            return
        }
        let captured = operation
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.perform(request, peer: peer, endpoint: endpoint, operation: captured)
                let result = try self.renames.acknowledgeSubmission(ticket, response: response)
                await self.finishRename(ticket, result: result, peer: peer, endpoint: endpoint, operation: captured)
            } catch {
                await self.reconcileRename(ticket, peer: peer, endpoint: endpoint, operation: captured)
            }
        }
    }
    private func finishRename(
        _ ticket: CentralRenameTicket, result: CentralRenameResolution,
        peer: AxoJSONRPCWebSocketConnection, endpoint: LocalDaemonEndpoint, operation captured: UUID
    ) async {
        guard captured == operation, connection === peer else { return }
        switch result {
        case .renamed:
            message = "Central Rename accepted."
            refresh(message: "Central Rename accepted.")
        case .missing:
            await reconcileRename(ticket, peer: peer, endpoint: endpoint, operation: captured)
        }
    }
    private func reconcilePendingRename() async {
        guard let ticket = renames.pendingTicket, let peer = connection, let endpoint else { return }
        await reconcileRename(ticket, peer: peer, endpoint: endpoint, operation: operation)
    }
    private func reconcileRename(
        _ ticket: CentralRenameTicket, peer: AxoJSONRPCWebSocketConnection,
        endpoint: LocalDaemonEndpoint, operation captured: UUID
    ) async {
        guard reconcilingRename == nil else { return }
        reconcilingRename = ticket.commandId
        defer { reconcilingRename = nil }
        guard captured == operation, connection === peer, let source = catalog?.source else { return }
        do {
            let request = try renames.reconciliation(ticket, source: source)
            let response = try await perform(request, peer: peer, endpoint: endpoint, operation: captured)
            guard captured == operation, connection === peer, catalog?.source == source else { return }
            let result = try renames.acknowledgeReconciliation(ticket, source: source, response: response)
            switch result {
            case .renamed:
                message = "Central Rename was reconciled from its original receipt."
                refresh(message: "Central Rename accepted.")
            case .missing:
                message = "Rename remains unresolved. The original operation was not repeated."
            }
        } catch {
            guard captured == operation, connection === peer, catalog?.source == source else { return }
            message = "Rename remains unresolved. The original operation was not repeated."
        }
    }
    func selectedPiEditingCapture() throws -> CentralEditCapture {
        guard let response = selectedPiResponse, !selectedPiReadUnavailable,
              case .piObservation(.live(let target, _)) = response.payload,
              selectedSessionID == target.sessionId, catalog?.source == target.source else {
            throw CentralInputIssue.unavailable
        }
        return try inputBuffers.editingCapture(for: CentralEditingTarget(target))
    }
    func editSelectedPiInput(_ text: String) throws {
        guard let response = selectedPiResponse, !selectedPiReadUnavailable,
              case .piObservation(.live(let target, _)) = response.payload,
              selectedSessionID == target.sessionId, catalog?.source == target.source else {
            throw CentralInputIssue.unavailable
        }
        try inputBuffers.edit(text, in: CentralEditingTarget(target))
    }
    @discardableResult func applyPiInput(_ text: String, matching capture: CentralEditCapture) throws -> Bool {
        try inputBuffers.apply(text, matching: capture)
    }
    func submitSelectedPiInput() {
        guard let response = selectedPiResponse, !selectedPiReadUnavailable,
              case .piObservation(.live(let target, _)) = response.payload,
              selectedSessionID == target.sessionId, catalog?.source == target.source else {
            message = "Pi input is unavailable until the selected central binding is observed."
            return
        }
        do { dispatchPiInput(try inputBuffers.captureText(from: response)) }
        catch { message = "Pi input could not be captured for the current interaction." }
    }
    func cancelSelectedPiInteraction() { submitSelectedPiControl(.cancel) }
    func answerSelectedPiQuestion(optionId: UUID) { submitSelectedPiControl(.answer(optionId: optionId)) }
    private func submitSelectedPiControl(_ choice: CentralControlChoice) {
        guard let response = selectedPiResponse, !selectedPiReadUnavailable else { return }
        do { dispatchPiInput(try inputBuffers.captureControl(choice, from: response)) }
        catch { message = "That Pi control is no longer available for the observed interaction." }
    }
    private func dispatchPiInput(_ ticket: CentralInputTicket) {
        guard let peer = connection, let endpoint else {
            do { try inputBuffers.abandonBeforeSubmission(ticket) }
            catch { message = "Pi input could not be released before submission."; return }
            message = "Pi input was not sent because the central connection is unavailable."
            return
        }
        let request: CentralRequest
        do { request = try inputBuffers.beginSubmission(ticket) }
        catch {
            do { try inputBuffers.abandonBeforeSubmission(ticket) }
            catch { message = "The Pi input reservation remains fenced and was not submitted."; return }
            message = "The captured Pi command could not be submitted. No replacement command was sent."
            return
        }
        let captured = operation
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.perform(request, peer: peer, endpoint: endpoint, operation: captured)
                let result = try self.inputBuffers.acknowledgeSubmission(ticket, response: response)
                await self.finishPiInput(ticket, result: result, peer: peer, endpoint: endpoint, operation: captured)
            } catch {
                await self.reconcilePiInput(ticket, peer: peer, endpoint: endpoint, operation: captured)
            }
        }
    }
    private func finishPiInput(
        _ ticket: CentralInputTicket, result: CentralInputResolution,
        peer: AxoJSONRPCWebSocketConnection, endpoint: LocalDaemonEndpoint, operation captured: UUID
    ) async {
        guard captured == operation, connection === peer else { return }
        switch result {
        case .dispatched:
            message = "Pi acknowledged the submitted command; execution is still observed separately."
            await refreshSelectedPi()
        case .rejected:
            message = "Pi rejected the submitted command. Editing remains available for a new explicit submission."
            await refreshSelectedPi()
        case .missing, .unconfirmed, .outcomeUnknown:
            await reconcilePiInput(ticket, peer: peer, endpoint: endpoint, operation: captured)
        }
    }
    private func reconcilePendingPiInputs() async {
        guard let peer = connection, let endpoint, catalog != nil else { return }
        let captured = operation
        let tickets = inputBuffers.pendingTickets
        guard !tickets.isEmpty else { return }
        let index = nextPiInputReconciliation.flatMap { last in
            tickets.firstIndex { $0.command.commandId == last }.map { ($0 + 1) % tickets.count }
        } ?? 0
        let ticket = tickets[index]
        nextPiInputReconciliation = ticket.command.commandId
        await reconcilePiInput(ticket, peer: peer, endpoint: endpoint, operation: captured)
    }
    private func reconcilePiInput(
        _ ticket: CentralInputTicket, peer: AxoJSONRPCWebSocketConnection,
        endpoint: LocalDaemonEndpoint, operation captured: UUID
    ) async {
        let commandId = ticket.command.commandId
        guard reconcilingPiInputs.insert(commandId).inserted else { return }
        defer { reconcilingPiInputs.remove(commandId) }
        guard captured == operation, connection === peer, let source = catalog?.source else { return }
        do {
            let request = try inputBuffers.reconciliation(ticket, source: source)
            let response = try await perform(request, peer: peer, endpoint: endpoint, operation: captured)
            guard captured == operation, connection === peer, catalog?.source == source else { return }
            let result = try inputBuffers.acknowledgeReconciliation(ticket, source: source, response: response)
            switch result {
            case .dispatched:
                message = "The original Pi command was acknowledged; execution is still observed separately."
                await refreshSelectedPi()
            case .rejected:
                message = "The original Pi command was rejected. No replacement command was sent."
                await refreshSelectedPi()
            case .missing, .unconfirmed, .outcomeUnknown:
                message = "The Pi command outcome remains unresolved. No replacement command was sent."
            }
        } catch {
            guard captured == operation, connection === peer, catalog?.source == source else { return }
            // The original capture stays fenced. Lookup failure is never permission to resend.
            message = "The Pi command outcome remains unresolved. No replacement command was sent."
        }
    }
    var selectedSessionView: CentralSessionView? { catalog?.sessions.first { $0.session.sessionId == selectedSessionID } }
    func sessionView(_ id: UUID) -> CentralSessionView? { catalog?.sessions.first { $0.session.sessionId == id } }
    func preparePaneLayout(_ session: CentralSession) {
        guard selectedSessionID == session.sessionId, let view = sessionView(session.sessionId), let source = catalog?.source else { return }
        paneLayouts.observe(view, source: source)
    }
    func terminalSnapshot(paneID: UUID, sessionID: UUID) -> TerminalSnapshot? {
        sessionView(sessionID)?.panes.first { $0.desired.paneId == paneID && $0.desired.present }?.terminal
    }
    func terminalLaunch(for snapshot: TerminalSnapshot, sessionID: UUID) throws -> TerminalLaunch {
        guard connectionState == .connected, let source = catalog?.source, let endpoint, let directory,
              source.machine == MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration),
              snapshot.runtime.target.sessionId == sessionID, snapshot.runtime.hostGeneration == endpoint.hostGeneration,
              terminalSnapshot(paneID: snapshot.runtime.target.paneId, sessionID: sessionID) == snapshot,
              case .running = snapshot.process else { throw LaunchError.surfaceCreation }
        try directory.requireCurrentEndpoint(endpoint)
#if AXO_NATIVE_FIXTURE
        let helper = fixtureAttachmentHelper ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/axod")
#else
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/axod")
#endif
        return try TerminalLaunch.attachment(namespace: .centralStore(source.storeGeneration), root: directory.root, machineID: endpoint.machineId, runtime: snapshot.runtime, helper: helper)
    }
    func focusTerminal(_ key: TerminalLaunch.Key) {
        guard let source = catalog?.source, selectedSessionID == key.sessionID,
              currentTerminalKey(key.paneID, sessionID: key.sessionID) == key else { return }
        paneLayouts.focus(key.paneID, in: .init(source: source, sessionID: key.sessionID))
    }
    private func currentTerminalKey(_ paneID: UUID, sessionID: UUID) -> TerminalLaunch.Key? {
        guard let snapshot = terminalSnapshot(paneID: paneID, sessionID: sessionID) else { return nil }
        return try? terminalLaunch(for: snapshot, sessionID: sessionID).key
    }
    func capturePaneFocus(_ direction: AxodPaneFocusDirection, in window: NSWindow) -> AxodPaneFocus? {
        guard let source = catalog?.source, let view = window.firstResponder as? TerminalView,
              let current = terminalSurfaces.presentation(for: view), current.window === window,
              selectedSessionID == current.key.sessionID, currentTerminalKey(current.key.paneID, sessionID: current.key.sessionID) == current.key else { return nil }
        let identity = AxodPaneLayouts.Session(source: source, sessionID: current.key.sessionID)
        guard let move = paneLayouts.captureFocus(from: current.key.paneID, direction: direction, in: identity),
              let key = currentTerminalKey(move.destination, sessionID: current.key.sessionID),
              let destination = terminalSurfaces.presentation(for: key), destination.window === window,
              destination.viewportID == current.viewportID else { return nil }
        return AxodPaneFocus(move: move, source: current.key, destination: key, viewportID: current.viewportID, responderGeneration: view.focusGeneration, window: window)
    }
    @discardableResult func focusPane(_ direction: AxodPaneFocusDirection, in window: NSWindow) -> Bool {
        guard let request = capturePaneFocus(direction, in: window) else { return false }; return applyPaneFocus(request)
    }
    @discardableResult func applyPaneFocus(_ request: AxodPaneFocus) -> Bool {
        guard let window = request.window, selectedSessionID == request.source.sessionID, paneLayouts.isCurrent(request.move),
              currentTerminalKey(request.source.paneID, sessionID: request.source.sessionID) == request.source,
              currentTerminalKey(request.destination.paneID, sessionID: request.destination.sessionID) == request.destination,
              let source = terminalSurfaces.presentation(for: request.source), let destination = terminalSurfaces.presentation(for: request.destination),
              source.window === window, destination.window === window, window.firstResponder === source.view,
              source.view.focusGeneration == request.responderGeneration, source.viewportID == request.viewportID, destination.viewportID == request.viewportID else { return false }
        return window.makeFirstResponder(destination.view)
    }
    private func saveSelection() {
        guard let source = catalog?.source else { return }
        preferences.set(source.machine.machineId.uuidString, forKey: PreferenceKey.machine); preferences.set(source.storeGeneration.uuidString, forKey: PreferenceKey.store)
        preferences.set(selectedWorkspaceID?.uuidString ?? "", forKey: PreferenceKey.workspace); preferences.set(selectedSessionID?.uuidString ?? "", forKey: PreferenceKey.session)
    }
    private func requireCurrent(_ captured: UUID, peer: AxoJSONRPCWebSocketConnection, endpoint: LocalDaemonEndpoint) throws {
        guard captured == operation, connection === peer, self.endpoint == endpoint else { throw AxodWorkbenchError.superseded }
        guard let directory else { throw LaunchError.missingDirectory }
        try directory.requireCurrentEndpoint(endpoint)
    }
    private func timeout(_ deadline: ContinuousClock.Instant?) throws -> TimeInterval {
        guard let deadline else { return 2 }
        let duration = ContinuousClock.now.duration(to: deadline).components
        let remaining = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        guard remaining > 0 else { throw AxodWorkbenchError.startupTimedOut }; return min(2, remaining)
    }
    private static func lostAuthority(_ error: Error) -> Bool {
        switch error {
        case AxoProtocolValidationError.staleHost, AxoProtocolValidationError.staleStore, AxoProtocolValidationError.invalidResult,
             AxoJSONRPCClientError.disconnected, AxoJSONRPCClientError.outcomeUnknown, AxoJSONRPCClientError.malformedResponse,
             AxoJSONRPCClientError.mismatchedResponseID, AxoJSONRPCClientError.remote(code: -32008, message: _),
             is AxodStateDirectoryError, LaunchError.missingDirectory: return true
        default: return false
        }
    }
    private func connectionFailed(peer: AxoJSONRPCWebSocketConnection) {
        guard connection === peer else { return }; disconnect()
        connectionState = .failed("Local daemon connection lost"); message = "Connection lost. No work was replayed."
        if let serviceObservation { serviceLifecycle.observedUnavailable(observation: serviceObservation) }
    }
    func disconnect() {
        operation = UUID()
        reconcilingCreation = nil
        creationRevisionFloor = nil
        refreshGeneration = UUID()
        catalogLoadGeneration = UUID()
        connectTask?.cancel()
        connectTask = nil
        observationTask?.cancel()
        let old = connection
        connection = nil
        endpoint = nil
        catalog = nil
        hostStatus = nil
        selectedWorkspaceID = nil
        selectedSessionID = nil
        clearSelectedPi()
        connectionState = .disconnected
        message = "Disconnected. The daemon and its work are left running."
        // Runtime absence does not release cached surfaces or remove layout leaves.
        if let old { Task { await old.close() } }
    }
}
private enum AxodWorkbenchError: Error, LocalizedError {
    case protocolMismatch, superseded, startupTimedOut
    var errorDescription: String? { switch self {
    case .protocolMismatch: "The discovered daemon speaks an incompatible local protocol. It was left untouched."
    case .superseded: "A newer connection operation replaced this result."
    case .startupTimedOut: "The registered Axod service did not become ready. Reconnect did not launch, replace, or restart work."
    } }
}
