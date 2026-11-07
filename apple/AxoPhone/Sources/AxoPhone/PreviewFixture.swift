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
    static var settingsOpen: Bool { ProcessInfo.processInfo.environment["AXO_PHONE_PREVIEW_SETTINGS"] == "1" || appsOpen }
    /// Open Settings › Apps (`AXO_PHONE_PREVIEW_APPS=1`).
    static var appsOpen: Bool { ProcessInfo.processInfo.environment["AXO_PHONE_PREVIEW_APPS"] == "1" }
    /// Open the Macs and account panel (`AXO_PHONE_PREVIEW_HOSTS=1`).
    static var hostsOpen: Bool { ProcessInfo.processInfo.environment["AXO_PHONE_PREVIEW_HOSTS"] == "1" }
    /// Play a reply being written, a running tool and a question in the open chat
    /// (`AXO_PHONE_PREVIEW_LIVE=reply|question|stopping`).
    static var live: String? { ProcessInfo.processInfo.environment["AXO_PHONE_PREVIEW_LIVE"] }
    /// Note where the conversation layer is at every frame, in this file
    /// (`AXO_PHONE_PREVIEW_MOTION=path`, for AxoPhoneMotionTests).
    static let motionLog = ProcessInfo.processInfo.environment["AXO_PHONE_PREVIEW_MOTION"].flatMap { LayerMotionLog(path: $0) }
    static let account = SignedInAccount(
      accountId: UUID(uuidString: "6b0f0e0e-2c43-4b8e-9d0a-0d8f7b2b9c11")!,
      profile: .init(email: "leandro@example.com", name: "Leandro"))

    static func liveEvents(_ kind: String) -> [PreviewStep] {
      var steps: [PreviewStep] = [
        .working(true),
        .record(#"{"role":"user","content":"Run the tests and tell me what fails."}"#),
        .record(#"{"role":"assistant","content":[{"type":"text","text":"Running them now."},{"type":"toolCall","id":"t1","name":"bash","arguments":{"command":"swift test"}}]}"#),
        .progress("t1", #"{"toolCallId":"t1","partialResult":{"content":[{"type":"text","text":"Building for debugging...\nCompiling AxoPhoneModel\nTest Suite 'All tests' started\nTest Case ChatTranscriptTests passed\nTest Case ScrollFollowTests passed\nTest Case HostWorkbenchLiveTests passed\nTest Case PhoneWorkbenchTests running"}]}}"#),
      ]
      switch kind {
      case "question":
        steps.append(.progress("question", #"{"kind":"confirm","title":"Delete the build folder first?"}"#))
      default:
        steps.append(.progress("message", #"{"message":{"role":"assistant","content":[{"type":"text","text":"So far **83 tests** pass. Still waiting on the"}]}}"#))
      }
      return steps
    }

    /// A reply written a little at a time, as the agent streams one (`AXO_PHONE_PREVIEW_LIVE=stream`):
    /// `steps` updates, each a few words longer, then the whole message.
    static func streamEvents(steps: Int) -> [PreviewStep] {
      let words = (1...steps).map { "word\($0)" }
      func text(_ count: Int) -> String {
        #"{"role":"assistant","content":[{"type":"text","text":"Streaming **now**: \#(words.prefix(count).joined(separator: " "))"}]}"#
      }
      var events: [PreviewStep] = [.working(true)]
      for step in 1...steps { events.append(.progress("message", #"{"message":\#(text(step))}"#)) }
      events.append(.record(text(steps)))
      events.append(.working(false))
      return events
    }

    /// Many whole replies landing quickly, each long and with a wide code block
    /// (`AXO_PHONE_PREVIEW_LIVE=flood`): what a busy agent sends while the phone is following.
    static func floodEvents(replies: Int) -> [PreviewStep] {
      func reply(_ number: Int) -> String {
        let words = Array(repeating: "and then the next step of the plan", count: 6).joined(separator: ", ")
        let code = "```swift\\nlet reply\(number) = Array(repeating: \\\"a line far wider than any phone screen could ever show at once\\\", count: \(number))\\n```"
        return #"{"role":"assistant","content":[{"type":"text","text":"Flood reply \#(number): \#(words).\\n\\n\#(code)"}]}"#
      }
      var events: [PreviewStep] = [.working(true)]
      for number in 1...replies { events.append(.record(reply(number))) }
      events.append(.working(false))
      return events
    }

    static let studio = UUID(uuidString: "18355f00-95fd-4c93-8586-a71a8a52bf73")!
    static let imac = UUID(uuidString: "28355f00-95fd-4c93-8586-a71a8a52bf73")!

    /// Preview chats are numbered; this is the Session ID of chat `number`.
    static func sessionID(_ number: Int) -> SessionID {
      SessionID(rawValue: String(format: "%08x-0000-4000-8000-%012x", number, number))!
    }

    /// The sample Macs and chats, as the account's socket lists them.
    static var listing: String {
      // The menu lists the most recently active first: in the order they are written here. Times
      // are relative to now, so the last 8 hours (what the menu lists before "older") stay put.
      func ago(_ seconds: TimeInterval) -> Int64 { Int64(Date.now.addingTimeInterval(-seconds).timeIntervalSince1970) }
      func session(_ host: UUID, _ id: Int, _ name: String, _ emoji: String, _ workspace: String, status: String = "ready", active: Int64) -> String {
        let host = host.uuidString.lowercased()
        // The Axo chats are in the repository, with a couple of files changed; Home is no repository.
        let path = workspace == "Axo" ? "/Users/leo/Developer/axo" : "/Users/leo"
        let state = workspace == "Axo"
          ? #"{"path":"\#(path)","repoRoot":"\#(path)","remote":"https://github.com/leostera/axo","branch":"main","head":"e71752e0c1d2b3a4f5e6d7c8b9a0f1e2d3c4b5a6","upstreamHead":"c22a4480c1d2b3a4f5e6d7c8b9a0f1e2d3c4b5a6","dirty":["apple/AxoPhone/BUILD.bazel","README.md"],"dirtyMore":0,"at":\#(active)}"#
          : #"{"path":"\#(path)","repoRoot":null,"remote":null,"branch":null,"head":null,"upstreamHead":null,"dirty":[],"dirtyMore":0,"at":\#(active)}"#
        return #"{"hostId":"\#(host)","sessionId":"\#(sessionID(id))","epoch":1,"head":\#(records(for: sessionID(id)).count),"status":"\#(status)","metadata":{"name":"\#(name)","emoji":"\#(emoji)","workspaceId":null,"workspaceName":"\#(workspace)","hasAgent":true,"createdAt":null,"lastMessageAt":\#(active),"archived":false,"workspaceState":\#(state)}}"#
      }
      return """
        {"hosts":[
        {"hostId":"\(studio.uuidString.lowercased())","hostGeneration":"c3b6da28-55c0-4bb0-ac04-dd458fd41a2b","label":"Studio","hostKind":"macos","online":true,"lastSeenAt":"2026-10-16T00:00:00Z"},
        {"hostId":"\(imac.uuidString.lowercased())","hostGeneration":"d3b6da28-55c0-4bb0-ac04-dd458fd41a2b","label":"Old iMac","hostKind":"macos","online":false,"lastSeenAt":"2026-10-15T00:00:00Z"}],
        "sessions":[\
        \(session(studio, 1, "Ship the remote Workbench", "🦀", "Axo", status: "working", active: ago(20 * 60))),\
        \(session(studio, 2, "Fix the sidebar spacing", "🎨", "Axo", active: ago(2 * 3600))),\
        \(session(studio, 3, "Explain the relay", "📡", "Axo", active: ago(3 * 3600))),\
        \(session(studio, 6, "Plan the week", "🗓️", "Home", active: ago(10 * 60))),\
        \(session(studio, 7, "Draft the release notes", "📝", "Home", active: ago(5 * 3600))),\
        \(session(imac, 5, "Photo library cleanup", "📷", "Home", active: ago(12 * 86400)))]}
        """
    }

    /// The answer to opening a sample chat: all of its records.
    static func opened(_ session: SessionID) -> String {
      let lines = records(for: session)
      let records = lines.enumerated().map { index, message in
        let line = #"{"type":"message","id":"e\#(index + 1)","message":\#(message)}"#
        let escaped = line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"cursor":\#(index + 1),"id":"e\#(index + 1)","format":"pi/3","line":"\#(escaped)","hash":"sha256:\#(String(repeating: "0", count: 64))"}"#
      }
      return #"{"epoch":1,"records":[\#(records.joined(separator: ","))],"cursor":\#(lines.count),"older":null,"progress":[]}"#
    }

    /// A sample chat's Pi message entries, oldest first, as JSON.
    static func records(for session: SessionID) -> [String] {
      func message(_ role: String, _ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        return #"{"role":"\#(role)","content":"\#(escaped)"}"#
      }
      let plan = "Yes. Here is the plan:\n\n# Plan\n1. Bring back the sliding **chats** menu\n2. Chat-first layout\n   - a rounded composer\n   - nothing else on screen\n3. Ship it\n\n> The old app is the reference.\n\n| Part | State |\n|---|---|\n| Menu | done |\n| Composer | in progress |\n\n---\n\nThe message box looks like this:\n\n```swift\nTextField(\"Message Axo\", text: $draft)\n    .padding(18)\n```\n\nI'll start with the menu."
      if session == sessionID(2) { return [message("user", "What's the plan?"), message("assistant", plan)] }
      if session == sessionID(3) {
        // Wider than the screen if laid out in one row: four pictures and a long command.
        let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let image = #"{"type":"image","data":"\#(pixel)","mimeType":"image/png"}"#
        return [
          #"{"role":"user","content":[{"type":"text","text":"Here are the screenshots."},\#(image),\#(image),\#(image),\#(image)]}"#,
          #"{"role":"assistant","timestamp":1792810292070,"content":[{"type":"text","text":"Live and correct now."},{"type":"toolCall","id":"w1","name":"bash","arguments":{"command":"cd /tmp/sharepage && U=https://axo.leostera.dev/s/fuVgs7XzUJNX7wpVhCTqWg/riot-zcaml-toolchain; node shot2.mjs $U live-dark.png"}}]}"#,
          #"{"role":"toolResult","toolCallId":"w1","content":"ok","isError":false}"#,
          message("assistant", "The relay keeps each Session's log in order, from https://axo.leostera.dev/s/fuVgs7XzUJNX7wpVhCTqWg/riot-zcaml-toolchain-and-a-very-long-path-without-spaces"),
        ]
      }
      guard session == sessionID(1) else { return [message("user", "Hello"), message("assistant", "Hi! What are we working on?")] }
      return [
        message("user", "Can you make the phone app feel like the old one again?"),
        message("assistant", plan),
        message("user", "Great, go ahead."),
        #"{"role":"assistant","timestamp":1792810292069,"content":[{"type":"thinking","thinking":"I should check the repository first."},{"type":"text","text":"Let me look at the project."},{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"git status --short --branch"}},{"type":"toolCall","id":"c2","name":"read","arguments":{"path":"apple/AxoPhone/README.md"}},{"type":"toolCall","id":"c3","name":"bash","arguments":{"command":"false"}}]}"#,
        #"{"role":"toolResult","toolCallId":"c1","content":[{"type":"text","text":"On branch main\n M apple/AxoPhone/Sources/AxoPhone/ChatMessageView.swift\n M apple/AxoPhone/Sources/AxoPhone/ConversationView.swift\n?? apple/AxoPhone/Sources/AxoPhone/ToolTranscriptView.swift\n M one\n M two\n M three"}],"isError":false}"#,
        #"{"role":"toolResult","toolCallId":"c2","content":"Axo Phone, the iPhone client.","isError":false}"#,
        #"{"role":"toolResult","toolCallId":"c3","content":"exit code 1","isError":true}"#,
        message("assistant", "Done. Open the menu with the button at the top left, or swipe from the left edge."),
      ]
    }
  #else
    static var requested: Bool { false }
    static var menuOpen: Bool { false }
    static var chatOpen: Int? { nil }
    static var settingsOpen: Bool { false }
    static var appsOpen: Bool { false }
    static var hostsOpen: Bool { false }
    static var live: String? { nil }
    static let motionLog: LayerMotionLog? = nil
  #endif
}
