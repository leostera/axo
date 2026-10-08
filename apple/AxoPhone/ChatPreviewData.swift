#if DEBUG
import AxoCore
import Foundation

/// Opt-in UI-test/screenshot content. Never sent to the relay or used in release builds.
enum ChatPreviewData {
    static var enabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--axo-chat-preview") || arguments.contains("--axo-chat-preview-working")
    }
    static var showsActivity: Bool { ProcessInfo.processInfo.arguments.contains("--axo-chat-preview-working") }
    static let liveText = "I’m checking how cancellation should flow through the relay and into Pi’s active run."
    static let events = [
        AgentEvent(id: "preview-event-1", sequence: 1, timestamp: 0, category: .lifecycle,
                   name: "agent_start", anchorMessageId: "preview-user", summary: "Pi run started"),
        AgentEvent(id: "preview-event-2", sequence: 2, timestamp: 0, category: .assistant,
                   name: "assistant.thinking_start", anchorMessageId: "preview-user", summary: "Private reasoning block started; content withheld"),
        AgentEvent(id: "preview-event-3", sequence: 3, timestamp: 0, category: .tool,
                   name: "tool_execution_start", anchorMessageId: "preview-user", correlationId: "preview-tool-1",
                   summary: "bash started", detail: "{ command: npm test }"),
        AgentEvent(id: "preview-event-4", sequence: 4, timestamp: 0, category: .assistant,
                   name: "assistant.text_delta", summary: "Assistant text streamed", detail: "I’m checking how cancellation should flow through the relay."),
    ]
    static let activities = [
        AgentActivity(id: "preview-tool-1", toolName: "bash", summary: "{ command: npm test }", status: .running, output: "Running protocol and bridge tests…"),
        AgentActivity(id: "preview-tool-2", toolName: "read", summary: "{ path: bridge/extension.ts }", status: .completed, output: "Added live tool activity and steering delivery."),
    ]
    static let messages: [ConversationMessage] = {
        let records = [
            ["id": "preview-user", "role": "user", "text": "Can we make this feel a little more calm and focused?"],
            ["id": "preview-thinking", "role": "thinking", "text": "Thinking block · content not shared"],
            ["id": "preview-success", "role": "tool", "text": "{ command: npm test }", "toolName": "bash",
             "toolCallId": "preview-tool-1", "status": "completed", "output": "All protocol and bridge tests passed."],
            ["id": "preview-failure", "role": "tool", "text": "{ path: missing.txt }", "toolName": "read",
             "toolCallId": "preview-tool-3", "status": "failed", "output": "File not found"],
            ["id": "preview-assistant", "role": "assistant", "text": """
            Absolutely. Let’s give the conversation some room to breathe.

            ## A quieter place to work

            The chat should feel like a conversation, not a control panel. Your work stays front and center; the connection details are there when you need them.

            > Keep the context. Lose the clutter.

            A few small changes make a big difference:

            - **Readable responses.** Clear paragraphs, proper lists, and a little more space between ideas.
            - **One simple composer.** Type a thought, or tap the waveform to speak it. Dictated prompts send when transcription finishes.
            - **Quiet controls.** Connection settings live behind the menu instead of taking over the screen.

            **Still your Pi session.** Nothing about how your Mac runs the work has changed.
            """]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: records) else { return [] }
        return (try? JSONDecoder().decode([ConversationMessage].self, from: data)) ?? []
    }()
}
#endif
