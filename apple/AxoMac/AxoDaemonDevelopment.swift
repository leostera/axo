import AppKit
import AxoCore
import AxoProtocol
import Darwin
import Observation
import SwiftUI

@MainActor @Observable
final class AxoDaemonDevelopmentCoordinator {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var runtimes: [TerminalSnapshot] = []
    private(set) var fixtureAttempted = false
    private(set) var message = "Connect to a daemon in the isolated development state directory."
    private(set) var stateDirectoryDescription = "Isolated development state"

    private let rpc = AxoJSONRPCClient()
    private var localConnection: AxoJSONRPCWebSocketConnection?
    private var endpoint: LocalDaemonEndpoint?
    private var stateStore: AxodDevelopmentStateStore?
    private var daemonProcess: Process?
    private var processGeneration: UUID?
    private var operationGeneration = UUID()
    private var connectTask: Task<Void, Never>?

    var canLaunchFixture: Bool {
        connectionState == .connected && localConnection != nil && !fixtureAttempted
    }

    func connect() {
        guard connectTask == nil else { return }
        let operation = UUID()
        operationGeneration = operation
        let oldConnection = localConnection
        localConnection = nil
        endpoint = nil
        connectionState = .connecting
        message = "Checking the isolated daemon state."
        connectTask = Task { [weak self] in
            guard let self else { return }
            await oldConnection?.close()
            await self.bootstrapAndConnect(operation: operation)
            if self.operationGeneration == operation { self.connectTask = nil }
        }
    }

    func disconnect() {
        operationGeneration = UUID()
        connectTask?.cancel()
        connectTask = nil
        let connection = localConnection
        localConnection = nil
        endpoint = nil
        runtimes = []
        connectionState = .disconnected
        message = "Disconnected. Daemon-owned work continues."
        if let connection { Task { await connection.close() } }
    }

    func refreshRuntimes() {
        guard let connection = localConnection, let endpoint else { return }
        let operation = operationGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.listRuntimes(over: connection, endpoint: endpoint, operation: operation)
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint) else { return }
                self.runtimes = result.terminals
                self.message = "Showing daemon runtime metadata. No terminal bytes or Pi history are exposed here."
            } catch {
                self.connectionLost(error, operation: operation, connection: connection)
            }
        }
    }

    /// Called only after a native confirmation. The intent marker is durable before dispatch;
    /// reopening the panel never repeats an uncertain launch.
    func launchApprovedFixture() {
        guard canLaunchFixture, let connection = localConnection, let endpoint, let stateStore else { return }
        let operation = operationGeneration
        let target = TerminalTarget(
            machineId: endpoint.machineId,
            hostGeneration: endpoint.hostGeneration,
            sessionId: UUID(),
            paneId: UUID()
        )
        let commandID = UUID()
        do {
            try stateStore.recordFixtureAttempt(commandID: commandID, target: target)
            fixtureAttempted = true
        } catch {
            message = "A fixture launch is already recorded or the private state is unsafe. No launch was sent."
            return
        }

        message = "Submitting the single approved fixture launch."
        Task { [weak self] in
            guard let self else { return }
            do {
                let parameters = RuntimeStartParameters(
                    target: target,
                    commandId: commandID,
                    profileId: AxodDevelopmentStateStore.fixtureProfileID
                )
                let value = try await connection.request(
                    method: AxoProtocol.Method.startApprovedRuntime,
                    parameters: parameters
                )
                let result = try AxoProtocolResultValidator.runtimeStart(value, target: target)
                guard self.isCurrent(operation, connection: connection, endpoint: endpoint) else { return }
                self.runtimes = try await self.listRuntimes(
                    over: connection, endpoint: endpoint, operation: operation
                ).terminals
                self.message = "Approved fixture launched once. Runtime state is daemon-owned; closing this client will not stop it."
                _ = result
            } catch {
                guard self.operationGeneration == operation else { return }
                self.message = "Launch outcome may be unknown. It was not retried; refresh runtime metadata before taking further action."
                self.connectionState = .failed("Fixture launch needs reconciliation")
            }
        }
    }

    private func bootstrapAndConnect(operation: UUID) async {
        do {
            let stateStore = try AxodDevelopmentStateStore.prepare()
            try requireCurrent(operation)
            self.stateStore = stateStore
            fixtureAttempted = stateStore.hasFixtureAttempt

            if let existing = try stateStore.readEndpoint() {
                do {
                    try await connect(to: existing, stateStore: stateStore, operation: operation)
                    return
                } catch DaemonDevelopmentError.protocolMismatch {
                    throw DaemonDevelopmentError.protocolMismatch
                } catch {
                    try requireCurrent(operation)
                    message = "No compatible daemon answered its private discovery endpoint; checking the owner lock by starting axod safely."
                }
            }

            try startPackagedDaemon(stateStore: stateStore)
            let discovered = try await waitForEndpoint(stateStore: stateStore, operation: operation)
            try await connect(to: discovered, stateStore: stateStore, operation: operation)
        } catch {
            guard operationGeneration == operation else { return }
            connectionState = .failed(error.localizedDescription)
            if case DaemonDevelopmentError.protocolMismatch = error {
                message = "The discovered daemon speaks an incompatible protocol. It was left untouched."
            } else {
                message = "Could not connect to the isolated local daemon. Existing state and processes were left untouched."
            }
        }
    }

    private func connect(
        to endpoint: LocalDaemonEndpoint,
        stateStore: AxodDevelopmentStateStore,
        operation: UUID
    ) async throws {
        try requireCurrent(operation)
        let connection = try rpc.openLocalWebSocket(endpoint: endpoint)
        localConnection = connection
        self.endpoint = endpoint

        do {
            let negotiation: JSONValue
            do {
                negotiation = try await connection.request(
                    method: AxoProtocol.Method.negotiate,
                    parameters: NegotiationParameters()
                )
            } catch let error as AxoJSONRPCClientError {
                if case .remote = error { throw DaemonDevelopmentError.protocolMismatch }
                throw error
            }
            do { _ = try AxoProtocolResultValidator.localNegotiation(negotiation) }
            catch { throw DaemonDevelopmentError.protocolMismatch }
            try requireCurrent(operation)
            try stateStore.requireCurrentEndpoint(endpoint)

            let result: RuntimeListResult
            do {
                result = try await listRuntimes(over: connection, endpoint: endpoint, operation: operation)
            } catch let error as AxoJSONRPCClientError {
                if case .remote = error { throw DaemonDevelopmentError.protocolMismatch }
                throw error
            } catch is AxoProtocolValidationError {
                throw DaemonDevelopmentError.protocolMismatch
            }
            guard isCurrent(operation, connection: connection, endpoint: endpoint) else {
                throw DaemonDevelopmentError.superseded
            }
            self.stateStore = stateStore
            self.endpoint = endpoint
            self.localConnection = connection
            runtimes = result.terminals
            fixtureAttempted = stateStore.hasFixtureAttempt
            connectionState = .connected
            message = "Connected to local axod. Existing Axo workspaces and sessions were not imported or changed."
        } catch {
            await connection.close()
            if localConnection === connection { localConnection = nil }
            if self.endpoint == endpoint { self.endpoint = nil }
            throw error
        }
    }

    private func listRuntimes(
        over connection: AxoJSONRPCWebSocketConnection,
        endpoint: LocalDaemonEndpoint,
        operation: UUID
    ) async throws -> RuntimeListResult {
        let destination = MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration)
        let value = try await connection.request(
            method: AxoProtocol.Method.listRuntimes,
            parameters: RuntimeListParameters(target: destination)
        )
        let result = try AxoProtocolResultValidator.runtimeList(value, target: destination)
        try requireCurrent(operation)
        try stateStore?.requireCurrentEndpoint(endpoint)
        return result
    }

    private func waitForEndpoint(
        stateStore: AxodDevelopmentStateStore,
        operation: UUID
    ) async throws -> LocalDaemonEndpoint {
        for _ in 0..<100 {
            try requireCurrent(operation)
            if let endpoint = try stateStore.readEndpoint() { return endpoint }
            if let daemonProcess, !daemonProcess.isRunning {
                throw DaemonDevelopmentError.daemonExited(daemonProcess.terminationStatus)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw DaemonDevelopmentError.startupTimedOut
    }

    private func startPackagedDaemon(stateStore: AxodDevelopmentStateStore) throws {
        if daemonProcess?.isRunning == true { return }
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/axod")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw DaemonDevelopmentError.packagedDaemonMissing
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve", stateStore.root.path, "--profiles-config", stateStore.profilesURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let generation = UUID()
        processGeneration = generation
        process.terminationHandler = { [weak self, weak process] terminated in
            guard let process else { return }
            Task { @MainActor [weak self] in
                guard let self, self.processGeneration == generation,
                      self.daemonProcess === process else { return }
                if self.connectionState == .connected { return }
                self.connectionState = .failed("axod exited before a compatible connection was established (status \(terminated.terminationStatus)).")
            }
        }
        do {
            try process.run()
            daemonProcess = process
        } catch {
            throw DaemonDevelopmentError.daemonStartFailed
        }
    }

    private func isCurrent(
        _ operation: UUID,
        connection: AxoJSONRPCWebSocketConnection,
        endpoint: LocalDaemonEndpoint
    ) -> Bool {
        operationGeneration == operation && localConnection === connection && self.endpoint == endpoint
    }

    private func connectionLost(
        _ error: Error,
        operation: UUID,
        connection: AxoJSONRPCWebSocketConnection
    ) {
        guard operationGeneration == operation, localConnection === connection else { return }
        localConnection = nil
        endpoint = nil
        connectionState = .failed("Local connection lost")
        message = "The client disconnected; daemon-owned work continues. \(error.localizedDescription)"
        Task { await connection.close() }
    }

    private func requireCurrent(_ operation: UUID) throws {
        guard operationGeneration == operation else { throw DaemonDevelopmentError.superseded }
    }
}

private enum DaemonDevelopmentError: Error, LocalizedError {
    case protocolMismatch
    case superseded
    case startupTimedOut
    case daemonExited(Int32)
    case daemonStartFailed
    case packagedDaemonMissing
    case unsafeState
    case fixtureAlreadyAttempted

    var errorDescription: String? {
        switch self {
        case .protocolMismatch: "The local daemon protocol version is incompatible."
        case .superseded: "A newer local daemon operation replaced this result."
        case .startupTimedOut: "The local daemon did not publish discovery before the startup deadline."
        case .daemonExited(let status): "The packaged daemon exited before connection (status \(status))."
        case .daemonStartFailed: "The packaged daemon could not be started."
        case .packagedDaemonMissing: "The signed app bundle does not contain axod. Rebuild the Mac package."
        case .unsafeState: "The isolated daemon state directory or file failed its private-permission checks."
        case .fixtureAlreadyAttempted: "The one approved fixture launch has already been attempted."
        }
    }
}

private struct AxodDevelopmentStateStore {
    static let fixtureProfileID = "approved-fixture"
    let root: URL
    let profilesURL: URL
    private let fixtureDirectory: URL
    private let endpointURL: URL
    private let fixtureIntentURL: URL

    static func prepare() throws -> AxodDevelopmentStateStore {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = support.appendingPathComponent("Axo/Development/DaemonIntegration-v1", isDirectory: true)
        try createPrivateDirectory(root)
        let fixtureDirectory = root.appendingPathComponent("fixture-worktree", isDirectory: true)
        try createPrivateDirectory(fixtureDirectory)
        let profilesURL = root.appendingPathComponent("profiles-config.json")
        let store = AxodDevelopmentStateStore(
            root: root,
            profilesURL: profilesURL,
            fixtureDirectory: fixtureDirectory,
            endpointURL: root.appendingPathComponent("local-endpoint.json"),
            fixtureIntentURL: root.appendingPathComponent("fixture-launch-intent.json")
        )
        try store.prepareProfiles()
        return store
    }

    var hasFixtureAttempt: Bool { (try? readPrivateFile(fixtureIntentURL, maximumBytes: 4096)) != nil }

    func readEndpoint() throws -> LocalDaemonEndpoint? {
        guard FileManager.default.fileExists(atPath: endpointURL.path) else { return nil }
        let data = try readPrivateFile(endpointURL, maximumBytes: 4096)
        do { return try JSONDecoder().decode(LocalDaemonEndpoint.self, from: data) }
        catch { throw DaemonDevelopmentError.unsafeState }
    }

    func requireCurrentEndpoint(_ expected: LocalDaemonEndpoint) throws {
        guard try readEndpoint() == expected else { throw DaemonDevelopmentError.superseded }
    }

    func recordFixtureAttempt(commandID: UUID, target: TerminalTarget) throws {
        let intent = FixtureLaunchIntent(commandId: commandID, target: target)
        let data = try JSONEncoder().encode(intent)
        try createPrivateFileOnce(fixtureIntentURL, data: data)
    }

    private func prepareProfiles() throws {
        let profile = FixtureProfile(
            directory: fixtureDirectory.path,
            argv: ["/usr/bin/printf", "Axo local daemon fixture completed\\n"]
        )
        let data = try JSONEncoder().encode(FixtureProfiles(profiles: [Self.fixtureProfileID: profile]))
        try createOrVerifyPrivateFile(profilesURL, data: data)
    }

    private static func createPrivateDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0 else {
            throw DaemonDevelopmentError.unsafeState
        }
    }

    private func createOrVerifyPrivateFile(_ url: URL, data: Data) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            guard try readPrivateFile(url, maximumBytes: 4096) == data else {
                throw DaemonDevelopmentError.unsafeState
            }
            return
        }
        try createPrivateFileOnce(url, data: data)
    }

    private func createPrivateFileOnce(_ url: URL, data: Data) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw DaemonDevelopmentError.fixtureAlreadyAttempted }
            throw DaemonDevelopmentError.unsafeState
        }
        defer { _ = close(descriptor) }
        var remaining = [UInt8](data)
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress, buffer.count)
            }
            guard written > 0 else { throw DaemonDevelopmentError.unsafeState }
            remaining.removeFirst(written)
        }
        guard fsync(descriptor) == 0 else { throw DaemonDevelopmentError.unsafeState }
        let parentDescriptor = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parentDescriptor >= 0 else { throw DaemonDevelopmentError.unsafeState }
        defer { _ = close(parentDescriptor) }
        guard fsync(parentDescriptor) == 0 else { throw DaemonDevelopmentError.unsafeState }
    }

    private func readPrivateFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw DaemonDevelopmentError.unsafeState }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o600,
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= maximumBytes else {
            throw DaemonDevelopmentError.unsafeState
        }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: min(maximumBytes, 4096))
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0, data.count + count <= maximumBytes else {
                throw DaemonDevelopmentError.unsafeState
            }
            data.append(contentsOf: buffer[..<count])
        }
        return data
    }
}

private struct FixtureProfiles: Encodable {
    let profiles: [String: FixtureProfile]
}

private struct FixtureProfile: Encodable {
    let directory: String
    let argv: [String]
}

private struct FixtureLaunchIntent: Encodable {
    let commandId: UUID
    let target: TerminalTarget
}

struct AxoDaemonDevelopmentView: View {
    @Bindable var coordinator: AxoDaemonDevelopmentCoordinator
    @State private var confirmFixture = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Local axod · Development only").font(.title2.weight(.semibold))
                    Text(coordinator.stateDirectoryDescription).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(statusTitle).font(.callout)
            }

            Text(coordinator.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Connect / Reconnect") { coordinator.connect() }
                    .disabled(coordinator.connectionState == .connecting)
                Button("Refresh runtimes") { coordinator.refreshRuntimes() }
                    .disabled(coordinator.connectionState != .connected)
                Button("Disconnect") { coordinator.disconnect() }
                    .disabled(coordinator.connectionState != .connected)
                Spacer()
                Button("Launch approved fixture…") { confirmFixture = true }
                    .disabled(!coordinator.canLaunchFixture)
            }

            List(coordinator.runtimes, id: \.runtime.runtimeGeneration) { terminal in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(terminal.process.displayName) · \(terminal.runtime.target.sessionId.uuidString.lowercased())")
                        .font(.system(.body, design: .monospaced))
                    Text("Pane \(terminal.runtime.target.paneId.uuidString.lowercased()) · runtime \(terminal.runtime.runtimeGeneration.uuidString.lowercased())")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            }
            .overlay {
                if coordinator.runtimes.isEmpty {
                    ContentUnavailableView("No daemon runtimes", systemImage: "server.rack", description: Text("Listing is read-only. It does not restore or launch work."))
                }
            }

            Text("Debug-only credential-free loopback RPC. This panel never attaches Ghostty, imports the Axo workspace registry, or reconstructs a terminal screen from raw output.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(minWidth: 780, minHeight: 460)
        .confirmationDialog("Launch the approved local fixture?", isPresented: $confirmFixture) {
            Button("Launch once") { coordinator.launchApprovedFixture() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This starts a fixed /usr/bin/printf fixture in the isolated development state directory. It does not use Pi or an existing Axo session.")
        }
    }

    private var statusTitle: String {
        switch coordinator.connectionState {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .failed: "Needs attention"
        }
    }

    private var statusColor: Color {
        switch coordinator.connectionState {
        case .disconnected: .secondary
        case .connecting: .orange
        case .connected: .green
        case .failed: .red
        }
    }
}

private extension TerminalProcess {
    var displayName: String {
        switch self {
        case .starting: "Starting"
        case .running(let pid): "Running (pid \(pid))"
        case .stopping(let pid): "Stopping (pid \(pid))"
        case .exited(let status): "Exited (status \(status))"
        case .failed: "Failed"
        case .recoveryRequired: "Recovery required"
        }
    }
}
