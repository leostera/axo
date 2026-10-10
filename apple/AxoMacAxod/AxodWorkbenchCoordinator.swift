import AppKit
import AxoCore
import AxoProtocol
import Darwin
import Observation

@MainActor @Observable
final class AxodWorkbenchCoordinator {
    enum ConnectionState: Equatable {
        case starting
        case connected
        case disconnected
        case failed(String)
    }

    private(set) var connectionState: ConnectionState = .starting
    private(set) var workspaces: [WorkspaceRecord] = []
    private(set) var sessions: [WorkSessionRecord] = []
    private(set) var runtimes: [TerminalSnapshot] = []
    private(set) var selectedWorkspaceID: UUID?
    private(set) var nextWorkspaceCursor: WorkPageCursor?
    private(set) var nextSessionCursor: WorkPageCursor?
    private(set) var nextRuntimeID: UUID?
    private(set) var message = "Starting the local Axo daemon."

    private let rpc = AxoJSONRPCClient()
    private var stateDirectory: AxodStateDirectory?
    private var endpoint: LocalDaemonEndpoint?
    private var connection: AxoJSONRPCWebSocketConnection?
    private var daemonProcess: Process?
    private var processGeneration: UUID?
    private var operationGeneration = UUID()
    private var refreshGeneration = UUID()
    private var sessionLoadGeneration = UUID()
    private var connectTask: Task<Void, Never>?

    func connect() {
        guard connectTask == nil else { return }
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
        selectedWorkspaceID = nil
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
        selectedWorkspaceID = workspaceID
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
                self.nextSessionCursor = result.next
            } catch {
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint),
                      self.sessionLoadGeneration == load else { return }
                self.message = "Could not load this workspace's sessions. Refresh to reconcile the current revision."
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
                    message = "The discovered daemon did not answer. Attempting the packaged daemon without replacing its state."
                }
            }

            try startPackagedDaemon(in: stateDirectory)
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

            self.endpoint = endpoint
            self.connection = connection
            self.runtimes = runtimes.terminals
            self.nextRuntimeID = runtimes.next
            self.workspaces = workspaces.workspaces
            self.nextWorkspaceCursor = workspaces.next
            self.selectedWorkspaceID = workspaces.workspaces.first?.workspaceId
            self.sessions = []
            self.nextSessionCursor = nil
            connectionState = .connected
            message = "Connected to local axod. Legacy workspaces and Pi histories were not imported or changed."
            if let workspaceID = selectedWorkspaceID {
                await loadInitialSessions(workspaceID, over: connection, endpoint: endpoint, operation: operation)
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
            nextSessionCursor = nil
            if let selectedWorkspaceID {
                await loadInitialSessions(selectedWorkspaceID, over: connection, endpoint: endpoint, operation: operation)
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
            nextSessionCursor = result.next
        } catch {
            guard operationGeneration == operation else { return }
            message = "Connected, but the selected workspace's session page could not be read."
        }
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

    private func startPackagedDaemon(in stateDirectory: AxodStateDirectory) throws {
        if daemonProcess?.isRunning == true { return }
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/axod")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AxodWorkbenchError.packagedDaemonMissing
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve", stateDirectory.root.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let generation = UUID()
        processGeneration = generation
        process.terminationHandler = { [weak self, weak process] terminated in
            guard let process else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.processGeneration == generation,
                      self.daemonProcess === process,
                      self.connectionState != .connected else { return }
                self.connectionState = .failed("axod exited before the connection was established (status \(terminated.terminationStatus)).")
            }
        }
        do {
            try process.run()
            daemonProcess = process
        } catch {
            throw AxodWorkbenchError.daemonStartFailed
        }
    }

    private func waitForEndpoint(
        in stateDirectory: AxodStateDirectory,
        replacing previous: LocalDaemonEndpoint?,
        operation: UUID
    ) async throws -> LocalDaemonEndpoint {
        for _ in 0..<100 {
            try requireCurrent(operation)
            if let endpoint = try stateDirectory.readEndpoint(), endpoint != previous { return endpoint }
            if let daemonProcess, !daemonProcess.isRunning {
                throw AxodWorkbenchError.daemonExited(daemonProcess.terminationStatus)
            }
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
    case daemonExited(Int32)
    case daemonStartFailed
    case packagedDaemonMissing

    var errorDescription: String? {
        switch self {
        case .protocolMismatch: "The discovered daemon speaks an incompatible local protocol. It was left untouched."
        case .superseded: "A newer connection operation replaced this result."
        case .startupTimedOut: "The packaged daemon did not publish a fresh discovery endpoint in time."
        case .daemonExited(let status): "axod exited before it accepted local clients (status \(status))."
        case .daemonStartFailed: "The packaged axod process could not be started."
        case .packagedDaemonMissing: "This Axo app bundle does not contain its axod helper. Rebuild the package."
        }
    }
}
