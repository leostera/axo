import AxoProtocol
import Foundation
import XCTest

@testable import AxoClient

final class RelayEndpointTests: XCTestCase {
  func testOnlyHTTPSOriginsAreAccepted() {
    XCTAssertNotNil(RelayEndpoint(origin: URL(string: "https://axo.leostera.dev")!))
    XCTAssertNotNil(RelayEndpoint(origin: URL(string: "https://axo.leostera.dev/")!))
    for bad in [
      "http://axo.leostera.dev", "ftp://axo.leostera.dev", "https://axo.leostera.dev/api",
      "https://axo.leostera.dev?x=1", "https://user:pw@axo.leostera.dev", "https://",
    ] {
      XCTAssertNil(RelayEndpoint(origin: URL(string: bad)!), bad)
    }
  }

  func testPlainHTTPIsForLoopbackAndOnlyWhenAskedFor() {
    let local = URL(string: "http://127.0.0.1:8787")!
    XCTAssertNil(RelayEndpoint(origin: local))
    XCTAssertNotNil(RelayEndpoint(origin: local, allowInsecureLoopback: true))
    XCTAssertNil(
      RelayEndpoint(origin: URL(string: "http://example.com")!, allowInsecureLoopback: true))
  }

  func testURLsAreBuiltFromTheOrigin() {
    let host = RemoteHostRef(hostId: UUID(), hostGeneration: UUID())
    let endpoint = RelayEndpoint.production
    XCTAssertEqual(endpoint.hostsURL.absoluteString, "https://axo.leostera.dev/api/v1/account/hosts")
    XCTAssertEqual(
      endpoint.sessionsURL(of: host).absoluteString,
      "https://axo.leostera.dev/api/v1/account/hosts/\(host.hostId.uuidString.lowercased())/sessions?hostGeneration=\(host.hostGeneration.uuidString.lowercased())"
    )
    XCTAssertEqual(
      endpoint.clientSocketURL(hostID: host.hostId).absoluteString,
      "wss://axo.leostera.dev/api/v1/account/hosts/\(host.hostId.uuidString.lowercased())/client")
  }
}

final class AccessTokenTests: XCTestCase {
  func testATokenIsHeaderSafe() {
    XCTAssertNotNil(AccessToken("eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.c2ln"))
    for bad in ["", "a b", "a\nb", "a\r\nX-Evil: 1", "tökén", String(repeating: "a", count: 16_385)] {
      XCTAssertNil(AccessToken(bad), bad)
    }
  }

  func testAuthorizedRequestsCarryTheTokenAndNoCookies() async throws {
    let token = try XCTUnwrap(AccessToken("abc.def.ghi"))
    let request = try await RelayCredentials.authorize(
      URLRequest(url: URL(string: "https://axo.leostera.dev/api/auth/me")!),
      with: StaticAccessToken(token))
    XCTAssertEqual(request.value(forHTTPHeaderField: "cf-access-token"), "abc.def.ghi")
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
  }

  func testTheRelaySessionKeepsNoCookiesAndNoCache() {
    let configuration = RelayCredentials.makeURLSession().configuration
    XCTAssertFalse(configuration.httpShouldSetCookies)
    XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
    XCTAssertNil(configuration.httpCookieStorage)
    XCTAssertNil(configuration.urlCache)
  }
}

final class AccountClientTests: XCTestCase {
  private let hostID = UUID()
  private let generation = UUID()

  func testHostsAreRequestedWithTheAccessTokenAndDecoded() async throws {
    let loader = StubLoader(status: 200, body: hostList)
    let client = makeClient(loader)
    let hosts = try await client.hosts()
    XCTAssertEqual(hosts.map(\.label), ["Studio"])
    let request = try XCTUnwrap(loader.requests.first)
    XCTAssertEqual(request.url?.path, "/api/v1/account/hosts")
    XCTAssertEqual(request.value(forHTTPHeaderField: "cf-access-token"), "tok.en")
    XCTAssertFalse(request.httpShouldHandleCookies)
  }

  func testAnAccessRefusalMeansSignInAgain() async {
    for status in [401, 403] {
      let client = makeClient(StubLoader(status: status, body: "{}"))
      do {
        _ = try await client.hosts()
        XCTFail("expected a refusal")
      } catch {
        XCTAssertEqual(error as? RelayError, .signInRequired)
      }
    }
  }

  func testOtherStatusesAndGarbageAreTyped() async {
    do {
      _ = try await makeClient(StubLoader(status: 503, body: "")).hosts()
      XCTFail()
    } catch {
      XCTAssertEqual(error as? RelayError, .httpStatus(503))
    }
    do {
      _ = try await makeClient(StubLoader(status: 200, body: "not json")).hosts()
      XCTFail()
    } catch {
      guard case .invalidResponse = error as? AxoClientError else { return XCTFail("\(error)") }
    }
  }

  func testSessionsAskForOneRunOfOneHostAndRefuseAnotherRunsAnswer() async throws {
    let ref = RemoteHostRef(hostId: hostID, hostGeneration: generation)
    let loader = StubLoader(status: 200, body: sessions(generation: generation))
    let found = try await makeClient(loader).sessions(of: ref)
    XCTAssertEqual(found.map(\.sessionId), [4])
    XCTAssertEqual(loader.requests.first?.url?.query, "hostGeneration=\(generation.uuidString.lowercased())")

    let other = StubLoader(status: 200, body: sessions(generation: UUID()))
    do {
      _ = try await makeClient(other).sessions(of: ref)
      XCTFail("a different run's answer must not pass")
    } catch {
      guard case .invalidResponse = error as? AxoClientError else { return XCTFail("\(error)") }
    }
  }

  private func makeClient(_ loader: StubLoader) -> AccountClient {
    AccountClient(
      tokens: StaticAccessToken(AccessToken("tok.en")!), loader: loader)
  }

  private var hostList: String {
    #"{"hosts":[{"hostId":"\#(hostID.uuidString)","hostGeneration":"\#(generation.uuidString)","label":"Studio","hostKind":"macos","status":"online","stale":false,"lastSeenAt":"2026-10-16T00:00:00Z","sessions":[]}]}"#
  }

  private func sessions(generation: UUID) -> String {
    #"{"host":{"hostId":"\#(hostID.uuidString)","hostGeneration":"\#(generation.uuidString)","label":"Studio","hostKind":"macos","status":"online","stale":false,"lastSeenAt":"2026-10-16T00:00:00Z","sessions":[]},"sessions":[{"hostId":"\#(hostID.uuidString)","sessionId":4,"shells":[],"layout":null,"updatedAt":"2026-10-16T00:00:00Z"}]}"#
  }
}

private final class StubLoader: HTTPDataLoading, @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [URLRequest] = []
  let status: Int
  let body: String

  init(status: Int, body: String) {
    self.status = status
    self.body = body
  }

  var requests: [URLRequest] { lock.withLock { seen } }

  func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    lock.withLock { seen.append(request) }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    return (Data(body.utf8), response)
  }
}

final class RelayWebSocketChannelTests: XCTestCase {
  func testEveryTextFrameIsDeliveredInOrderAndAcknowledged() async throws {
    let socket = FakeSocket()
    let channel = RelayWebSocketChannel(task: socket)
    socket.deliver(.string(#"{"a":1}"#))
    socket.deliver(.string(#"{"b":2}"#))
    var iterator = channel.messages.makeAsyncIterator()
    let first = await iterator.next()
    let second = await iterator.next()
    XCTAssertEqual(first.map { String(decoding: $0, as: UTF8.self) }, #"{"a":1}"#)
    XCTAssertEqual(second.map { String(decoding: $0, as: UTF8.self) }, #"{"b":2}"#)
    try await socket.waitForSent(count: 2)
    for text in socket.sent {
      XCTAssertEqual(
        text, #"{"jsonrpc":"2.0","method":"axo.transport.ack","params":{"frames":1}}"#)
    }
    channel.close()
  }

  func testABinaryFrameEndsTheConnectionInsteadOfBeingGuessedAt() async {
    let socket = FakeSocket()
    let channel = RelayWebSocketChannel(task: socket)
    socket.deliver(.data(Data([1, 2, 3])))
    var iterator = channel.messages.makeAsyncIterator()
    let next = await iterator.next()
    XCTAssertNil(next)
    XCTAssertTrue(socket.isClosed)
  }

  func testTheSocketEndingFinishesMessagesAndSendsFailAfterwards() async {
    let socket = FakeSocket()
    let channel = RelayWebSocketChannel(task: socket)
    socket.fail()
    var iterator = channel.messages.makeAsyncIterator()
    let next = await iterator.next()
    XCTAssertNil(next)
    do {
      try await channel.send(Data("{}".utf8))
      XCTFail("a closed channel must not send")
    } catch {
      XCTAssertEqual(error as? AxoClientError, .connectionClosed)
    }
    channel.close()
    channel.close()
  }

  func testAFailingWriteClosesTheChannelAndReportsItClosed() async {
    let socket = FakeSocket()
    let channel = RelayWebSocketChannel(task: socket)
    socket.failSends()
    do {
      try await channel.send(Data("{}".utf8))
      XCTFail()
    } catch {
      XCTAssertEqual(error as? AxoClientError, .connectionClosed)
    }
    XCTAssertTrue(socket.isClosed)
  }
}

private final class FakeSocket: WebSocketTasking, @unchecked Sendable {
  private let lock = NSLock()
  private var frames: [Result<URLSessionWebSocketTask.Message, Error>] = []
  private var waiters: [CheckedContinuation<URLSessionWebSocketTask.Message, Error>] = []
  private var sentTexts: [String] = []
  private var closed = false
  private var sendsFail = false

  var sent: [String] { lock.withLock { sentTexts } }
  var isClosed: Bool { lock.withLock { closed } }

  func deliver(_ message: URLSessionWebSocketTask.Message) { push(.success(message)) }
  func fail() { push(.failure(AxoClientError.connectionClosed)) }
  func failSends() { lock.withLock { sendsFail = true } }

  private func push(_ frame: Result<URLSessionWebSocketTask.Message, Error>) {
    let waiter = lock.withLock { () -> CheckedContinuation<URLSessionWebSocketTask.Message, Error>? in
      if waiters.isEmpty {
        frames.append(frame)
        return nil
      }
      return waiters.removeFirst()
    }
    waiter?.resume(with: frame)
  }

  func send(text: String) async throws {
    try lock.withLock {
      guard !sendsFail else { throw AxoClientError.connectionClosed }
      sentTexts.append(text)
    }
  }

  func receive() async throws -> URLSessionWebSocketTask.Message {
    try await withCheckedThrowingContinuation { continuation in
      let ready = lock.withLock { () -> Result<URLSessionWebSocketTask.Message, Error>? in
        if frames.isEmpty {
          waiters.append(continuation)
          return nil
        }
        return frames.removeFirst()
      }
      if let ready { continuation.resume(with: ready) }
    }
  }

  func closeConnection() {
    let pending = lock.withLock { () -> [CheckedContinuation<URLSessionWebSocketTask.Message, Error>] in
      closed = true
      defer { waiters = [] }
      return waiters
    }
    for waiter in pending { waiter.resume(throwing: AxoClientError.connectionClosed) }
  }

  func waitForSent(count: Int) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while sent.count < count {
      guard ContinuousClock.now < deadline else { throw AxoClientError.requestTimedOut }
      try await Task.sleep(for: .milliseconds(2))
    }
  }
}

final class HostConnectionTests: XCTestCase {
  private static let wait: Duration = .seconds(15)
  private let host = RemoteHostRef(hostId: UUID(), hostGeneration: UUID())

  func testCallsNameTheHostAndTheRunOfIt() async throws {
    let transport = FakeTransport()
    let connection = HostConnection(transport: transport, host: host)
    async let created = connection.createSession()
    let channel = try await transport.channel(0)
    let raw = try await channel.rawRequests(count: 1)[0]
    let request = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
    XCTAssertEqual(request["method"] as? String, "axo.remote.session.create")
    let target = try XCTUnwrap((request["params"] as? [String: Any])?["target"] as? [String: String])
    XCTAssertEqual(target["hostId"]?.lowercased(), host.hostId.uuidString.lowercased())
    XCTAssertEqual(target["hostGeneration"]?.lowercased(), host.hostGeneration.uuidString.lowercased())
    channel.reply(
      to: try XCTUnwrap(request["id"] as? Int),
      result: #"{"session":{"hostId":"\#(host.hostId.uuidString)","sessionId":7,"shells":[],"layout":null,"updatedAt":"2026-10-16T00:00:00Z"}}"#
    )
    let session = try await created
    XCTAssertEqual(session.sessionId, 7)
  }

  func testASessionCreatedOnAnotherHostIsRefused() async throws {
    let transport = FakeTransport()
    let connection = HostConnection(transport: transport, host: host)
    async let created = connection.createSession()
    let channel = try await transport.channel(0)
    let id = try await channel.firstRequestID()
    channel.reply(
      to: id,
      result: #"{"session":{"hostId":"\#(UUID().uuidString)","sessionId":7,"shells":[],"layout":null,"updatedAt":"2026-10-16T00:00:00Z"}}"#
    )
    do {
      _ = try await created
      XCTFail("a Session from elsewhere must not be accepted")
    } catch {
      guard case .invalidResponse = error as? AxoClientError else { return XCTFail("\(error)") }
    }
  }

  func testInputIsBase64AndItsAcknowledgementMustMatch() async throws {
    let transport = FakeTransport()
    let connection = HostConnection(transport: transport, host: host)
    async let sent: Void = connection.sendInput(Data("ls\n".utf8), to: 4, in: 3, sequence: 9)
    let channel = try await transport.channel(0)
    let raw = try await channel.rawRequests(count: 1)[0]
    let request = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
    let params = try XCTUnwrap(request["params"] as? [String: Any])
    XCTAssertEqual(params["data"] as? String, "bHMK")
    XCTAssertEqual(params["sequence"] as? Int, 9)
    XCTAssertEqual(params["shellId"] as? Int, 4)
    channel.reply(to: try XCTUnwrap(request["id"] as? Int), result: #"{"accepted":true,"sequence":10}"#)
    do {
      try await sent
      XCTFail("an acknowledgement for different input must not count")
    } catch {
      guard case .invalidResponse = error as? AxoClientError else { return XCTFail("\(error)") }
    }
  }

  func testEventsForThisHostArriveAndOthersAreDropped() async throws {
    let transport = FakeTransport()
    let connection = HostConnection(transport: transport, host: host)
    async let subscribed: Void = connection.subscribe()
    let channel = try await transport.channel(0)
    let id = try await channel.firstRequestID()
    channel.reply(to: id, result: #"{"subscriptionId":"\#(UUID().uuidString)"}"#)
    try await subscribed

    let subscription = UUID().uuidString
    func event(for ref: RemoteHostRef, text: String) -> String {
      #"{"jsonrpc":"2.0","method":"axo.host.event","params":{"subscriptionId":"\#(subscription)","event":{"type":"host.data","hostId":"\#(ref.hostId.uuidString)","hostGeneration":"\#(ref.hostGeneration.uuidString)","event":{"type":"terminal.output","sessionId":1,"shellId":2,"sequence":0,"data":"\#(Data(text.utf8).base64EncodedString())"}}}}"#
    }
    let stranger = RemoteHostRef(hostId: UUID(), hostGeneration: UUID())
    channel.send(raw: event(for: stranger, text: "nope"))
    channel.send(raw: #"{"jsonrpc":"2.0","method":"axo.host.event","params":{"garbage":true}}"#)
    channel.send(raw: event(for: host, text: "yes"))

    var iterator = connection.events.makeAsyncIterator()
    let first = try await withThrowingTaskGroup(of: RemoteHostEvent?.self) { group in
      group.addTask { await iterator.next() }
      group.addTask {
        try await Task.sleep(for: Self.wait)
        return nil
      }
      defer { group.cancelAll() }
      return try await group.next() ?? nil
    }
    guard case .terminalOutput(let ref, _, _, _, let data)? = first else {
      return XCTFail("expected this host's output, got \(String(describing: first))")
    }
    XCTAssertEqual(ref, host)
    XCTAssertEqual(String(decoding: data, as: UTF8.self), "yes")
  }
}

extension FakeChannel {
  /// The id of the first request, whatever its params look like.
  func firstRequestID() async throws -> Int {
    let raw = try await rawRequests(count: 1)[0]
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
    return try XCTUnwrap(object["id"] as? Int)
  }
}
