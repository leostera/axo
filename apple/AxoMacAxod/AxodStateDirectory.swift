import AxoProtocol
import Darwin
import Foundation

struct AxodStateDirectory {
    let root: URL
    private let endpointFile: URL

    static func prepare(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "") throws -> AxodStateDirectory {
        let instanceID = try instanceID(for: bundleIdentifier)
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appRoot = support.appendingPathComponent("Axo", isDirectory: true)
        try createPrivateDirectoryIfNeeded(appRoot)
        try requireOwnedDirectory(appRoot, privatePermissions: true)

        let stateParent: URL
        if let instanceID {
            let instances = appRoot.appendingPathComponent("Instances", isDirectory: true)
            try createPrivateDirectoryIfNeeded(instances)
            try requireOwnedDirectory(instances, privatePermissions: true)
            stateParent = instances.appendingPathComponent(instanceID, isDirectory: true)
            try createPrivateDirectoryIfNeeded(stateParent)
            try requireOwnedDirectory(stateParent, privatePermissions: true)
        } else {
            stateParent = appRoot
        }

        let root = stateParent.appendingPathComponent("Axod", isDirectory: true)
        try createPrivateDirectoryIfNeeded(root)
        try requireOwnedDirectory(root, privatePermissions: true)
        return AxodStateDirectory(
            root: root,
            endpointFile: root.appendingPathComponent("local-endpoint.json")
        )
    }

#if AXO_NATIVE_FIXTURE
    /// The fixture already owns the selected root; never creates or imports state.
    static func openExisting(root: URL) throws -> AxodStateDirectory {
        try requireOwnedDirectory(root, privatePermissions: true)
        return AxodStateDirectory(root: root, endpointFile: root.appendingPathComponent("local-endpoint.json"))
    }
#endif

    static func instanceID(for bundleIdentifier: String) throws -> String? {
        let base = "dev.leostera.axo.mac"
        if bundleIdentifier == base { return nil }
        let prefix = base + "."
        guard bundleIdentifier.hasPrefix(prefix) else {
            throw AxodStateDirectoryError.invalidBundleIdentifier
        }
        let value = String(bundleIdentifier.dropFirst(prefix.count))
        let valid = !value.isEmpty && value.utf8.count <= 32 &&
            value.split(separator: "-", omittingEmptySubsequences: false).allSatisfy { part in
                !part.isEmpty && part.utf8.allSatisfy { byte in
                    (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 122)
                }
            }
        guard valid else { throw AxodStateDirectoryError.invalidBundleIdentifier }
        return value
    }

    private static func createPrivateDirectoryIfNeeded(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private static func requireOwnedDirectory(_ url: URL, privatePermissions: Bool) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              !privatePermissions || metadata.st_mode & 0o077 == 0 else {
            throw AxodStateDirectoryError.unsafeDirectory
        }
    }

    func requireCurrentEndpoint(_ expected: LocalDaemonEndpoint) throws {
        guard try readEndpoint() == expected else {
            throw AxodStateDirectoryError.endpointChanged
        }
    }

    func readEndpoint() throws -> LocalDaemonEndpoint? {
        let descriptor = open(endpointFile.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw AxodStateDirectoryError.unsafeDiscovery
        }
        defer { _ = close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o777 == 0o600,
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              metadata.st_size <= 4096 else {
            throw AxodStateDirectoryError.unsafeDiscovery
        }

        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0, data.count + count <= 4096 else {
                throw AxodStateDirectoryError.unsafeDiscovery
            }
            data.append(contentsOf: buffer[..<count])
        }
        do { return try JSONDecoder().decode(LocalDaemonEndpoint.self, from: data) }
        catch { throw AxodStateDirectoryError.unsafeDiscovery }
    }
}

enum AxodStateDirectoryError: Error, LocalizedError {
    case unsafeDirectory
    case unsafeDiscovery
    case endpointChanged
    case invalidBundleIdentifier

    var errorDescription: String? {
        switch self {
        case .unsafeDirectory: "Axo's private daemon state directory failed its ownership or permission checks."
        case .unsafeDiscovery: "The private daemon discovery file is malformed or unsafe. It was left untouched."
        case .endpointChanged: "The daemon restarted while Axo was reading it. Reconnect before continuing."
        case .invalidBundleIdentifier: "This Axo bundle has an unsupported bundle identifier. Rebuild the standard Axo.app package."
        }
    }
}
