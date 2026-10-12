import Foundation

public struct ConversationMessage: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let role: String
    public let text: String
    public let toolName: String?
    public let toolCallId: String?
    public let status: AgentActivityStatus?
    public let output: String?
    public let toolPresentation: ToolPresentation?
    public var attachments: [SharedFile]? = nil
    public var timestamp: Int64? = nil
    public var commandId: String? = nil
    public var delivery: PromptDeliveryState? = nil
}

public enum PromptDeliveryState: String, Codable, Sendable {
    case submitting, submitted, steering, uncertain, rejected
}

public struct ToolPresentation: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case shell, edit, file, search, generic }
    public let kind: Kind
    public let title: String
    public let subtitle: String?
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

public struct Snapshot: Decodable, Sendable {
    public let sessionID: AxoSessionID
    public let conversationID: String
    public let viewId: String
    public let state: AgentState
    public let messages: [ConversationMessage]
    public let hasEarlierMessages: Bool
    public let activities: [AgentActivity]?
    public let events: [AgentEvent]?
    public let droppedEvents: Int?
    public let liveText: String?
    public let runId: String?
    public let question: Question?

    private struct WireValue: Decodable {
        let sessionId: String
        let conversationId: String
        let viewId: String
        let state: AgentState
        let messages: [ConversationMessage]
        let hasEarlierMessages: Bool
        let activities: [AgentActivity]?
        let events: [AgentEvent]?
        let droppedEvents: Int?
        let liveText: String?
        let runId: String?
        let question: Question?
    }

    public init(from decoder: Decoder) throws {
        let wire = try WireValue(from: decoder)
        guard let sessionUUID = UUID(uuidString: wire.sessionId),
              !wire.conversationId.isEmpty, wire.conversationId.utf8.count <= 128 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid session/conversation identity"))
        }
        sessionID = AxoSessionID(sessionUUID)
        conversationID = wire.conversationId
        viewId = wire.viewId
        state = wire.state
        messages = wire.messages
        hasEarlierMessages = wire.hasEarlierMessages
        activities = wire.activities
        events = wire.events
        droppedEvents = wire.droppedEvents
        liveText = wire.liveText
        runId = wire.runId
        question = wire.question
    }
}

public struct HistoryPage: Decodable, Sendable {
    public let id: String
    public let sessionID: AxoSessionID
    public let conversationID: String
    public let beforeId: String
    public let viewId: String
    public let direction: String?
    public let messages: [ConversationMessage]
    public let hasEarlierMessages: Bool
    public let hasLaterMessages: Bool

    private struct WireValue: Decodable {
        let id: String
        let sessionId: String
        let conversationId: String
        let beforeId: String
        let viewId: String
        let direction: String?
        let messages: [ConversationMessage]
        let hasEarlierMessages: Bool
        let hasLaterMessages: Bool
    }

    public init(from decoder: Decoder) throws {
        let wire = try WireValue(from: decoder)
        guard let sessionUUID = UUID(uuidString: wire.sessionId),
              !wire.conversationId.isEmpty, wire.conversationId.utf8.count <= 128 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid history destination"))
        }
        id = wire.id
        sessionID = AxoSessionID(sessionUUID)
        conversationID = wire.conversationId
        beforeId = wire.beforeId
        viewId = wire.viewId
        direction = wire.direction
        messages = wire.messages
        hasEarlierMessages = wire.hasEarlierMessages
        hasLaterMessages = wire.hasLaterMessages
    }
}

public struct ToolOutputPage: Decodable, Sendable {
    public let id: String
    public let sessionID: AxoSessionID
    public let conversationID: String
    public let toolCallId: String
    public let offset: Int
    public let nextOffset: Int?
    public let text: String

    private struct WireValue: Decodable {
        let id: String
        let sessionId: String
        let conversationId: String
        let toolCallId: String
        let offset: Int
        let nextOffset: Int?
        let text: String
    }

    public init(from decoder: Decoder) throws {
        let wire = try WireValue(from: decoder)
        guard let sessionUUID = UUID(uuidString: wire.sessionId),
              !wire.conversationId.isEmpty, wire.conversationId.utf8.count <= 128 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid tool-output destination"))
        }
        id = wire.id
        sessionID = AxoSessionID(sessionUUID)
        conversationID = wire.conversationId
        toolCallId = wire.toolCallId
        offset = wire.offset
        nextOffset = wire.nextOffset
        text = wire.text
    }
}

public struct CatalogWorkspace: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case project, standalone }

    public let id: WorkspaceID
    public let name: String
    public let kind: Kind

    private enum CodingKeys: String, CodingKey { case id, name, kind }

    private struct WireValue: Decodable {
        let id: UUID
        let name: String
        let kind: Kind
    }

    public init(from decoder: Decoder) throws {
        let wire = try WireValue(from: decoder)
        guard let parsedName = try? WorkbenchName(wire.name), parsedName.value == wire.name else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid workspace name"))
        }
        id = WorkspaceID(wire.id)
        name = parsedName.value
        kind = wire.kind
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.rawValue, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
    }
}

public struct CatalogSession: Codable, Equatable, Identifiable, Sendable {
    public enum Availability: String, Codable, Sendable { case running, stopped, failed }

    public let id: AxoSessionID
    public let workspaceId: WorkspaceID
    public let name: String
    public let conversationId: String?
    public let availability: Availability

    private enum CodingKeys: String, CodingKey { case id, workspaceId, name, conversationId, availability }

    private struct WireValue: Decodable {
        let id: UUID
        let workspaceId: UUID
        let name: String
        let conversationId: String?
        let availability: Availability
    }

    public init(from decoder: Decoder) throws {
        let wire = try WireValue(from: decoder)
        guard let parsedName = try? WorkbenchName(wire.name), parsedName.value == wire.name,
              wire.conversationId.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid session catalog entry"))
        }
        id = AxoSessionID(wire.id)
        workspaceId = WorkspaceID(wire.workspaceId)
        name = parsedName.value
        conversationId = wire.conversationId
        availability = wire.availability
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.rawValue, forKey: .id)
        try container.encode(workspaceId.rawValue, forKey: .workspaceId)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(conversationId, forKey: .conversationId)
        try container.encode(availability, forKey: .availability)
    }
}

public struct CatalogPage: Decodable, Equatable, Sendable {
    public enum Item: Decodable, Equatable, Sendable {
        case workspace(CatalogWorkspace)
        case session(CatalogSession)

        private enum CodingKeys: String, CodingKey { case kind, workspace, session }
        private enum Kind: String, Decodable { case workspace, session }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .workspace: self = .workspace(try container.decode(CatalogWorkspace.self, forKey: .workspace))
            case .session: self = .session(try container.decode(CatalogSession.self, forKey: .session))
            }
        }
    }

    public static let maximumItems = 50
    public let requestId: String?
    public let revision: Int
    public let items: [Item]
    public let nextCursor: String?
    public let hostOnline: Bool

    private enum CodingKeys: String, CodingKey { case requestId, revision, items, nextCursor, hostOnline }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        let revision = try container.decode(Int.self, forKey: .revision)
        let items = try container.decode([Item].self, forKey: .items)
        let nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
        guard requestId.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
              revision >= 0, items.count <= Self.maximumItems,
              nextCursor.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .items, in: container, debugDescription: "Invalid catalog page bounds" )
        }
        var workspaceIDs = Set<WorkspaceID>()
        var sessionIDs = Set<AxoSessionID>()
        for item in items {
            switch item {
            case .workspace(let workspace):
                guard workspaceIDs.insert(workspace.id).inserted else {
                    throw DecodingError.dataCorruptedError(forKey: .items, in: container, debugDescription: "Duplicate workspace ID in catalog page")
                }
            case .session(let session):
                guard sessionIDs.insert(session.id).inserted else {
                    throw DecodingError.dataCorruptedError(forKey: .items, in: container, debugDescription: "Duplicate session ID in catalog page")
                }
            }
        }
        self.requestId = requestId
        self.revision = revision
        self.items = items
        self.nextCursor = nextCursor
        hostOnline = try container.decode(Bool.self, forKey: .hostOnline)
    }
}

public struct SubscriptionAcknowledgement: Decodable, Equatable, Sendable {
    public let id: String
    public let sessionID: AxoSessionID?
    public let hostOnline: Bool

    private struct WireValue: Decodable {
        let id: String
        let sessionId: String?
        let hostOnline: Bool
    }

    public init(from decoder: Decoder) throws {
        let wire = try WireValue(from: decoder)
        let sessionID = try Self.decodeSessionID(wire.sessionId, codingPath: decoder.codingPath)
        guard !wire.id.isEmpty, wire.id.utf8.count <= 128 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid subscription acknowledgement"))
        }
        id = wire.id
        self.sessionID = sessionID
        hostOnline = wire.hostOnline
    }

    private static func decodeSessionID(_ value: String?, codingPath: [CodingKey]) throws -> AxoSessionID? {
        guard let value else { return nil }
        guard let uuid = UUID(uuidString: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Invalid Axo session ID"))
        }
        return AxoSessionID(uuid)
    }
}

public struct CreationAcknowledgement: Equatable, Sendable {
    public let id: String
    public let sessionID: AxoSessionID?
    public let workspaceID: WorkspaceID?
}

public enum RelayEvent: Sendable {
    case catalogPage(CatalogPage)
    case subscription(SubscriptionAcknowledgement)
    case creationAcknowledged(CreationAcknowledgement)
    case snapshot(Snapshot)
    case history(HistoryPage)
    case toolOutput(ToolOutputPage)
    case presence(Bool)
    case filesChanged(sessionId: String, revision: Int)
    case acknowledged(String, cancelled: Bool, delivery: PromptDeliveryState? = nil)
    case error(id: String?, sessionID: AxoSessionID?, message: String)

    public static func decode(_ data: Data) throws -> RelayEvent {
        guard data.count <= 256 * 1024 else { throw ProtocolError.oversized }
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(Envelope.self, from: data)
        switch envelope.type {
        case "catalog_page": return .catalogPage(try decoder.decode(CatalogPage.self, from: data))
        case "subscription": return .subscription(try decoder.decode(SubscriptionAcknowledgement.self, from: data))
        case "snapshot": return .snapshot(try decoder.decode(Snapshot.self, from: data))
        case "history": return .history(try decoder.decode(HistoryPage.self, from: data))
        case "tool_output": return .toolOutput(try decoder.decode(ToolOutputPage.self, from: data))
        case "files_changed":
            guard let sessionId = envelope.sessionId, let revision = envelope.revision else { throw ProtocolError.malformed }
            return .filesChanged(sessionId: sessionId, revision: revision)
        case "presence":
            guard let online = envelope.online else { throw ProtocolError.malformed }
            return .presence(online)
        case "ack":
            guard let id = envelope.id, let disposition = envelope.disposition else { throw ProtocolError.malformed }
            if disposition == "created" {
                return .creationAcknowledged(CreationAcknowledgement(
                    id: id,
                    sessionID: try decodeSessionID(envelope.sessionId),
                    workspaceID: try decodeWorkspaceID(envelope.workspaceId)
                ))
            }
            guard disposition == "submitted" || disposition == "cancelled" else { throw ProtocolError.malformed }
            return .acknowledged(id, cancelled: disposition == "cancelled", delivery: envelope.delivery)
        case "error":
            guard let message = envelope.message else { throw ProtocolError.malformed }
            return .error(id: envelope.id, sessionID: try decodeSessionID(envelope.sessionId), message: message)
        default: throw ProtocolError.malformed
        }
    }

    private struct Envelope: Decodable {
        let type: String
        let online: Bool?
        let id: String?
        let disposition: String?
        let message: String?
        let sessionId: String?
        let workspaceId: String?
        let revision: Int?
        let delivery: PromptDeliveryState?
    }

    private static func decodeSessionID(_ value: String?) throws -> AxoSessionID? {
        guard let value else { return nil }
        guard let uuid = UUID(uuidString: value) else { throw ProtocolError.malformed }
        return AxoSessionID(uuid)
    }

    private static func decodeWorkspaceID(_ value: String?) throws -> WorkspaceID? {
        guard let value else { return nil }
        guard let uuid = UUID(uuidString: value) else { throw ProtocolError.malformed }
        return WorkspaceID(uuid)
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
    public var beforeId: String? = nil
    public var viewId: String? = nil
    public var direction: String? = nil
    public var toolCallId: String? = nil
    public var offset: Int? = nil
    public var attachmentIds: [String]? = nil
    public var workspaceId: String? = nil
    public var name: String? = nil
    public var revision: Int? = nil
    public var cursor: String? = nil
    public var expectedRevision: Int? = nil

    private enum CodingKeys: String, CodingKey {
        case type, id, sessionId, text, questionId, value, runId
        case beforeId, viewId, direction, toolCallId, offset, attachmentIds
        case workspaceId, name, revision, cursor, expectedRevision
    }

    private init(type: String, id: String?, sessionId: String? = nil, text: String? = nil,
                 questionId: String? = nil, value: String? = nil, runId: String? = nil) {
        self.type = type
        self.id = id
        self.sessionId = sessionId
        self.text = text
        self.questionId = questionId
        self.value = value
        self.runId = runId
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(id, forKey: .id)
        if type == "subscribe" { try container.encode(sessionId, forKey: .sessionId) }
        else { try container.encodeIfPresent(sessionId, forKey: .sessionId) }
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(questionId, forKey: .questionId)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(runId, forKey: .runId)
        try container.encodeIfPresent(beforeId, forKey: .beforeId)
        try container.encodeIfPresent(viewId, forKey: .viewId)
        try container.encodeIfPresent(direction, forKey: .direction)
        try container.encodeIfPresent(toolCallId, forKey: .toolCallId)
        try container.encodeIfPresent(offset, forKey: .offset)
        try container.encodeIfPresent(attachmentIds, forKey: .attachmentIds)
        try container.encodeIfPresent(workspaceId, forKey: .workspaceId)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(expectedRevision, forKey: .expectedRevision)
        if type == "catalog_page" {
            try container.encode(revision, forKey: .revision)
            try container.encode(cursor, forKey: .cursor)
        }
    }

    public static func catalogPage(id: String, revision: Int?, cursor: String?) -> Self {
        var command = Self(type: "catalog_page", id: id)
        command.revision = revision
        command.cursor = cursor
        return command
    }
    public static func subscribe(id: String, sessionID: AxoSessionID?) -> Self {
        Self(type: "subscribe", id: id, sessionId: sessionID?.rawValue.uuidString)
    }
    public static func createWorkspace(id: String, name: String) -> Self {
        var command = Self(type: "create_workspace", id: id)
        command.name = name
        return command
    }
    public static func createSession(id: String, workspaceID: WorkspaceID, name: String) -> Self {
        var command = Self(type: "create_session", id: id)
        command.workspaceId = workspaceID.rawValue.uuidString
        command.name = name
        return command
    }
    public static func renameWorkspace(id: String, workspaceID: WorkspaceID, name: String, expectedRevision: Int) -> Self {
        var command = Self(type: "rename_workspace", id: id)
        command.workspaceId = workspaceID.rawValue.uuidString
        command.name = name
        command.expectedRevision = expectedRevision
        return command
    }
    public static func renameSession(id: String, sessionID: AxoSessionID, name: String, expectedRevision: Int) -> Self {
        var command = Self(type: "rename_session", id: id, sessionId: sessionID.rawValue.uuidString)
        command.name = name
        command.expectedRevision = expectedRevision
        return command
    }
    public static func history(id: String, sessionID: AxoSessionID, viewId: String, beforeId: String, direction: String = "before") -> Self {
        var command = Self(type: "history", id: id, sessionId: sessionID.rawValue.uuidString, text: nil, questionId: nil, value: nil, runId: nil)
        command.beforeId = beforeId
        command.viewId = viewId
        command.direction = direction
        return command
    }
    public static func toolOutput(id: String, sessionID: AxoSessionID, toolCallId: String, offset: Int) -> Self {
        var command = Self(type: "tool_output", id: id, sessionId: sessionID.rawValue.uuidString, text: nil, questionId: nil, value: nil, runId: nil)
        command.toolCallId = toolCallId
        command.offset = offset
        return command
    }
    public static func sync() -> Self {
        Self(type: "sync", id: nil)
    }
    public static func prompt(id: String, sessionID: AxoSessionID, text: String, attachmentIds: [String] = []) -> Self {
        var command = Self(type: "prompt", id: id, sessionId: sessionID.rawValue.uuidString, text: text, questionId: nil, value: nil, runId: nil)
        command.attachmentIds = attachmentIds.isEmpty ? nil : attachmentIds
        return command
    }
    public static func answer(id: String, sessionID: AxoSessionID, question: String, value: String) -> Self {
        Self(type: "answer", id: id, sessionId: sessionID.rawValue.uuidString, text: nil, questionId: question, value: value, runId: nil)
    }
    public static func cancel(id: String, sessionID: AxoSessionID, runId: String) -> Self {
        Self(type: "cancel", id: id, sessionId: sessionID.rawValue.uuidString, text: nil, questionId: nil, value: nil, runId: runId)
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
