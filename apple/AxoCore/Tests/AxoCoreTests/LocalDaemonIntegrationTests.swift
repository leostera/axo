import AxoProtocol
import Darwin
import Foundation
import XCTest
import AxoCore

#if os(macOS)
final class LocalDaemonIntegrationTests: XCTestCase {
    func testLocalDaemonDiscoveryDisconnectAndRestartDoNotReplayFixture() async throws {
        guard let executable = ProcessInfo.processInfo.environment["AXO_LOCAL_DAEMON_BINARY"],
              FileManager.default.isExecutableFile(atPath: executable) else {
            throw XCTSkip("Set AXO_LOCAL_DAEMON_BINARY to a built axod executable to run this isolated integration test.")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("axo-local-daemon-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let profileDirectory = root.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let profilesURL = root.appendingPathComponent("profiles-config.json")
        let profiles = FixtureProfiles(profiles: [
            "approved-fixture": FixtureProfile(directory: profileDirectory.path,
                                                argv: ["/usr/bin/printf", "isolated fixture completed\\n"])
        ])
        try writePrivate(JSONEncoder().encode(profiles), to: profilesURL)

        let daemon = try startDaemon(executable: executable, stateDirectory: root, profiles: profilesURL)
        defer { stopOwned(daemon) }
        let firstEndpoint = try await waitForEndpoint(in: root)

        // A second bootstrap is allowed to fail on the daemon's owner lock; it must not
        // replace discovery or disturb the process that owns this private state directory.
        let duplicate = try startDaemon(executable: executable, stateDirectory: root, profiles: profilesURL)
        let duplicateDeadline = Date().addingTimeInterval(3)
        while duplicate.isRunning && Date() < duplicateDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        if duplicate.isRunning {
            stopOwned(duplicate)
            XCTFail("A duplicate daemon did not fail its owner-lock check promptly.")
        } else {
            duplicate.waitUntilExit()
            XCTAssertNotEqual(duplicate.terminationStatus, 0)
        }
        XCTAssertTrue(daemon.isRunning)
        XCTAssertEqual(try readEndpoint(in: root), firstEndpoint)

        let target = TerminalTarget(machineId: firstEndpoint.machineId,
                                    hostGeneration: firstEndpoint.hostGeneration,
                                    sessionId: UUID(), paneId: UUID())
        let commandID = UUID()
        let firstConnection = try AxoJSONRPCClient().openLocalWebSocket(endpoint: firstEndpoint)
        let negotiation = try await firstConnection.request(
            method: AxoProtocol.Method.negotiate,
            parameters: NegotiationParameters()
        )
        XCTAssertEqual(try AxoProtocolResultValidator.localNegotiation(negotiation).protocolVersion,
                       AxoProtocol.version)

        let before = try await firstConnection.request(
            method: AxoProtocol.Method.listRuntimes,
            parameters: RuntimeListParameters(
                target: MachineTarget(machineId: firstEndpoint.machineId,
                                      hostGeneration: firstEndpoint.hostGeneration)
            )
        )
        XCTAssertTrue(try AxoProtocolResultValidator.runtimeList(
            before,
            target: MachineTarget(machineId: firstEndpoint.machineId,
                                  hostGeneration: firstEndpoint.hostGeneration)
        ).terminals.isEmpty)

        let started = try await firstConnection.request(
            method: AxoProtocol.Method.startApprovedRuntime,
            parameters: RuntimeStartParameters(target: target, commandId: commandID,
                                               profileId: "approved-fixture")
        )
        let startResult = try AxoProtocolResultValidator.runtimeStart(started, target: target)
        await firstConnection.close()
        XCTAssertTrue(daemon.isRunning, "Closing the native client must not stop daemon-owned work.")

        let reconnectedEndpoint = try readEndpoint(in: root)
        XCTAssertEqual(reconnectedEndpoint, firstEndpoint)
        let secondConnection = try AxoJSONRPCClient().openLocalWebSocket(endpoint: reconnectedEndpoint)
        defer { Task { await secondConnection.close() } }
        _ = try await secondConnection.request(
            method: AxoProtocol.Method.negotiate,
            parameters: NegotiationParameters()
        )
        let after = try await secondConnection.request(
            method: AxoProtocol.Method.listRuntimes,
            parameters: RuntimeListParameters(
                target: MachineTarget(machineId: firstEndpoint.machineId,
                                      hostGeneration: firstEndpoint.hostGeneration)
            )
        )
        let listed = try AxoProtocolResultValidator.runtimeList(
            after,
            target: MachineTarget(machineId: firstEndpoint.machineId,
                                  hostGeneration: firstEndpoint.hostGeneration)
        )
        XCTAssertTrue(listed.terminals.contains {
            $0.runtime.runtimeGeneration == startResult.terminal.runtime.runtimeGeneration
        })
        await secondConnection.close()

        stopOwned(daemon)
        let restarted = try startDaemon(executable: executable, stateDirectory: root, profiles: profilesURL)
        defer { stopOwned(restarted) }
        let newEndpoint = try await waitForEndpoint(in: root)
        XCTAssertEqual(newEndpoint.machineId, firstEndpoint.machineId)
        XCTAssertNotEqual(newEndpoint.hostGeneration, firstEndpoint.hostGeneration)

        let recoveryConnection = try AxoJSONRPCClient().openLocalWebSocket(endpoint: newEndpoint)
        defer { Task { await recoveryConnection.close() } }
        _ = try await recoveryConnection.request(
            method: AxoProtocol.Method.negotiate,
            parameters: NegotiationParameters()
        )
        let recoveredValue = try await recoveryConnection.request(
            method: AxoProtocol.Method.listRuntimes,
            parameters: RuntimeListParameters(
                target: MachineTarget(machineId: newEndpoint.machineId,
                                      hostGeneration: newEndpoint.hostGeneration)
            )
        )
        let recovered = try AxoProtocolResultValidator.runtimeList(
            recoveredValue,
            target: MachineTarget(machineId: newEndpoint.machineId,
                                  hostGeneration: newEndpoint.hostGeneration)
        )
        XCTAssertEqual(recovered.terminals.count, 1, "Restart recovery lists the receipt; it does not launch it again.")
        XCTAssertEqual(recovered.terminals[0].runtime.runtimeGeneration,
                       startResult.terminal.runtime.runtimeGeneration)
        await recoveryConnection.close()
    }

    private func startDaemon(executable: String, stateDirectory: URL, profiles: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["serve", stateDirectory.path, "--profiles-config", profiles.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func stopOwned(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    private func waitForEndpoint(in root: URL) async throws -> LocalDaemonEndpoint {
        let deadline = Date().addingTimeInterval(8)
        let endpointURL = root.appendingPathComponent("local-endpoint.json")
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: endpointURL.path) {
                return try readEndpoint(in: root)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw XCTSkip("axod did not publish local discovery before the test deadline.")
    }

    private func readEndpoint(in root: URL) throws -> LocalDaemonEndpoint {
        let url = root.appendingPathComponent("local-endpoint.json")
        let data = try readPrivate(url, limit: 4096)
        return try JSONDecoder().decode(LocalDaemonEndpoint.self, from: data)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard count == data.count, fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }

    private func readPrivate(_ url: URL, limit: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o600,
              info.st_nlink == 1,
              info.st_size <= limit else { throw DaemonFixtureError.unsafeFile }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: limit)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count >= 0, count <= limit else { throw DaemonFixtureError.unsafeFile }
        data.append(contentsOf: buffer[..<count])
        return data
    }
}

private struct FixtureProfiles: Encodable { let profiles: [String: FixtureProfile] }
private struct FixtureProfile: Encodable { let directory: String; let argv: [String] }
private enum DaemonFixtureError: Error { case unsafeFile }
#endif
