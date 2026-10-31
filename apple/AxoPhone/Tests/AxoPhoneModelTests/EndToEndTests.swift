import AxoClient
import AxoProtocol
import Foundation
import XCTest

@testable import AxoPhoneModel

/// The phone's real code against a real stack: the phone's model and client over a real WebSocket to
/// a real Worker (simulated Cloudflare sign-in) that relays to a real axod, whose Pi is a stand-in
/// recording what it is sent and writing a transcript. Nothing in between is faked.
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
    let feed = AccountConnection(endpoint: endpoint, clientID: .random(), tokens: account.tokens)
    let workbench = PhoneWorkbench(hosts: HostsModel(profile: client), feed: feed, account: account) { host in
      HostWorkbenchModel(
        host: host, connection: HostConnection(account: feed, host: host.reference), feed: feed, account: account)
    }

    // Opening the app follows the account and lands on a new chat on the Mac that is online.
    await workbench.start()
    let listed = Date().addingTimeInterval(20)
    while workbench.hosts.hosts.isEmpty || workbench.selection == nil, Date() < listed {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(workbench.hosts.hosts.map(\.hostId), [stack.hostID])
    XCTAssertTrue(workbench.isDrafting)
    XCTAssertNil(workbench.current?.selectedSession, "no chat is open")

    // The first message brings the chat into being, and the words reach its Pi over the bridge.
    workbench.setDraft("please run the tests", for: try XCTUnwrap(workbench.selection))
    let sent = await workbench.send()
    XCTAssertEqual(sent, .sent, workbench.current?.failure ?? "")
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
    XCTAssertTrue(typed.contains("SENT:please run the tests\n"), typed)

    // Pi's transcript reaches the phone: the user's message comes back as a record.
    let recorded = Date().addingTimeInterval(20)
    while workbench.current?.chats[chat.sessionId]?.messages.contains(where: { $0.text == "please run the tests" }) != true,
      Date() < recorded
    {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertEqual(workbench.current?.chats[chat.sessionId]?.messages.first?.text, "please run the tests")

    // The socket drops (a phone in a pocket loses it all the time); the next message goes on a new one.
    workbench.suspend()
    try await Task.sleep(for: .milliseconds(500))  // the socket closes in the background
    await workbench.resume()
    let again = await workbench.current?.sendPrompt("and again")
    XCTAssertEqual(again, .accepted, workbench.current?.failure ?? "")
    typed = ""
    let second = Date().addingTimeInterval(20)
    while Date() < second {
      typed = (try? String(contentsOf: stack.piLog, encoding: .utf8)) ?? ""
      if typed.contains("and again") { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(typed.contains("SENT:and again\n"), typed)

    workbench.stop()
  }
}
