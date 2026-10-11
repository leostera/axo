import AxoProtocol
import Foundation
import Observation

/// One explicit tool reader: one 8-KiB page, one in-flight read, bounded backward positions.
/// Dropping a presentation never drops canonical Pi data or grants execution permission.
@MainActor @Observable
final class AxodToolOutput {
    static let maximumPreviousPages = 512
    struct Source: Equatable {
        let target: PiChatTarget
        let readMode: PiReadMode
        let entryID: String
        let toolCallID: String

        init?(entry: PiCanonicalProjection, snapshot: PiChatSnapshot) {
            guard entry.role == "toolResult", let call = entry.toolCallId else { return nil }
            target = snapshot.target; readMode = snapshot.readMode
            entryID = entry.entryId; toolCallID = call
        }
    }
    enum Movement { case first, next, previous }
    enum Issue: String {
        case unavailable = "This recorded output is no longer in the selected conversation. Reopen it from the current history."
        case failed = "The canonical page could not be read. Any previously loaded page was kept; retry this read explicitly."
        case changed = "The recorded output changed between pages. The previous page was kept; close and reopen this entry."
        case capacity = "The bounded viewer has reached its page-position limit. Canonical output was not truncated or removed."
    }
    struct Ticket {
        let id = UUID()
        let source: Source
        let offset: Int
        fileprivate let generation: UUID
        fileprivate let previous: [Int]
        var parameters: PiToolOutputParameters {
            PiToolOutputParameters(target: source.target, readMode: source.readMode, entryId: source.entryID,
                                   toolCallId: source.toolCallID, offset: offset)
        }
    }
    private(set) var source: Source?
    private(set) var page: PiToolOutputResult?
    private(set) var issue: Issue?
    private(set) var previousOffsets: [Int] = []
    private var active: Ticket?
    private var generation = UUID()
    var isLoading: Bool { active != nil }
    private var isFenced: Bool { issue == .changed || issue == .unavailable }
    var isAtPositionLimit: Bool { page?.nextOffset != nil && previousOffsets.count == Self.maximumPreviousPages }
    var canGoBack: Bool { !isLoading && !isFenced && !previousOffsets.isEmpty }
    var canGoForward: Bool { !isLoading && !isFenced && page?.nextOffset != nil && !isAtPositionLimit }

    func open(_ source: Source) -> Ticket? {
        guard !isLoading else { return nil }
        generation = UUID(); self.source = source; page = nil; issue = nil; previousOffsets = []
        return begin(.first)
    }
    func close() {
        generation = UUID(); source = nil; page = nil; issue = nil; previousOffsets = []
        // Keep the active slot until its owning read settles; switching cannot multiply pending RPCs.
    }
    func invalidateSource() {
        generation = UUID(); issue = .unavailable
    }
    func begin(_ movement: Movement) -> Ticket? {
        guard active == nil, !isFenced, let source else { return nil }
        var previous = previousOffsets
        let offset: Int
        switch movement {
        case .first: offset = 0; previous = []
        case .next:
            guard let page, let next = page.nextOffset else { return nil }
            guard previous.count < Self.maximumPreviousPages else { issue = .capacity; return nil }
            previous.append(page.offset); offset = next
        case .previous:
            guard let last = previous.popLast() else { return nil }
            offset = last
        }
        let ticket = Ticket(source: source, offset: offset, generation: generation, previous: previous)
        active = ticket; issue = nil
        return ticket
    }
    func complete(_ ticket: Ticket, page incoming: PiToolOutputResult) {
        guard settle(ticket) else { return }
        guard incoming.target == ticket.source.target, incoming.readMode == ticket.source.readMode,
              incoming.entryId == ticket.source.entryID, incoming.toolCallId == ticket.source.toolCallID,
              incoming.offset == ticket.offset, incoming.text.utf8.count <= PiProtocolValidator.maximumToolOutputBytes,
              page == nil || page?.totalBytes == incoming.totalBytes else { issue = .changed; return }
        page = incoming; previousOffsets = ticket.previous
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
}
