import Foundation

public struct SharedFile: Codable, Identifiable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case pending, ready, deleting, deleted }
    public enum Origin: String, Codable, Sendable { case host, phone }
    public enum MediaType: String, Codable, Sendable {
        case png = "image/png", jpeg = "image/jpeg", pdf = "application/pdf"
        case text = "text/plain", markdown = "text/markdown", binary = "application/octet-stream"

        public var isImage: Bool { self == .png || self == .jpeg }
        var fileExtension: String {
            switch self { case .png: "png"; case .jpeg: "jpg"; case .pdf: "pdf"; case .text: "txt"; case .markdown: "md"; case .binary: "bin" }
        }
        static func forFilename(_ filename: String) -> Self {
            switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
            case "png": .png; case "jpg", "jpeg": .jpeg; case "pdf": .pdf; case "txt": .text; case "md": .markdown; default: .binary
            }
        }
    }
    public let id: String
    public let sessionId: String
    public let filename: String
    public let mediaType: MediaType
    public let byteLength: Int
    public let sha256: String
    public let origin: Origin
    public let createdAt: Int64
    public let state: State

    private enum CodingKeys: String, CodingKey { case id, sessionId, filename, mediaType, byteLength, sha256, origin, createdAt, state }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        sessionId = try values.decode(String.self, forKey: .sessionId)
        filename = try values.decode(String.self, forKey: .filename)
        mediaType = try values.decode(MediaType.self, forKey: .mediaType)
        byteLength = try values.decode(Int.self, forKey: .byteLength)
        sha256 = try values.decode(String.self, forKey: .sha256)
        origin = try values.decode(Origin.self, forKey: .origin)
        createdAt = try values.decode(Int64.self, forKey: .createdAt)
        state = try values.decode(State.self, forKey: .state)
        try validate()
    }
    public func validate() throws {
        guard UUID(uuidString: id) != nil, byteLength >= 0, byteLength <= 25 * 1024 * 1024, createdAt >= 0,
              !filename.isEmpty, ![".", ".."].contains(filename), filename.utf16.count <= 255,
              filename.rangeOfCharacter(from: .controlCharacters) == nil, !filename.contains("/"), !filename.contains("\\"),
              sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              sessionId.range(of: "^[a-zA-Z0-9_.:-]{1,128}$", options: .regularExpression) != nil else {
            throw FileTransferError.message("Invalid file metadata from relay.")
        }
    }
}

public struct FilePage: Decodable, Sendable {
    public let files: [SharedFile]
    public let nextCursor: String?
    public let revision: Int
    private enum CodingKeys: String, CodingKey { case files, nextCursor, revision }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        files = try values.decode([SharedFile].self, forKey: .files)
        nextCursor = try values.decodeIfPresent(String.self, forKey: .nextCursor)
        revision = try values.decode(Int.self, forKey: .revision)
        guard files.count <= 20, Set(files.map(\.id)).count == files.count, revision >= 0,
              nextCursor.map({ $0.range(of: "^[1-9][0-9]{0,15}$", options: .regularExpression) != nil }) ?? true else {
            throw FileTransferError.message("Invalid file page from relay.")
        }
    }
}

public enum DraftTransfer: Codable, Equatable, Sendable {
    case staged
    case queued
    case uploading(progress: Double, reservation: SharedFile?)
    case ready(SharedFile)
    case failed(message: String, reservation: SharedFile?)
}

public struct DraftFile: Codable, Identifiable, Sendable {
    public let id: UUID
    public let sessionId: String
    public let filename: String
    public internal(set) var source: URL
    public internal(set) var transfer: DraftTransfer = .staged
    public var file: SharedFile? {
        switch transfer { case .ready(let file): file; case .uploading(_, let file), .failed(_, let file): file; default: nil }
    }
    public var readyFile: SharedFile? { if case .ready(let file) = transfer { return file }; return nil }
    public var isUploading: Bool { switch transfer { case .queued, .uploading: true; default: false } }
    public var isQueued: Bool { if case .queued = transfer { return true }; return false }
    public var progress: Double { switch transfer { case .ready: 1; case .uploading(let progress, _): progress; default: 0 } }
    public var error: String? { if case .failed(let message, _) = transfer { return message }; return nil }

    init(id: UUID, sessionId: String, filename: String, source: URL) {
        self.id = id; self.sessionId = sessionId; self.filename = filename; self.source = source
    }
    mutating func fail(_ message: String) { transfer = .failed(message: message, reservation: file) }
    mutating func reportProgress(_ fraction: Double) {
        guard case .uploading(_, let reservation) = transfer else { return }
        transfer = .uploading(progress: min(1, max(0, fraction)), reservation: reservation)
    }
    private enum CodingKeys: String, CodingKey { case id, sessionId, filename, source, transfer }
    private enum LegacyKeys: String, CodingKey { case file, progress, isUploading, error }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        sessionId = try values.decode(String.self, forKey: .sessionId)
        filename = try values.decode(String.self, forKey: .filename)
        source = try values.decode(URL.self, forKey: .source)
        if values.contains(.transfer) {
            transfer = try values.decode(DraftTransfer.self, forKey: .transfer)
            try validateTransfer()
            return
        }
        // Local storage migration preserves selections made by the initial prototype.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let file = try legacy.decodeIfPresent(SharedFile.self, forKey: .file)
        if try legacy.decodeIfPresent(Bool.self, forKey: .isUploading) == true {
            transfer = .uploading(progress: try legacy.decodeIfPresent(Double.self, forKey: .progress) ?? 0, reservation: file)
        } else if let error = try legacy.decodeIfPresent(String.self, forKey: .error) {
            transfer = .failed(message: error, reservation: file)
        } else if let file, file.state == .ready { transfer = .ready(file) }
        try validateTransfer()
    }
    private func validateTransfer() throws {
        guard source.isFileURL, sessionId.range(of: "^[a-zA-Z0-9_.:-]{1,128}$", options: .regularExpression) != nil,
              file.map({ $0.sessionId == sessionId }) ?? true else { throw FileTransferError.message("Invalid saved attachment destination.") }
        if case .ready(let file) = transfer, file.state != .ready { throw FileTransferError.message("Saved attachment was not ready.") }
        if case .uploading(let fraction, _) = transfer, !fraction.isFinite || !(0...1).contains(fraction) {
            throw FileTransferError.message("Invalid saved upload progress.")
        }
    }
}

public enum FileTransferError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
