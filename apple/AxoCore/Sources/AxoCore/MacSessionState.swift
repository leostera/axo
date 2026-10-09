import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum MacAgentState: String, Codable, Sendable { case idle, working, attention, detached }
public enum MacAttentionReason: String, Codable, Sendable { case question, result, failure }

/// Ephemeral local observations; no transcript or execution capability belongs in this envelope.
public struct MacSessionState: Codable, Equatable, Sendable {
    public let version: Int
    public let sessionID: String
    public let paneID: String
    public let runtimeGeneration: String
    public let updatedAt: Double
    public let conversationID: String?
    public let state: MacAgentState
    public let attentionID: String?
    public let attentionReason: MacAttentionReason?

    public func matches(session: AxoSessionID, pane: PaneID, generation: UUID) -> Bool {
        let age = Date().timeIntervalSince1970 * 1_000 - updatedAt
        guard updatedAt.isFinite, age >= -5_000, age <= 30_000,
              version == 1, UUID(uuidString: sessionID) == session.rawValue,
              UUID(uuidString: paneID) == pane.rawValue, UUID(uuidString: runtimeGeneration) == generation else { return false }
        if state != .detached {
            guard let conversationID, !conversationID.isEmpty, conversationID.utf8.count <= 128 else { return false }
        }
        if state == .attention { return attentionID.flatMap(UUID.init(uuidString:)) != nil && attentionReason != nil }
        return attentionID == nil && attentionReason == nil
    }
    public static func read(from path: String) -> MacSessionState? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= 4_096 else { return nil }
        guard let data = try? file.read(upToCount: 4_097), data.count <= 4_096 else { return nil }
        return try? JSONDecoder().decode(MacSessionState.self, from: data)
    }
}

/// One attention episode per admitted runtime. Repeated polls never generate repeated banners.
public struct MacAttentionReceipt: Sendable {
    private var observedEpisode: String?
    private var acknowledgedEpisode: String?
    public init() {}
    public mutating func observe(_ snapshot: MacSessionState, isViewing: Bool) -> Bool {
        guard snapshot.state == .attention, let id = snapshot.attentionID else { return false }
        if isViewing { acknowledgedEpisode = id }
        guard observedEpisode != id else { return false }
        observedEpisode = id
        return !isViewing
    }
    public func presentation(_ snapshot: MacSessionState) -> MacAgentState {
        if snapshot.state == .attention, snapshot.attentionReason != .question,
           snapshot.attentionID == acknowledgedEpisode { return .idle }
        return snapshot.state
    }
}
