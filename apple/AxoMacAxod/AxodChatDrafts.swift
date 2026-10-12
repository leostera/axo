import AxoProtocol
import Foundation
import Observation

/// Bounded, conversation-scoped editing buffers. Nothing is saved or restored;
/// quitting or recreating the coordinator discards unsent text. Pending captures
/// only fence this client's sends; the daemon's original receipts own outcomes.
@MainActor @Observable final class AxodChatDrafts {
    struct Conversation: Hashable, Sendable {
        let machineID: UUID
        let workspaceID: UUID?
        let sessionID: UUID
        let paneID: UUID
        let chatID: UUID
        init(_ target: PiChatTarget) {
            machineID = target.machineId; workspaceID = target.workspaceId; sessionID = target.sessionId
            paneID = target.paneId; chatID = target.chatId
        }
    }
    struct Submission {
        let target: PiChatTarget
        let commandID: UUID
        let revision: UUID
        let text: String
        let operation: PiChatOperation
    }
    struct Pending {
        let commandID: UUID
        let target: PiChatTarget
        let revision: UUID
        let operation: PiChatOperation
    }
    enum Outcome: Equatable { case dispatched, rejected, unknown }
    enum Issue: Equatable {
        case textCapacity, conversationCapacity, invalidMessage, pendingSubmission
        var message: String {
            switch self {
            case .textCapacity: "The local draft budget is full. Existing text was preserved; nothing was sent."
            case .conversationCapacity: "The local draft slots are full. Existing drafts were preserved; nothing was sent."
            case .invalidMessage: "Use nonempty plain text within Pi's supported bounds. Slash commands stay in Pi's terminal; the draft was preserved."
            case .pendingSubmission: "This conversation has an unresolved submission. Its text was preserved; nothing was resent."
            }
        }
    }
    private struct Entry { let text: String; let revision: UUID; let bytes: Int }
    private struct Captured { let target: PiChatTarget; let revision: UUID; let operation: PiChatOperation }
    nonisolated static let maximumConversations = 32
    nonisolated static let maximumDraftBytes = 65536
    nonisolated static let maximumBytes = 1048576
    private var entries: [Conversation: Entry] = [:]
    private var submissions: [UUID: Captured] = [:]
    private var lastIssue: (Conversation, Issue)?

    func hasPending(machineID: UUID) -> Bool { submissions.values.contains { $0.target.machineId == machineID } }
    func pending(for target: PiChatTarget) -> Pending? {
        guard let item = submissions.first(where: { Conversation($0.value.target) == Conversation(target) }) else { return nil }
        return Pending(commandID: item.key, target: item.value.target, revision: item.value.revision, operation: item.value.operation)
    }
    subscript(text conversation: Conversation) -> String {
        get { entries[conversation]?.text ?? "" }
        set { edit(newValue, in: conversation) }
    }
    func text(for target: PiChatTarget) -> String { entries[Conversation(target)]?.text ?? "" }
    func issue(for target: PiChatTarget) -> Issue? {
        lastIssue?.0 == Conversation(target) ? lastIssue?.1 : nil
    }
    @discardableResult func edit(_ text: String, for target: PiChatTarget) -> Bool { edit(text, in: Conversation(target)) }
    @discardableResult private func edit(_ text: String, in key: Conversation) -> Bool {
        if text == entries[key]?.text {
            if lastIssue?.0 == key { lastIssue = nil }
            return true
        }
        let bytes = text.utf8.count
        let total = entries.values.reduce(0) { $0 + $1.bytes } - (entries[key]?.bytes ?? 0) + bytes
        guard bytes <= Self.maximumDraftBytes, total <= Self.maximumBytes else { lastIssue = (key, .textCapacity); return false }
        guard text.isEmpty || entries[key] != nil || entries.count < Self.maximumConversations else {
            lastIssue = (key, .conversationCapacity); return false
        }
        if text.isEmpty { entries.removeValue(forKey: key) }
        else { entries[key] = Entry(text: text, revision: UUID(), bytes: bytes) }
        if lastIssue?.0 == key { lastIssue = nil }
        return true
    }
    func capture(for target: PiChatTarget, commandID: UUID = UUID(), operation: PiChatOperation = .sendMessage) -> Submission? {
        let key = Conversation(target)
        guard operation == .sendMessage || operation == .sendSteeringMessage else { return nil }
        if lastIssue?.0 == key, lastIssue?.1 == .textCapacity || lastIssue?.1 == .conversationCapacity { return nil }
        guard let entry = entries[key] else { lastIssue = (key, .invalidMessage); return nil }
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PiProtocolValidator.validMessageText(text) else { lastIssue = (key, .invalidMessage); return nil }
        guard submissions[commandID] == nil, submissions.count < Self.maximumConversations,
              !submissions.values.contains(where: { Conversation($0.target) == key }) else {
            lastIssue = (key, .pendingSubmission); return nil
        }
        submissions[commandID] = Captured(target: target, revision: entry.revision, operation: operation)
        if lastIssue?.0 == key { lastIssue = nil }
        return Submission(target: target, commandID: commandID, revision: entry.revision, text: text, operation: operation)
    }

    /// A receipt never clears later edits, including equal-looking ABA edits.
    /// Unknown outcomes retain the exact capture and cannot authorize another send.
    @discardableResult func resolve(commandID: UUID, target: PiChatTarget, outcome: Outcome) -> Bool {
        guard let captured = submissions[commandID] else { return true }
        guard captured.target == target else { return false }
        guard outcome != .unknown else { return true }
        let key = Conversation(captured.target)
        if outcome == .dispatched && entries[key]?.revision == captured.revision { entries.removeValue(forKey: key) }
        submissions.removeValue(forKey: commandID)
        if lastIssue?.0 == key, lastIssue?.1 == .pendingSubmission { lastIssue = nil }
        return true
    }
}
