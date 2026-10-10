import AxoProtocol
import Darwin
import Foundation

struct AxodStateDirectory {
    let root: URL
    private let endpointFile: URL

    static func prepare() throws -> AxodStateDirectory {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appRoot = support.appendingPathComponent("Axo", isDirectory: true)
        if !FileManager.default.fileExists(atPath: appRoot.path) {
            try FileManager.default.createDirectory(
                at: appRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try requireOwnedDirectory(appRoot, privatePermissions: false)

        let root = appRoot.appendingPathComponent("Axod", isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try requireOwnedDirectory(root, privatePermissions: true)
        return AxodStateDirectory(
            root: root,
            endpointFile: root.appendingPathComponent("local-endpoint.json")
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

    var errorDescription: String? {
        switch self {
        case .unsafeDirectory: "Axo's private daemon state directory failed its ownership or permission checks."
        case .unsafeDiscovery: "The private daemon discovery file is malformed or unsafe. It was left untouched."
        case .endpointChanged: "The daemon restarted while Axo was reading it. Reconnect before continuing."
        }
    }
}
