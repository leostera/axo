import AxoProtocol
import Foundation
import XCTest
@testable import AxoCore

#if os(macOS)
import Darwin

final class CentralDaemonIntegrationTests: XCTestCase {
    func testActualCentralRPCPublishesCompleteGraphsWithoutClientStartsAndPreservesOriginalsOnRestart() async throws {
        guard let executable = ProcessInfo.processInfo.environment["AXO_CENTRAL_FIXTURE_BINARY"], FileManager.default.isExecutableFile(atPath: executable) else {
            throw XCTSkip("Set AXO_CENTRAL_FIXTURE_BINARY to the disposable central-client-fixture executable.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axo-central-client-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let daemon = try launch(executable, root: root)
        defer { stopOwned(daemon) }
        let endpoint = try await waitForEndpoint(root, process: daemon)
        let connection = try AxoJSONRPCClient().openLocalWebSocket(endpoint: endpoint)
        _ = try AxoProtocolResultValidator.localNegotiation(await connection.request(method: AxoProtocol.Method.negotiate, parameters: NegotiationParameters()))
        let machine = MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration)
        let bootstrap = try CentralRequest.bootstrap(machine: machine)
        let initial = try await Self.call(bootstrap, connection)
        XCTAssertEqual(initial.revision.rawValue, 0)
        let source = initial.source
        let homeCommand = UUID(), workspaceCommand = UUID()
        let home = try await Self.call(CentralRequest.createSession(source: source, workspaceId: nil, commandId: homeCommand, expectedRevision: initial.revision), connection)
        guard case .operation(.createStandalone(let homeOriginal)?, _) = home.payload else { return XCTFail("Complete home graph") }
        XCTAssertEqual(homeOriginal.graph.panes.count, 2)
        let workspace = try await Self.call(CentralRequest.createWorkspace(source: source, commandId: workspaceCommand, expectedRevision: home.revision, name: "Workspace", directoryPath: root.path), connection)
        guard case .operation(.createWorkspace(let workspaceOriginal)?, _) = workspace.payload else { return XCTFail("Complete workspace graph") }
        XCTAssertEqual(workspaceOriginal.graph.initialSession.panes.count, 2)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var catalog = try await load(source, connection)
        while catalog.terminals.count != 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            catalog = try await load(source, connection)
        }
        XCTAssertEqual(catalog.workspaces.count, 1)
        XCTAssertEqual(catalog.sessions.count, 2)
        XCTAssertEqual(catalog.terminals.count, 2, "Both account shells materialize without any runtime/Pi start RPC.")
        XCTAssertTrue(catalog.sessions.allSatisfy { $0.readiness != .ready }, "No Pi policy means no fabricated backend readiness.")
        for view in catalog.sessions {
            let observation = try await Self.call(CentralRequest.observePi(source: source, workspaceId: view.session.workspaceId, sessionId: view.session.sessionId), connection)
            XCTAssertEqual(observation.payload, .piObservation(.notAdmitted))
        }
        let original = try await Self.call(CentralRequest.operation(source: source, commandId: workspaceCommand), connection)
        guard case .operation(.createWorkspace(let unchanged)?, _) = original.payload else { return XCTFail("Original receipt") }
        XCTAssertEqual(unchanged, workspaceOriginal)
        await connection.close()
        XCTAssertTrue(daemon.isRunning, "Disconnect is not runtime intent.")
        stopOwned(daemon)
        let restarted = try launch(executable, root: root)
        defer { stopOwned(restarted) }
        let next = try await waitForEndpoint(root, process: restarted, previousGeneration: endpoint.hostGeneration)
        XCTAssertEqual(next.machineId, endpoint.machineId)
        XCTAssertNotEqual(next.hostGeneration, endpoint.hostGeneration)
        let reconnected = try AxoJSONRPCClient().openLocalWebSocket(endpoint: next)
        _ = try AxoProtocolResultValidator.localNegotiation(await reconnected.request(method: AxoProtocol.Method.negotiate, parameters: NegotiationParameters()))
        let newBootstrap = try await Self.call(CentralRequest.bootstrap(machine: .init(machineId: next.machineId, hostGeneration: next.hostGeneration)), reconnected)
        XCTAssertEqual(newBootstrap.source.storeGeneration, source.storeGeneration)
        let restored = try await load(newBootstrap.source, reconnected)
        XCTAssertEqual(Set(restored.sessions.map { $0.session.sessionId }), Set(catalog.sessions.map { $0.session.sessionId }))
        let receipt = try await Self.call(CentralRequest.operation(source: newBootstrap.source, commandId: workspaceCommand), reconnected)
        guard case .operation(.createWorkspace(let retained)?, _) = receipt.payload else { return XCTFail("Retained immutable original") }
        XCTAssertEqual(retained, workspaceOriginal)
        await reconnected.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("work-records.json").path))
    }
    private struct FixtureCallFailure: Error {
        let method: String
        let domain: String
        let code: Int
    }
    private static func call(_ request: CentralRequest, _ connection: AxoJSONRPCWebSocketConnection) async throws -> CentralResponse {
        do {
            let value = try await connection.request(method: request.method, parameters: request.parameters)
            return try request.parseResult(value)
        } catch {
            // Preserve phase/cause without retaining parameters or reply bodies.
            let failure = error as NSError
            throw FixtureCallFailure(method: request.method, domain: failure.domain, code: failure.code)
        }
    }
    private func load(_ source: CentralSource, _ connection: AxoJSONRPCWebSocketConnection) async throws -> CentralCatalog {
        try await CentralCatalogLoader.load(source: source) { request in
            try await Self.call(request, connection)
        }
    }
    private func launch(_ executable: String, root: URL) throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable); child.arguments = [root.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.path
        child.environment = environment
        child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.standardError
        try child.run(); return child
    }
    private func stopOwned(_ child: Process) {
        guard child.isRunning else { return }
        child.terminate()
        let deadline = Date().addingTimeInterval(5)
        while child.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
        child.waitUntilExit()
    }
    private func waitForEndpoint(_ root: URL, process: Process, previousGeneration: UUID? = nil) async throws -> LocalDaemonEndpoint {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            guard process.isRunning else { throw AxoJSONRPCClientError.disconnected }
            if let endpoint = try? readEndpoint(root), endpoint.hostGeneration != previousGeneration { return endpoint }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AxoJSONRPCClientError.disconnected
    }
    private func readEndpoint(_ root: URL) throws -> LocalDaemonEndpoint {
        let fd = Darwin.open(root.appendingPathComponent("local-endpoint.json").path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(.ENOENT) }
        defer { _ = Darwin.close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o777 == 0o600,
              metadata.st_nlink == 1, metadata.st_uid == geteuid(), (1...4096).contains(metadata.st_size) else { throw POSIXError(.EINVAL) }
        var bytes = [UInt8](repeating: 0, count: 4097)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count > 0, count <= 4096 else { throw POSIXError(.EINVAL) }
        return try JSONDecoder().decode(LocalDaemonEndpoint.self, from: Data(bytes.prefix(count)))
    }
}
#endif
