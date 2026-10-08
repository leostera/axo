import Foundation

public struct ConversationMessage: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let role: String
    public let text: String
}

public struct Question: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let options: [String]
}

public enum AgentState: String, Codable, Sendable { case idle, running, waiting }

public struct Snapshot: Codable, Sendable {
    public let sessionId: String
    public let state: AgentState
    public let messages: [ConversationMessage]
    public let question: Question?
}

public enum RelayEvent: Sendable {
    case snapshot(Snapshot)
    case presence(Bool)
    case acknowledged(String)
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
            guard let id = envelope.id, envelope.disposition == "submitted" else { throw ProtocolError.malformed }
            return .acknowledged(id)
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

    public static func sync() -> Self { Self(type: "sync", id: nil, sessionId: nil, text: nil, questionId: nil, value: nil) }
    public static func prompt(id: String, session: String, text: String) -> Self {
        Self(type: "prompt", id: id, sessionId: session, text: text, questionId: nil, value: nil)
    }
    public static func answer(id: String, session: String, question: String, value: String) -> Self {
        Self(type: "answer", id: id, sessionId: session, text: nil, questionId: question, value: value)
    }
}

public struct RelayEndpoint: Sendable {
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
