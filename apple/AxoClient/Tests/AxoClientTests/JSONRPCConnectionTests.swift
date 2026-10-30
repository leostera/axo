import Foundation
import XCTest

@testable import AxoClient

/// The connection's guarantees, over an in-memory transport: one persistent connection with
/// many calls in flight, and every call ending exactly once however the connection behaves.
final class JSONRPCConnectionTests: XCTestCase {
  /// Generous: only a failing test waits it out.
  private static let wait: Duration = .seconds(15)

  func testConcurrentCallsShareOneConnectionAndMatchRepliesOutOfOrder() async throws {
    let transport = FakeTransport()
    let rpc = JSONRPCConnection(transport: transport)
    async let first: Echo = rpc.call("echo", params: Echo(value: "a"), timeout: Self.wait)
    async let second: Echo = rpc.call("echo", params: Echo(value: "b"), timeout: Self.wait)
    async let third: Echo = rpc.call("echo", params: Echo(value: "c"), timeout: Self.wait)

    let channel = try await transport.channel(0)
    let requests = try await channel.requests(count: 3)
    for request in requests.reversed() {
      channel.reply(to: request.id, result: #"{"value":"\#(request.value!)!"}"#)
    }
    let results = try await [first, second, third].map(\.value)
    XCTAssertEqual(results, ["a!", "b!", "c!"])
    XCTAssertEqual(transport.connectCount, 1)

    // Later calls reuse it.
    async let fourth: Echo = rpc.call("echo", params: Echo(value: "d"), timeout: Self.wait)
    let next = try await channel.requests(count: 4)[3]
    channel.reply(to: next.id, result: #"{"value":"d"}"#)
    _ = try await fourth
    XCTAssertEqual(transport.connectCount, 1)
  }

  func testRequestsAreJSONRPC2WithNullParamsWhenThereAreNone() async throws {
    let transport = FakeTransport()
    let rpc = JSONRPCConnection(transport: transport)
    async let health: Echo = rpc.call("axo.daemon.health", params: String?.none, timeout: Self.wait)
    let channel = try await transport.channel(0)
    let raw = try await channel.rawRequests(count: 1)[0]
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
    XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
    XCTAssertEqual(object["method"] as? String, "axo.daemon.health")
    XCTAssertTrue(object["params"] is NSNull)
    let id = try XCTUnwrap(object["id"] as? Int)
    channel.reply(to: id, result: #"{"value":"ok"}"#)
    _ = try await health
  }

  func testATimedOutCallRetiresItsConnectionWithoutFailingCallsStillOnIt() async throws {
    let transport = FakeTransport()
    let rpc = JSONRPCConnection(transport: transport)
    async let slow: Echo = rpc.call("slow", params: Echo(value: "s"), timeout: Self.wait)
    let old = try await transport.channel(0)
    let slowRequest = try await old.requests(count: 1)[0]

    do {
      let _: Echo = try await rpc.call("stuck", params: Echo(value: "t"), timeout: .milliseconds(50))
      XCTFail("expected a timeout")
    } catch {
      XCTAssertEqual(error as? AxoClientError, .requestTimedOut)
    }

    // New calls go to a fresh connection.
    async let fresh: Echo = rpc.call("echo", params: Echo(value: "f"), timeout: Self.wait)
    let new = try await transport.channel(1)
    let freshRequest = try await new.requests(count: 1)[0]
    new.reply(to: freshRequest.id, result: #"{"value":"f"}"#)
    _ = try await fresh

    // The call still on the retired connection completes; then it closes. The late reply to
    // the timed-out call is ignored.
    XCTAssertFalse(old.isClosed)
    let stuckRequest = try await old.requests(count: 2)[1]
    old.reply(to: stuckRequest.id, result: #"{"value":"late"}"#)
    old.reply(to: slowRequest.id, result: #"{"value":"s"}"#)
    let slowResult = try await slow
    XCTAssertEqual(slowResult.value, "s")
    try await eventually { old.isClosed }
    XCTAssertFalse(new.isClosed)
  }

  func testTheConnectionEndingFailsItsCallsAndTheNextCallReconnects() async throws {
    let transport = FakeTransport()
    let rpc = JSONRPCConnection(transport: transport)
    let pending = Task { () throws -> Echo in
      try await rpc.call("echo", params: Echo(value: "a"), timeout: Self.wait)
    }
    let first = try await transport.channel(0)
    _ = try await first.requests(count: 1)
    first.endFromPeer()
    do {
      _ = try await pending.value
      XCTFail("expected the call to fail")
    } catch {
      XCTAssertEqual(error as? AxoClientError, .connectionClosed)
    }

    async let again: Echo = rpc.call("echo", params: Echo(value: "b"), timeout: Self.wait)
    let second = try await transport.channel(1)
    let request = try await second.requests(count: 1)[0]
    second.reply(to: request.id, result: #"{"value":"b"}"#)
    _ = try await again
  }

  func testLosingTheConnectionInUseIsReportedOnceAndAReplacementIsNot() async throws {
    let transport = FakeTransport()
    let rpc = JSONRPCConnection(transport: transport)
    var losses = rpc.connectionLost.makeAsyncIterator()

    async let first: Echo = rpc.call("echo", params: Echo(value: "a"), timeout: Self.wait)
    let channel = try await transport.channel(0)
    channel.reply(to: try await channel.requests(count: 1)[0].id, result: #"{"value":"a"}"#)
    _ = try await first
    channel.endFromPeer()
    let lost: Void? = await losses.next()
    XCTAssertNotNil(lost, "the end of the connection in use is reported")

    // Connecting again (and the next loss) is reported anew; a connect that fails is not a loss.
    async let second: Echo = rpc.call("echo", params: Echo(value: "b"), timeout: Self.wait)
    let replacement = try await transport.channel(1)
    replacement.reply(to: try await replacement.requests(count: 1)[0].id, result: #"{"value":"b"}"#)
    _ = try await second
    await rpc.disconnect()
    let lostAgain: Void? = await losses.next()
    XCTAssertNotNil(lostAgain)
  }

  func testACallWhoseRequestCannotBeSentFailsAtOnce() async throws {
    let transport = FakeTransport()
    let rpc = JSONRPCConnection(transport: transport)
    let warmup = Task { () throws -> Echo in
      try await rpc.call("echo", params: Echo(value: "w"), timeout: Self.wait)
    }
    let channel = try await transport.channel(0)
    let request = try await channel.requests(count: 1)[0]
    channel.reply(to: request.id, result: #"{"value":"w"}"#)
    _ = try await warmup.value

    channel.failSends()
    let start = ContinuousClock.now
    do {
      let _: Echo = try await rpc.call("echo", params: Echo(value: "a"), timeout: Self.wait)
      XCTFail("expected the send to fail")
    } catch {
      XCTAssertEqual(error as? AxoClientError, .connectionClosed)
    }
    XCTAssertLessThan(ContinuousClock.now - start, .seconds(5), "must not wait for the timeout")
  }

  func testCancellingACallEndsItAndKeepsTheConnection() async throws {
    let transport = FakeTransport()
    let rpc = JSONRPCConnection(transport: transport)
    let cancelled = Task { () throws -> Echo in
      try await rpc.call("poll", params: Echo(value: "p"), timeout: Self.wait)
    }
    let channel = try await transport.channel(0)
    let pollRequest = try await channel.requests(count: 1)[0]
    cancelled.cancel()
    do {
      _ = try await cancelled.value
      XCTFail("expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError, "\(error)")
    }
    channel.reply(to: pollRequest.id, result: #"{"value":"late"}"#)

    async let next: Echo = rpc.call("echo", params: Echo(value: "n"), timeout: Self.wait)
    let request = try await channel.requests(count: 2)[1]
    channel.reply(to: request.id, result: #"{"value":"n"}"#)
    let result = try await next
    XCTAssertEqual(result.value, "n")
    XCTAssertEqual(transport.connectCount, 1)
    XCTAssertFalse(channel.isClosed)
  }

  func testConcurrentFirstCallsShareOneConnect() async throws {
    let transport = FakeTransport(connectDelay: .milliseconds(100))
    let rpc = JSONRPCConnection(transport: transport)
    async let first: Echo = rpc.call("echo", params: Echo(value: "a"), timeout: Self.wait)
    async let second: Echo = rpc.call("echo", params: Echo(value: "b"), timeout: Self.wait)
    let channel = try await transport.channel(0)
    for request in try await channel.requests(count: 2) {
      channel.reply(to: request.id, result: #"{"value":"x"}"#)
    }
    _ = try await (first, second)
    XCTAssertEqual(transport.connectCount, 1)
  }

  func testAFailedConnectIsReportedAndTheNextCallTriesAgain() async throws {
    let transport = FakeTransport(failingConnects: 1)
    let rpc = JSONRPCConnection(transport: transport)
    do {
      let _: Echo = try await rpc.call("echo", params: Echo(value: "a"), timeout: Self.wait)
      XCTFail("expected the connect to fail")
    } catch {
      XCTAssertEqual(error as? AxoClientError, .connectionFailed("refused"))
    }
    async let again: Echo = rpc.call("echo", params: Echo(value: "b"), timeout: Self.wait)
    let channel = try await transport.channel(0)
    let request = try await channel.requests(count: 1)[0]
    channel.reply(to: request.id, result: #"{"value":"b"}"#)
    _ = try await again
    XCTAssertEqual(transport.connectCount, 2)
  }

  func testDisconnectFailsCallsInFlight() async throws {
    let transport = FakeTransport()
    let rpc = JSONRPCConnection(transport: transport)
    let pending = Task { () throws -> Echo in
      try await rpc.call("echo", params: Echo(value: "a"), timeout: Self.wait)
    }
    let channel = try await transport.channel(0)
    _ = try await channel.requests(count: 1)
    await rpc.disconnect()
    do {
      _ = try await pending.value
      XCTFail("expected the call to fail")
    } catch {
      XCTAssertEqual(error as? AxoClientError, .connectionClosed)
    }
    XCTAssertTrue(channel.isClosed)
  }

  func testNotificationsAreDeliveredInOrderAndNeverMistakenForReplies() async throws {
    let transport = FakeTransport()
    let rpc = JSONRPCConnection(transport: transport)
    async let echo: Echo = rpc.call("echo", params: Echo(value: "a"), timeout: Self.wait)
    let channel = try await transport.channel(0)
    let request = try await channel.requests(count: 1)[0]
    channel.send(raw: #"{"jsonrpc":"2.0","method":"tick","params":{"value":"one"}}"#)
    channel.send(raw: #"{"jsonrpc":"2.0","method":"tick","params":{"value":"two"}}"#)
    channel.reply(to: request.id, result: #"{"value":"a"}"#)
    _ = try await echo

    var iterator = rpc.notifications.makeAsyncIterator()
    let firstOrNil = await iterator.next()
    let secondOrNil = await iterator.next()
    let first = try XCTUnwrap(firstOrNil)
    let second = try XCTUnwrap(secondOrNil)
    XCTAssertEqual(first.method, "tick")
    XCTAssertEqual(try first.params(as: Echo.self).value, "one")
    XCTAssertEqual(try second.params(as: Echo.self).value, "two")
  }

  func testErrorsAndMalformedRepliesAreTyped() async throws {
    let transport = FakeTransport()
    let rpc = JSONRPCConnection(transport: transport)
    let replies = [
      (#""error":{"code":-32601,"message":"no such method"}"#,
       AxoClientError.serverRejected(code: -32601, message: "no such method")),
      (#""result":{"unexpected":1}"#, nil),
      (#""result":null"#, AxoClientError.invalidResponse("the reply has neither a result nor an error")),
    ]
    for (index, (body, expected)) in replies.enumerated() {
      let call = Task { () throws -> Echo in
        try await rpc.call("echo", params: Echo(value: "a"), timeout: Self.wait)
      }
      let channel = try await transport.channel(0)
      let request = try await channel.requests(count: index + 1)[index]
      channel.send(raw: #"{"jsonrpc":"2.0","id":\#(request.id),\#(body)}"#)
      do {
        _ = try await call.value
        XCTFail("expected \(body) to fail")
      } catch let error as AxoClientError {
        if let expected {
          XCTAssertEqual(error, expected)
        } else if case .invalidResponse = error {
        } else {
          XCTFail("unexpected \(error)")
        }
      }
    }
  }

  private func eventually(_ condition: @escaping () -> Bool) async throws {
    let deadline = ContinuousClock.now + Self.wait
    while !condition() {
      guard ContinuousClock.now < deadline else { return XCTFail("condition never held") }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}

struct Echo: Codable, Sendable {
  let value: String
}

struct SentRequest: Decodable {
  let id: Int
  let method: String
  let params: Echo?

  var value: String? { params?.value }
}

/// Hands out `FakeChannel`s; can delay or refuse connects.
final class FakeTransport: AxoTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var channels: [FakeChannel] = []
  private var connects = 0
  private var failuresLeft: Int
  private let connectDelay: Duration

  /// Whether channels agree to a protocol version themselves, as a relay does on every connection.
  private let negotiates: Bool

  init(connectDelay: Duration = .zero, failingConnects: Int = 0, negotiates: Bool = false) {
    self.connectDelay = connectDelay
    failuresLeft = failingConnects
    self.negotiates = negotiates
  }

  var connectCount: Int { lock.withLock { connects } }

  func connect() async throws -> any AxoMessageChannel {
    if connectDelay > .zero { try await Task.sleep(for: connectDelay) }
    return try lock.withLock {
      connects += 1
      if failuresLeft > 0 {
        failuresLeft -= 1
        throw AxoClientError.connectionFailed("refused")
      }
      let channel = FakeChannel()
      channel.answersNegotiation = negotiates
      channels.append(channel)
      return channel
    }
  }

  /// The `index`th connection made, once it exists.
  func channel(_ index: Int) async throws -> FakeChannel {
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline {
      if let channel = lock.withLock({ channels.indices.contains(index) ? channels[index] : nil }) {
        return channel
      }
      try await Task.sleep(for: .milliseconds(2))
    }
    throw AxoClientError.connectionFailed("connection \(index) was never made")
  }
}

/// A connection whose peer the test plays.
final class FakeChannel: AxoMessageChannel, @unchecked Sendable {
  let messages: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  private let lock = NSLock()
  private var sent: [Data] = []
  private var closed = false
  private var sendsFail = false

  init() {
    (messages, continuation) = AsyncStream<Data>.makeStream()
  }

  /// Answers `axo.protocol.negotiate` itself and does not count it among the requests sent.
  var answersNegotiation = false

  var isClosed: Bool { lock.withLock { closed } }
  var sentCount: Int { lock.withLock { sent.count } }

  func send(_ message: Data) async throws {
    let handshake = try lock.withLock { () -> Int? in
      guard !closed, !sendsFail else { throw AxoClientError.connectionClosed }
      if answersNegotiation,
        let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
        object["method"] as? String == "axo.protocol.negotiate"
      {
        return object["id"] as? Int
      }
      sent.append(message)
      return nil
    }
    if let handshake { reply(to: handshake, result: #"{"protocolVersion":2,"methods":[]}"#) }
  }

  func close() {
    lock.withLock { closed = true }
    continuation.finish()
  }

  /// Writes fail from now on, as on a broken socket the reader has not noticed yet.
  func failSends() {
    lock.withLock { sendsFail = true }
  }

  /// The peer hangs up.
  func endFromPeer() {
    continuation.finish()
  }

  func reply(to id: Int, result: String) {
    send(raw: #"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#)
  }

  func send(raw: String) {
    continuation.yield(Data(raw.utf8))
  }

  func rawRequests(count: Int) async throws -> [Data] {
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline {
      let current = lock.withLock { sent }
      if current.count >= count { return current }
      try await Task.sleep(for: .milliseconds(2))
    }
    throw AxoClientError.requestTimedOut
  }

  func requests(count: Int) async throws -> [SentRequest] {
    try await rawRequests(count: count).map { try JSONDecoder().decode(SentRequest.self, from: $0) }
  }
}
