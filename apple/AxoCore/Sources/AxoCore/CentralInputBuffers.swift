import AxoProtocol
import Foundation
import Observation

/// Editing identity deliberately excludes host/runtime generations, but includes
/// the store: a replacement process may retain live editing, a new store may not.
public struct CentralEditingTarget: Hashable, Sendable {
    public let machineId: UUID
    public let storeGeneration: UUID
    public let workspaceId: UUID?
    public let sessionId: UUID
    public let paneId: UUID
    public let chatId: UUID
    public init(_ target: CentralPiBindingTarget) {
        machineId = target.source.machine.machineId; storeGeneration = target.source.storeGeneration
        workspaceId = target.workspaceId; sessionId = target.sessionId; paneId = target.paneId; chatId = target.chatId
    }
}
/// A delayed paste/transcription must still belong to this exact editing revision.
/// Neither this token nor pending submissions can be serialized or restored.
public struct CentralEditCapture: Equatable, Sendable {
    fileprivate let owner: UUID
    fileprivate let revision: UUID
    public let target: CentralEditingTarget
}
public struct CentralInputTicket: Equatable, Sendable {
    fileprivate let owner: UUID
    public let command: CentralPiCommandCapture
}
public enum CentralInputIssue: Error, Equatable, Sendable {
    case conversationCapacity, textCapacity, pendingCapacity, pendingSubmission
    case unavailable, invalidCapture, alreadySubmitted
}
public enum CentralInputResolution: Equatable, Sendable {
    case missing, unconfirmed, outcomeUnknown
    case dispatched(clearedEditing: Bool)
    case rejected(CentralPiRejection)
}
public enum CentralControlChoice: Equatable, Sendable {
    case cancel
    case answer(optionId: UUID)
}

/// One bounded in-memory editing owner, shared by native clients. No defaults,
/// files, draft registry, automatic retries or surface/process lifecycle effects.
@MainActor @Observable public final class CentralInputBuffers {
    public nonisolated static let maximumConversations = 32
    public nonisolated static let maximumTextBytes = 65_536
    public nonisolated static let maximumAggregateBytes = 1_048_576
    public nonisolated static let maximumPendingCaptures = 32
    private struct Entry { let text: String; let bytes: Int; let revision: UUID }
    private enum Phase { case reserved, awaitingOriginal }
    private struct Pending {
        let ticket: CentralInputTicket
        let editing: CentralEditCapture?
        var phase: Phase
    }
    private let owner = UUID()
    private var entries: [CentralEditingTarget: Entry] = [:]
    private var submissions: [UUID: Pending] = [:]
    private var rejectedEdits: Set<CentralEditingTarget> = []
    public init() {}
    public func text(for target: CentralEditingTarget) -> String { entries[target]?.text ?? "" }
    public var pendingTickets: [CentralInputTicket] {
        submissions.values.map(\.ticket).sorted { $0.command.commandId.uuidString < $1.command.commandId.uuidString }
    }
    public func hasPending(for target: CentralEditingTarget) -> Bool {
        submissions.values.contains { CentralEditingTarget($0.ticket.command.target) == target }
    }
    public func editingCapture(for target: CentralEditingTarget) throws -> CentralEditCapture {
        guard !rejectedEdits.contains(target) else { throw CentralInputIssue.unavailable }
        let entry = try reserveEditor(target)
        return CentralEditCapture(owner: owner, revision: entry.revision, target: target)
    }
    public func edit(_ text: String, in target: CentralEditingTarget) throws {
        let bytes = text.utf8.count
        let aggregate = entries.values.reduce(0) { $0 + $1.bytes } - (entries[target]?.bytes ?? 0) + bytes
        guard bytes <= Self.maximumTextBytes, aggregate <= Self.maximumAggregateBytes else {
            // The rendered editor may now differ from retained text. Neither a
            // stale send nor an old acknowledgement may act on that difference.
            if let previous = entries[target] {
                entries[target] = Entry(text: previous.text, bytes: previous.bytes, revision: UUID())
                rejectedEdits.insert(target)
            }
            throw CentralInputIssue.textCapacity
        }
        let previous = try reserveEditor(target)
        rejectedEdits.remove(target)
        guard !previous.text.utf8.elementsEqual(text.utf8) else { return }
        if text.isEmpty { entries.removeValue(forKey: target) }
        else { entries[target] = Entry(text: text, bytes: bytes, revision: UUID()) }
    }
    /// Returns false rather than overwriting edits made after asynchronous input
    /// was captured, including an empty -> text -> empty ABA transition.
    @discardableResult public func apply(_ text: String, matching capture: CentralEditCapture) throws -> Bool {
        guard capture.owner == owner, entries[capture.target]?.revision == capture.revision else { return false }
        try edit(text, in: capture.target)
        return true
    }
    private func reserveEditor(_ target: CentralEditingTarget) throws -> Entry {
        if let entry = entries[target] { return entry }
        guard entries.count < Self.maximumConversations else { throw CentralInputIssue.conversationCapacity }
        let entry = Entry(text: "", bytes: 0, revision: UUID())
        entries[target] = entry
        return entry
    }
    public func captureText(from observation: CentralResponse) throws -> CentralInputTicket {
        let (target, state) = try live(observation)
        guard !state.recovery, !state.pending, state.uiWaits == 0, state.question == nil else { throw CentralInputIssue.unavailable }
        let key = CentralEditingTarget(target)
        guard let entry = entries[key], !rejectedEdits.contains(key) else { throw CentralInputIssue.unavailable }
        let action: CentralPiAction
        if state.busy {
            guard let interaction = state.interactionId else { throw CentralInputIssue.unavailable }
            action = .steer(interactionId: interaction, text: entry.text)
        } else { action = .send(text: entry.text) }
        let command = try CentralRequest.capturePi(target: target, commandId: UUID(), expectedRevision: observation.revision, action: action)
        return try reserve(command, editing: CentralEditCapture(owner: owner, revision: entry.revision, target: key))
    }
    public func captureControl(_ choice: CentralControlChoice, from observation: CentralResponse) throws -> CentralInputTicket {
        let (target, state) = try live(observation)
        guard !state.recovery, let interaction = state.interactionId else { throw CentralInputIssue.unavailable }
        let action: CentralPiAction
        switch choice {
        case .cancel:
            guard state.busy else { throw CentralInputIssue.unavailable }
            action = .cancel(interactionId: interaction)
        case .answer(let option):
            guard let question = state.question, question.interactionId == interaction,
                  question.options.contains(where: { $0.id == option }) else { throw CentralInputIssue.unavailable }
            action = .answer(interactionId: interaction, questionId: question.id, optionId: option)
        }
        let command = try CentralRequest.capturePi(target: target, commandId: UUID(), expectedRevision: observation.revision, action: action)
        return try reserve(command, editing: nil)
    }
    private func live(_ response: CentralResponse) throws -> (CentralPiBindingTarget, CentralPiLiveState) {
        let target: CentralPiBindingTarget, state: CentralPiLiveState
        switch response.payload {
        case .piObservation(.live(let binding, let observed)), .piSnapshot(let binding, let observed): target = binding; state = observed
        default: throw CentralInputIssue.unavailable
        }
        guard response.source == target.source, target.runtime.hostGeneration == response.source.machine.hostGeneration else { throw CentralInputIssue.unavailable }
        return (target, state)
    }
    private func reserve(_ command: CentralPiCommandCapture, editing: CentralEditCapture?) throws -> CentralInputTicket {
        guard !hasPending(for: CentralEditingTarget(command.target)) else { throw CentralInputIssue.pendingSubmission }
        guard submissions.count < Self.maximumPendingCaptures else { throw CentralInputIssue.pendingCapacity }
        guard submissions[command.commandId] == nil else { throw CentralInputIssue.invalidCapture }
        let ticket = CentralInputTicket(owner: owner, command: command)
        submissions[command.commandId] = Pending(ticket: ticket, editing: editing, phase: .reserved)
        return ticket
    }
    /// The only dispatch-producing operation, once per ticket. Even failure or
    /// cancellation after this boundary is uncertain; it never remints a request.
    public func beginSubmission(_ ticket: CentralInputTicket) throws -> CentralRequest {
        var pending = try require(ticket)
        guard pending.phase == .reserved else { throw CentralInputIssue.alreadySubmitted }
        let request = try CentralRequest.submitPi(ticket.command)
        pending.phase = .awaitingOriginal
        submissions[ticket.command.commandId] = pending
        return request
    }
    /// Safe only before beginSubmission; no caller-supplied no-effect boolean.
    public func abandonBeforeSubmission(_ ticket: CentralInputTicket) throws {
        guard try require(ticket).phase == .reserved else { throw CentralInputIssue.alreadySubmitted }
        submissions.removeValue(forKey: ticket.command.commandId)
    }
    public func reconciliation(_ ticket: CentralInputTicket, source: CentralSource) throws -> CentralRequest {
        guard try require(ticket).phase == .awaitingOriginal else { throw CentralInputIssue.invalidCapture }
        return try CentralRequest.piCommand(source: source, capture: ticket.command)
    }
    @discardableResult public func acknowledgeSubmission(_ ticket: CentralInputTicket, result: JSONValue) throws -> CentralInputResolution {
        guard try require(ticket).phase == .awaitingOriginal else { throw CentralInputIssue.invalidCapture }
        return try acknowledgeSubmission(ticket, response: CentralRequest.submitPi(ticket.command).parseResult(result))
    }
    @discardableResult public func acknowledgeSubmission(_ ticket: CentralInputTicket, response: CentralResponse) throws -> CentralInputResolution {
        guard try require(ticket).phase == .awaitingOriginal, response.source == ticket.command.target.source else { throw CentralInputIssue.invalidCapture }
        return try acknowledge(ticket, response: response)
    }
    @discardableResult public func acknowledgeReconciliation(_ ticket: CentralInputTicket, source: CentralSource, result: JSONValue) throws -> CentralInputResolution {
        let request = try reconciliation(ticket, source: source)
        return try acknowledgeReconciliation(ticket, source: source, response: request.parseResult(result))
    }
    @discardableResult public func acknowledgeReconciliation(_ ticket: CentralInputTicket, source: CentralSource, response: CentralResponse) throws -> CentralInputResolution {
        let request = try reconciliation(ticket, source: source)
        guard response.source == request.source else { throw CentralInputIssue.invalidCapture }
        return try acknowledge(ticket, response: response)
    }
    private func require(_ ticket: CentralInputTicket) throws -> Pending {
        guard ticket.owner == owner, let pending = submissions[ticket.command.commandId], pending.ticket == ticket else { throw CentralInputIssue.invalidCapture }
        return pending
    }
    private func acknowledge(_ ticket: CentralInputTicket, response: CentralResponse) throws -> CentralInputResolution {
        guard case .piCommand(let original) = response.payload else { throw CentralInputIssue.invalidCapture }
        if let original {
            let capture = ticket.command
            guard original.target == capture.target, original.commandId == capture.commandId,
                  original.expectedRevision == capture.expectedRevision,
                  original.action == actionDescriptor(capture.action),
                  original.acceptedRevision.rawValue == capture.expectedRevision.rawValue + 1,
                  original.acceptedRevision <= response.revision else { throw CentralInputIssue.invalidCapture }
        }
        return try acknowledge(ticket, original: original)
    }
    private func actionDescriptor(_ action: CentralPiAction) -> CentralPiActionDescriptor {
        switch action {
        case .send: .send
        case .steer(let interactionId, _): .steer(interactionId: interactionId)
        case .cancel(let interactionId): .cancel(interactionId: interactionId)
        case .answer(let interactionId, let questionId, let optionId):
            .answer(interactionId: interactionId, questionId: questionId, optionId: optionId)
        }
    }
    private func acknowledge(_ ticket: CentralInputTicket, original: CentralPiOriginal?) throws -> CentralInputResolution {
        let pending = try require(ticket)
        guard let original else { return .missing }
        switch original.disposition {
        case .unconfirmed: return .unconfirmed
        case .outcomeUnknown: return .outcomeUnknown
        case .rejected(let reason):
            submissions.removeValue(forKey: ticket.command.commandId)
            return .rejected(reason)
        case .dispatched:
            var cleared = false
            if let editing = pending.editing, entries[editing.target]?.revision == editing.revision {
                entries.removeValue(forKey: editing.target)
                rejectedEdits.remove(editing.target)
                cleared = true
            }
            submissions.removeValue(forKey: ticket.command.commandId)
            return .dispatched(clearedEditing: cleared)
        }
    }
}
