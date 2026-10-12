import AxoProtocol
import SwiftUI

/// Bindings capture the rendered conversation, not the coordinator's selection
/// at the time a delayed editor callback happens to arrive.
struct AxodChatComposer: View {
    let snapshot: PiChatSnapshot
    let coordinator: AxodWorkbenchCoordinator
    @Bindable var drafts: AxodChatDrafts

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(snapshot.busy ? "Steer the active Pi interaction…" : "Send a message to Pi…",
                          text: $drafts[text: AxodChatDrafts.Conversation(snapshot.target)], axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(9)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
                    // Editing remains local even while a command/question is
                    // pending. Submit is fenced separately; this is no outbox.
                    .onSubmit(submit)
                if snapshot.busy, snapshot.interactionId != nil {
                    Button("Cancel") { coordinator.cancelChatTurn(snapshot: snapshot) }
                        .disabled(coordinator.pendingChatCommandId != nil || coordinator.isSendingPiMessage)
                }
                Button(snapshot.busy ? "Steer" : "Send", action: submit)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(unavailable || drafts.issue(for: snapshot.target) != nil || coordinator.connectionState != .connected ||
                              drafts.text(for: snapshot.target).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let issue = drafts.issue(for: snapshot.target) {
                Text(issue.message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .padding(10)
        .background(Color.black.opacity(0.14))
    }

    private var unavailable: Bool {
        snapshot.readMode != .live || snapshot.recovery || snapshot.uiWaits > 0 || snapshot.question != nil ||
        coordinator.pendingChatCommandId != nil || coordinator.isSendingPiMessage
    }
    private func submit() { coordinator.submitChatDraft(snapshot: snapshot) }
}
