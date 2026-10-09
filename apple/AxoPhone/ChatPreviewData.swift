#if DEBUG
import AxoCore
import Foundation

/// Opt-in UI-test/screenshot content. Never sent to the relay or used in release builds.
enum ChatPreviewData {
    static var enabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--axo-chat-preview") || arguments.contains("--axo-chat-preview-working")
            || arguments.contains("--axo-history-preview") || arguments.contains("--axo-live-history-preview") || arguments.contains("--axo-markdown-preview") || arguments.contains("--axo-files-preview") || arguments.contains("--axo-file-draft-preview")
    }
    static func newMessage() -> ConversationMessage? {
        let fields = ["id": UUID().uuidString, "role": "assistant", "text": "New synthetic message at the latest end."]
        guard let data = try? JSONSerialization.data(withJSONObject: fields) else { return nil }
        return try? JSONDecoder().decode(ConversationMessage.self, from: data)
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
        var records: [[String: Any]] = [
            ["id": "preview-user", "role": "user", "text": "Can we make this feel a little more calm and focused?"],
            ["id": "preview-thinking", "role": "thinking", "text": "Synthetic provider thinking text for the chat preview."],
            ["id": "preview-success", "role": "tool", "text": "npm test", "toolName": "bash",
             "toolCallId": "preview-tool-1", "status": "completed", "output": "All protocol and bridge tests passed.",
             "toolPresentation": ["kind": "shell", "title": "Bash"]],
            ["id": "preview-failure", "role": "tool", "text": "", "toolName": "read",
             "toolCallId": "preview-tool-3", "status": "failed", "output": "File not found",
             "toolPresentation": ["kind": "file", "title": "Read", "subtitle": "missing.txt"]],
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
        if ProcessInfo.processInfo.arguments.contains("--axo-markdown-preview") {
            records = [["id": "markdown-thinking", "role": "thinking", "text": "## Public thinking heading\n\nA **formatted** thought with `inline code`.\n\n- First public point\n- Second public point"],
                       ["id": "markdown-reply", "role": "assistant", "text": "## Response heading\n\nA **formatted** response with `inline code`.\n\n```swift\nlet safe = true\n```"]]
        }
        if ProcessInfo.processInfo.arguments.contains("--axo-history-preview") || ProcessInfo.processInfo.arguments.contains("--axo-live-history-preview") {
            records = (0..<60).map { ["id": "history-\($0)", "role": "user", "text": "Earlier message \($0): synthetic scroll fixture."] }
            records.append(["id": "latest-preview", "role": "user", "text": "LATEST MESSAGE"])
        }
        if ProcessInfo.processInfo.arguments.contains("--axo-files-preview") {
            records = [["id": "file-preview", "role": "user", "text": "Discuss this shared report", "attachments": [[
                "id": "00000000-0000-4000-8000-000000000001", "sessionId": "preview", "filename": "report.md",
                "mediaType": "text/markdown", "byteLength": 1234, "sha256": String(repeating: "a", count: 64),
                "origin": "host", "createdAt": 0, "state": "ready",
            ]]]]
        }
        for index in records.indices { records[index]["timestamp"] = Int64(Date().timeIntervalSince1970 * 1000) - 300_000 }
        guard let data = try? JSONSerialization.data(withJSONObject: records) else { return [] }
        return (try? JSONDecoder().decode([ConversationMessage].self, from: data)) ?? []
    }()
}
#endif
