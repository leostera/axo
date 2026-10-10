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
    private(set) var workspaces: [UUID: [ProtocolWorkspaceRecord]] = [:]
    private(set) var workSessions: [UUID: [WorkSessionRecord]] = [:]
    private(set) var workRevisions: [UUID: WorkRevision] = [:]
    private(set) var isLoadingWork = false
    private(set) var workNotice: String?

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
    var selectedWorkspaces: [ProtocolWorkspaceRecord] { selectedMachineID.flatMap { workspaces[$0] } ?? [] }
    var selectedWorkSessions: [WorkSessionRecord] { selectedMachineID.flatMap { workSessions[$0] } ?? [] }
    var selectedWorkRevision: WorkRevision? { selectedMachineID.flatMap { workRevisions[$0] } }
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
        workspaces = [:]
        workSessions = [:]
        workRevisions = [:]
        workNotice = nil
        selectedMachineID = nil
        connectedMachineID = nil
        isConnected = false
        accessMessage = nil
        notice = nil
        selectionOperation = UUID()
        discoveryOperation = UUID()
        isDiscovering = false
        isLoadingRuntimes = false
        isLoadingWork = false
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
                    selectionOperation = UUID()
                    isLoadingRuntimes = false
                    isLoadingWork = false
                    isConnected = false
                    connectedMachineID = nil
                    clearWorkRecords(for: selectedMachineID)
                    await controlPlane.disconnect()
                }
            } else if let selectedMachineID {
                selectionOperation = UUID()
                isLoadingRuntimes = false
                isLoadingWork = false
                isConnected = false
                connectedMachineID = nil
                notice = "This host is no longer in the authorized machine directory."
                clearWorkRecords(for: selectedMachineID)
                await controlPlane.disconnect()
            }
        } catch {
            await report(error)
        }
    }

    func selectMachine(_ machineID: UUID) async {
        guard let machine = machines.first(where: { $0.machineId == machineID }) else { return }
        selectedMachineID = machineID
        workspaces[machineID] = nil
        workSessions[machineID] = nil
        workRevisions[machineID] = nil
        workNotice = nil
        isLoadingWork = false
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
            workspaces[machineID] = nil
            workSessions[machineID] = nil
            workRevisions[machineID] = nil
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
            await refreshWorkRecords(for: machineID, operation: operation)
        } catch {
            guard selectionOperation == operation, selectedMachineID == machineID else { return }
            await report(error)
        }
    }

    func refreshWorkRecords() async {
        guard let machineID = selectedMachineID else { return }
        await refreshWorkRecords(for: machineID, operation: selectionOperation)
    }

    private func refreshWorkRecords(for machineID: UUID, operation: UUID) async {
        guard connectedMachineID == machineID, selectionOperation == operation,
              let controlPlane else { return }
        workspaces[machineID] = nil
        workSessions[machineID] = nil
        workRevisions[machineID] = nil
        isLoadingWork = true
        workNotice = nil
        defer { if selectionOperation == operation { isLoadingWork = false } }

        do {
            var workspaceRecords: [ProtocolWorkspaceRecord] = []
            var workspaceCursor: WorkPageCursor?
            var revision: WorkRevision?
            repeat {
                let page = try await controlPlane.listWorkspaces(cursor: workspaceCursor)
                guard selectionOperation == operation, selectedMachineID == machineID else { return }
                if let revision, revision != page.revision { throw AxoProtocolValidationError.invalidResult(method: AxoProtocol.Method.listWorkspaces) }
                revision = page.revision
                workspaceRecords.append(contentsOf: page.workspaces)
                workspaceCursor = page.next
            } while workspaceCursor != nil

            var sessionRecords: [WorkSessionRecord] = []
            var sessionCursor: WorkPageCursor?
            repeat {
                let page = try await controlPlane.listSessions(cursor: sessionCursor)
                guard selectionOperation == operation, selectedMachineID == machineID else { return }
                guard page.revision == revision else { throw AxoProtocolValidationError.invalidResult(method: AxoProtocol.Method.listSessions) }
                sessionRecords.append(contentsOf: page.sessions)
                sessionCursor = page.next
            } while sessionCursor != nil

            guard selectionOperation == operation, selectedMachineID == machineID,
                  let revision,
                  sessionRecords.allSatisfy({ session in workspaceRecords.contains(where: { $0.workspaceId == session.workspaceId }) }) else {
                throw AxoProtocolValidationError.invalidResult(method: AxoProtocol.Method.listSessions)
            }
            workspaces[machineID] = workspaceRecords
            workSessions[machineID] = sessionRecords
            workRevisions[machineID] = revision
        } catch {
            guard selectionOperation == operation, selectedMachineID == machineID else { return }
            workspaces[machineID] = nil
            workSessions[machineID] = nil
            workRevisions[machineID] = nil
            await reportWork(error)
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
            await refreshWorkRecords(for: machineID, operation: operation)
        } catch {
            guard selectionOperation == operation else { return }
            isConnected = false
            connectedMachineID = nil
            isLoadingWork = false
            clearWorkRecords(for: machineID)
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
        isLoadingWork = false
        if let selectedMachineID { clearWorkRecords(for: selectedMachineID) }
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

    private func clearWorkRecords(for machineID: UUID) {
        workspaces[machineID] = nil
        workSessions[machineID] = nil
        workRevisions[machineID] = nil
        workNotice = nil
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
            case .unsupportedMethod(let method):
                notice = "This host does not support \(method). No legacy data was loaded."
            case .invalidPageRequest:
                notice = "The work-record page no longer matches the selected host or revision. Refresh before continuing."
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

    private func reportWork(_ error: Error) async {
        if let controlError = error as? AxoControlPlaneSessionError,
           case .unsupportedMethod(let method) = controlError {
            workNotice = "This daemon does not support \(method). No legacy or cached catalog was used."
            return
        }
        if let validationError = error as? AxoProtocolValidationError,
           case .staleHost = validationError {
            workNotice = "The daemon restarted while loading work records. Refresh machines and try again."
            return
        }
        if let rpcError = error as? AxoJSONRPCClientError,
           case .remote(code: -32002, message: _) = rpcError {
            workNotice = "The work-record page became stale. Refresh to load one current revision."
            return
        }
        await report(error)
        workNotice = notice ?? "Work records are unavailable. Nothing was loaded from a legacy catalog."
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
        let workspaceID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let workSessionID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        workspaces[onlineID] = [ProtocolWorkspaceRecord(workspaceId: workspaceID, name: "Axo", directoryId: "project")]
        workSessions[onlineID] = [WorkSessionRecord(
            sessionId: workSessionID, workspaceId: workspaceID, name: "Build the phone app",
            nameSource: .manual,
            pi: WorkSessionPiBinding(paneId: UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!,
                                     chatId: nil, admission: .notAdmitted),
            runtime: nil
        )]
        workRevisions[onlineID] = WorkRevision(rawValue: 7)
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
