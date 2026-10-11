import Darwin
import Foundation

/// Pinned owner-only draft storage. A checkpoint carries exact original bytes;
/// another process's commit is a conflict, never permission to overwrite it.
/// This storage primitive does not load editors or dispatch/reconcile commands.
final class AxodChatDraftStore {
    enum Failure: Error, Equatable { case unsafeStorage, invalidArchive, writerBusy, conflict, io, fenced }
    struct Checkpoint {
        let archive: AxodChatDraftArchive?
        fileprivate let storeID: UUID
        fileprivate let bytes: Data?
    }
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        init(_ metadata: stat) { device = metadata.st_dev; inode = metadata.st_ino }
    }
    private let root: URL
    private let directory: Int32
    private let identity: Identity
    private let storeID = UUID()
    private var fenced = false
    private static let archiveName = "drafts.bin"
    private static let lockName = "drafts.lock"

    #if AXO_DRAFT_STORE_FIXTURE
    enum FixtureFault { case beforeRename, afterRename }
    var fixtureFault: FixtureFault?
    #endif

    init(root: URL) throws {
        guard root.isFileURL, root.host == nil || root.host == "", root.query == nil, root.fragment == nil,
              root.path.hasPrefix("/") else { throw Failure.unsafeStorage }
        let fd = try Self.openDirectory(root)
        do {
            let metadata = try Self.directoryMetadata(fd)
            self.root = root; self.directory = fd; self.identity = Identity(metadata)
        } catch { close(fd); throw error }
    }
    deinit { close(directory) }

    func load() throws -> Checkpoint {
        let lock = try acquire()
        defer { _ = flock(lock, LOCK_UN); close(lock) }
        let checkpoint = try read()
        try validateRoot(); try validateLock(lock)
        return checkpoint
    }

    func commit(_ archive: AxodChatDraftArchive, replacing original: Checkpoint) throws -> Checkpoint {
        guard !fenced else { throw Failure.fenced }
        guard original.storeID == storeID, archive.revision != original.archive?.revision else { throw Failure.conflict }
        let lock = try acquire()
        defer { _ = flock(lock, LOCK_UN); close(lock) }
        let current = try read()
        guard current.bytes == original.bytes else { throw Failure.conflict }
        let bytes = archive.encoded
        guard bytes.count <= AxodChatDraftArchive.maximumEncodedBytes else { throw Failure.invalidArchive }
        let name = ".draft-\(UUID().uuidString).tmp"
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { fenced = true; throw Failure.io }
        var created: Identity?
        var renamed = false
        defer {
            // Only this call's still-open, not-yet-committed creation descriptor
            // grants cleanup. Never reclaim a file after archive ownership begins.
            if !renamed, let created, let path = try? Self.fileMetadata(at: name, directory: directory), Identity(path) == created {
                _ = unlinkat(directory, name, 0)
            }
            close(fd)
        }
        do {
            created = Identity(try Self.fileMetadata(fd))
            try Self.write(bytes, to: fd)
            try Self.flush(fd)
            try validateRoot()
            try validateLock(lock)
            guard try read().bytes == original.bytes else { throw Failure.conflict }
            let stage = try Self.fileMetadata(fd), path = try Self.fileMetadata(at: name, directory: directory)
            guard Identity(stage) == created, Identity(path) == created else { throw Failure.unsafeStorage }
            #if AXO_DRAFT_STORE_FIXTURE
            if fixtureFault == .beforeRename { throw Failure.io }
            #endif
            guard renameat(directory, name, directory, Self.archiveName) == 0 else { throw Failure.io }
            renamed = true
            #if AXO_DRAFT_STORE_FIXTURE
            if fixtureFault == .afterRename { throw Failure.io }
            #endif
            try Self.flush(directory)
            try validateRoot()
            try validateLock(lock)
            return Checkpoint(archive: archive, storeID: storeID, bytes: bytes)
        } catch {
            // Even an uncertain post-rename/flush result grants no retry. The
            // original/replacement file is preserved for explicit recovery.
            if (error as? Failure) != .conflict { fenced = true }
            throw error
        }
    }

    private func read() throws -> Checkpoint {
        try validateRoot()
        let fd = openat(directory, Self.archiveName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            guard errno == ENOENT else { throw Failure.unsafeStorage }
            return Checkpoint(archive: nil, storeID: storeID, bytes: nil)
        }
        defer { close(fd) }
        let before = try Self.fileMetadata(fd)
        guard before.st_size >= 0, before.st_size <= AxodChatDraftArchive.maximumEncodedBytes else { throw Failure.invalidArchive }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let size = Darwin.read(fd, &buffer, buffer.count)
            if size < 0 && errno == EINTR { continue }
            guard size >= 0 else { throw Failure.io }
            if size == 0 { break }
            guard data.count + size <= AxodChatDraftArchive.maximumEncodedBytes else { throw Failure.invalidArchive }
            data.append(contentsOf: buffer.prefix(size))
        }
        let after = try Self.fileMetadata(fd), path = try Self.fileMetadata(at: Self.archiveName, directory: directory)
        guard Identity(before) == Identity(after), Identity(after) == Identity(path),
              before.st_size == after.st_size, data.count == after.st_size else { throw Failure.conflict }
        let archive: AxodChatDraftArchive
        do { archive = try AxodChatDraftArchive.parse(data) } catch { throw Failure.invalidArchive }
        return Checkpoint(archive: archive, storeID: storeID, bytes: data)
    }

    private func acquire() throws -> Int32 {
        try validateRoot()
        let fd = openat(directory, Self.lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw Failure.unsafeStorage }
        do {
            _ = try Self.fileMetadata(fd)
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN { throw Failure.writerBusy }
                throw Failure.io
            }
            try validateLock(fd)
            return fd
        } catch { _ = flock(fd, LOCK_UN); close(fd); throw error }
    }
    private func validateLock(_ fd: Int32) throws {
        let held = try Self.fileMetadata(fd), path = try Self.fileMetadata(at: Self.lockName, directory: directory)
        guard held.st_size == 0, path.st_size == 0, Identity(held) == Identity(path) else { throw Failure.unsafeStorage }
    }
    private func validateRoot() throws {
        let held = try Self.directoryMetadata(directory)
        let reopened = try Self.openDirectory(root)
        defer { close(reopened) }
        let path = try Self.directoryMetadata(reopened)
        guard Identity(held) == identity, Identity(path) == identity else { throw Failure.unsafeStorage }
    }
    /// Only the captured local app namespace may provision this fixed child.
    /// Existing roots are checked, never chmodded/replaced to make them usable.
    static func provision(in parent: URL) throws -> URL {
        guard parent.isFileURL, parent.host == nil || parent.host == "", parent.path.hasPrefix("/") else { throw Failure.unsafeStorage }
        let fd = try openDirectory(parent)
        defer { close(fd) }
        _ = try directoryMetadata(fd)
        let created = mkdirat(fd, "chat-drafts", 0o700) == 0
        if !created && errno != EEXIST { throw Failure.io }
        let root = parent.appendingPathComponent("chat-drafts", isDirectory: true)
        let child = try openDirectory(root)
        defer { close(child) }
        _ = try directoryMetadata(child)
        if created { try flush(fd) }
        return root
    }

    private static func openDirectory(_ root: URL) throws -> Int32 {
        // Walk from /: O_NOFOLLOW on only the final component is insufficient.
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unsafeStorage }
        for component in root.path.split(separator: "/") {
            guard component != ".", component != ".." else { close(fd); throw Failure.unsafeStorage }
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            close(fd)
            guard next >= 0 else { throw Failure.unsafeStorage }
            fd = next
        }
        return fd
    }
    private static func directoryMetadata(_ fd: Int32) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
              value.st_uid == geteuid(), value.st_mode & 0o077 == 0 else { throw Failure.unsafeStorage }
        return value
    }
    private static func fileMetadata(_ fd: Int32) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0, safe(value) else { throw Failure.unsafeStorage }
        return value
    }
    private static func fileMetadata(at name: String, directory: Int32) throws -> stat {
        var value = stat()
        guard fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW) == 0, safe(value) else { throw Failure.unsafeStorage }
        return value
    }
    private static func safe(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFREG && value.st_uid == geteuid() && value.st_nlink == 1 && value.st_mode & 0o777 == 0o600
    }
    private static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let size = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if size < 0 && errno == EINTR { continue }
                guard size > 0 else { throw Failure.io }
                offset += size
            }
        }
    }
    private static func flush(_ fd: Int32) throws {
        while fsync(fd) != 0 {
            guard errno == EINTR else { throw Failure.io }
        }
    }
}
