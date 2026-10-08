import Foundation

public struct ConversationMessage: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let role: String
    public let text: String
    public let toolName: String?
    public let toolCallId: String?
    public let status: AgentActivityStatus?
    public let output: String?
}

public struct Question: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let options: [String]
}

public enum AgentState: String, Codable, Sendable { case idle, running, waiting }
public enum AgentActivityStatus: String, Codable, Sendable { case running, completed, failed }
public enum AgentEventCategory: String, Codable, Sendable { case session, lifecycle, turn, assistant, tool, input, model, provider }

public struct AgentEvent: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let sequence: Int
    public let timestamp: Int64
    public let category: AgentEventCategory
    public let name: String
    public let anchorMessageId: String?
    public let correlationId: String?
    public let summary: String
    public let detail: String?

    public init(id: String, sequence: Int, timestamp: Int64, category: AgentEventCategory,
                name: String, anchorMessageId: String? = nil, correlationId: String? = nil,
                summary: String, detail: String? = nil) {
        self.id = id
        self.sequence = sequence
        self.timestamp = timestamp
        self.category = category
        self.name = name
        self.anchorMessageId = anchorMessageId
        self.correlationId = correlationId
        self.summary = summary
        self.detail = detail
    }
}

public struct AgentActivity: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let toolName: String
    public let summary: String
    public let status: AgentActivityStatus
    public let output: String?

    public init(id: String, toolName: String, summary: String, status: AgentActivityStatus, output: String? = nil) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.status = status
        self.output = output
    }
}

public struct Snapshot: Codable, Sendable {
    public let sessionId: String
    public let state: AgentState
    public let messages: [ConversationMessage]
    public let activities: [AgentActivity]?
    public let events: [AgentEvent]?
    public let droppedEvents: Int?
    public let liveText: String?
    public let runId: String?
    public let question: Question?
}

public enum RelayEvent: Sendable {
    case snapshot(Snapshot)
    case presence(Bool)
    case acknowledged(String, cancelled: Bool)
    case error(id: String?, message: String)

    public static func decode(_ data: Data) throws -> RelayEvent {
        guard data.count <= 256 * 1024 else { throw ProtocolError.oversized }
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(Envelope.self, from: data)
        switch envelope.type {
        case "snapshot": return .snapshot(try decoder.decode(Snapshot.self, from: data))
        case "presence":
            guard let online = envelope.online else { throw ProtocolError.malformed }
            return .presence(online)
        case "ack":
            guard let id = envelope.id,
                  let disposition = envelope.disposition,
                  disposition == "submitted" || disposition == "cancelled" else { throw ProtocolError.malformed }
            return .acknowledged(id, cancelled: disposition == "cancelled")
        case "error":
            guard let message = envelope.message else { throw ProtocolError.malformed }
            return .error(id: envelope.id, message: message)
        default: throw ProtocolError.malformed
        }
    }

    private struct Envelope: Decodable {
        let type: String
        let online: Bool?
        let id: String?
        let disposition: String?
        let message: String?
    }
}

public enum ProtocolError: Error { case malformed, oversized, invalidEndpoint }

public struct PhoneCommand: Encodable, Sendable {
    public let type: String
    public let id: String?
    public let sessionId: String?
    public let text: String?
    public let questionId: String?
    public let value: String?
    public let runId: String?

    public static func sync() -> Self {
        Self(type: "sync", id: nil, sessionId: nil, text: nil, questionId: nil, value: nil, runId: nil)
    }
    public static func prompt(id: String, session: String, text: String) -> Self {
        Self(type: "prompt", id: id, sessionId: session, text: text, questionId: nil, value: nil, runId: nil)
    }
    public static func answer(id: String, session: String, question: String, value: String) -> Self {
        Self(type: "answer", id: id, sessionId: session, text: nil, questionId: question, value: value, runId: nil)
    }
    public static func cancel(id: String, session: String, runId: String) -> Self {
        Self(type: "cancel", id: id, sessionId: session, text: nil, questionId: nil, value: nil, runId: runId)
    }
}

public struct RelayEndpoint: Sendable {
    public static let defaultOrigin = "https://bridge.axo.leostera.dev"

    public static func restoredOrigin(_ stored: String?) -> String {
        // Migrate only the shipped placeholder; never replace a user's custom endpoint.
        guard let stored, stored != "https://api.axo.example.invalid" else { return defaultOrigin }
        return stored
    }

    public let baseURL: URL

    public init(_ text: String) throws {
        guard let url = URL(string: text), url.scheme == "https", let host = url.host,
              !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { throw ProtocolError.invalidEndpoint }
        baseURL = url
    }

    public var loginURL: URL { baseURL.appendingPathComponent("login") }
    public var socketURL: URL {
        var parts = URLComponents(url: baseURL.appendingPathComponent("connect/phone"), resolvingAgainstBaseURL: false)!
        parts.scheme = "wss"
        return parts.url!
    }
}
