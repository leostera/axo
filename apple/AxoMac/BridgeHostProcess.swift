import Foundation

/// Owns the one relay-facing broker process for this Mac app. Pi runtimes connect only over its private socket.
final class BridgeHostProcess {
    var onRequest: (([String: Any]) -> Void)?

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var outputBuffer = Data()
    private let writeLock = NSLock()

    init(repository: String, config: URL, registry: URL, socket: URL, bindings: URL) throws {
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        guard let node = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw BridgeHostFault.nodeUnavailable
        }
        let script = URL(fileURLWithPath: repository).appendingPathComponent("bridge/dist/host-broker.mjs")
        guard FileManager.default.isReadableFile(atPath: script.path), FileManager.default.isReadableFile(atPath: config.path) else {
            throw BridgeHostFault.bridgeBuildUnavailable
        }
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [script.path, "--config", config.path, "--registry", registry.path,
                             "--socket", socket.path, "--bindings", bindings.path]
        process.currentDirectoryURL = URL(fileURLWithPath: repository)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(data) }
        }
    }

    func start() throws {
        guard !process.isRunning else { return }
        try process.run()
    }

    func reply(_ frame: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(frame),
              let body = try? JSONSerialization.data(withJSONObject: ["type": "mac_reply", "frame": frame]),
              body.count <= 256 * 1024 else { return }
        writeLock.lock(); defer { writeLock.unlock() }
        guard process.isRunning else { return }
        input.fileHandleForWriting.write(body + Data([0x0a]))
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        guard outputBuffer.count <= 512 * 1024 else { outputBuffer.removeAll(); return }
        while let newline = outputBuffer.firstIndex(of: 0x0a) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard line.count <= 256 * 1024,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if object["type"] as? String == "mac_command", let frame = object["frame"] as? [String: Any] {
                onRequest?(frame)
            }
        }
    }
}

enum BridgeHostFault: LocalizedError {
    case nodeUnavailable, bridgeBuildUnavailable
    var errorDescription: String? {
        switch self {
        case .nodeUnavailable: "Node.js is required to run the local Axo bridge. Install Node.js, then relaunch Axo."
        case .bridgeBuildUnavailable: "The Axo bridge has not been built. Run scripts/build-bridge.mjs, then relaunch Axo."
        }
    }
}
