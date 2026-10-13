import Foundation

public struct CentralPiToolCallProjection: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
}

public struct CentralPiCanonicalProjection: Codable, Equatable, Sendable, Identifiable {
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
    public let toolCalls: [CentralPiToolCallProjection]
}
