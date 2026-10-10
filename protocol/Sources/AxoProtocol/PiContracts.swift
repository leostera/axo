import Foundation

public enum PiAdmission: String, Codable, Equatable, Sendable {
    case notAdmitted
    case ready
    case stopped
    case failed
    case recoveryRequired
}

public struct PiSessionTarget: Codable, Equatable, Sendable {
    public let machineId: UUID
    public let hostGeneration: UUID
    public let workspaceId: UUID
    public let sessionId: UUID
    public let paneId: UUID

    public init(machineId: UUID, hostGeneration: UUID, workspaceId: UUID, sessionId: UUID, paneId: UUID) {
        self.machineId = machineId
        self.hostGeneration = hostGeneration
        self.workspaceId = workspaceId
        self.sessionId = sessionId
        self.paneId = paneId
    }
}

public struct PiChatTarget: Codable, Equatable, Sendable {
    public let machineId: UUID
    public let hostGeneration: UUID
    public let workspaceId: UUID
    public let sessionId: UUID
    public let paneId: UUID
    public let runtimeHostGeneration: UUID
    public let runtimeGeneration: UUID
    public let chatId: UUID

    public init(machineId: UUID, hostGeneration: UUID, workspaceId: UUID, sessionId: UUID, paneId: UUID,
                runtimeHostGeneration: UUID, runtimeGeneration: UUID, chatId: UUID) {
        self.machineId = machineId
        self.hostGeneration = hostGeneration
        self.workspaceId = workspaceId
        self.sessionId = sessionId
        self.paneId = paneId
        self.runtimeHostGeneration = runtimeHostGeneration
        self.runtimeGeneration = runtimeGeneration
        self.chatId = chatId
    }

    public init(session: PiSessionTarget, runtime: TerminalRuntime, chatId: UUID) {
        self.init(machineId: session.machineId, hostGeneration: session.hostGeneration,
                  workspaceId: session.workspaceId, sessionId: session.sessionId, paneId: session.paneId,
                  runtimeHostGeneration: runtime.hostGeneration, runtimeGeneration: runtime.runtimeGeneration,
                  chatId: chatId)
    }

    public var runtime: TerminalRuntime {
        TerminalRuntime(
            hostGeneration: runtimeHostGeneration,
            target: .init(sessionId: sessionId, paneId: paneId),
            runtimeGeneration: runtimeGeneration
        )
    }
}

public enum PiPersistence: Equatable, Sendable {
    case fresh
    case resume(chatId: UUID, previousRuntime: TerminalRuntime)
}

extension PiPersistence: Codable {
    private enum CodingKeys: String, CodingKey { case kind, chatId, previousRuntime }
    private enum Kind: String, Codable { case fresh, resume }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .fresh:
            self = .fresh
        case .resume:
            self = .resume(chatId: try container.decode(UUID.self, forKey: .chatId),
                           previousRuntime: try container.decode(TerminalRuntime.self, forKey: .previousRuntime))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fresh:
            try container.encode(Kind.fresh, forKey: .kind)
        case .resume(let chatId, let runtime):
            try container.encode(Kind.resume, forKey: .kind)
            try container.encode(chatId, forKey: .chatId)
            try container.encode(runtime, forKey: .previousRuntime)
        }
    }
}

public struct PiSessionStartParameters: Codable, Equatable, Sendable {
    public let target: PiSessionTarget
    public let commandId: UUID
    public let persistence: PiPersistence

    public init(target: PiSessionTarget, commandId: UUID = UUID(), persistence: PiPersistence = .fresh) {
        self.target = target
        self.commandId = commandId
        self.persistence = persistence
    }
}

public enum PiReadMode: String, Codable, Equatable, Sendable {
    case live
    case stopped
}

public enum PiChatOperation: String, Codable, Equatable, Sendable {
    case sendMessage
    case sendSteeringMessage
    case cancelTurn
    case answerQuestion
    case setViewing
}

public enum PiIntent: Equatable, Sendable {
    case start(target: PiSessionTarget, persistence: PiPersistence)
    case chat(target: PiChatTarget, operation: PiChatOperation)
}

extension PiIntent: Codable {
    private enum CodingKeys: String, CodingKey { case kind, target, persistence, operation }
    private enum Kind: String, Codable { case start, chat }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .start:
            self = .start(target: try container.decode(PiSessionTarget.self, forKey: .target),
                          persistence: try container.decode(PiPersistence.self, forKey: .persistence))
        case .chat:
            self = .chat(target: try container.decode(PiChatTarget.self, forKey: .target),
                         operation: try container.decode(PiChatOperation.self, forKey: .operation))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .start(let target, let persistence):
            try container.encode(Kind.start, forKey: .kind)
            try container.encode(target, forKey: .target)
            try container.encode(persistence, forKey: .persistence)
        case .chat(let target, let operation):
            try container.encode(Kind.chat, forKey: .kind)
            try container.encode(target, forKey: .target)
            try container.encode(operation, forKey: .operation)
        }
    }
}

public enum PiDisposition: Equatable, Sendable {
    case prepared
    case dispatched
    case rejected(code: Int)
}

extension PiDisposition: Codable {
    private enum CodingKeys: String, CodingKey { case kind, code }
    private enum Kind: String, Codable { case prepared, dispatched, rejected }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .prepared: self = .prepared
        case .dispatched: self = .dispatched
        case .rejected: self = .rejected(code: try container.decode(Int.self, forKey: .code))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .prepared: try container.encode(Kind.prepared, forKey: .kind)
        case .dispatched: try container.encode(Kind.dispatched, forKey: .kind)
        case .rejected(let code):
            try container.encode(Kind.rejected, forKey: .kind)
            try container.encode(code, forKey: .code)
        }
    }
}

public struct PiCommandReceipt: Codable, Equatable, Sendable {
    public let commandId: UUID
    public let intent: PiIntent
    public let disposition: PiDisposition
    public let runtime: TerminalRuntime?

    public init(commandId: UUID, intent: PiIntent, disposition: PiDisposition, runtime: TerminalRuntime?) {
        self.commandId = commandId
        self.intent = intent
        self.disposition = disposition
        self.runtime = runtime
    }
}

public struct PiSessionStartResult: Codable, Equatable, Sendable {
    public let hostGeneration: UUID
    public let receipt: PiCommandReceipt
    public let chat: PiChatTarget?
    public let admission: PiAdmission
}

public struct PiChatGetParameters: Codable, Equatable, Sendable {
    public let target: PiChatTarget
    public let readMode: PiReadMode
    public init(target: PiChatTarget, readMode: PiReadMode = .live) {
        self.target = target
        self.readMode = readMode
    }
}

public struct PiHistoryCursor: Codable, Equatable, Sendable {
    public let target: PiChatTarget
    public let readMode: PiReadMode
    public let leafId: String?
    public let after: String

    public init(target: PiChatTarget, readMode: PiReadMode, leafId: String?, after: String) {
        self.target = target
        self.readMode = readMode
        self.leafId = leafId
        self.after = after
    }

    private enum CodingKeys: String, CodingKey { case target, readMode, leafId, after }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(target, forKey: .target)
        try container.encode(readMode, forKey: .readMode)
        try container.encode(leafId, forKey: .leafId)
        try container.encode(after, forKey: .after)
    }
}

public struct PiChatHistoryParameters: Codable, Equatable, Sendable {
    public let target: PiChatTarget
    public let readMode: PiReadMode
    public let limit: Int
    public let cursor: PiHistoryCursor?

    public init(target: PiChatTarget, readMode: PiReadMode = .live, limit: Int = 50, cursor: PiHistoryCursor? = nil) {
        self.target = target
        self.readMode = readMode
        self.limit = limit
        self.cursor = cursor
    }
}

public struct PiToolOutputParameters: Codable, Equatable, Sendable {
    public let target: PiChatTarget
    public let readMode: PiReadMode
    public let entryId: String
    public let toolCallId: String
    public let offset: Int
    public let limit: Int

    public init(target: PiChatTarget, readMode: PiReadMode = .live, entryId: String,
                toolCallId: String, offset: Int, limit: Int = 8192) {
        self.target = target
        self.readMode = readMode
        self.entryId = entryId
        self.toolCallId = toolCallId
        self.offset = offset
        self.limit = limit
    }
}

public struct PiToolCallProjection: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
}

public struct PiCanonicalProjection: Codable, Equatable, Sendable, Identifiable {
    public var id: String { entryId }
    public let entryId: String
    public let parentId: String?
    public let timestamp: String
    public let kind: String
    public let role: String?
    public let text: String
    public let truncated: Bool
    public let toolCallId: String?
    public let toolName: String?
    public let toolCalls: [PiToolCallProjection]
}

public struct PiQuestionOption: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let label: String
}

public struct PiQuestion: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let interactionId: UUID
    public let title: String
    public let options: [PiQuestionOption]
}

public struct PiChatSnapshot: Codable, Equatable, Sendable {
    public let hostGeneration: UUID
    public let readMode: PiReadMode
    public let target: PiChatTarget
    public let admission: PiAdmission
    public let busy: Bool
    public let interactionId: UUID?
    public let uiWaits: Int
    public let question: PiQuestion?
    public let recovery: Bool
    public let leafId: String?
    public let recentEntries: [PiCanonicalProjection]
    public let viewingCount: Int
}

public struct PiChatHistoryResult: Codable, Equatable, Sendable {
    public let hostGeneration: UUID
    public let readMode: PiReadMode
    public let target: PiChatTarget
    public let leafId: String?
    public let entries: [PiCanonicalProjection]
    public let next: PiHistoryCursor?
}

public struct PiToolOutputResult: Codable, Equatable, Sendable {
    public let hostGeneration: UUID
    public let readMode: PiReadMode
    public let target: PiChatTarget
    public let entryId: String
    public let toolCallId: String
    public let offset: Int
    public let text: String
    public let nextOffset: Int?
    public let totalBytes: Int
}

public struct PiChatTextParameters: Codable, Equatable, Sendable {
    public let target: PiChatTarget
    public let commandId: UUID
    public let text: String
    public init(target: PiChatTarget, commandId: UUID = UUID(), text: String) {
        self.target = target
        self.commandId = commandId
        self.text = text
    }
}

public struct PiChatSteeringParameters: Codable, Equatable, Sendable {
    public let target: PiChatTarget
    public let commandId: UUID
    public let interactionId: UUID
    public let text: String
    public init(target: PiChatTarget, commandId: UUID = UUID(), interactionId: UUID, text: String) {
        self.target = target
        self.commandId = commandId
        self.interactionId = interactionId
        self.text = text
    }
}

public struct PiChatCancelParameters: Codable, Equatable, Sendable {
    public let target: PiChatTarget
    public let commandId: UUID
    public let interactionId: UUID
    public init(target: PiChatTarget, commandId: UUID = UUID(), interactionId: UUID) {
        self.target = target
        self.commandId = commandId
        self.interactionId = interactionId
    }
}

public struct PiChatAnswerParameters: Codable, Equatable, Sendable {
    public let target: PiChatTarget
    public let commandId: UUID
    public let interactionId: UUID
    public let questionId: UUID
    public let optionId: UUID
    public init(target: PiChatTarget, commandId: UUID = UUID(), interactionId: UUID,
                questionId: UUID, optionId: UUID) {
        self.target = target
        self.commandId = commandId
        self.interactionId = interactionId
        self.questionId = questionId
        self.optionId = optionId
    }
}

public struct PiChatViewingParameters: Codable, Equatable, Sendable {
    public let target: PiChatTarget
    public let commandId: UUID
    public let leaseId: UUID
    public let viewing: Bool
    public let ttlSeconds: Int
    public init(target: PiChatTarget, commandId: UUID = UUID(), leaseId: UUID,
                viewing: Bool, ttlSeconds: Int = 45) {
        self.target = target
        self.commandId = commandId
        self.leaseId = leaseId
        self.viewing = viewing
        self.ttlSeconds = ttlSeconds
    }
}

public struct PiMutationResult: Codable, Equatable, Sendable {
    public let hostGeneration: UUID
    public let receipt: PiCommandReceipt
}
