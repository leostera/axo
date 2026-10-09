import Foundation

struct MacVoiceTranscript: Codable, Equatable, Identifiable {
    enum Insertion: String, Codable {
        case inserted
        case originalPaneUnavailable
    }

    let id: UUID
    let createdAt: Date
    let workspaceName: String
    let sessionName: String
    let text: String
    let insertion: Insertion

    var destinationLabel: String { "\(sessionName) · \(workspaceName)" }
}

struct MacVoiceHistoryStore {
    static let maximumTranscripts = 500

    private let fileURL: URL

    init(fileURL: URL) { self.fileURL = fileURL }

    func load() -> [MacVoiceTranscript] {
        guard let data = try? Data(contentsOf: fileURL),
              data.count <= 16 * 1_024 * 1_024,
              let transcripts = try? JSONDecoder().decode([MacVoiceTranscript].self, from: data) else { return [] }
        return Array(transcripts.prefix(Self.maximumTranscripts))
    }

    func save(_ transcripts: [MacVoiceTranscript]) throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Array(transcripts.prefix(Self.maximumTranscripts)))
        guard data.count <= 16 * 1_024 * 1_024 else { throw VoiceHistoryFault.tooLarge }
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

private enum VoiceHistoryFault: LocalizedError {
    case tooLarge
    var errorDescription: String? { "The local voice transcript history has reached its storage limit." }
}
