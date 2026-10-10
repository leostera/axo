import Darwin
import Foundation

/// Kernel-backed absence of a cooperative axod owner, not a PID or stale discovery observation.
final class AxodOwnerAbsenceLease {
    enum Failure: Error, LocalizedError {
        case unsafeOwnership
        var errorDescription: String? { "The axod ownership lock failed its safety checks. Its service registration was left untouched." }
    }
    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(in root: URL) throws -> AxodOwnerAbsenceLease? {
        var directory = stat()
        guard lstat(root.path, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_uid == geteuid(), directory.st_mode & 0o077 == 0 else {
            throw Failure.unsafeOwnership
        }
        let path = root.appendingPathComponent("owner.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw Failure.unsafeOwnership }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_nlink == 1, metadata.st_mode & 0o777 == 0o600 else {
            close(fd)
            throw Failure.unsafeOwnership
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK || errno == EAGAIN
            close(fd)
            if busy { return nil }
            throw Failure.unsafeOwnership
        }
        return AxodOwnerAbsenceLease(descriptor: fd)
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
