import AxoProtocol
import Foundation

@main struct ToolOutputChecks {
    @MainActor static func main() throws {
        let source = try makeSource(entryID: "entry-one", callID: "tool-one")
        let other = try makeSource(entryID: "entry-two", callID: "tool-two")
        let reader = AxodToolOutput()
        let initial = reader.open(source)!
        precondition(reader.open(other) == nil && reader.source == source)
        reader.close()
        precondition(reader.isLoading && reader.source == nil)
        reader.complete(initial, page: try page(initial, text: "a", total: 3))
        precondition(!reader.isLoading && reader.source == nil && reader.page == nil)

        let first = reader.open(source)!
        let original = try page(first, text: "λ", total: 5)
        reader.complete(first, page: original)
        let next = reader.begin(.next)!
        reader.fail(next)
        precondition(reader.page == original && reader.previousOffsets.isEmpty && reader.issue == .failed)
        let retry = reader.begin(.next)!
        reader.complete(retry, page: try page(retry, text: "界", total: 5))
        precondition(reader.page?.offset == 2 && reader.page?.nextOffset == nil && reader.previousOffsets == [0])
        let back = reader.begin(.previous)!
        reader.complete(back, page: try page(back, text: "λ", total: 5))
        precondition(reader.page == original && reader.previousOffsets.isEmpty)
        let changed = reader.begin(.next)!
        reader.complete(changed, page: try page(changed, text: "界", total: 6))
        precondition(reader.page == original && reader.issue == .changed && !reader.canGoForward)
        precondition(reader.begin(.first) == nil)
        reader.close()

        let bounded = reader.open(source)!
        reader.complete(bounded, page: try page(bounded, text: "a", total: 514))
        for _ in 0..<AxodToolOutput.maximumPreviousPages {
            let ticket = reader.begin(.next)!
            reader.complete(ticket, page: try page(ticket, text: "a", total: 514))
        }
        precondition(reader.previousOffsets.count == 512 && reader.isAtPositionLimit && !reader.canGoForward)
        precondition(reader.page?.text.utf8.count == 1 && reader.begin(.next) == nil && reader.issue == .capacity)
        let previous = reader.begin(.previous)!
        reader.complete(previous, page: try page(previous, text: "a", total: 514))
        precondition(reader.previousOffsets.count == 511 && reader.canGoForward)
        let retained = reader.page
        let late = reader.begin(.next)!
        reader.invalidateSource()
        reader.complete(late, page: try page(late, text: "a", total: 514))
        precondition(reader.page == retained && reader.issue == .unavailable && !reader.isLoading && !reader.canGoBack)
        print("PASS: single-flight canonical tool reader, late close fences, exact UTF-8 paging, failed-read preservation, changed-total refusal and bounded backward positions")
    }

    private static func json<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
    @MainActor private static func makeSource(entryID: String, callID: String) throws -> AxodToolOutput.Source {
        let target = PiChatTarget(machineId: UUID(), hostGeneration: UUID(), workspaceId: nil, sessionId: UUID(),
            paneId: UUID(), runtimeHostGeneration: UUID(), runtimeGeneration: UUID(), chatId: UUID())
        let snapshotValue: JSONValue = .object(["hostGeneration": .string(target.hostGeneration.uuidString), "readMode": .string("live"),
            "target": try json(target), "admission": .string("ready"), "busy": .bool(false), "interactionId": .null,
            "uiWaits": .number(0), "question": .null, "recovery": .bool(false), "leafId": .null, "recentEntries": .array([]), "viewingCount": .number(0)])
        let snapshot = try PiProtocolValidator.chatGet(snapshotValue, target: target)
        let entryValue: JSONValue = .object(["entryId": .string(entryID), "parentId": .null, "timestamp": .string("2026-10-11T00:00:00Z"),
            "kind": .string("message"), "role": .string("toolResult"), "text": .string("preview"), "truncated": .bool(true),
            "toolCallId": .string(callID), "toolName": .string("bash"), "toolCalls": .array([])])
        let entry = try JSONDecoder().decode(PiCanonicalProjection.self, from: JSONEncoder().encode(entryValue))
        return AxodToolOutput.Source(entry: entry, snapshot: snapshot)!
    }
    @MainActor private static func page(_ ticket: AxodToolOutput.Ticket, text: String, total: Int) throws -> PiToolOutputResult {
        let next = ticket.offset + text.utf8.count
        let value: JSONValue = .object(["hostGeneration": .string(ticket.source.target.hostGeneration.uuidString),
            "readMode": .string(ticket.source.readMode.rawValue), "target": try json(ticket.source.target),
            "entryId": .string(ticket.source.entryID), "toolCallId": .string(ticket.source.toolCallID),
            "offset": .number(Double(ticket.offset)), "text": .string(text), "nextOffset": next < total ? .number(Double(next)) : .null,
            "totalBytes": .number(Double(total))])
        return try PiProtocolValidator.toolOutput(value, target: ticket.source.target, readMode: ticket.source.readMode,
            entryId: ticket.source.entryID, toolCallId: ticket.source.toolCallID, offset: ticket.offset)
    }
}
