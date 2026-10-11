import AxoProtocol
import Foundation
import Observation

/// A bounded canonical page, not an accumulated transcript or inferred branch.
@MainActor @Observable
final class AxodChatHistoryWindow {
    static let maximumPreviousPages = 128
    static let maximumPageBytes = 128 * 1024
    static let maximumRecentBytes = 64 * 1024
    struct Source: Equatable { let target: PiChatTarget; let readMode: PiReadMode }
    enum Mode { case recent, page }
    enum Movement { case beginning, next, previous }
    enum Issue: String {
        case headChanged = "Pi's canonical head changed. This captured page was kept; reload the beginning or choose Recent before paging."
        case failed = "This history page could not be read. Any previous page was kept. Retry the navigation explicitly."
        case unavailable = "The captured conversation is no longer selected or readable. No history was retargeted."
        case capacity = "The bounded history viewer reached its display or cursor-position budget. Canonical history was not removed."
    }
    fileprivate enum LeafExpectation { case current, exact(String?) }
    struct Ticket {
        let id = UUID()
        let source: Source
        let cursor: PiHistoryCursor?
        fileprivate let generation: UUID
        fileprivate let snapshotEpoch: UUID
        fileprivate let leaf: LeafExpectation
        fileprivate let previous: [PiHistoryCursor?]
        var parameters: PiChatHistoryParameters {
            PiChatHistoryParameters(target: source.target, readMode: source.readMode, cursor: cursor)
        }
    }
    private(set) var source: Source?
    private(set) var mode: Mode = .recent
    private(set) var page: PiChatHistoryResult?
    private(set) var pageCursor: PiHistoryCursor?
    private(set) var previous: [PiHistoryCursor?] = []
    private(set) var issue: Issue?
    private(set) var presentationID = UUID()
    private var generation = UUID()
    private var snapshotEpoch = UUID()
    private var latestLeaf: String?
    private var active: Ticket?
    var isLoading: Bool { active != nil }
    var isAtPositionLimit: Bool { page?.next != nil && previous.count == Self.maximumPreviousPages }
    private var isFenced: Bool { issue == .headChanged || issue == .unavailable }
    var canGoBack: Bool { !isLoading && !isFenced && !previous.isEmpty }
    var canGoForward: Bool { !isLoading && !isFenced && page?.next != nil && !isAtPositionLimit }

    func observe(_ snapshot: PiChatSnapshot) {
        let source = Source(target: snapshot.target, readMode: snapshot.readMode)
        if self.source != source { close(); self.source = source }
        snapshotEpoch = UUID(); latestLeaf = snapshot.leafId
        if mode == .page, let page, page.leafId != snapshot.leafId { issue = .headChanged }
    }
    func showRecent() {
        generation = UUID(); mode = .recent; page = nil; pageCursor = nil; previous = []; issue = nil
        presentationID = UUID()
    }
    func close() {
        showRecent(); source = nil; latestLeaf = nil
        // Cancellation does not release the single-flight slot until the original read returns.
    }
    func invalidateSource() { generation = UUID(); issue = .unavailable }
    func begin(_ movement: Movement, presentationID: UUID) -> Ticket? {
        guard active == nil, self.presentationID == presentationID, let source else { return nil }
        var previous = self.previous
        let cursor: PiHistoryCursor?
        let leaf: LeafExpectation
        switch movement {
        case .beginning: cursor = nil; previous = []; leaf = .current
        case .next:
            guard !isFenced, let page, let next = page.next else { return nil }
            guard previous.count < Self.maximumPreviousPages else { issue = .capacity; return nil }
            cursor = next; leaf = .exact(page.leafId); previous.append(pageCursor)
        case .previous:
            guard !isFenced, let page, !previous.isEmpty else { return nil }
            cursor = previous.removeLast(); leaf = .exact(page.leafId)
        }
        let ticket = Ticket(source: source, cursor: cursor, generation: generation, snapshotEpoch: snapshotEpoch,
                            leaf: leaf, previous: previous)
        mode = .page; active = ticket; issue = nil
        return ticket
    }
    func complete(_ ticket: Ticket, result: PiChatHistoryResult) {
        guard settle(ticket) else { return }
        guard result.target == ticket.source.target, result.readMode == ticket.source.readMode else { issue = .unavailable; return }
        if case .exact(let leaf) = ticket.leaf, result.leafId != leaf { issue = .headChanged; return }
        guard result.entries.count <= 50, Self.fits(result.entries, bytes: Self.maximumPageBytes) else { issue = .capacity; return }
        page = result; pageCursor = ticket.cursor; previous = ticket.previous; presentationID = UUID()
        issue = snapshotEpoch != ticket.snapshotEpoch && latestLeaf != result.leafId ? .headChanged : nil
    }
    func fail(_ ticket: Ticket, issue: Issue = .failed) {
        guard settle(ticket) else { return }
        self.issue = issue
    }
    private func settle(_ ticket: Ticket) -> Bool {
        guard active?.id == ticket.id else { return false }
        active = nil
        return generation == ticket.generation && source == ticket.source
    }
    static func fits(_ entries: [PiCanonicalProjection], bytes: Int) -> Bool {
        var used = 0
        for entry in entries {
            // Include fixed record/optional-field overhead as well as every retained string.
            used += 512 + entry.entryId.utf8.count + (entry.parentId?.utf8.count ?? 0) + entry.timestamp.utf8.count +
                entry.kind.utf8.count + (entry.role?.utf8.count ?? 0) + entry.text.utf8.count +
                (entry.toolCallId?.utf8.count ?? 0) + (entry.toolName?.utf8.count ?? 0)
            for tool in entry.toolCalls { used += 128 + tool.id.utf8.count + tool.name.utf8.count }
            if used > bytes { return false }
        }
        return true
    }
}
