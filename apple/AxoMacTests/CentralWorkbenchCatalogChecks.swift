import AppKit
import AxoCore
import AxoProtocol
import Foundation

/// Actual production coordinator against an explicitly owned local fixture.
/// This is catalog/transport acceptance, not foreground, selection or IME proof.
@main struct CentralWorkbenchCatalogChecks {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Owned fixture and helper required") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axo-native-central-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1]); process.arguments = [root.path]
        var environment = ProcessInfo.processInfo.environment; environment["HOME"] = root.path; environment["ZDOTDIR"] = root.path
        process.environment = environment; process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let directory = try AxodStateDirectory.openExisting(root: root)
        var endpoint: LocalDaemonEndpoint?
        try await wait {
            endpoint = try directory.readEndpoint()
            return endpoint != nil
        }
        let discovered = endpoint!
        let suite = "Axo.CentralWorkbenchCheck.\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let retired = "Axo.axod.selection.sessionID", opaque = Data([0x91, 0, 0xff, 0x23])
        preferences.set(opaque, forKey: retired)
        let coordinator = AxodWorkbenchCoordinator(preferences: preferences)
        try await coordinator.connectOwnedFixture(root: root, helper: URL(fileURLWithPath: CommandLine.arguments[2]))
        precondition(coordinator.connectionState == .connected && coordinator.catalog != nil)
        precondition(coordinator.sessions.isEmpty && coordinator.workspaces.isEmpty && coordinator.runtimes.isEmpty, "Connection does not create or start work")
        let peer = try AxoJSONRPCClient().openLocalWebSocket(endpoint: discovered)
        _ = try AxoProtocolResultValidator.localNegotiation(await peer.request(method: AxoProtocol.Method.negotiate, parameters: NegotiationParameters()))
        let bootstrap = try await call(CentralRequest.bootstrap(machine: .init(machineId: discovered.machineId, hostGeneration: discovered.hostGeneration)), peer)
        let workspace = try await call(CentralRequest.createWorkspace(source: bootstrap.source, commandId: UUID(), expectedRevision: bootstrap.revision, name: "Owned workspace", directoryPath: root.path), peer)
        guard case .operation(.createWorkspace(let original)?, _) = workspace.payload else { fatalError("Complete workspace graph") }
        precondition(original.graph.initialSession.panes.count == 2)
        let home = try await call(CentralRequest.createSession(source: bootstrap.source, workspaceId: nil, commandId: UUID(), expectedRevision: workspace.revision), peer)
        guard case .operation(.createStandalone(let standalone)?, _) = home.payload else { fatalError("Complete home graph") }
        coordinator.refresh()
        try await wait { coordinator.sessions.count == 2 && coordinator.workspaces.count == 1 && coordinator.runtimes.count == 2 }
        precondition(coordinator.catalog?.source == bootstrap.source)
        precondition(coordinator.catalog?.sessions.allSatisfy { $0.readiness != .ready } == true, "No Pi policy cannot fabricate readiness")
        coordinator.selectSession(standalone.graph.session.sessionId)
        precondition(coordinator.selectedWorkspaceID == nil && coordinator.selectedSessionID == standalone.graph.session.sessionId)
        coordinator.selectWorkspace(original.graph.workspace.workspaceId)
        precondition(coordinator.selectedSessionID == original.graph.initialSession.session.sessionId)
        precondition(preferences.data(forKey: retired) == opaque, "Retired selection preference bytes are neither imported nor changed")
        let captured = coordinator.runtimes.map(\.runtime)
        coordinator.disconnect()
        precondition(process.isRunning, "Client disconnect is not lifecycle intent")
        let catalog = try await CentralCatalogLoader.load(source: bootstrap.source) { request in try await call(request, peer) }
        precondition(catalog.terminals.count == captured.count && catalog.terminals.allSatisfy { captured.contains($0.runtime) })
        precondition(catalog.terminals.allSatisfy { if case .running = $0.process { return true }; return false })
        try await coordinator.connectOwnedFixture(root: root, helper: URL(fileURLWithPath: CommandLine.arguments[2]))
        let retainedGeometry = coordinator.paneLayouts.trees.count
        let endpointFile = root.appendingPathComponent("local-endpoint.json")
        let withheldEndpoint = root.appendingPathComponent("withheld-endpoint.json")
        try FileManager.default.moveItem(at: endpointFile, to: withheldEndpoint)
        coordinator.refresh()
        try await wait { if case .failed = coordinator.connectionState { return true }; return false }
        precondition(coordinator.catalog == nil && process.isRunning, "Endpoint loss fences presentation, not daemon lifecycle")
        precondition(coordinator.paneLayouts.trees.count == retainedGeometry, "Endpoint absence cannot prove leaf completion")
        try FileManager.default.moveItem(at: withheldEndpoint, to: endpointFile)
        precondition(coordinator.catalog == nil, "Restored discovery does not automatically restore authority")
        await peer.close()
        print("PASS: central native coordinator, complete graph reads, desired availability, scoped selection, endpoint fence and disconnect independence")
    }
    @MainActor private static func wait(_ predicate: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try !predicate() {
            guard ContinuousClock.now < deadline else { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private static func call(_ request: CentralRequest, _ peer: AxoJSONRPCWebSocketConnection) async throws -> CentralResponse {
        try request.parseResult(await peer.request(method: request.method, parameters: request.parameters))
    }
    private enum Failure: Error { case deadline }
}
