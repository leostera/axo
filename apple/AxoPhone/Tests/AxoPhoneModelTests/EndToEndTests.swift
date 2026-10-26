import AxoClient
import AxoProtocol
import Foundation
import XCTest

@testable import AxoPhoneModel

/// The phone's real code against a real stack: the phone's model and client over a real WebSocket to
/// a real Worker (simulated Cloudflare sign-in) that relays to a real axod, whose Pi is a stand-in
/// recording what is typed into it. Nothing in between is faked.
///
///     cargo build --release -p axod
///     AXO_E2E_AXOD=$PWD/target/release/axod swift test --package-path apple/AxoPhone --filter EndToEnd
///
/// Skipped without `AXO_E2E_AXOD`: it needs Node and a built axod.
@MainActor
final class EndToEndTests: XCTestCase {
  private struct Stack {
    let process: Process
    let input: Pipe
    let url: URL
    let token: SessionToken
    let piLog: URL
    let hostID: UUID

    /// Starts `scripts/e2e-stack.ts` and waits for its ready line.
    static func start(axod: String) throws -> Stack {
      let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = ["npx", "tsx", "scripts/e2e-stack.ts"]
      process.currentDirectoryURL = repository.appendingPathComponent("packages/axo-api-worker")
      process.environment = ProcessInfo.processInfo.environment.merging(["AXOD_BINARY": axod]) { $1 }
      let output = Pipe()
      let input = Pipe()
      process.standardOutput = output
      process.standardInput = input
      process.standardError = FileHandle.nullDevice
      try process.run()

      var buffered = Data()
      let deadline = Date().addingTimeInterval(120)
      while Date() < deadline {
        let chunk = output.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        buffered.append(chunk)
        for line in String(decoding: buffered, as: UTF8.self).split(separator: "\n") where line.hasPrefix("{\"url\"") {
          struct Ready: Decodable { let url: URL; let token: String; let piLog: String; let hostId: UUID }
          let ready = try JSONDecoder().decode(Ready.self, from: Data(line.utf8))
          return Stack(
            process: process, input: input, url: ready.url, token: try XCTUnwrap(SessionToken(ready.token)),
            piLog: URL(fileURLWithPath: ready.piLog), hostID: ready.hostId)
        }
      }
      process.terminate()
      throw NSError(domain: "e2e", code: 1, userInfo: [NSLocalizedDescriptionKey: "the stack did not start"])
    }

    func stop() {
      try? input.fileHandleForWriting.close()
      process.waitUntilExit()
    }
  }

  func testAPhoneStartsAChatOnTheMacAndPromptsItsPi() async throws {
    guard let axod = ProcessInfo.processInfo.environment["AXO_E2E_AXOD"] else {
      throw XCTSkip("set AXO_E2E_AXOD to a built axod to run the end-to-end test")
    }
    let stack = try Stack.start(axod: axod)
    defer { stack.stop() }

    let endpoint = try XCTUnwrap(RelayEndpoint(origin: stack.url, allowInsecureLoopback: true))
    let account = AccountSession(store: MemoryTokenStore(stack.token))
    let client = AccountClient(endpoint: endpoint, tokens: account.tokens)
    let workbench = PhoneWorkbench(hosts: HostsModel(listing: client, account: account)) { host in
      HostWorkbenchModel(
        host: host,
        connection: HostConnection(endpoint: endpoint, host: host.reference, tokens: account.tokens),
        history: client, account: account)
    }

    // Opening the app lands on a new chat on the Mac that is online. Nothing exists yet.
    await workbench.start()
    XCTAssertEqual(workbench.hosts.hosts.map(\.hostId), [stack.hostID])
    XCTAssertTrue(workbench.isDrafting)
    XCTAssertEqual(workbench.current?.sessions.isEmpty, false, "the Mac's terminal Session is there but is not a chat")
    XCTAssertNil(workbench.current?.selectedSession, "no chat is open")

    // The first message brings the chat into being (the Mac has one Workspace, so it starts there
    // at once), and the words reach its Pi as a paste and a submit.
    let started = await workbench.startChat(sending: "please run the tests")
    XCTAssertEqual(started, .started, workbench.current?.failure ?? "")
    XCTAssertFalse(workbench.isDrafting)
    let chat = try XCTUnwrap(workbench.current?.selectedSession)
    XCTAssertEqual(chat.hasAgent, true, "a chat is a Session with a Pi")
    let deadline = Date().addingTimeInterval(20)
    var typed = ""
    while Date() < deadline {
      typed = (try? String(contentsOf: stack.piLog, encoding: .utf8)) ?? ""
      if typed.contains("please run the tests") { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertEqual(typed, "\u{1B}[200~please run the tests\u{1B}[201~\n")

    // The connection drops (a phone in a pocket loses its socket all the time). The next message
    // opens a new socket, which the relay treats as a stranger until it negotiates: this used to
    // fail with "Negotiate first".
    workbench.current?.stop()
    try await Task.sleep(for: .milliseconds(500))  // stop() closes the socket in the background
    let again = await workbench.current?.sendPrompt("and again")
    XCTAssertEqual(again, true, workbench.current?.failure ?? "")
    typed = ""
    let second = Date().addingTimeInterval(20)
    while Date() < second {
      typed = (try? String(contentsOf: stack.piLog, encoding: .utf8)) ?? ""
      if typed.contains("and again") { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(typed.hasSuffix("\u{1B}[200~and again\u{1B}[201~\n"), typed)

    workbench.close()
  }
}
