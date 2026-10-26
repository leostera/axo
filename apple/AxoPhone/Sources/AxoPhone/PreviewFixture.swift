import AxoClient
import AxoPhoneModel
import AxoProtocol
import Foundation

/// Sample Macs and conversations for looking at the app in the simulator without signing in:
/// `AXO_PHONE_PREVIEW=1`. It exists only in simulator debug builds.
enum PreviewFixture {
  #if DEBUG && targetEnvironment(simulator)
    static var requested: Bool { ProcessInfo.processInfo.environment["AXO_PHONE_PREVIEW"] == "1" }

    static var menuOpen: Bool { ProcessInfo.processInfo.environment["AXO_PHONE_PREVIEW_MENU"] == "1" }
    /// Open this chat (1 is the first in the menu) instead of a blank one.
    static var chatOpen: Int? { ProcessInfo.processInfo.environment["AXO_PHONE_PREVIEW_CHAT"].flatMap(Int.init) }
    static var settingsOpen: Bool { ProcessInfo.processInfo.environment["AXO_PHONE_PREVIEW_SETTINGS"] == "1" }

    static let studio = UUID(uuidString: "18355f00-95fd-4c93-8586-a71a8a52bf73")!
    static let imac = UUID(uuidString: "28355f00-95fd-4c93-8586-a71a8a52bf73")!

    static var hosts: [RemoteHost] {
      func session(_ host: UUID, _ id: Int, _ name: String, _ emoji: String, _ workspace: String, status: String = "ready") -> String {
        #"{"hostId":"\#(host)","sessionId":\#(id),"name":"\#(name)","emoji":"\#(emoji)","workspaceName":"\#(workspace)","status":"\#(status)","hasAgent":true,"shells":[{"shellId":\#(id * 10)}],"layout":{"kind":"pane","shellId":\#(id * 10)},"updatedAt":"2026-10-16T00:00:00Z"}"#
      }
      let json = """
        {"hosts":[
        {"hostId":"\(studio)","hostGeneration":"c3b6da28-55c0-4bb0-ac04-dd458fd41a2b","label":"Studio","hostKind":"macos","status":"online","stale":false,"lastSeenAt":"2026-10-16T00:00:00Z","sessions":[\
        \(session(studio, 1, "Ship the remote Workbench", "🦀", "Axo", status: "working")),\
        \(session(studio, 2, "Fix the sidebar spacing", "🎨", "Axo")),\
        \(session(studio, 3, "Explain the relay", "📡", "Axo"))]},
        {"hostId":"\(imac)","hostGeneration":"d3b6da28-55c0-4bb0-ac04-dd458fd41a2b","label":"Old iMac","hostKind":"macos","status":"offline","stale":true,"lastSeenAt":"2026-10-15T00:00:00Z","sessions":[\
        \(session(imac, 5, "Photo library cleanup", "📷", "Home"))]}]}
        """
      return (try? JSONDecoder().decode(RemoteHostList.self, from: Data(json.utf8)).hosts) ?? []
    }

    static func events(for session: SessionID) -> [StoredPiEvent] {
      func raw(_ id: Int, _ message: String) -> StoredPiEvent {
        let json = #"{"id":\#(id),"streamId":"41c77dd7-f2dc-4e91-b481-1507b62ec118","sequence":\#(id),"name":"message.end","data":{"message":\#(message)},"receivedAt":1}"#
        return try! JSONDecoder().decode(StoredPiEvent.self, from: Data(json.utf8))
      }
      func message(_ id: Int, _ role: String, _ text: String) -> StoredPiEvent {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        let json = #"{"id":\#(id),"streamId":"41c77dd7-f2dc-4e91-b481-1507b62ec118","sequence":\#(id),"name":"message.end","data":{"message":{"role":"\#(role)","content":"\#(escaped)"}},"receivedAt":1}"#
        return try! JSONDecoder().decode(StoredPiEvent.self, from: Data(json.utf8))
      }
      if session == 2 { return [message(1, "user", "What's the plan?"), message(2, "assistant", "Yes. Here is the plan:\n\n# Plan\n1. Bring back the sliding **chats** menu\n2. Chat-first layout\n   - a rounded composer\n   - nothing else on screen\n3. Ship it\n\n> The old app is the reference.\n\n| Part | State |\n|---|---|\n| Menu | done |\n| Composer | in progress |\n\n---\n\nThe message box looks like this:\n\n```swift\nTextField(\"Message Axo\", text: $draft)\n    .padding(18)\n```\n\nI'll start with the menu.")] }
      guard session == 1 else { return [message(1, "user", "Hello"), message(2, "assistant", "Hi! What are we working on?")] }
      return [
        message(1, "user", "Can you make the phone app feel like the old one again?"),
        message(2, "assistant", "Yes. Here is the plan:\n\n# Plan\n1. Bring back the sliding **chats** menu\n2. Chat-first layout\n   - a rounded composer\n   - nothing else on screen\n3. Ship it\n\n> The old app is the reference.\n\n| Part | State |\n|---|---|\n| Menu | done |\n| Composer | in progress |\n\n---\n\nThe message box looks like this:\n\n```swift\nTextField(\"Message Axo\", text: $draft)\n    .padding(18)\n```\n\nI'll start with the menu."),
        message(3, "user", "Great, go ahead."),
        raw(7, #"{"role":"assistant","timestamp":1792810292069,"content":[{"type":"thinking","thinking":"I should check the repository first."},{"type":"text","text":"Let me look at the project."},{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"git status --short --branch"}},{"type":"toolCall","id":"c2","name":"read","arguments":{"path":"apple/AxoPhone/README.md"}},{"type":"toolCall","id":"c3","name":"bash","arguments":{"command":"false"}}]}"#),
        raw(8, #"{"role":"toolResult","toolCallId":"c1","content":[{"type":"text","text":"On branch main\n M apple/AxoPhone/Sources/AxoPhone/ChatMessageView.swift\n M apple/AxoPhone/Sources/AxoPhone/ConversationView.swift\n?? apple/AxoPhone/Sources/AxoPhone/ToolTranscriptView.swift\n M one\n M two\n M three"}],"isError":false}"#),
        raw(9, #"{"role":"toolResult","toolCallId":"c2","content":"Axo Phone, the iPhone client.","isError":false}"#),
        raw(10, #"{"role":"toolResult","toolCallId":"c3","content":"exit code 1","isError":true}"#),
        message(4, "assistant", "Done. Open the menu with the button at the top left, or swipe from the left edge."),
      ]
    }
  #else
    static var requested: Bool { false }
    static var menuOpen: Bool { false }
    static var chatOpen: Int? { nil }
    static var settingsOpen: Bool { false }
  #endif
}
