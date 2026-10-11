import AxoProtocol
import Foundation
import Observation

/// Local editable text, never a Pi transcript, receipt or replay queue. Logical
/// conversation identity survives exact runtime resume; dispatch still captures
/// the complete current PiChatTarget separately. Persistence remains a separate
/// owning slice; this bounded cache protects in-process selection/reconnect.
@MainActor @Observable
final class AxodChatDrafts {
    struct Conversation: Hashable {
        let machineID: UUID
        let workspaceID: UUID?
        let sessionID: UUID
        let paneID: UUID
        let chatID: UUID
        init(machineID: UUID, workspaceID: UUID?, sessionID: UUID, paneID: UUID, chatID: UUID) {
            self.machineID = machineID; self.workspaceID = workspaceID; self.sessionID = sessionID
            self.paneID = paneID; self.chatID = chatID
        }
        init(_ target: PiChatTarget) {
            self.init(machineID: target.machineId, workspaceID: target.workspaceId, sessionID: target.sessionId,
                      paneID: target.paneId, chatID: target.chatId)
        }
    }
    struct Submission {
        let target: PiChatTarget
        let commandID: UUID
        let revision: UUID
        let text: String
    }
    enum Outcome { case dispatched, rejected, unknown }
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
    private struct Entry: Equatable {
        let text: String
        let revision: UUID
        let bytes: Int
    }
    private struct Captured: Equatable { let target: PiChatTarget; let revision: UUID }
    static let maximumConversations = 32
    static let maximumDraftBytes = 65536
    static let maximumBytes = 1048576
    private var entries: [Conversation: Entry] = [:]
    private var submissions: [UUID: Captured] = [:]
    private var lastIssue: (Conversation, Issue)?

    subscript(text conversation: Conversation) -> String {
        get { entries[conversation]?.text ?? "" }
        set { edit(newValue, in: conversation) }
    }

    func text(for target: PiChatTarget) -> String { entries[Conversation(target)]?.text ?? "" }
    func issue(for target: PiChatTarget) -> Issue? {
        let key = Conversation(target)
        guard lastIssue?.0 == key else { return nil }
        return lastIssue?.1
    }

    @discardableResult
    func edit(_ text: String, for target: PiChatTarget) -> Bool {
        edit(text, in: Conversation(target))
    }

    @discardableResult
    private func edit(_ text: String, in key: Conversation) -> Bool {
        if text == entries[key]?.text {
            if lastIssue?.0 == key { lastIssue = nil }
            return true
        }
        let bytes = text.utf8.count
        let total = entries.values.reduce(0) { $0 + $1.bytes } - (entries[key]?.bytes ?? 0) + bytes
        guard bytes <= Self.maximumDraftBytes, total <= Self.maximumBytes else {
            lastIssue = (key, .textCapacity); return false
        }
        guard text.isEmpty || entries[key] != nil || entries.count < Self.maximumConversations else {
            lastIssue = (key, .conversationCapacity); return false
        }
        if text.isEmpty { entries.removeValue(forKey: key) }
        else { entries[key] = Entry(text: text, revision: UUID(), bytes: bytes) }
        if lastIssue?.0 == key { lastIssue = nil }
        return true
    }

    func capture(for target: PiChatTarget, commandID: UUID = UUID()) -> Submission? {
        let key = Conversation(target)
        // A rejected editor write must not submit the older saved text while
        // the field editor may still display its unaccepted replacement.
        if lastIssue?.0 == key, lastIssue?.1 == .textCapacity || lastIssue?.1 == .conversationCapacity { return nil }
        guard let entry = entries[key] else { lastIssue = (key, .invalidMessage); return nil }
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PiProtocolValidator.validMessageText(text) else { lastIssue = (key, .invalidMessage); return nil }
        guard submissions[commandID] == nil, submissions.count < Self.maximumConversations,
              !submissions.values.contains(where: { Conversation($0.target) == key }) else {
            lastIssue = (key, .pendingSubmission); return nil
        }
        submissions[commandID] = Captured(target: target, revision: entry.revision)
        if lastIssue?.0 == key { lastIssue = nil }
        return Submission(target: target, commandID: commandID, revision: entry.revision, text: text)
    }

    /// Call only after validating the original immutable receipt/known no-effect
    /// boundary. Unknown evidence never clears text or permits another dispatch.
    func resolve(commandID: UUID, target: PiChatTarget, outcome: Outcome) {
        guard let captured = submissions[commandID], captured.target == target else { return }
        switch outcome {
        case .unknown: return
        case .rejected: break
        case .dispatched:
            let key = Conversation(target)
            if entries[key]?.revision == captured.revision { entries.removeValue(forKey: key) }
        }
        submissions.removeValue(forKey: commandID)
        if lastIssue?.0 == Conversation(target), lastIssue?.1 == .pendingSubmission { lastIssue = nil }
    }
}
