import AxoProtocol
import Foundation

@main struct ChatHistoryWindowChecks {
    @MainActor static func main() throws {
        let target = PiChatTarget(machineId: UUID(), hostGeneration: UUID(), workspaceId: nil, sessionId: UUID(), paneId: UUID(),
            runtimeHostGeneration: UUID(), runtimeGeneration: UUID(), chatId: UUID())
        let window = AxodChatHistoryWindow()
        window.observe(try snapshot(target, leaf: "head-a"))
        let first = window.begin(.beginning, presentationID: window.presentationID)!
        let original = try page(first, leaf: "head-a", ids: [0, 1], more: true)
        window.complete(first, result: original)
        let firstPresentation = window.presentationID
        let next = window.begin(.next, presentationID: firstPresentation)!
        window.fail(next)
        precondition(window.page == original && window.previous.isEmpty && window.issue == .failed)
        let retry = window.begin(.next, presentationID: window.presentationID)!
        let following = try page(retry, leaf: "head-a", ids: [2, 3], more: true)
        window.complete(retry, result: following)
        precondition(window.page == following && window.previous.count == 1 && window.previous[0] == nil)
        let back = window.begin(.previous, presentationID: window.presentationID)!
        // A nil beginning cursor does not bind its reply's head. The window still must.
        window.complete(back, result: try page(back, leaf: "head-b", ids: [0, 1], more: true))
        precondition(window.page == following && window.issue == .headChanged && !window.canGoBack)
        precondition(window.begin(.next, presentationID: window.presentationID) == nil)
        window.observe(try snapshot(target, leaf: "head-b"))
        let reload = window.begin(.beginning, presentationID: window.presentationID)!
        window.complete(reload, result: try page(reload, leaf: "head-b", ids: [0, 1], more: true))
        precondition(window.issue == nil && window.previous.isEmpty)
        precondition(window.begin(.next, presentationID: firstPresentation) == nil)
        let cached = window.page
        let oversized = window.begin(.beginning, presentationID: window.presentationID)!
        window.complete(oversized, result: try page(oversized, leaf: "head-b", ids: Array(10..<60), more: false, text: String(repeating: "x", count: 2048), tools: true))
        precondition(window.page == cached && window.issue == .capacity)
        let late = window.begin(.beginning, presentationID: window.presentationID)!
        window.showRecent()
        precondition(window.isLoading && window.page == nil && window.mode == .recent)
        window.complete(late, result: try page(late, leaf: "head-b", ids: [0], more: true))
        precondition(!window.isLoading && window.page == nil && window.mode == .recent)

        let bounded = window.begin(.beginning, presentationID: window.presentationID)!
        window.complete(bounded, result: try page(bounded, leaf: "head-b", ids: [0], more: true))
        for id in 1...AxodChatHistoryWindow.maximumPreviousPages {
            let ticket = window.begin(.next, presentationID: window.presentationID)!
            window.complete(ticket, result: try page(ticket, leaf: "head-b", ids: [id], more: true))
        }
        precondition(window.previous.count == 128 && window.isAtPositionLimit && !window.canGoForward)
        precondition(window.begin(.next, presentationID: window.presentationID) == nil)
        let prior = window.begin(.previous, presentationID: window.presentationID)!
        window.complete(prior, result: try page(prior, leaf: "head-b", ids: [127], more: true))
        precondition(window.previous.count == 127 && window.canGoForward)
        window.observe(try snapshot(target, leaf: "head-c"))
        precondition(window.issue == .headChanged && !window.canGoForward && window.page != nil)
        print("PASS: bounded canonical history windows, nil-cursor head fence, failure/capacity preservation, exact previous cursors, rendered-page ABA refusal and late Recent settlement")
    }
    private static func json<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
    @MainActor private static func snapshot(_ target: PiChatTarget, leaf: String) throws -> PiChatSnapshot {
        let value: JSONValue = .object(["hostGeneration": .string(target.hostGeneration.uuidString), "readMode": .string("live"),
            "target": try json(target), "admission": .string("ready"), "busy": .bool(false), "interactionId": .null,
            "uiWaits": .number(0), "question": .null, "recovery": .bool(false), "leafId": .string(leaf), "recentEntries": .array([]), "viewingCount": .number(0)])
        return try PiProtocolValidator.chatGet(value, target: target)
    }
    @MainActor private static func page(_ ticket: AxodChatHistoryWindow.Ticket, leaf: String, ids: [Int], more: Bool, text: String = "canonical text", tools: Bool = false) throws -> PiChatHistoryResult {
        let entries: [JSONValue] = ids.map { id in .object(["entryId": .string("history-\(id)"), "parentId": .null,
            "timestamp": .string("2026-10-11T00:00:00Z"), "kind": .string("message"), "role": .string("user"),
            "text": .string(text), "truncated": .bool(false), "toolCallId": .null, "toolName": .null, "toolCalls": tools ? .array([.object(["id": .string("capacity-tool"), "name": .string("capacity-tool")])]) : .array([])]) }
        let next: JSONValue = more ? try json(PiHistoryCursor(target: ticket.source.target, readMode: ticket.source.readMode,
            leafId: leaf, after: "history-\(ids.last!)")) : .null
        let value: JSONValue = .object(["hostGeneration": .string(ticket.source.target.hostGeneration.uuidString),
            "readMode": .string(ticket.source.readMode.rawValue), "target": try json(ticket.source.target), "leafId": .string(leaf), "entries": .array(entries), "next": next])
        return try PiProtocolValidator.chatHistory(value, target: ticket.source.target, readMode: ticket.source.readMode, cursor: ticket.cursor)
    }
}
