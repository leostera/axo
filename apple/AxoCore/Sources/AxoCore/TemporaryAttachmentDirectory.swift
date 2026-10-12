import Darwin
import Foundation

/// Owns only one fresh 0700 temporary directory. There is no archive discovery,
/// restoration or cleanup of other clients' or retired draft-storage paths.
final class TemporaryAttachmentDirectory: Sendable {
    private let directory: URL?

    init() {
        var template = FileManager.default.temporaryDirectory.appendingPathComponent("AxoAttachments-XXXXXX").path.utf8CString
        directory = template.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress, let path = mkdtemp(base) else { return nil }
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
    }

    func requireURL() throws -> URL {
        guard let directory else { throw FileTransferError.message("Could not stage the attachment temporarily.") }
        return directory
    }

    deinit {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
}
