import AxoProtocol
import Foundation
import XCTest
@testable import AxoCore

/// Metadata-only client state tests. Parsed fixtures do not claim real native
/// admission, PTY ownership, model delivery or editor/IME acceptance.
@MainActor final class CentralInputBufferTests: XCTestCase {
    private let machine = UUID(), host = UUID(), store = UUID(), session = UUID(), pane = UUID(), chat = UUID()
    private func json(_ value: Any) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func observed(chat: UUID? = nil, host: UUID? = nil, store: UUID? = nil, busy: Bool = false, question: [String: Any]? = nil, interaction: UUID? = nil, recovery: Bool = false) throws -> CentralResponse {
        let host = host ?? self.host, store = store ?? self.store
        let source = try CentralSource(machine: .init(machineId: machine, hostGeneration: host), storeGeneration: store)
        let request = try CentralRequest.observePi(source: source, workspaceId: nil, sessionId: session)
        let target: [String: Any] = ["machineId": machine.uuidString, "hostGeneration": host.uuidString, "storeGeneration": store.uuidString, "workspaceId": NSNull(), "sessionId": session.uuidString, "paneId": pane.uuidString, "chatId": (chat ?? self.chat).uuidString, "runtime": ["host_generation": host.uuidString, "runtime_generation": UUID().uuidString, "target": ["session_id": session.uuidString, "pane_id": pane.uuidString]]]
        let state: [String: Any] = ["title": NSNull(), "leafId": NSNull(), "busy": busy, "interactionId": interaction?.uuidString as Any? ?? NSNull(), "uiWaits": question == nil ? 0 : 1, "question": question as Any? ?? NSNull(), "pending": false, "recovery": recovery]
        return try request.parseResult(json(["hostGeneration": host.uuidString, "storeGeneration": store.uuidString, "revision": 4, "value": ["kind": "live", "target": target, "state": state]]))
    }
    private func key(_ response: CentralResponse) throws -> CentralEditingTarget {
        guard case .piObservation(.live(let target, _)) = response.payload else { throw CentralInputIssue.unavailable }
        return CentralEditingTarget(target)
    }
    private func result(_ ticket: CentralInputTicket, disposition: [String: Any], header: CentralSource? = nil, foreignChat: UUID? = nil) throws -> JSONValue {
        let capture = ticket.command, target = capture.target, source = target.source
        let runtime = try JSONSerialization.jsonObject(with: JSONEncoder().encode(target.runtime))
        let binding: [String: Any] = ["machineId": source.machine.machineId.uuidString, "hostGeneration": source.machine.hostGeneration.uuidString, "storeGeneration": source.storeGeneration.uuidString, "workspaceId": NSNull(), "sessionId": target.sessionId.uuidString, "paneId": target.paneId.uuidString, "chatId": (foreignChat ?? target.chatId).uuidString, "runtime": runtime]
        let action: [String: Any]
        switch capture.action {
        case .send: action = ["kind": "send"]
        case .steer(let interaction, _): action = ["kind": "steer", "interactionId": interaction.uuidString]
        case .cancel(let interaction): action = ["kind": "cancel", "interactionId": interaction.uuidString]
        case .answer(let interaction, let question, let option): action = ["kind": "answer", "interactionId": interaction.uuidString, "questionId": question.uuidString, "optionId": option.uuidString]
        }
        let body: [String: Any] = ["target": binding, "commandId": capture.commandId.uuidString, "expectedRevision": capture.expectedRevision.rawValue, "acceptedRevision": capture.expectedRevision.rawValue + 1, "configuration": ["paneRevision": 1, "sessionRevision": 2, "workspaceRevision": NSNull()], "action": action, "disposition": disposition]
        let header = header ?? source
        return try json(["hostGeneration": header.machine.hostGeneration.uuidString, "storeGeneration": header.storeGeneration.uuidString, "revision": 6, "value": body])
    }
    func testExactTextIsCapturedOnceAndOnlyUnchangedEditingIsCleared() async throws {
        let observed = try observed(), key = try key(observed), input = CentralInputBuffers()
        let text = "  Owned input λ界  "
        try input.edit(text, in: key)
        let delayed = try input.editingCapture(for: key)
        let ticket = try input.captureText(from: observed)
        XCTAssertEqual(ticket.command.action, .send(text: text))
        let request = try input.beginSubmission(ticket)
        XCTAssertEqual(request.commandId, ticket.command.commandId)
        XCTAssertThrowsError(try input.beginSubmission(ticket))
        XCTAssertThrowsError(try input.abandonBeforeSubmission(ticket))
        XCTAssertEqual(try input.acknowledgeSubmission(ticket, result: result(ticket, disposition: ["kind": "unconfirmed"])), .unconfirmed)
        XCTAssertThrowsError(try input.captureText(from: observed))
        XCTAssertEqual(try input.acknowledgeSubmission(ticket, result: result(ticket, disposition: ["kind": "dispatched"])), .dispatched(clearedEditing: true))
        XCTAssertEqual(input.text(for: key), "")
        XCTAssertFalse(try input.apply("Late transcript", matching: delayed))
        XCTAssertThrowsError(try input.beginSubmission(ticket))
        XCTAssertTrue(input.pendingTickets.isEmpty)
    }
    func testLaterAndEqualLookingABAEditsSurviveOldAcknowledgement() async throws {
        let observed = try observed(), key = try key(observed), input = CentralInputBuffers()
        try input.edit("Original", in: key)
        let ticket = try input.captureText(from: observed)
        _ = try input.beginSubmission(ticket)
        try input.edit("Later", in: key); try input.edit("Original", in: key)
        XCTAssertEqual(try input.acknowledgeSubmission(ticket, result: result(ticket, disposition: ["kind": "dispatched"])), .dispatched(clearedEditing: false))
        XCTAssertEqual(input.text(for: key), "Original")
        let second = try input.captureText(from: observed)
        _ = try input.beginSubmission(second)
        try input.edit("é", in: key)
        let accent = try input.editingCapture(for: key)
        try input.edit("e\u{301}", in: key)
        XCTAssertEqual(Array(input.text(for: key).utf8), Array("e\u{301}".utf8))
        XCTAssertFalse(try input.apply("Late paste", matching: accent))
        XCTAssertEqual(try input.acknowledgeSubmission(second, result: result(second, disposition: ["kind": "dispatched"])), .dispatched(clearedEditing: false))
    }
    func testMissingUnknownAndForeignResultsNeverReleaseOrRetargetCapture() async throws {
        let observed = try observed(), key = try key(observed), input = CentralInputBuffers()
        try input.edit("Frozen original", in: key)
        let ticket = try input.captureText(from: observed)
        _ = try input.beginSubmission(ticket)
        XCTAssertEqual(try input.acknowledgeSubmission(ticket, result: result(ticket, disposition: ["kind": "outcomeUnknown"])), .outcomeUnknown)
        XCTAssertThrowsError(try input.acknowledgeSubmission(ticket, result: result(ticket, disposition: ["kind": "dispatched"], foreignChat: UUID())))
        let next = try self.observed(host: UUID())
        XCTAssertEqual(try self.key(next), key)
        XCTAssertThrowsError(try input.captureText(from: next))
        let lookup = try input.reconciliation(ticket, source: next.source)
        XCTAssertNil(lookup.commandId)
        XCTAssertEqual(lookup.method, "axo.state.chat.command.get")
        let missing = try json(["hostGeneration": next.source.machine.hostGeneration.uuidString, "storeGeneration": store.uuidString, "revision": 6, "value": NSNull()])
        XCTAssertEqual(try input.acknowledgeReconciliation(ticket, source: next.source, result: missing), .missing)
        XCTAssertEqual(input.text(for: key), "Frozen original")
        XCTAssertThrowsError(try input.beginSubmission(ticket))
        let reset = try self.observed(store: UUID())
        XCTAssertNotEqual(try self.key(reset), key)
        XCTAssertEqual(input.text(for: try self.key(reset)), "")
        XCTAssertThrowsError(try input.reconciliation(ticket, source: reset.source))
        XCTAssertEqual(try input.acknowledgeReconciliation(ticket, source: next.source, result: result(ticket, disposition: ["kind": "dispatched"], header: next.source)), .dispatched(clearedEditing: true))
    }
    func testRejectionPreservesTextAndAllowsOnlyANewExplicitCapture() async throws {
        let observed = try observed(), key = try key(observed), input = CentralInputBuffers()
        try input.edit("Rejected input", in: key)
        let ticket = try input.captureText(from: observed)
        _ = try input.beginSubmission(ticket)
        XCTAssertEqual(try input.acknowledgeSubmission(ticket, result: result(ticket, disposition: ["kind": "rejected", "reason": "busy"])), .rejected(.busy))
        XCTAssertEqual(input.text(for: key), "Rejected input")
        let next = try input.captureText(from: observed)
        XCTAssertNotEqual(next.command.commandId, ticket.command.commandId)
        XCTAssertThrowsError(try input.beginSubmission(ticket))
    }
    func testRejectedEditFencesStaleSendAndOldAcknowledgementUntilResynchronized() async throws {
        let observed = try observed(), key = try key(observed), input = CentralInputBuffers()
        try input.edit("Retained", in: key)
        let ticket = try input.captureText(from: observed)
        _ = try input.beginSubmission(ticket)
        XCTAssertThrowsError(try input.edit(String(repeating: "x", count: 65537), in: key))
        XCTAssertEqual(input.text(for: key), "Retained")
        XCTAssertEqual(try input.acknowledgeSubmission(ticket, result: result(ticket, disposition: ["kind": "dispatched"])), .dispatched(clearedEditing: false))
        XCTAssertThrowsError(try input.captureText(from: observed))
        try input.edit("Retained", in: key)
        _ = try input.captureText(from: observed)
    }
    func testDelayedPasteAndVoiceEditsRequireExactLogicalRevisionIncludingEmptyABA() async throws {
        let observed = try observed(), key = try key(observed), input = CentralInputBuffers()
        let empty = try input.editingCapture(for: key)
        try input.edit("Typed", in: key); try input.edit("", in: key)
        XCTAssertFalse(try input.apply("Late voice result", matching: empty))
        let current = try input.editingCapture(for: key)
        XCTAssertTrue(try input.apply("Pasted text", matching: current))
        XCTAssertFalse(try input.apply("Other delayed result", matching: current))
        XCTAssertEqual(input.text(for: key), "Pasted text")
    }
    func testQuotasRejectWithoutEvictionTruncationOrStaleSubmission() async throws {
        let slots = CentralInputBuffers()
        var first: CentralEditingTarget?
        for _ in 0..<32 {
            let key = try key(observed(chat: UUID()))
            first = first ?? key
            try slots.edit("Slot", in: key)
        }
        XCTAssertThrowsError(try slots.edit("Overflow", in: key(observed(chat: UUID()))))
        XCTAssertEqual(slots.text(for: try XCTUnwrap(first)), "Slot")
        let bytes = CentralInputBuffers(), large = String(repeating: "🦊", count: 16384)
        for _ in 0..<16 { try bytes.edit(large, in: key(observed(chat: UUID()))) }
        XCTAssertThrowsError(try bytes.edit("Overflow", in: key(observed(chat: UUID()))))
        let bounded = CentralInputBuffers(), observed = try observed(), key = try key(observed)
        try bounded.edit(large, in: key)
        XCTAssertThrowsError(try bounded.captureText(from: observed), "Full transport overhead is bounded before a pending capture exists")
        XCTAssertTrue(bounded.pendingTickets.isEmpty)
        XCTAssertEqual(bounded.text(for: key), large)
    }
    func testControlsUseObservedInteractionAndOptionWithoutClearingEditing() async throws {
        let interaction = UUID(), question = UUID(), option = UUID()
        let busy = try observed(busy: true, interaction: interaction), input = CentralInputBuffers(), key = try key(busy)
        try input.edit("Keep this unsent text", in: key)
        let cancel = try input.captureControl(.cancel, from: busy)
        XCTAssertEqual(cancel.command.action, .cancel(interactionId: interaction))
        _ = try input.beginSubmission(cancel)
        XCTAssertEqual(try input.acknowledgeSubmission(cancel, result: result(cancel, disposition: ["kind": "dispatched"])), .dispatched(clearedEditing: false))
        XCTAssertEqual(input.text(for: key), "Keep this unsent text")
        let asked = try observed(busy: true, question: ["id": question.uuidString, "interactionId": interaction.uuidString, "title": "Owned question", "options": [["id": option.uuidString, "label": "One"], ["id": UUID().uuidString, "label": "Two"]]], interaction: interaction)
        XCTAssertThrowsError(try input.captureControl(.answer(optionId: UUID()), from: asked))
        XCTAssertThrowsError(try input.captureText(from: asked))
        let answer = try input.captureControl(.answer(optionId: option), from: asked)
        XCTAssertEqual(answer.command.action, .answer(interactionId: interaction, questionId: question, optionId: option))
        _ = try input.beginSubmission(answer)
        _ = try input.acknowledgeSubmission(answer, result: result(answer, disposition: ["kind": "dispatched"]))
        XCTAssertEqual(input.text(for: key), "Keep this unsent text")
    }
    func testSteeringAndUnavailableObservationsDoNotManufactureAdmission() async throws {
        let interaction = UUID(), input = CentralInputBuffers()
        let busy = try observed(busy: true, interaction: interaction), key = try key(busy)
        try input.edit("Exact steering text", in: key)
        let ticket = try input.captureText(from: busy)
        XCTAssertEqual(ticket.command.action, .steer(interactionId: interaction, text: "Exact steering text"))
        try input.abandonBeforeSubmission(ticket)
        XCTAssertEqual(input.text(for: key), "Exact steering text")
        XCTAssertThrowsError(try input.captureText(from: observed(busy: true)))
        XCTAssertThrowsError(try input.captureText(from: observed(recovery: true)))
        let request = try CentralRequest.observePi(source: busy.source, workspaceId: nil, sessionId: session)
        let absent = try request.parseResult(json(["hostGeneration": host.uuidString, "storeGeneration": store.uuidString, "revision": 4, "value": ["kind": "notAdmitted"]]))
        XCTAssertThrowsError(try input.captureText(from: absent))
        XCTAssertTrue(input.pendingTickets.isEmpty)
    }
    func testAcknowledgedBuffersReleaseSlotsWithoutRevalidatingOldAsyncEdits() async throws {
        let input = CentralInputBuffers()
        for _ in 0..<33 {
            let observed = try observed(chat: UUID()), key = try key(observed)
            try input.edit("Owned slot", in: key)
            let delayed = try input.editingCapture(for: key)
            let ticket = try input.captureText(from: observed)
            _ = try input.beginSubmission(ticket)
            XCTAssertEqual(try input.acknowledgeSubmission(ticket, result: result(ticket, disposition: ["kind": "dispatched"])), .dispatched(clearedEditing: true))
            XCTAssertFalse(try input.apply("Delayed result", matching: delayed))
        }
    }
    func testPendingQuotaAndOwnerIncarnationCannotBeBypassed() async throws {
        let input = CentralInputBuffers(), interaction = UUID()
        for _ in 0..<32 { _ = try input.captureControl(.cancel, from: observed(chat: UUID(), busy: true, interaction: interaction)) }
        XCTAssertThrowsError(try input.captureControl(.cancel, from: observed(chat: UUID(), busy: true, interaction: interaction)))
        let ticket = try XCTUnwrap(input.pendingTickets.first)
        let recreated = CentralInputBuffers()
        XCTAssertThrowsError(try recreated.beginSubmission(ticket))
        XCTAssertTrue(recreated.pendingTickets.isEmpty)
        XCTAssertEqual(recreated.text(for: CentralEditingTarget(ticket.command.target)), "")
        try input.abandonBeforeSubmission(ticket)
        XCTAssertThrowsError(try input.beginSubmission(ticket))
        _ = try input.captureControl(.cancel, from: observed(chat: UUID(), busy: true, interaction: interaction))
    }
}
