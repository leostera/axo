import AxoProtocol
import Foundation

/// One addressed central authority. Connecting and loading are read-only;
/// callers submit closed intents once and reconcile unknown originals by ID.
public actor AxoControlPlaneSession {
    private let endpoint: AxoControlPlaneEndpoint
    private let accessCookie: AxoControlPlaneAccessCookie
    private let rpc: AxoJSONRPCClient
    private var connection: AxoJSONRPCWebSocketConnection?
    private var machine: MachineTarget?
    private var source: CentralSource?
    private var methods = Set<String>()
    private var operationID = UUID()

    public init(endpoint: AxoControlPlaneEndpoint = .production, accessCookie: AxoControlPlaneAccessCookie, rpc: AxoJSONRPCClient = AxoJSONRPCClient()) {
        self.endpoint = endpoint; self.accessCookie = accessCookie; self.rpc = rpc
    }
    public func discoverMachines() async throws -> MachineListResult {
        let value = try await rpc.callHTTP(endpoint: endpoint, accessCookie: accessCookie, method: AxoProtocol.Method.listMachines, parameters: EmptyRPCParameters())
        return try AxoProtocolResultValidator.machineList(value)
    }
    public func connect(to summary: MachineSummary) async throws -> CentralResponse {
        guard summary.online, let generation = summary.hostGeneration else { throw AxoControlPlaneSessionError.machineOffline(summary.machineId) }
        let destination = MachineTarget(machineId: summary.machineId, hostGeneration: generation)
        let operation = UUID()
        operationID = operation
        let previous = connection
        connection = nil; source = nil; methods = []; machine = destination
        await previous?.close()
        try requireCurrent(operation, machine: destination)
        var opened: AxoJSONRPCWebSocketConnection?
        do {
            let directory = try await discoverMachines()
            try requireCurrent(operation, machine: destination)
            guard let current = directory.machines.first(where: { $0.machineId == summary.machineId }), current.online, let currentGeneration = current.hostGeneration else {
                throw AxoControlPlaneSessionError.machineOffline(summary.machineId)
            }
            guard currentGeneration == generation else { throw AxoProtocolValidationError.staleHost(expected: generation, actual: currentGeneration) }
            let peer = try rpc.openWebSocket(endpoint: endpoint, machineID: summary.machineId, accessCookie: accessCookie)
            opened = peer; connection = peer
            let negotiation = try await peer.request(method: AxoProtocol.Method.negotiate, parameters: NegotiationParameters())
            try requireCurrent(operation, machine: destination, connection: peer)
            let capabilities = try AxoProtocolResultValidator.negotiation(negotiation)
            guard CentralRequest.readMethods.isSubset(of: Set(capabilities.methods)) else { throw AxoControlPlaneSessionError.protocolMismatch }
            let request = try CentralRequest.bootstrap(machine: destination)
            let result = try request.parseResult(await peer.request(method: request.method, parameters: request.parameters))
            try requireCurrent(operation, machine: destination, connection: peer)
            source = result.source; methods = Set(capabilities.methods)
            return result
        } catch {
            if operationID == operation { connection = nil; source = nil; machine = nil; methods = [] }
            await opened?.close()
            throw error
        }
    }
    public func selectedSource() throws -> CentralSource {
        guard let source, connection != nil else { throw AxoControlPlaneSessionError.noSelectedMachine }; return source
    }
    public func supports(method: String) -> Bool { source != nil && connection != nil && methods.contains(method) }
    public func perform(_ request: CentralRequest) async throws -> CentralResponse {
        let captured = try selectedSource()
        guard request.machine == captured.machine,
              request.source == captured || (request.source == nil && request.method == "axo.state.get") else {
            throw AxoControlPlaneSessionError.superseded
        }
        guard methods.contains(request.method) else { throw AxoControlPlaneSessionError.unsupportedMethod(request.method) }
        guard let peer = connection else { throw AxoControlPlaneSessionError.noSelectedMachine }
        let operation = operationID
        do {
            let raw = try await peer.request(method: request.method, parameters: request.parameters)
            try requireCurrent(operation, machine: captured.machine, connection: peer)
            let response = try request.parseResult(raw)
            guard response.source == captured else { throw AxoProtocolValidationError.staleStore(expected: captured.storeGeneration, actual: response.source.storeGeneration) }
            return response
        } catch {
            // A changed authority invalidates this connection, not just this page.
            // Other in-flight calls cannot publish into a replacement selection.
            if let validation = error as? AxoProtocolValidationError {
                switch validation {
                case .staleHost, .staleStore:
                    if operationID == operation { operationID = UUID(); connection = nil; source = nil; machine = nil; methods = [] }
                    await peer.close()
                default: break
                }
            }
            if let commandId = request.commandId {
                throw AxoControlPlaneSessionError.outcomeUnknown(source: captured, commandId: commandId)
            }
            throw error
        }
    }
    public func catalog() async throws -> CentralCatalog {
        let captured = try selectedSource(), operation = operationID
        do {
            let result = try await CentralCatalogLoader.load(source: captured) { request in try await self.perform(request) }
            try requireCurrent(operation, machine: captured.machine)
            return result
        } catch {
            if operationID == operation { await disconnect() }
            throw error
        }
    }
    public func disconnect() async {
        operationID = UUID(); machine = nil; source = nil; methods = []
        let previous = connection; connection = nil
        await previous?.close()
    }
    private func requireCurrent(_ operation: UUID, machine expected: MachineTarget, connection peer: AxoJSONRPCWebSocketConnection? = nil) throws {
        guard operationID == operation, machine == expected, peer == nil || connection === peer else { throw AxoControlPlaneSessionError.superseded }
    }
}
