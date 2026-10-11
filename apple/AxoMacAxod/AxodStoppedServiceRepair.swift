import AxoCore
import AxoProtocol
import Darwin
import Foundation
import ServiceManagement

#if DEBUG
/// Explicit operator maintenance, never called by connect/reconnect. A durable
/// original ticket survives SDK ambiguity; an existing ticket refuses replay.
@MainActor enum AxodStoppedServiceRepair {
    private struct Intent: Codable {
        let operationID: UUID
        let serviceLabel: String
        let bundleIdentifier: String
        let replacementVersion: String
        let replacementBuild: String
        let rootDevice: UInt64
        let rootInode: UInt64
    }
    private struct Confirmation: Codable {
        let operationID: UUID
        let source: MachineTarget
        let daemonVersion: String
    }
    enum Failure: Error { case unsafeStorage, unresolvedOperation, liveOwner, installation, notReady }

    static func run() async throws {
        guard Bundle.main.bundleIdentifier == "dev.leostera.axo.mac",
              let version = Bundle.main.infoDictionary?["AxoBundledAxodVersion"] as? String,
              let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else { throw Failure.installation }
        let directory = try AxodStateDirectory.prepare()
        guard let absence = try AxodOwnerAbsenceLease.acquire(in: directory.root) else { throw Failure.liveOwner }
        defer { absence.release() }
        let root = open(directory.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw Failure.unsafeStorage }
        defer { close(root) }
        var rootMetadata = stat()
        guard fstat(root, &rootMetadata) == 0, rootMetadata.st_uid == geteuid(),
              rootMetadata.st_mode & 0o077 == 0 else { throw Failure.unsafeStorage }
        let intent = Intent(operationID: UUID(), serviceLabel: "dev.leostera.axo.axod",
            bundleIdentifier: "dev.leostera.axo.mac", replacementVersion: version, replacementBuild: build,
            rootDevice: UInt64(rootMetadata.st_dev), rootInode: UInt64(rootMetadata.st_ino))
        let pending = "agent-service-repair.pending.json"
        let fd = openat(root, pending, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw errno == EEXIST ? Failure.unresolvedOperation : Failure.unsafeStorage }
        defer { close(fd) }
        let bytes = try JSONEncoder().encode(intent)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard count > 0 else { throw Failure.unsafeStorage }
                offset += count
            }
        }
        guard fsync(fd) == 0, fsync(root) == 0 else { throw Failure.unsafeStorage }
        let service = SMAppService.agent(plistName: "dev.leostera.axo.axod.plist")
        // This lease proves no daemon owns the root. It does not signal or settle
        // any historical execution; original journals and recovery records remain.
        switch service.status {
        case .enabled, .notFound, .requiresApproval: try await service.unregister()
        case .notRegistered: break
        @unknown default: throw Failure.installation
        }
        try requireSameRoot(directory.root, rootMetadata)
        absence.release()
        try service.register()

        let rpc = AxoJSONRPCClient()
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            try requireSameRoot(directory.root, rootMetadata)
            if let endpoint = try directory.readEndpoint() {
                let connection = try rpc.openLocalWebSocket(endpoint: endpoint)
                do {
                    let negotiation = try await connection.request(method: AxoProtocol.Method.negotiate,
                        parameters: NegotiationParameters(), timeout: 2)
                    _ = try AxoProtocolResultValidator.localNegotiation(negotiation)
                    let target = MachineTarget(machineId: endpoint.machineId, hostGeneration: endpoint.hostGeneration)
                    let value = try await connection.request(method: AxoProtocol.Method.getHost,
                        parameters: HostGetParameters(target: target), timeout: 2)
                    let host = try AxoProtocolResultValidator.host(value, target: target)
                    try directory.requireCurrentEndpoint(endpoint)
                    guard host.daemonVersion == version, service.status == .enabled else { throw Failure.notReady }
                    await connection.close()
                    try requireSameRoot(directory.root, rootMetadata)
                    var created = stat(), current = stat()
                    guard fstat(fd, &created) == 0,
                          fstatat(root, pending, &current, AT_SYMLINK_NOFOLLOW) == 0,
                          created.st_dev == current.st_dev, created.st_ino == current.st_ino,
                          current.st_uid == geteuid(), current.st_nlink == 1,
                          current.st_mode & 0o077 == 0 else { throw Failure.unsafeStorage }
                    let confirmation = try JSONEncoder().encode(Confirmation(operationID: intent.operationID,
                        source: target, daemonVersion: host.daemonVersion))
                    let resultName = "agent-service-repair.\(intent.operationID.uuidString).confirmed.json"
                    let result = openat(root, resultName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    guard result >= 0 else { throw Failure.unsafeStorage }
                    defer { close(result) }
                    try confirmation.withUnsafeBytes { buffer in
                        var offset = 0
                        while offset < buffer.count {
                            let count = write(result, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                            guard count > 0 else { throw Failure.unsafeStorage }
                            offset += count
                        }
                    }
                    guard fsync(result) == 0, fsync(root) == 0 else { throw Failure.unsafeStorage }
                    // Retain the original immutable ticket as the reconciled
                    // receipt; never overwrite a prior receipt or discard bytes.
                    let receipt = "agent-service-repair.\(intent.operationID.uuidString).receipt.json"
                    guard renameatx_np(root, pending, root, receipt, UInt32(RENAME_EXCL)) == 0,
                          fsync(root) == 0 else { throw Failure.unsafeStorage }
                    print("PASS: stopped registration replaced through SMAppService; intended helper responds; original operation retained")
                    return
                } catch {
                    await connection.close()
                    if error is Failure { throw error }
                }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        // Do not unregister, register again, clear the ticket, or bypass approval.
        throw Failure.notReady
    }

    private static func requireSameRoot(_ url: URL, _ captured: stat) throws {
        var current = stat()
        guard lstat(url.path, &current) == 0, current.st_dev == captured.st_dev,
              current.st_ino == captured.st_ino, current.st_uid == geteuid(),
              current.st_mode & S_IFMT == S_IFDIR, current.st_mode & 0o077 == 0 else { throw Failure.unsafeStorage }
    }
}
#endif
