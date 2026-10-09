import Foundation
import AxoCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct MacNotificationPresentation: Equatable {
    let title: String
    let subtitle: String
    let body: String
}

enum MacNotificationCopy {
    static let previewCharacterLimit = 180

    static func make(sessionName: String, reason: MacAttentionReason, preview: String?, includePreview: Bool) -> MacNotificationPresentation {
        let subtitle: String
        let body: String
        switch reason {
        case .question:
            subtitle = "Waiting for your input"
            body = "Open this session to respond."
        case .failure:
            subtitle = "Run failed"
            body = "The agent needs attention. Open this session to review it."
        case .result:
            subtitle = "Reply ready"
            body = includePreview ? preview ?? "The agent finished. Open this session to review the reply."
                : "The agent finished. Open this session to review the reply."
        }
        return MacNotificationPresentation(title: sessionName, subtitle: subtitle, body: body)
    }
}

enum MacNotificationPreview {
    private static let readLimit = 128 * 1_024
    static let characterLimit = MacNotificationCopy.previewCharacterLimit

    static func read(from path: String, conversationID: String) -> String? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }

        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0 else { return nil }
        do {
            guard let headerData = try file.read(upToCount: 4_096),
                  let headerLine = headerData.split(separator: 10).first,
                  let header = try JSONSerialization.jsonObject(with: Data(headerLine)) as? [String: Any],
                  header["type"] as? String == "session", header["id"] as? String == conversationID else { return nil }

            let offset = max(0, info.st_size - Int64(readLimit))
            var startsAtBoundary = true
            if offset > 0 {
                try file.seek(toOffset: UInt64(offset - 1))
                startsAtBoundary = try file.read(upToCount: 1) == Data([10])
            }
            try file.seek(toOffset: UInt64(offset))
            guard let tail = try file.read(upToCount: readLimit + 1), tail.count <= readLimit else { return nil }
            var lines = tail.split(separator: 10, omittingEmptySubsequences: false)
            if !startsAtBoundary, !lines.isEmpty { lines.removeFirst() }
            // Ignore the final line: Pi only commits newline-terminated JSONL records.
            if !lines.isEmpty { lines.removeLast() }

            for line in lines.reversed() {
                guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      entry["type"] as? String == "message",
                      let message = entry["message"] as? [String: Any],
                      message["role"] as? String == "assistant",
                      message["stopReason"] as? String == "stop",
                      let blocks = message["content"] as? [[String: Any]] else { continue }
                let text = blocks.compactMap { block -> String? in
                    guard block["type"] as? String == "text" else { return nil }
                    return block["text"] as? String
                }.joined(separator: " ")
                let preview = normalized(text)
                if !preview.isEmpty { return String(preview.prefix(characterLimit)) }
            }
        } catch { return nil }
        return nil
    }

    private static func normalized(_ text: String) -> String {
        let flattened = text.unicodeScalars.reduce(into: String()) { result, scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                result.append(" ")
            } else if !CharacterSet.controlCharacters.contains(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
        return flattened.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
