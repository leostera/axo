import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Reads only bounded metadata windows, never hydrates the conversation or follows a symlink.
public struct PiSessionTitle: Equatable, Sendable {
    public let conversationID: String
    public let name: String

    public static func read(from path: String) -> PiSessionTitle? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        do {
            let headerData = try file.read(upToCount: 4_096) ?? Data()
            guard let headerLine = headerData.split(separator: 10).first,
                  let header = try JSONSerialization.jsonObject(with: Data(headerLine)) as? [String: Any],
                  header["type"] as? String == "session", let id = header["id"] as? String,
                  !id.isEmpty, id.utf8.count <= 128 else { return nil }
            let offset = max(0, info.st_size - 65_536)
            var startsAtBoundary = true
            if offset > 0 {
                try file.seek(toOffset: UInt64(offset - 1))
                startsAtBoundary = try file.read(upToCount: 1) == Data([10])
            }
            try file.seek(toOffset: UInt64(offset))
            let tail = try file.read(upToCount: 65_536) ?? Data()
            var lines = tail.split(separator: 10, omittingEmptySubsequences: false)
            if !startsAtBoundary, !lines.isEmpty { lines.removeFirst() }
            // The last component is either empty or an incomplete, uncommitted record.
            if !lines.isEmpty { lines.removeLast() }
            for line in lines.reversed() {
                guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      entry["type"] as? String == "session_info", let name = entry["name"] as? String,
                      (try? WorkspaceStore.validName(name)) == name else { continue }
                return PiSessionTitle(conversationID: id, name: name)
            }
        } catch { return nil }
        return nil
    }
}
