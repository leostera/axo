import Foundation

public struct SessionAddress: Codable, Equatable, Sendable {
    public let workspaceId: UUID?
    public let sessionId: UUID
    public init(workspaceId: UUID?, sessionId: UUID) { self.workspaceId = workspaceId; self.sessionId = sessionId }
    private enum CodingKeys: String, CodingKey { case workspaceId, sessionId }
    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(workspaceId, forKey: .workspaceId)
        try fields.encode(sessionId, forKey: .sessionId)
    }
}
public struct SessionDeletionIntent: Codable, Equatable, Sendable {
    public let target: MachineTarget
    public let sessions: [SessionAddress]
    public let expectedRevision: WorkRevision
    public init(target: MachineTarget, sessions: [SessionAddress], expectedRevision: WorkRevision) {
        self.target = target; self.sessions = sessions; self.expectedRevision = expectedRevision
    }
}
public struct SessionDeletionParameters: Codable, Equatable, Sendable {
    public let target: MachineTarget
    public let commandId: UUID
    public let sessions: [SessionAddress]
    public let expectedRevision: WorkRevision
    public var intent: SessionDeletionIntent { .init(target: target, sessions: sessions, expectedRevision: expectedRevision) }
    public init(target: MachineTarget, commandId: UUID, sessions: [SessionAddress], expectedRevision: WorkRevision) {
        self.target = target; self.commandId = commandId; self.sessions = sessions; self.expectedRevision = expectedRevision
    }
}
public struct SessionDeletionReceipt: Codable, Equatable, Sendable {
    public let commandId: UUID
    public let intent: SessionDeletionIntent
    public let runtimes: [TerminalRuntime]
    /// Null is prepared/unknown, never automatic stop/retry authority.
    public let revision: WorkRevision?
}
public struct SessionDeletionResult: Decodable, Equatable, Sendable {
    public let hostGeneration: UUID
    public let receipt: SessionDeletionReceipt
}
