import AxoProtocol
import Foundation
import Observation

/// Editable text is not canonical history or a replay queue. Logical scope
/// survives exact runtime resume; submission still captures current authority.
@MainActor @Observable final class AxodChatDrafts {
    struct Conversation: Hashable, Sendable {
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
        let operation: PiChatOperation
    }
    enum Outcome: Equatable { case dispatched, rejected, unknown }
    enum Issue: Equatable {
        case textCapacity, conversationCapacity, invalidMessage, pendingSubmission, storageUnavailable
        var message: String {
            switch self {
            case .textCapacity: "The local draft budget is full. Existing text was preserved; nothing was sent."
            case .conversationCapacity: "The local draft slots are full. Existing drafts were preserved; nothing was sent."
            case .invalidMessage: "Use nonempty plain text within Pi's supported bounds. Slash commands stay in Pi's terminal; the draft was preserved."
            case .pendingSubmission: "This conversation has an unresolved submission. Its text was preserved; nothing was resent."
            case .storageUnavailable: "Draft storage is unavailable or not ready. Existing text was preserved; nothing was sent."
            }
        }
    }
    private struct Entry: Equatable { let text: String; let revision: UUID; let bytes: Int }
    private struct Captured: Equatable { let target: PiChatTarget; let revision: UUID; let operation: PiChatOperation }
    private enum Storage: Equatable { case volatile, awaitingRoot, loading, ready, failed }
    private struct Save {
        let sequence: UInt64
        let drafts: [AxodChatDraftArchive.Draft]
        let pending: [AxodChatDraftArchive.Pending]
        let resolutions: [UUID: Outcome]
    }
    private enum Condition {
        case pending(UUID, Captured), resolved(UUID), sequence(UInt64)
    }
    private struct Waiter { let condition: Condition; let continuation: CheckedContinuation<Bool, Never> }
    nonisolated static let maximumConversations = 32
    nonisolated static let maximumDraftBytes = 65536
    nonisolated static let maximumBytes = 1048576
    private var entries: [Conversation: Entry] = [:]
    private var submissions: [UUID: Captured] = [:]
    private var lastIssue: (Conversation, Issue)?
    private var storage: Storage
    private var loaded = false
    private var quitting = false
    private(set) var quitMessage: String?
    private var parent: URL?
    private var worker: AxodDraftPersistence?
    private var queued: Save?
    private var pump: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var sequence: UInt64 = 0
    private var savedSequence: UInt64 = 0
    private var savedArchive: AxodChatDraftArchive?
    private var resolutions: [UUID: Outcome] = [:]
    private var waiters: [Waiter] = []
    #if AXO_DRAFT_PERSISTENCE_FIXTURE
    @ObservationIgnored var fixtureAfterLoad: (() async -> Void)?
    @ObservationIgnored var fixtureAfterSave: (() async -> Void)?
    func fixtureAwaitSave() async { if let pump { await pump.value } }
    #endif

    /// Volatile mode is explicit for pure local tests. Product coordinators
    /// require storage and cannot edit/send before a trusted load completes.
    init(requiresPersistence: Bool = false) { storage = requiresPersistence ? .awaitingRoot : .volatile }
    var canEdit: Bool { !quitting && (storage == .volatile || loaded) }
    var hasUnsavedChanges: Bool { storage != .volatile && sequence > savedSequence }
    var storageMessage: String? {
        switch storage {
        case .volatile: nil
        case .awaitingRoot, .loading: "Loading private local drafts. Stored data is not command authority."
        case .failed: "Draft storage could not be used safely. Existing data and local text were preserved; copy unsaved edits before quitting. Nothing will be sent."
        case .ready: pump == nil && queued == nil ? nil : "Saving local drafts…"
        }
    }
    var blocksAutomaticStartup: Bool { storage != .volatile && storage != .ready }
    func hasPending(machineID: UUID) -> Bool { submissions.values.contains { $0.target.machineId == machineID } }
    func pending(for target: PiChatTarget) -> AxodChatDraftArchive.Pending? {
        guard let item = submissions.first(where: { Conversation($0.value.target) == Conversation(target) }) else { return nil }
        return .init(commandID: item.key, target: item.value.target, revision: item.value.revision, operation: item.value.operation)
    }

    func openStorage(in parent: URL) async {
        guard storage != .volatile else { return }
        if let previous = self.parent {
            guard previous == parent else { failStorage(); return }
            if let loadTask { await loadTask.value }
            return
        }
        self.parent = parent; storage = .loading
        let worker = AxodDraftPersistence(parent: parent)
        self.worker = worker
        let task = Task { [weak self] in
            do {
                let archive = try await worker.load()
                #if AXO_DRAFT_PERSISTENCE_FIXTURE
                if let gate = self?.fixtureAfterLoad { await gate() }
                #endif
                guard let self, self.storage == .loading, self.parent == parent else { return }
                if let archive {
                    self.entries = Dictionary(uniqueKeysWithValues: archive.drafts.map {
                        ($0.conversation, Entry(text: $0.text, revision: $0.revision, bytes: $0.text.utf8.count))
                    })
                    self.submissions = Dictionary(uniqueKeysWithValues: archive.pending.map {
                        ($0.commandID, Captured(target: $0.target, revision: $0.revision, operation: $0.operation))
                    })
                }
                self.savedArchive = archive; self.loaded = true; self.storage = .ready
            } catch { self?.failStorage() }
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    subscript(text conversation: Conversation) -> String {
        get { entries[conversation]?.text ?? "" }
        set { edit(newValue, in: conversation) }
    }
    func text(for target: PiChatTarget) -> String { entries[Conversation(target)]?.text ?? "" }
    func issue(for target: PiChatTarget) -> Issue? {
        if storage != .volatile && storage != .ready { return .storageUnavailable }
        let key = Conversation(target)
        return lastIssue?.0 == key ? lastIssue?.1 : nil
    }
    @discardableResult func edit(_ text: String, for target: PiChatTarget) -> Bool { edit(text, in: Conversation(target)) }
    @discardableResult private func edit(_ text: String, in key: Conversation) -> Bool {
        guard canEdit else { lastIssue = (key, .storageUnavailable); return false }
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
        queueSave()
        return true
    }
    func capture(for target: PiChatTarget, commandID: UUID = UUID(), operation: PiChatOperation = .sendMessage) -> Submission? {
        let key = Conversation(target)
        guard !quitting, storage == .volatile || storage == .ready,
              operation == .sendMessage || operation == .sendSteeringMessage else { return nil }
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
        queueSave()
        return Submission(target: target, commandID: commandID, revision: entry.revision, text: text, operation: operation)
    }

    /// Local callers may resolve known no-send evidence without awaiting. Product
    /// receipt/hint clearing uses settle(), which waits for the storage boundary.
    func resolve(commandID: UUID, target: PiChatTarget, outcome: Outcome) {
        guard let captured = submissions[commandID], captured.target == target, outcome != .unknown else { return }
        if storage == .volatile { apply(commandID: commandID, captured: captured, outcome: outcome); return }
        resolutions[commandID] = outcome
        queueSave()
    }
    func settle(commandID: UUID, target: PiChatTarget, outcome: Outcome) async -> Bool {
        guard outcome != .unknown else { return true }
        if let captured = submissions[commandID], captured.target != target { return false }
        resolve(commandID: commandID, target: target, outcome: outcome)
        return await wait(for: .resolved(commandID))
    }
    func persist(_ submission: Submission) async -> Bool {
        await wait(for: .pending(submission.commandID, Captured(target: submission.target, revision: submission.revision, operation: submission.operation)))
    }
    func flush() async -> Bool { await wait(for: .sequence(sequence)) }
    func prepareToQuit() async -> Bool {
        quitMessage = nil
        quitting = true
        if lastIssue?.1 == .textCapacity || lastIssue?.1 == .conversationCapacity {
            quitting = false
            quitMessage = "Quit was cancelled: an editor replacement exceeded the draft budget. Existing text was preserved; copy unaccepted edits before quitting."
            return false
        }
        guard hasUnsavedChanges else { return true }
        let saved = await flush()
        if !saved {
            quitting = false
            quitMessage = "Quit was cancelled because local draft edits could not be saved safely. Existing text remains available; copy unsaved edits before closing the app."
        }
        return saved
    }

    private func queueSave() {
        guard storage != .volatile else { return }
        let next = sequence.addingReportingOverflow(1)
        guard !next.overflow else { failStorage(); return }
        sequence = next.partialValue
        guard storage == .ready else { return }
        let drafts = entries.compactMap { key, entry -> AxodChatDraftArchive.Draft? in
            let cleared = submissions.contains { command, captured in
                resolutions[command] == .dispatched && Conversation(captured.target) == key && captured.revision == entry.revision
            }
            return cleared ? nil : .init(conversation: key, revision: entry.revision, text: entry.text)
        }
        let pending = submissions.compactMap { command, captured -> AxodChatDraftArchive.Pending? in
            resolutions[command] == nil ? .init(commandID: command, target: captured.target, revision: captured.revision, operation: captured.operation) : nil
        }
        queued = Save(sequence: sequence, drafts: drafts, pending: pending, resolutions: resolutions)
        guard pump == nil, let worker else { return }
        pump = Task { [weak self] in
            guard let self else { return }
            while self.storage == .ready, let save = self.queued {
                self.queued = nil
                let archive: AxodChatDraftArchive
                do { archive = try await worker.save(drafts: save.drafts, pending: save.pending) }
                catch { self.failStorage(); break }
                #if AXO_DRAFT_PERSISTENCE_FIXTURE
                if let gate = self.fixtureAfterSave { await gate() }
                #endif
                guard self.storage == .ready else { break }
                self.savedSequence = save.sequence; self.savedArchive = archive
                for (command, outcome) in save.resolutions {
                    guard self.resolutions[command] == outcome, let captured = self.submissions[command] else { continue }
                    self.apply(commandID: command, captured: captured, outcome: outcome)
                    self.resolutions.removeValue(forKey: command)
                }
                self.resumeWaiters()
            }
            self.pump = nil
        }
    }
    private func apply(commandID: UUID, captured: Captured, outcome: Outcome) {
        let key = Conversation(captured.target)
        if outcome == .dispatched && entries[key]?.revision == captured.revision { entries.removeValue(forKey: key) }
        submissions.removeValue(forKey: commandID)
        if lastIssue?.0 == key, lastIssue?.1 == .pendingSubmission { lastIssue = nil }
    }
    private func result(for condition: Condition) -> Bool? {
        if storage == .volatile { return true }
        if storage != .ready { return false }
        switch condition {
        case .sequence(let required): return savedSequence >= required ? true : nil
        case .resolved(let command): return submissions[command] == nil ? true : nil
        case .pending(let command, let captured):
            guard submissions[command] == captured, resolutions[command] == nil else { return false }
            return savedArchive?.pending.contains { $0.commandID == command && $0.target == captured.target && $0.revision == captured.revision && $0.operation == captured.operation } == true ? true : nil
        }
    }
    private func wait(for condition: Condition) async -> Bool {
        if let result = result(for: condition) { return result }
        guard waiters.count < 64 else { return false }
        return await withCheckedContinuation { waiters.append(Waiter(condition: condition, continuation: $0)) }
    }
    private func resumeWaiters() {
        var remaining: [Waiter] = []
        for waiter in waiters {
            if let result = result(for: waiter.condition) { waiter.continuation.resume(returning: result) }
            else { remaining.append(waiter) }
        }
        waiters = remaining
    }
    private func failStorage() {
        storage = .failed; queued = nil
        resumeWaiters()
    }
}
