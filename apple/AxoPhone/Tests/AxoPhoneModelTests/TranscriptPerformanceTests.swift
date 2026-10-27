import AxoProtocol
import Foundation
import XCTest

@testable import AxoPhoneModel

/// How long the conversation's main-actor work takes on a long chat. Apple's guidance is to keep
/// an app's own main-thread work under about 5 ms while the screen is moving; these print the
/// median of several runs so a change can be compared before and after. Run in release:
///
///     AXO_PHONE_PERF=1 swift test -c release --filter TranscriptPerformanceTests
///
/// They only report; they are skipped unless asked for.
final class TranscriptPerformanceTests: XCTestCase {
  private let stream = UUID()

  override func setUpWithError() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["AXO_PHONE_PERF"] == "1", "set AXO_PHONE_PERF=1")
  }

  // MARK: - A long chat, as Pi writes one

  private static let reply = """
    Here is what I found in **the relay**, and what I would change:

    1. The account object forwards `axo.remote.*` calls to the Mac's socket.
    2. Each reply is matched by id; a late one is dropped with a warning.
    3. Events are fanned out to every subscribed client, see [the docs](https://example.com/docs).

    ```swift
    func forward(_ call: Call) async throws -> Reply {
      let socket = try await link.socket(for: call.host)
      return try await socket.send(call)
    }
    ```

    - It keeps one socket per Mac.
    - It never buffers more than *eight* calls.
      - Beyond that it answers `WouldBlock`.

    > The Mac always dials out, so no inbound port is needed.

    | Method | Allowed |
    | --- | --- |
    | session.prompt | yes |
    | terminal.input | yes |

    That should be enough to make the first message of a chat arrive every time.
    """

  private static let output = String(repeating: "test result: ok. 37 passed; 0 failed; finished in 2.06s\n", count: 60)

  private func record(_ sequence: UInt64, _ name: String, _ data: JSONValue) -> PiEventRecord {
    PiEventRecord(streamId: stream, sequence: sequence, name: name, data: data)
  }

  private func turn(_ index: Int) -> [PiEventRecord] {
    let base = UInt64(index * 5)
    let user: JSONValue = .object(["message": .object(["role": .string("user"), "content": .string("Please look at item \(index)")])])
    let assistant: JSONValue = .object([
      "message": .object([
        "role": .string("assistant"),
        "content": .array([
          .object(["type": .string("thinking"), "thinking": .string(String(repeating: "Let me think about it. ", count: 20))]),
          .object(["type": .string("text"), "text": .string(Self.reply)]),
          .object(["type": .string("toolCall"), "id": .string("a\(index)"), "name": .string("bash"),
                   "arguments": .object(["command": .string("cargo test")])]),
          .object(["type": .string("toolCall"), "id": .string("b\(index)"), "name": .string("read"),
                   "arguments": .object(["path": .string("README.md")])]),
        ]),
      ])
    ])
    func result(_ id: String) -> JSONValue {
      .object(["message": .object(["role": .string("toolResult"), "toolCallId": .string(id), "content": .string(Self.output)])])
    }
    return [
      record(base + 1, "message.end", user),
      record(base + 2, "message.end", assistant),
      record(base + 3, "message.end", result("a\(index)")),
      record(base + 4, "message.end", result("b\(index)")),
      record(base + 5, "agent.end", .object([:])),
    ]
  }

  private func history(turns: Int) -> [PiEventRecord] { (0..<turns).flatMap(turn) }

  private func median(_ label: String, runs: Int = 9, _ work: () -> Void) {
    var samples: [Duration] = []
    for _ in 0..<runs {
      let start = ContinuousClock.now
      work()
      samples.append(ContinuousClock.now - start)
    }
    samples.sort()
    let ms = Double(samples[runs / 2].components.attoseconds) / 1e15 + Double(samples[runs / 2].components.seconds) * 1000
    print(String(format: "PERF %@: %.2f ms (median of %d)", label, ms, runs))
  }

  // MARK: - Measurements

  func testReadingHistory() {
    let page = history(turns: 10)  // 50 events, one page
    let ten = history(turns: 100)  // 500 events, ten pages
    median("first page, 50 events") { var t = ChatTranscript(); t.merge(history: page) }
    median("all ten pages rebuilt, 500 events (the old way to add a page)") { var t = ChatTranscript(); t.merge(history: ten) }
    // Now: a page is parsed away from the main actor, then joined to what is shown on it.
    let older = Array(ten.prefix(50))
    var shown = ChatTranscript()
    shown.merge(newest: ChatTranscript(history: Array(ten.dropFirst(50))), keepingOlder: false)
    median("older page parsed, 50 events (off the main actor)") { _ = ChatTranscript(history: older) }
    let parsed = ChatTranscript(history: older)
    median("older page joined to 450 events shown (main actor)") { var t = shown; t.prepend(older: parsed) }
  }

  func testAReplyAsItGrows() {
    for size in [2_000, 8_000, 16_000] {
      let text = String(String(repeating: Self.reply + "\n\n", count: size / Self.reply.count + 1).prefix(size))
      let update = record(1, "message.update", .object([
        "message": .object(["role": .string("assistant"), "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
      ]))
      var transcript = ChatTranscript()
      transcript.merge(history: history(turns: 20))
      median("message.update, \(size / 1000) kB reply") { transcript.apply(update) }
    }
  }

  func testInlineMarkdownForOneScreen() {
    let blocks = MarkdownBlocks.parse(Self.reply)
    let lines: [String] = blocks.compactMap {
      switch $0 {
      case .paragraph(let text), .heading(_, let text), .listItem(_, _, let text), .quote(let text): text
      default: nil
      }
    }
    // About a screenful: three replies' worth of prose.
    let screen = Array(repeating: lines, count: 3).flatMap { $0 }
    median("inline Markdown for \(screen.count) lines") {
      for line in screen {
        _ = try? AttributedString(
          markdown: line, options: .init(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace))
      }
    }
  }
}
