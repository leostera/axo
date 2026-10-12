import Darwin
import Foundation

/// One original registration request. An ambiguous SDK result stays pending;
/// subsequent launches may observe it but cannot dispatch another registration.
struct AxodAgentRegistrationRequest {
    enum Failure: Error { case unresolved, unsafeStorage }
    private struct Intent: Encodable {
        let version = 1
        let operationID: UUID
        let serviceLabel = "dev.leostera.axo.axod"
        let appBundleIdentifier = Bundle.main.bundleIdentifier
        let appBundleURL = Bundle.main.bundleURL
        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        let rootDevice: UInt64
        let rootInode: UInt64
    }
    private let root: URL
    private let device: dev_t
    private let inode: ino_t
    private let operationID: UUID
    private let pendingDevice: dev_t
    private let pendingInode: ino_t
    private let originalBytes: Data
    private static let pending = "agent-registration.pending.json"

    static func hasReceipt(in root: URL) throws -> Bool {
        // Presence only refuses an automatic mutation; opaque evidence is never
        // interpreted as permission to register again after removal by the user.
        try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
            $0.hasPrefix("agent-registration.") && $0.hasSuffix(".receipt.json")
        }
    }

    static func prepare(in root: URL) throws -> Self {
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.unsafeStorage }
        defer { close(directory) }
        var attributes = stat()
        guard fstat(directory, &attributes) == 0, attributes.st_uid == geteuid(), attributes.st_mode & 0o077 == 0 else {
            throw Failure.unsafeStorage
        }
        // Do not supersede an original operator repair whose effects are unknown.
        for name in [pending, "agent-service-repair.pending.json", "agent-parent-repair.pending.json"] {
            var existing = stat()
            if fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 { throw Failure.unresolved }
            guard errno == ENOENT else { throw Failure.unsafeStorage }
        }
        let operation = UUID()
        let file = openat(directory, pending, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw errno == EEXIST ? Failure.unresolved : Failure.unsafeStorage }
        defer { close(file) }
        let bytes = try JSONEncoder().encode(Intent(operationID: operation,
            rootDevice: UInt64(UInt32(bitPattern: attributes.st_dev)), rootInode: UInt64(attributes.st_ino)))
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard count > 0 else { throw Failure.unsafeStorage }
                offset += count
            }
        }
        var created = stat()
        guard fsync(file) == 0, fsync(directory) == 0, fstat(file, &created) == 0 else { throw Failure.unsafeStorage }
        return Self(root: root, device: attributes.st_dev, inode: attributes.st_ino, operationID: operation,
            pendingDevice: created.st_dev, pendingInode: created.st_ino, originalBytes: bytes)
    }

    func confirmRegistration() throws {
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.unsafeStorage }
        defer { close(directory) }
        var attributes = stat()
        guard fstat(directory, &attributes) == 0, attributes.st_dev == device, attributes.st_ino == inode,
              attributes.st_uid == geteuid(), attributes.st_mode & 0o077 == 0 else { throw Failure.unsafeStorage }
        let file = openat(directory, Self.pending, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw Failure.unsafeStorage }
        defer { close(file) }
        var current = stat()
        guard fstat(file, &current) == 0, current.st_dev == pendingDevice, current.st_ino == pendingInode,
              current.st_uid == geteuid(), current.st_nlink == 1, current.st_mode & S_IFMT == S_IFREG,
              current.st_mode & 0o777 == 0o600, current.st_size == off_t(originalBytes.count),
              try FileHandle(fileDescriptor: file, closeOnDealloc: false).read(upToCount: 4097) == originalBytes else {
            throw Failure.unsafeStorage
        }
        var named = stat()
        guard fstatat(directory, Self.pending, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == current.st_dev, named.st_ino == current.st_ino else { throw Failure.unsafeStorage }
        let receipt = "agent-registration.\(operationID.uuidString).receipt.json"
        guard renameatx_np(directory, Self.pending, directory, receipt, UInt32(RENAME_EXCL)) == 0,
              fsync(directory) == 0 else { throw Failure.unsafeStorage }
    }
}
