import AxoCore
import AxoProtocol
import Foundation
import Observation

@MainActor
@Observable
final class PrivateMachineBrowserModel {
    private(set) var machines: [MachineSummary] = []
    private(set) var isDiscovering = false
    private(set) var isLoadingCatalog = false
    private(set) var isConnected = false
    private(set) var accessMessage: String?
    private(set) var notice: String?
    private(set) var selectedMachineID: UUID?
    private(set) var catalog: CentralCatalog?
    private(set) var catalogNotice: String?
    private var connectedMachineID: UUID?
    private var controlPlane: AxoControlPlaneSession?
    private var selectionOperation = UUID()
    private var discoveryOperation = UUID()
    private var authorizationOperation = UUID()

    private let endpoint: AxoControlPlaneEndpoint
    private let persistsCredentials: Bool
    private var accessCookie: AxoControlPlaneAccessCookie?

    init(endpoint: AxoControlPlaneEndpoint = .production,
         credential: AxoControlPlaneAccessCookie? = nil, persistsCredentials: Bool = true) {
        self.endpoint = endpoint
        self.persistsCredentials = persistsCredentials
        if let credential { use(credential); return }
        #if DEBUG
        if isPreview { loadPreview(); return }
        #endif
        guard let host = endpoint.baseURL.host,
              let credential = ControlPlaneAccessCredential.load(host: host) else { return }
        use(credential)
    }

    var isSignedIn: Bool { accessCookie != nil }
    var selectedMachine: MachineSummary? { machines.first { $0.machineId == selectedMachineID } }

    /// One indivisible graph, scoped to the selected live host and store. Never
    /// expose independently cached workspace/runtime pages or an offline graph.
    var selectedCatalog: CentralCatalog? {
        guard isConnected, let machine = selectedMachine, machine.online, let catalog,
              catalog.source.machine.machineId == machine.machineId,
              catalog.source.machine.hostGeneration == machine.hostGeneration else { return nil }
        return catalog
    }
    var isRuntimeGenerationStale: Bool {
        guard let machine = selectedMachine, let catalog else { return false }
        return !machine.online || catalog.source.machine.machineId != machine.machineId || catalog.source.machine.hostGeneration != machine.hostGeneration
    }
    var selectedRuntimes: [TerminalSnapshot] { selectedCatalog?.terminals ?? [] }
    var selectedWorkspaces: [CentralWorkspace] { selectedCatalog?.workspaces ?? [] }
    var selectedWorkSessions: [CentralSessionView] { selectedCatalog?.sessions ?? [] }
    func sessions(in workspaceId: UUID?) -> [CentralSessionView] { selectedCatalog?.sessionsByWorkspace[workspaceId] ?? [] }
    var selectedWorkRevision: CentralRevision? { selectedCatalog?.revision }

    func start() async {
        #if DEBUG
        if isPreview { return }
        #endif
        while !Task.isCancelled {
            await refreshMachines()
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    func signIn(_ credential: AxoControlPlaneAccessCookie) async {
        guard let host = endpoint.baseURL.host else { return }
        do {
            if persistsCredentials { try ControlPlaneAccessCredential.save(credential, host: host) }
            let authorization = UUID()
            authorizationOperation = authorization
            discoveryOperation = UUID()
            await disconnect()
            guard authorizationOperation == authorization else { return }
            use(credential)
            machines = []
            accessMessage = nil
            await refreshMachines()
        } catch { notice = "Cloudflare Access could not be saved securely on this device." }
    }

    func signOut() async {
        // Fence old callbacks before awaiting transport teardown.
        authorizationOperation = UUID()
        discoveryOperation = UUID()
        selectionOperation = UUID()
        let previous = controlPlane
        controlPlane = nil
        if persistsCredentials, let host = endpoint.baseURL.host { ControlPlaneAccessCredential.remove(host: host) }
        accessCookie = nil
        machines = []; selectedMachineID = nil
        clearCatalog()
        isConnected = false; connectedMachineID = nil
        isDiscovering = false; isLoadingCatalog = false
        accessMessage = nil
        notice = nil
        await previous?.disconnect()
    }

    func refreshMachines() async {
        #if DEBUG
        if isPreview { return }
        #endif
        guard let controlPlane else { accessMessage = "Cloudflare Access authorization is required."; return }
        let operation = UUID()
        discoveryOperation = operation
        isDiscovering = true; notice = nil
        defer { if discoveryOperation == operation { isDiscovering = false } }
        do {
            let result = try await controlPlane.discoverMachines()
            guard discoveryOperation == operation else { return }
            let previous = selectedMachine
            machines = result.machines
            if let machineID = selectedMachineID,
               let current = machines.first(where: { $0.machineId == machineID }) {
                if !current.online || current.hostGeneration == nil || current.hostGeneration != previous?.hostGeneration {
                    selectionOperation = UUID()
                    clearCatalog()
                    isConnected = false; connectedMachineID = nil; isLoadingCatalog = false
                    notice = "The machine is offline or restarted. Reconnect to read its current central state."
                    await controlPlane.disconnect()
                }
            } else if selectedMachineID != nil {
                selectionOperation = UUID()
                clearCatalog()
                selectedMachineID = nil
                isConnected = false; connectedMachineID = nil; isLoadingCatalog = false
                await controlPlane.disconnect()
            }
        } catch {
            guard discoveryOperation == operation else { return }
            selectionOperation = UUID()
            machines = []; clearCatalog()
            selectedMachineID = nil
            isConnected = false; connectedMachineID = nil; isLoadingCatalog = false
            await controlPlane.disconnect()
            guard discoveryOperation == operation else { return }
            await report(error)
        }
    }

    func selectMachine(_ machineID: UUID) async {
        guard let machine = machines.first(where: { $0.machineId == machineID }) else { return }
        #if DEBUG
        if isPreview {
            selectedMachineID = machineID
            isConnected = machine.online && catalog?.source.machine.machineId == machineID && catalog?.source.machine.hostGeneration == machine.hostGeneration
            connectedMachineID = isConnected ? machineID : nil
            return
        }
        #endif
        selectedMachineID = machineID
        let operation = UUID()
        selectionOperation = operation
        clearCatalog()
        notice = nil
        isConnected = false; connectedMachineID = nil; isLoadingCatalog = false
        guard machine.online, machine.hostGeneration != nil else { await controlPlane?.disconnect(); return }
        guard let controlPlane else { return }
        isLoadingCatalog = true
        defer { if selectionOperation == operation { isLoadingCatalog = false } }
        do {
            _ = try await controlPlane.connect(to: machine)
            guard selectionOperation == operation, selectedMachineID == machineID else { return }
            connectedMachineID = machineID
            isConnected = true
            await loadCatalog(machineID: machineID, operation: operation)
        } catch {
            guard selectionOperation == operation, selectedMachineID == machineID else { return }
            clearCatalog()
            await report(error)
        }
    }

    private func loadCatalog(machineID: UUID, operation: UUID) async {
        guard connectedMachineID == machineID, selectionOperation == operation, let controlPlane else { return }
        clearCatalog()
        do {
            let result = try await controlPlane.catalog()
            guard selectionOperation == operation, selectedMachineID == machineID else { return }
            catalog = result
        } catch {
            guard selectionOperation == operation, selectedMachineID == machineID else { return }
            clearCatalog()
            isConnected = false; connectedMachineID = nil
            await report(error)
            guard selectionOperation == operation, selectedMachineID == machineID else { return }
            catalogNotice = notice ?? "Central state is unavailable. No cached graph was applied."
        }
    }

    func refreshCatalog() async {
        guard !isLoadingCatalog, let machineID = selectedMachineID, connectedMachineID == machineID else { return }
        let operation = selectionOperation
        notice = nil; isLoadingCatalog = true
        defer { if selectionOperation == operation { isLoadingCatalog = false } }
        await loadCatalog(machineID: machineID, operation: operation)
    }

    func disconnect() async {
        selectionOperation = UUID()
        clearCatalog()
        isConnected = false; connectedMachineID = nil; isLoadingCatalog = false
        await controlPlane?.disconnect()
    }

    func reconnect() async {
        guard !isLoadingCatalog else { return }
        guard let machineID = selectedMachineID else { await refreshMachines(); return }
        let operation = UUID()
        selectionOperation = operation
        await refreshMachines()
        guard selectionOperation == operation, selectedMachineID == machineID,
              let machine = machines.first(where: { $0.machineId == machineID }), machine.online else { return }
        await selectMachine(machineID)
    }

    private func clearCatalog() { catalog = nil; catalogNotice = nil }
    private func use(_ credential: AxoControlPlaneAccessCookie) {
        accessCookie = credential
        controlPlane = AxoControlPlaneSession(endpoint: endpoint, accessCookie: credential)
    }

    private func report(_ error: Error) async {
        if case AxoJSONRPCClientError.unauthorized = error {
            await signOut()
            guard accessCookie == nil else { return }
            accessMessage = "Cloudflare Access expired or was denied. Sign in again."
            return
        }
        if let error = error as? AxoJSONRPCClientError {
            switch error {
            case .redirectRejected: notice = "The endpoint redirected to sign-in. Open Cloudflare Access and authorize again."
            case .outcomeUnknown: notice = "Delivery is unknown. No mutation was replayed."
            case .remote(code: -32002, message: _): notice = "The central source or revision changed. Reconnect."
            case .remote(code: -32003, message: _): notice = "The selected machine is offline."
            case .remote(code: -32001, message: _): notice = "The selected host requires compatible negotiation."
            case .remote: notice = "The host rejected the request."
            default: notice = error.localizedDescription
            }
        } else if let error = error as? AxoProtocolValidationError {
            switch error {
            case .staleHost: notice = "The host restarted. Old cached sessions were discarded; reconnect."
            case .staleStore: notice = "The central store changed. Old cached sessions were discarded; reconnect."
            default: notice = "The host returned invalid central session metadata. No data was applied."
            }
        } else if let error = error as? AxoControlPlaneSessionError {
            switch error {
            case .machineOffline: notice = "The selected machine is offline."
            case .superseded: return
            case .noSelectedMachine: notice = "Select an online machine first."
            case .outcomeUnknown: notice = "The original central command has an unknown outcome. No mutation was replayed."
            case .unsupportedMethod, .protocolMismatch: notice = "This daemon does not support central session management. No legacy catalog was used."
            }
        } else { notice = "The private control plane is unavailable. Refresh or reconnect to the selected machine." }
    }

    #if DEBUG
    private var isPreview: Bool { ProcessInfo.processInfo.arguments.contains("--axo-control-plane-preview") }

    private func loadPreview() {
        let onlineID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let offlineID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let restartedID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let generation = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        machines = [MachineSummary(machineId: onlineID, label: "Studio Mac", online: true, hostGeneration: generation),
                    MachineSummary(machineId: offlineID, label: "Travel Mac", online: false, hostGeneration: nil),
                    MachineSummary(machineId: restartedID, label: "Restarted Mac", online: true, hostGeneration: generation)]
        let source = try! CentralSource(machine: .init(machineId: onlineID, hostGeneration: generation), storeGeneration: UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!)
        let fixture = try! CentralBrowserPreview.records(source: source, piID: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!)
        catalog = try! CentralCatalog(source: source, revision: CentralRevision(rawValue: 7)!, workspaces: fixture.workspaces, sessions: fixture.sessions)
        selectedMachineID = onlineID; connectedMachineID = onlineID; isConnected = true
        let header = Data(#"{"alg":"none"}"#.utf8).base64URL
        let payload = Data(#"{"aud":"\#(AxoControlPlaneEndpoint.accessAudience)","exp":4102444800,"type":"app"}"#.utf8).base64URL
        accessCookie = try? AxoControlPlaneAccessCookie("\(header).\(payload).signature")
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
