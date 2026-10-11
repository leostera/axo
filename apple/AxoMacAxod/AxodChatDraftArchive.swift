import AxoProtocol
import Foundation

/// A private draft archive, not canonical Pi history or permission to dispatch.
/// The bounded binary format has no object keys that can silently shadow text.
@MainActor struct AxodChatDraftArchive {
    struct Draft {
        let conversation: AxodChatDrafts.Conversation
        let revision: UUID
        let text: String
    }
    struct Pending {
        let commandID: UUID
        let target: PiChatTarget
        let revision: UUID
    }
    enum Failure: Error { case malformed }
    static let maximumEncodedBytes = 2 * 1024 * 1024
    private static let header = Data("AXO-DRAFTS".utf8) + Data([0, 1])
    let revision: UUID
    let drafts: [Draft]
    let pending: [Pending]
    private init(revision: UUID, drafts: [Draft], pending: [Pending]) {
        self.revision = revision; self.drafts = drafts; self.pending = pending
    }

    static func make(revision: UUID = UUID(), drafts: [Draft], pending: [Pending]) throws -> Self {
        guard nonzero(revision), drafts.count <= AxodChatDrafts.maximumConversations,
              pending.count <= AxodChatDrafts.maximumConversations else { throw Failure.malformed }
        var conversations = Set<AxodChatDrafts.Conversation>(), commands = Set<UUID>()
        var waiting = Set<AxodChatDrafts.Conversation>(), bytes = 0
        for draft in drafts {
            let key = draft.conversation
            let size = draft.text.utf8.count
            guard valid(key), nonzero(draft.revision), !draft.text.isEmpty,
                  size <= AxodChatDrafts.maximumDraftBytes, conversations.insert(key).inserted else { throw Failure.malformed }
            bytes += size
            guard bytes <= AxodChatDrafts.maximumBytes else { throw Failure.malformed }
        }
        for item in pending {
            let key = AxodChatDrafts.Conversation(item.target)
            guard valid(key), nonzero(item.commandID), nonzero(item.revision),
                  [item.target.hostGeneration, item.target.runtimeHostGeneration, item.target.runtimeGeneration].allSatisfy(nonzero),
                  commands.insert(item.commandID).inserted, waiting.insert(key).inserted else { throw Failure.malformed }
        }
        return Self(revision: revision, drafts: drafts, pending: pending)
    }

    var encoded: Data {
        var data = Self.header
        Self.append(revision, to: &data)
        Self.append(drafts.count, to: &data)
        for draft in drafts {
            Self.append(draft.conversation, to: &data)
            Self.append(draft.revision, to: &data)
            let text = Data(draft.text.utf8)
            Self.append(text.count, to: &data); data.append(text)
        }
        Self.append(pending.count, to: &data)
        for item in pending {
            Self.append(item.commandID, to: &data)
            Self.append(item.revision, to: &data)
            Self.append(AxodChatDrafts.Conversation(item.target), to: &data)
            Self.append(item.target.hostGeneration, to: &data)
            Self.append(item.target.runtimeHostGeneration, to: &data)
            Self.append(item.target.runtimeGeneration, to: &data)
        }
        return data
    }

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else { throw Failure.malformed }
        var reader = Reader(data: data)
        guard try reader.take(header.count) == header else { throw Failure.malformed }
        let revision = try reader.uuid()
        let count = try reader.count(maximum: AxodChatDrafts.maximumConversations)
        var drafts: [Draft] = []
        for _ in 0..<count {
            let key = try reader.conversation(), revision = try reader.uuid()
            let size = try reader.count(maximum: AxodChatDrafts.maximumDraftBytes)
            guard let text = String(data: try reader.take(size), encoding: .utf8) else { throw Failure.malformed }
            drafts.append(Draft(conversation: key, revision: revision, text: text))
        }
        let pendingCount = try reader.count(maximum: AxodChatDrafts.maximumConversations)
        var pending: [Pending] = []
        for _ in 0..<pendingCount {
            let command = try reader.uuid(), revision = try reader.uuid(), key = try reader.conversation()
            let host = try reader.uuid(), runtimeHost = try reader.uuid(), runtime = try reader.uuid()
            let target = PiChatTarget(machineId: key.machineID, hostGeneration: host, workspaceId: key.workspaceID,
                                      sessionId: key.sessionID, paneId: key.paneID, runtimeHostGeneration: runtimeHost,
                                      runtimeGeneration: runtime, chatId: key.chatID)
            pending.append(Pending(commandID: command, target: target, revision: revision))
        }
        guard reader.offset == data.count else { throw Failure.malformed }
        return try make(revision: revision, drafts: drafts, pending: pending)
    }

    nonisolated private static func nonzero(_ id: UUID) -> Bool { id.uuidString != "00000000-0000-0000-0000-000000000000" }
    private static func valid(_ key: AxodChatDrafts.Conversation) -> Bool {
        [key.machineID, key.sessionID, key.paneID, key.chatID].allSatisfy(nonzero) && key.workspaceID.map(nonzero) != false
    }
    private static func append(_ id: UUID, to data: inout Data) {
        var bytes = id.uuid
        withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
    }
    private static func append(_ count: Int, to data: inout Data) {
        var value = UInt32(count).bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    private static func append(_ key: AxodChatDrafts.Conversation, to data: inout Data) {
        append(key.machineID, to: &data)
        data.append(key.workspaceID == nil ? 0 : 1)
        if let workspace = key.workspaceID { append(workspace, to: &data) }
        append(key.sessionID, to: &data); append(key.paneID, to: &data); append(key.chatID, to: &data)
    }
    private struct Reader {
        let data: Data
        var offset = 0
        mutating func take(_ size: Int) throws -> Data {
            guard size >= 0, size <= data.count - offset else { throw Failure.malformed }
            defer { offset += size }
            return data.subdata(in: offset..<(offset + size))
        }
        mutating func count(maximum: Int) throws -> Int {
            let bytes = try take(4)
            let value = bytes.reduce(0) { ($0 << 8) | Int($1) }
            guard value <= maximum else { throw Failure.malformed }
            return value
        }
        mutating func uuid() throws -> UUID {
            let bytes = try take(16)
            let id = bytes.withUnsafeBytes { NSUUID(uuidBytes: $0.bindMemory(to: UInt8.self).baseAddress!) as UUID }
            guard nonzero(id) else { throw Failure.malformed }
            return id
        }
        mutating func conversation() throws -> AxodChatDrafts.Conversation {
            let machine = try uuid(), flag = try take(1)[0]
            guard flag <= 1 else { throw Failure.malformed }
            let workspace = flag == 1 ? try uuid() : nil
            let session = try uuid(), pane = try uuid(), chat = try uuid()
            return AxodChatDrafts.Conversation(machineID: machine, workspaceID: workspace,
                                              sessionID: session, paneID: pane, chatID: chat)
        }
    }
}
