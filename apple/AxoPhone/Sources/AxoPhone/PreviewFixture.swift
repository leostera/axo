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
      func message(_ id: Int, _ role: String, _ text: String) -> StoredPiEvent {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        let json = #"{"id":\#(id),"streamId":"41c77dd7-f2dc-4e91-b481-1507b62ec118","sequence":\#(id),"name":"message.end","data":{"message":{"role":"\#(role)","content":"\#(escaped)"}},"receivedAt":1}"#
        return try! JSONDecoder().decode(StoredPiEvent.self, from: Data(json.utf8))
      }
      guard session == 1 else { return [message(1, "user", "Hello"), message(2, "assistant", "Hi! What are we working on?")] }
      return [
        message(1, "user", "Can you make the phone app feel like the old one again?"),
        message(2, "assistant", "Yes. Here is the plan:\n\n# Plan\n- Bring back the sliding **Sessions** menu\n- Chat-first layout with a rounded composer\n- Keep the terminal one tap away\n\nThe message box looks like this:\n\n```swift\nTextField(\"Message Axo\", text: $draft)\n    .padding(18)\n```\n\nI'll start with the menu."),
        message(3, "user", "Great, go ahead."),
        message(4, "assistant", "Done. Open the menu with the button at the top left, or swipe from the left edge."),
      ]
    }
  #else
    static var requested: Bool { false }
    static var menuOpen: Bool { false }
    static var settingsOpen: Bool { false }
  #endif
}
