import AxoCore
import AxoProtocol
import Foundation
import Observation

@MainActor
@Observable
final class PrivateMachineBrowserModel {
    private(set) var machines: [MachineSummary] = []
    private(set) var isDiscovering = false
    private(set) var isLoadingRuntimes = false
    private(set) var isConnected = false
    private(set) var selectedMachineID: UUID?
    private(set) var notice: String?
    private(set) var accessMessage: String?
    private(set) var runtimeResults: [UUID: RuntimeListResult] = [:]
    private(set) var runtimeCursors: [UUID: UUID] = [:]

    private let endpoint = AxoControlPlaneEndpoint.production
    private var accessCookie: AxoControlPlaneAccessCookie?
    private var controlPlane: AxoControlPlaneSession?
    private var discoveryOperation = UUID()
    private var selectionOperation = UUID()
    private var connectedMachineID: UUID?

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--axo-control-plane-preview") {
            loadPreview()
            return
        }
        #endif

        guard let host = endpoint.baseURL.host,
              let credential = ControlPlaneAccessCredential.load(host: host) else { return }
        use(credential)
    }

    var selectedMachine: MachineSummary? {
        guard let selectedMachineID else { return nil }
        return machines.first { $0.machineId == selectedMachineID }
    }

    var selectedRuntimeResult: RuntimeListResult? {
        guard let selectedMachineID else { return nil }
        return runtimeResults[selectedMachineID]
    }

    var selectedRuntimes: [TerminalSnapshot] { selectedRuntimeResult?.terminals ?? [] }
    var selectedRuntimeCursor: UUID? {
        guard let selectedMachineID else { return nil }
        return runtimeCursors[selectedMachineID]
    }
    var isSignedIn: Bool { accessCookie != nil }
    var isRuntimeGenerationStale: Bool {
        guard let machine = selectedMachine, let result = selectedRuntimeResult else { return false }
        return !machine.online || machine.hostGeneration != result.hostGeneration
    }

    func start() async {
        #if DEBUG
        if isPreview { return }
        #endif
        await refreshMachines()
    }

    func signIn(_ credential: AxoControlPlaneAccessCookie) async {
        guard let host = endpoint.baseURL.host else { return }
        do {
            try ControlPlaneAccessCredential.save(credential, host: host)
            use(credential)
            accessMessage = nil
            await refreshMachines()
        } catch {
            notice = "Cloudflare Access could not be saved securely on this device."
        }
    }

    func signOut() async {
        if let host = endpoint.baseURL.host { ControlPlaneAccessCredential.remove(host: host) }
        await controlPlane?.disconnect()
        controlPlane = nil
        accessCookie = nil
        machines = []
        runtimeResults = [:]
        runtimeCursors = [:]
        selectedMachineID = nil
        connectedMachineID = nil
        isConnected = false
        accessMessage = nil
        notice = nil
        selectionOperation = UUID()
        discoveryOperation = UUID()
        isDiscovering = false
        isLoadingRuntimes = false
    }

    func refreshMachines() async {
        #if DEBUG
        if isPreview { return }
        #endif
        guard let controlPlane else { return }
        let operation = UUID()
        discoveryOperation = operation
        isDiscovering = true
        notice = nil
        defer {
            if discoveryOperation == operation { isDiscovering = false }
        }

        do {
            let result = try await controlPlane.discoverMachines()
            guard discoveryOperation == operation else { return }
            machines = result.machines
            if let selectedMachineID,
               let selected = result.machines.first(where: { $0.machineId == selectedMachineID }) {
                if !selected.online || selected.hostGeneration != runtimeResults[selectedMachineID]?.hostGeneration {
                    isConnected = false
                    connectedMachineID = nil
                    await controlPlane.disconnect()
                }
            } else if selectedMachineID != nil {
                isConnected = false
                connectedMachineID = nil
                notice = "This host is no longer in the authorized machine directory."
                await controlPlane.disconnect()
            }
        } catch {
            await report(error)
        }
    }

    func selectMachine(_ machineID: UUID) async {
        guard let machine = machines.first(where: { $0.machineId == machineID }) else { return }
        selectedMachineID = machineID
        let operation = UUID()
        selectionOperation = operation
        notice = nil
        isConnected = false
        connectedMachineID = nil

        #if DEBUG
        if isPreview {
            isConnected = machine.online && runtimeResults[machineID]?.hostGeneration == machine.hostGeneration
            connectedMachineID = isConnected ? machineID : nil
            return
        }
        #endif

        guard machine.online, machine.hostGeneration != nil else {
            await controlPlane?.disconnect()
            return
        }
        guard let controlPlane else { return }

        isLoadingRuntimes = true
        defer { if selectionOperation == operation { isLoadingRuntimes = false } }
        do {
            let result = try await controlPlane.connect(to: machine)
            guard selectionOperation == operation, selectedMachineID == machineID else { return }
            runtimeResults[machineID] = result
            runtimeCursors[machineID] = result.next
            connectedMachineID = machineID
            isConnected = true
        } catch {
            guard selectionOperation == operation, selectedMachineID == machineID else { return }
            await report(error)
        }
    }

    func refreshRuntimes() async {
        guard let machineID = selectedMachineID,
              connectedMachineID == machineID,
              let controlPlane else { return }
        let operation = selectionOperation
        isLoadingRuntimes = true
        notice = nil
        defer { if selectionOperation == operation { isLoadingRuntimes = false } }
        do {
            let result = try await controlPlane.refreshRuntimes()
            guard selectionOperation == operation, selectedMachineID == machineID else { return }
            runtimeResults[machineID] = result
            runtimeCursors[machineID] = result.next
        } catch {
            guard selectionOperation == operation else { return }
            isConnected = false
            connectedMachineID = nil
            await report(error)
        }
    }

    func loadMoreRuntimes() async {
        guard let machineID = selectedMachineID,
              connectedMachineID == machineID,
              let after = runtimeCursors[machineID],
              let controlPlane else { return }
        let operation = selectionOperation
        isLoadingRuntimes = true
        defer { if selectionOperation == operation { isLoadingRuntimes = false } }
        do {
            let page = try await controlPlane.refreshRuntimes(after: after)
            guard selectionOperation == operation, selectedMachineID == machineID else { return }
            let old = runtimeResults[machineID]
            let known = Set(old?.terminals.map(\.runtime.runtimeGeneration) ?? [])
            let additions = page.terminals.filter { !known.contains($0.runtime.runtimeGeneration) }
            runtimeResults[machineID] = RuntimeListResult(
                hostGeneration: page.hostGeneration,
                terminals: (old?.terminals ?? []) + additions,
                next: page.next
            )
            runtimeCursors[machineID] = page.next
        } catch {
            guard selectionOperation == operation else { return }
            await report(error)
        }
    }

    func disconnect() async {
        selectionOperation = UUID()
        isConnected = false
        connectedMachineID = nil
        await controlPlane?.disconnect()
    }

    func reconnect() async {
        guard let machineID = selectedMachineID else {
            await refreshMachines()
            return
        }
        await refreshMachines()
        guard let refreshed = machines.first(where: { $0.machineId == machineID }), refreshed.online else { return }
        await selectMachine(machineID)
    }

    private func use(_ credential: AxoControlPlaneAccessCookie) {
        accessCookie = credential
        controlPlane = AxoControlPlaneSession(endpoint: endpoint, accessCookie: credential)
    }

    private func report(_ error: Error) async {
        if let error = error as? AxoJSONRPCClientError,
           case .unauthorized = error {
            accessMessage = "Cloudflare Access expired or was denied. Sign in again."
            await signOut()
            accessMessage = "Cloudflare Access expired or was denied. Sign in again."
            return
        }
        if let error = error as? AxoControlPlaneSessionError {
            switch error {
            case .machineOffline:
                notice = error.localizedDescription
            case .noSelectedMachine, .superseded:
                notice = "The machine selection changed. Refresh the list before continuing."
            case .protocolMismatch:
                notice = "This host uses an incompatible control protocol. No runtime data was applied."
            }
            return
        }
        if let error = error as? AxoProtocolValidationError {
            if case .staleHost = error {
                notice = "The host generation changed. Refresh machines, then reconnect to the current generation."
            } else {
                notice = "The host returned invalid runtime metadata. No data was applied."
            }
            return
        }
        notice = error.localizedDescription
    }

    #if DEBUG
    private var isPreview: Bool { ProcessInfo.processInfo.arguments.contains("--axo-control-plane-preview") }

    private func loadPreview() {
        let onlineID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let currentGeneration = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let oldGeneration = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let offlineID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let restartedID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let sessionID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let paneID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        machines = [
            MachineSummary(machineId: onlineID, label: "Studio Mac", online: true, hostGeneration: currentGeneration),
            MachineSummary(machineId: offlineID, label: "Travel Mac", online: false, hostGeneration: nil),
            MachineSummary(machineId: restartedID, label: "Restarted Mac", online: true, hostGeneration: currentGeneration),
        ]
        let current = TerminalSnapshot(
            runtime: TerminalRuntime(
                hostGeneration: currentGeneration,
                target: .init(sessionId: sessionID, paneId: paneID),
                runtimeGeneration: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
            ),
            process: .running(pid: 1234), attached: true, backlogBytes: 0
        )
        let historical = TerminalSnapshot(
            runtime: TerminalRuntime(
                hostGeneration: oldGeneration,
                target: .init(sessionId: sessionID, paneId: UUID(uuidString: "88888888-8888-4888-8888-888888888888")!),
                runtimeGeneration: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
            ),
            process: .exited(waitStatus: 0), attached: false, backlogBytes: 0
        )
        runtimeResults[onlineID] = RuntimeListResult(hostGeneration: currentGeneration, terminals: [current, historical], next: nil)
        runtimeResults[offlineID] = RuntimeListResult(hostGeneration: oldGeneration, terminals: [current], next: nil)
        runtimeResults[restartedID] = RuntimeListResult(hostGeneration: oldGeneration, terminals: [historical], next: nil)
        selectedMachineID = onlineID
        connectedMachineID = onlineID
        isConnected = true
        accessCookie = try? AxoControlPlaneAccessCookie(Self.previewToken())
    }

    private static func previewToken() -> String {
        let header = Data(#"{"alg":"none"}"#.utf8).base64URL
        let payload = Data(#"{"aud":"\#(AxoControlPlaneEndpoint.accessAudience)","exp":4102444800,"type":"app"}"#.utf8).base64URL
        return "\(header).\(payload).signature"
    }
    #endif
}

#if DEBUG
private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#endif
