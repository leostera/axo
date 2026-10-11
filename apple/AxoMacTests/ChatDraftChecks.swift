import AxoProtocol
import Foundation

@main struct ChatDraftChecks {
    @MainActor static func main() {
        let machine = UUID(), workspace = UUID(), session = UUID(), pane = UUID(), chat = UUID()
        func target(machineID: UUID? = nil, workspaceID: UUID? = nil, sessionID: UUID? = nil,
                    paneID: UUID? = nil, chatID: UUID? = nil) -> PiChatTarget {
            PiChatTarget(machineId: machineID ?? machine, hostGeneration: UUID(), workspaceId: workspaceID ?? workspace,
                         sessionId: sessionID ?? session, paneId: paneID ?? pane, runtimeHostGeneration: UUID(),
                         runtimeGeneration: UUID(), chatId: chatID ?? chat)
        }
        let original = target(), resumed = target()
        let drafts = AxodChatDrafts()
        precondition(drafts.edit("  synthetic draft 🦊  ", for: original))
        precondition(drafts.text(for: resumed) == "  synthetic draft 🦊  ")
        for other in [target(machineID: UUID()), target(workspaceID: UUID()), target(sessionID: UUID()),
                      target(paneID: UUID()), target(chatID: UUID())] {
            precondition(drafts.text(for: other).isEmpty)
            precondition(drafts.edit("other synthetic draft", for: other))
        }
        let submission = drafts.capture(for: original)!
        precondition(submission.target == original && submission.text == "synthetic draft 🦊")
        drafts.resolve(commandID: submission.commandID, target: original, outcome: .unknown)
        precondition(drafts.capture(for: resumed) == nil)
        precondition(drafts.text(for: original) == "  synthetic draft 🦊  ")
        drafts.resolve(commandID: submission.commandID, target: resumed, outcome: .dispatched)
        precondition(drafts.text(for: original) == "  synthetic draft 🦊  ")
        drafts.resolve(commandID: UUID(), target: original, outcome: .dispatched)
        precondition(drafts.text(for: original) == "  synthetic draft 🦊  ")
        drafts.resolve(commandID: submission.commandID, target: original, outcome: .rejected)
        precondition(drafts.text(for: original) == "  synthetic draft 🦊  ")
        let accepted = drafts.capture(for: resumed)!
        drafts.resolve(commandID: accepted.commandID, target: resumed, outcome: .dispatched)
        precondition(drafts.text(for: original).isEmpty)

        // A late acknowledgement cannot erase edits, including equal-looking ABA.
        drafts.edit("first synthetic text", for: original)
        let stale = drafts.capture(for: original)!
        drafts.edit("second synthetic text", for: resumed)
        drafts.edit("first synthetic text", for: resumed)
        drafts.resolve(commandID: stale.commandID, target: original, outcome: .dispatched)
        precondition(drafts.text(for: original) == "first synthetic text")
        let fresh = drafts.capture(for: original)!
        drafts.resolve(commandID: fresh.commandID, target: original, outcome: .dispatched)
        precondition(drafts.text(for: original).isEmpty)
        drafts.edit(" \n ", for: original)
        precondition(drafts.capture(for: original) == nil)
        drafts.edit(String(repeating: "x", count: PiProtocolValidator.maximumMessageBytes + 1), for: original)
        precondition(drafts.capture(for: original) == nil)
        precondition(drafts.text(for: original).utf8.count == PiProtocolValidator.maximumMessageBytes + 1)
        precondition(!drafts.edit(String(repeating: "x", count: AxodChatDrafts.maximumDraftBytes + 1), for: original))
        precondition(drafts.text(for: original).utf8.count == PiProtocolValidator.maximumMessageBytes + 1)
        precondition(drafts.capture(for: original) == nil)
        drafts.edit("valid original synthetic body", for: original)
        precondition(!drafts.edit(String(repeating: "x", count: AxodChatDrafts.maximumDraftBytes + 1), for: original))
        precondition(drafts.capture(for: original) == nil)
        drafts.edit("valid original synthetic body", for: original)
        let restoredEditor = drafts.capture(for: original)!
        drafts.resolve(commandID: restoredEditor.commandID, target: original, outcome: .rejected)

        let slots = AxodChatDrafts()
        for _ in 0..<AxodChatDrafts.maximumConversations { precondition(slots.edit("slot", for: target(chatID: UUID()))) }
        precondition(!slots.edit("refused", for: original))
        precondition(slots.issue(for: original) == .conversationCapacity)
        let bytes = AxodChatDrafts()
        let large = String(repeating: "🦊", count: AxodChatDrafts.maximumDraftBytes / 4)
        for _ in 0..<(AxodChatDrafts.maximumBytes / AxodChatDrafts.maximumDraftBytes) {
            precondition(bytes.edit(large, for: target(chatID: UUID())))
        }
        precondition(!bytes.edit("refused", for: original))
        precondition(bytes.issue(for: original) == .textCapacity)
        precondition(bytes.issue(for: target(chatID: UUID())) == nil)
        let nilID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        func parsed(_ operation: PiChatOperation, interaction: UUID? = nil,
                    question: UUID? = nil, option: UUID? = nil, text: String? = nil) -> AxodPiMutationRequest? {
            try? AxodPiMutationRequest(target: original, commandID: UUID(), operation: operation,
                                      interactionID: interaction, questionID: question, optionID: option, text: text)
        }
        precondition(parsed(.sendMessage, text: "synthetic plain message")?.method == AxoProtocol.Method.sendChatMessage)
        precondition(parsed(.sendMessage, text: " /new") == nil)
        precondition(parsed(.sendMessage, text: " ") == nil)
        let escaped = String(repeating: "\"", count: 40000)
        precondition(PiProtocolValidator.validMessageText(escaped))
        precondition(parsed(.sendMessage, text: escaped) == nil)
        precondition(parsed(.sendMessage, text: String(repeating: "x", count: PiProtocolValidator.maximumMessageBytes)) != nil)
        precondition(parsed(.sendSteeringMessage, text: "synthetic steering") == nil)
        precondition(parsed(.sendSteeringMessage, interaction: nilID, text: "synthetic steering") == nil)
        precondition(parsed(.sendSteeringMessage, interaction: UUID(), text: "synthetic steering") != nil)
        precondition(parsed(.cancelTurn, interaction: nilID) == nil)
        precondition(parsed(.cancelTurn, interaction: UUID()) != nil)
        precondition(parsed(.answerQuestion, interaction: UUID(), question: UUID()) == nil)
        precondition(parsed(.answerQuestion, interaction: UUID(), question: UUID(), option: nilID) == nil)
        precondition(parsed(.answerQuestion, interaction: UUID(), question: UUID(), option: UUID()) != nil)
        precondition(parsed(.setViewing) == nil)
        print("PASS bounded conversation-scoped draft identity, exact resume, receipt/unknown rejection, ABA and capacity checks")
        print("PASS closed Pi mutation preflight: plain text, exact interactions, zero IDs and encoded frame capacity")
    }
}
