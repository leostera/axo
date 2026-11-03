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

  func testURLsAreBuiltFromTheOrigin() throws {
    let endpoint = RelayEndpoint.production
    XCTAssertEqual(endpoint.hostPairingsURL.absoluteString, "https://axo.leostera.dev/api/v1/account/host-pairings")
    let client = try XCTUnwrap(ClientID(rawValue: "ios-0123456789abcdef"))
    XCTAssertEqual(
      endpoint.accountClientSocketURL(clientID: client).absoluteString,
      "wss://axo.leostera.dev/api/v1/account/client?clientId=ios-0123456789abcdef")
  }

  func testOnlyWellFormedClientIDsParse() {
    XCTAssertNotNil(ClientID(rawValue: "abc_DEF-1234"))
    XCTAssertNotNil(ClientID.random())
    for bad in ["", "short", String(repeating: "a", count: 65), "has space!", "ünïcode1234", "a/b/c/d/e/f"] {
      XCTAssertNil(ClientID(rawValue: bad), bad)
    }
  }
}

final class SessionTokenTests: XCTestCase {
  func testOnlyCanonicalTokensParse() throws {
    let token = SessionToken.fixture()
    XCTAssertEqual(token.accountID, UUID(uuidString: "6b0f0e0e-2c43-4b8e-9d0a-0d8f7b2b9c11"))
    let secret = String(token.value.split(separator: ".")[2])
    let account = "6b0f0e0e-2c43-4b8e-9d0a-0d8f7b2b9c11"
    for bad in [
      "", "axo1", "axo2.\(account).\(secret)", "axo1.not-a-uuid.\(secret)",
      "axo1.\(account.uppercased()).\(secret)", "axo1.\(account).\(secret.dropLast())",
      "axo1.\(account).\(secret).extra", "axo1.\(account).\(secret.dropLast())B\n",
      "axo1.\(account).\(String(secret.dropLast()))B", "axo1.\(account).\(String(repeating: "A", count: 44))",
      "axo1.\(account).\(secret) ", "axo1.\(account).tökén\(secret.dropFirst(5))",
    ] {
      XCTAssertNil(SessionToken(bad), bad)
    }
  }

  func testAuthorizedRequestsCarryABearerTokenAndNoCookies() async throws {
    let token = SessionToken.fixture()
    let request = try await RelayCredentials.authorize(
      URLRequest(url: URL(string: "https://axo.leostera.dev/api/auth/me")!),
      with: StaticSessionToken(token))
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token.value)")
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

  func testTheAccountIsRequestedWithTheSessionTokenAndDecoded() async throws {
    let loader = StubLoader(status: 200, body: #"{"accountId":"6b0f0e0e-2c43-4b8e-9d0a-0d8f7b2b9c11","profile":{"email":"a@b.c","name":null}}"#)
    let account = try await makeClient(loader).account()
    XCTAssertEqual(account.profile?.email, "a@b.c")
    let request = try XCTUnwrap(loader.requests.first)
    XCTAssertEqual(request.url?.path, "/api/auth/me")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(SessionToken.fixture().value)")
    XCTAssertFalse(request.httpShouldHandleCookies)
  }

  func testAPairingCodeIsAskedForWithAPostAndParsed() async throws {
    let loader = StubLoader(status: 200, body: #"{"code":"7kq2-m4xd","expiresAt":"2026-10-27T10:10:00.000Z"}"#)
    let pairing = try await makeClient(loader).createHostPairing()
    XCTAssertEqual(pairing.code.value, "7KQ2-M4XD")
    XCTAssertEqual(pairing.expiresAt, try Date("2026-10-27T10:10:00Z", strategy: .iso8601))
    XCTAssertEqual(pairing.link.absoluteString, "axo://pair/7KQ2-M4XD")
    XCTAssertEqual(HostPairingCode.fromPairingURL(pairing.link), pairing.code, "the link the Mac opens")
    XCTAssertEqual(
      pairing.installCommand(origin: URL(string: "https://axo.leostera.dev")!),
      "curl -fsSL 'https://axo.leostera.dev/install?code=7KQ2-M4XD' | sh", "what a Mac without Axo runs")
    let request = try XCTUnwrap(loader.requests.first)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/api/v1/account/host-pairings")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(SessionToken.fixture().value)")
  }

  func testAPairingCodeThatIsNotOneIsRefusedAndALimitIsTyped() async {
    do {
      _ = try await makeClient(StubLoader(status: 200, body: #"{"code":"nope","expiresAt":"2026-10-27T10:10:00Z"}"#)).createHostPairing()
      XCTFail("a malformed code must not pass")
    } catch {
      guard case .invalidResponse = error as? AxoClientError else { return XCTFail("\(error)") }
    }
    do {
      _ = try await makeClient(StubLoader(status: 429, body: "")).createHostPairing()
      XCTFail()
    } catch {
      XCTAssertEqual(error as? RelayError, .httpStatus(429))
    }
  }

  func testAnAccessRefusalMeansSignInAgain() async {
    for status in [401, 403] {
      let client = makeClient(StubLoader(status: status, body: "{}"))
      do {
        _ = try await client.account()
        XCTFail("expected a refusal")
      } catch {
        XCTAssertEqual(error as? RelayError, .signInRequired)
      }
    }
  }

  func testACancelledRequestIsACancellationAndANetworkFailureSaysAxoIsUnreachable() async {
    do {
      _ = try await makeClient(StubLoader(failure: URLError(.cancelled))).account()
      XCTFail("expected a cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError, "a cancelled refresh is not a failure: \(error)")
    }
    do {
      _ = try await makeClient(StubLoader(failure: URLError(.notConnectedToInternet))).account()
      XCTFail("expected a failure")
    } catch {
      guard case .unreachable = error as? RelayError else { return XCTFail("\(error)") }
      XCTAssertTrue(error.localizedDescription.hasPrefix("Couldn't reach Axo:"), error.localizedDescription)
    }
  }

  func testOtherStatusesAndGarbageAreTyped() async {
    do {
      _ = try await makeClient(StubLoader(status: 503, body: "")).account()
      XCTFail()
    } catch {
      XCTAssertEqual(error as? RelayError, .httpStatus(503))
    }
    do {
      _ = try await makeClient(StubLoader(status: 200, body: "not json")).account()
      XCTFail()
    } catch {
      guard case .invalidResponse = error as? AxoClientError else { return XCTFail("\(error)") }
    }
  }

  private func makeClient(_ loader: StubLoader) -> AccountClient {
    AccountClient(
      tokens: StaticSessionToken(SessionToken.fixture()), loader: loader)
  }

}

/// Settings › Apps over HTTPS: each route, signed in with the session token, and Axo's refusals.
final class ConnectionsClientTests: XCTestCase {
  private func client(_ loader: StubLoader) -> ConnectionsClient {
    ConnectionsClient(tokens: StaticSessionToken(SessionToken.fixture()), loader: loader)
  }

  private func body(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
  }

  func testTheListingIsReadWithTheSessionToken() async throws {
    let loader = StubLoader(status: 200, body: #"{"connections":[{"kind":"host","name":"studio","hostId":"18355f00-95fd-4c93-8586-a71a8a52bf73","state":"online"}]}"#)
    let connections = try await client(loader).list()
    XCTAssertEqual(connections.count, 1)
    let request = try XCTUnwrap(loader.requests.first)
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(request.url?.absoluteString, "https://axo.leostera.dev/api/v1/account/connections")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(SessionToken.fixture().value)")
    XCTAssertFalse(request.httpShouldHandleCookies, "no cookie: a bearer token needs no Origin to change things")
  }

  func testOneServicesLogIsAskedForByName() async throws {
    let loader = StubLoader(status: 200, body: #"{"records":[]}"#)
    _ = try await client(loader).log(service: "apps.gmail", limit: 20, before: nil)
    let url = try XCTUnwrap(loader.requests.first?.url)
    XCTAssertEqual(url.path, "/api/v1/account/connections/log")
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    XCTAssertEqual(query.first { $0.name == "service" }?.value, "apps.gmail")
    XCTAssertEqual(query.first { $0.name == "limit" }?.value, "20")
  }

  func testATokenIsSentOnceWithTheAccountNameAndOnlyItsNameComesBack() async throws {
    let loader = StubLoader(status: 200, body: #"{"account":"personal"}"#)
    let added = try await client(loader).addToken(app: "apps.hetzner", account: "personal", fields: ["token": "s3cret"])
    XCTAssertEqual(added, "personal")
    let request = try XCTUnwrap(loader.requests.first)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/api/v1/account/connections/apps.hetzner/token")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    let sent = try body(request)
    XCTAssertEqual(sent["account"] as? String, "personal")
    XCTAssertEqual(sent["fields"] as? [String: String], ["token": "s3cret"])

    let unnamed = StubLoader(status: 200, body: #"{"account":"a@b.c"}"#)
    _ = try await client(unnamed).addToken(app: "apps.wise", account: nil, fields: ["token": "x"])
    XCTAssertNil(try body(try XCTUnwrap(unnamed.requests.first))["account"], "an unnamed account sends no name at all")
  }

  func testAxosRefusalIsItsOwnWords() async {
    do {
      _ = try await client(StubLoader(status: 400, body: #"{"error":"Hetzner refused that token."}"#))
        .addToken(app: "apps.hetzner", account: nil, fields: ["token": "bad"])
      XCTFail("a refusal must not pass")
    } catch {
      XCTAssertEqual(error as? ConnectionsRefusal, ConnectionsRefusal(status: 400, message: "Hetzner refused that token."))
      XCTAssertEqual(error.localizedDescription, "Hetzner refused that token.")
    }
    do {
      _ = try await client(StubLoader(status: 401, body: "{}")).list()
      XCTFail()
    } catch {
      XCTAssertEqual(error as? RelayError, .signInRequired)
    }
  }

  func testADeviceSignInStartsWithItsFlowAndCode() async throws {
    let loader = StubLoader(
      status: 200,
      body: #"{"flow":"5c1b3c2e-0f7a-4c0e-9b4f-2d1f7e0a9c11","state":"pending","userCode":"WDJB-MJHT","verificationUrl":"https://auth.openai.com/codex/device","intervalSeconds":5,"expiresAt":"2026-11-02T10:00:00Z"}"#)
    let (flow, state) = try await client(loader).startDeviceSignIn(app: "apps.chatgpt")
    XCTAssertEqual(flow, "5c1b3c2e-0f7a-4c0e-9b4f-2d1f7e0a9c11")
    guard case .pending(let code, _, 5, _) = state else { return XCTFail("\(state)") }
    XCTAssertEqual(code, "WDJB-MJHT")
    let request = try XCTUnwrap(loader.requests.first)
    XCTAssertEqual(request.url?.path, "/api/v1/account/connections/apps.chatgpt/device")
    XCTAssertEqual(request.httpBody, Data("{}".utf8), "a POST with nothing to say still sends JSON")
  }

  func testSigningAnAccountOutNamesItAndRemovingAServerNamesNone() async throws {
    let loader = StubLoader(status: 200, body: #"{"removed":true}"#)
    try await client(loader).remove("apps.gmail", account: "a@b.c")
    try await client(loader).remove("emdash_leostera_com", account: nil)
    XCTAssertEqual(loader.requests.map { $0.url?.path }, [
      "/api/v1/account/connections/apps.gmail/remove", "/api/v1/account/connections/emdash_leostera_com/remove",
    ])
    XCTAssertEqual(try body(loader.requests[0])["account"] as? String, "a@b.c")
    XCTAssertTrue(try body(loader.requests[1]).isEmpty)
  }

  func testABrowserSignInOpensTheAppsPageOnTheWeb() {
    let client = client(StubLoader(status: 200, body: "{}"))
    XCTAssertEqual(
      client.webPage(for: AppConnection(name: "apps.gmail", title: "Gmail")).absoluteString,
      "https://axo.leostera.dev/app/settings/apps/gmail")
    XCTAssertEqual(client.webPage(for: nil).absoluteString, "https://axo.leostera.dev/app/settings/apps/mcp")
  }
}

private final class StubLoader: HTTPDataLoading, @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [URLRequest] = []
  let status: Int
  let body: String
  let failure: Error?

  init(status: Int, body: String) {
    self.status = status
    self.body = body
    self.failure = nil
  }

  init(failure: Error) {
    self.status = 0
    self.body = ""
    self.failure = failure
  }

  var requests: [URLRequest] { lock.withLock { seen } }

  func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    lock.withLock { seen.append(request) }
    if let failure { throw failure }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    return (Data(body.utf8), response)
  }
}

final class RelayWebSocketChannelTests: XCTestCase {
  func testEveryTextFrameIsDeliveredInOrderAndNothingIsAcknowledged() async throws {
    let socket = FakeSocket()
    let channel = RelayWebSocketChannel(task: socket)
    socket.deliver(.string(#"{"a":1}"#))
    socket.deliver(.string(#"{"b":2}"#))
    var iterator = channel.messages.makeAsyncIterator()
    let first = await iterator.next()
    let second = await iterator.next()
    XCTAssertEqual(first.map { String(decoding: $0, as: UTF8.self) }, #"{"a":1}"#)
    XCTAssertEqual(second.map { String(decoding: $0, as: UTF8.self) }, #"{"b":2}"#)
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(socket.sent, [], "there are no delivery credits to return (RFD0018)")
    channel.close()
  }

  func testAMessageLargerThanAFrameArrivesInFragmentsAndLeavesInThem() async throws {
    let socket = FakeSocket()
    let channel = RelayWebSocketChannel(task: socket)
    let big = #"{"jsonrpc":"2.0","method":"x","params":{"text":""# + String(repeating: "é", count: 60_000) + #""}}"#
    let frames = try XCTUnwrap(Fragments.split(Data(big.utf8), messageID: "m1"))
    XCTAssertEqual(frames.count, 3)
    // A discard for another message, and a late fragment of it, change nothing.
    socket.deliver(.string(#"{"jsonrpc":"2.0","method":"axo.transport.discard","params":{"messageId":"gone"}}"#))
    for frame in frames { socket.deliver(.string(String(decoding: frame, as: UTF8.self))) }
    var iterator = channel.messages.makeAsyncIterator()
    let whole = await iterator.next()
    XCTAssertEqual(whole.map { String(decoding: $0, as: UTF8.self) }, big)

    try await channel.send(Data(big.utf8))
    try await socket.waitForSent(count: 3)
    var assembler = FragmentAssembler()
    let outcomes = socket.sent.map { assembler.receive(Data($0.utf8)) }
    XCTAssertEqual(outcomes.last, .message(Data(big.utf8)))
    channel.close()
  }

  func testAFragmentThatBreaksTheRulesEndsTheConnection() async {
    let socket = FakeSocket()
    let channel = RelayWebSocketChannel(task: socket)
    socket.deliver(.string(#"{"jsonrpc":"2.0","method":"axo.transport.fragment","params":{"messageId":"m","index":0,"count":2,"data":"AAAA"}}"#))
    var iterator = channel.messages.makeAsyncIterator()
    let next = await iterator.next()
    XCTAssertNil(next, "a first fragment shorter than a chunk is refused")
    XCTAssertTrue(socket.isClosed)
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

final class AccountConnectionTests: XCTestCase {
  private static let wait: Duration = .seconds(15)
  private let host = RemoteHostRef(hostId: UUID(), hostGeneration: UUID())
  private let clientID = ClientID(rawValue: "ios-test-client")!

  private var hello: String {
    #"{"hosts":[{"hostId":"\#(host.hostId.uuidString.lowercased())","hostGeneration":"\#(host.hostGeneration.uuidString.lowercased())","label":"Studio","hostKind":"macos","online":true,"lastSeenAt":"2026-10-16T00:00:00Z"}],"sessions":[{"hostId":"\#(host.hostId.uuidString.lowercased())","sessionId":"00000003-0000-4000-8000-000000000003","metadata":{"name":"Chat","emoji":null,"workspaceId":null,"workspaceName":null,"hasAgent":true,"createdAt":null,"lastMessageAt":null,"archived":false},"epoch":1,"head":2,"status":"ready"}]}"#
  }

  private func connect() async throws -> (AccountConnection, FakeChannel) {
    let transport = FakeTransport(hello: hello)
    let account = AccountConnection(transport: transport, clientID: clientID)
    try await account.connect()
    return (account, try await transport.channel(0))
  }

  private func next(_ account: AccountConnection) async throws -> AccountEvent? {
    var iterator = account.events.makeAsyncIterator()
    return try await withThrowingTaskGroup(of: AccountEvent?.self) { group in
      group.addTask { await iterator.next() }
      group.addTask {
        try await Task.sleep(for: Self.wait)
        return nil
      }
      defer { group.cancelAll() }
      return try await group.next() ?? nil
    }
  }

  private func request(_ channel: FakeChannel, _ index: Int) async throws -> [String: Any] {
    let raw = try await channel.rawRequests(count: index + 1)[index]
    return try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
  }

  func testEveryConnectionSaysHelloAsThisClientAndListsEverything() async throws {
    let transport = FakeTransport(hello: hello)
    let account = AccountConnection(transport: transport, clientID: clientID)
    try await account.connect()
    let channel = try await transport.channel(0)
    XCTAssertEqual(channel.helloParams?["clientId"] as? String, "ios-test-client")
    XCTAssertEqual(channel.helloParams?["protocolVersion"] as? Int, 2)
    guard case .hello(let listing)? = try await next(account) else { return XCTFail("expected hello") }
    XCTAssertEqual(listing.hosts.map(\.reference), [host])
    XCTAssertEqual(listing.sessions.map(\.sessionId), [3])

    // A replacement connection says hello again, and the listing comes again.
    channel.endFromPeer()
    try await Task.sleep(for: .milliseconds(50))
    try await account.connect()
    _ = try await transport.channel(1)
    guard case .hello? = try await next(account) else { return XCTFail("expected hello again") }
  }

  func testCommandsNameTheHostAndTheRunOfItLowercase() async throws {
    let (account, channel) = try await connect()
    let upper = RemoteHostRef(
      hostId: UUID(uuidString: "ABCDEF00-95FD-4C93-8586-A71A8A52BF73")!,
      hostGeneration: UUID(uuidString: "C3B6DA28-55C0-4BB0-AC04-DD458FD41A2B")!)
    let connection = HostConnection(account: account, host: upper)
    async let created = connection.createSession(inWorkspace: UUID(uuidString: "7F1918D3-8B6D-4AF4-A57E-7E6AE28E89E2")!)
    let sent = try await request(channel, 0)
    XCTAssertEqual(sent["method"] as? String, "axo.client.command")
    let params = try XCTUnwrap(sent["params"] as? [String: Any])
    XCTAssertEqual(params["hostId"] as? String, "abcdef00-95fd-4c93-8586-a71a8a52bf73")
    XCTAssertEqual(params["method"] as? String, "axo.remote.workspace.session.create")
    let raw = String(decoding: try await channel.rawRequests(count: 1)[0], as: UTF8.self)
    XCTAssertTrue(raw.contains("c3b6da28-55c0-4bb0-ac04-dd458fd41a2b"), raw)
    XCTAssertTrue(raw.contains("7f1918d3-8b6d-4af4-a57e-7e6ae28e89e2"), raw)
    XCTAssertFalse(raw.contains("ABCDEF00") || raw.contains("C3B6DA28"), "no uppercase identity may leave the app")
    channel.reply(
      to: try XCTUnwrap(sent["id"] as? Int),
      result: #"{"session":{"hostId":"abcdef00-95fd-4c93-8586-a71a8a52bf73","sessionId":"00000007-0000-4000-8000-000000000007","shells":[],"layout":null,"updatedAt":"2026-10-16T00:00:00Z"}}"#)
    let session = try await created
    XCTAssertEqual(session.sessionId, 7)
  }

  func testAMacIsRenamedOnTheAccountSocketByItsLowercaseIdAndAnswersItsName() async throws {
    let (account, channel) = try await connect()
    async let renamed = account.renameHost(UUID(uuidString: "ABCDEF00-95FD-4C93-8586-A71A8A52BF73")!, to: "Studio")
    let sent = try await request(channel, 0)
    XCTAssertEqual(sent["method"] as? String, "axo.client.host.rename", "the account's, not a command to the Mac")
    let params = try XCTUnwrap(sent["params"] as? [String: Any])
    XCTAssertEqual(params["hostId"] as? String, "abcdef00-95fd-4c93-8586-a71a8a52bf73")
    XCTAssertEqual(params["name"] as? String, "Studio")
    channel.reply(to: try XCTUnwrap(sent["id"] as? Int), result: #"{"label":"Studio"}"#)
    let label = try await renamed
    XCTAssertEqual(label, "Studio")
  }

  func testASessionCreatedOnAnotherHostIsRefused() async throws {
    let (account, channel) = try await connect()
    async let created = HostConnection(account: account, host: host).createSession()
    let sent = try await request(channel, 0)
    channel.reply(
      to: try XCTUnwrap(sent["id"] as? Int),
      result: #"{"session":{"hostId":"\#(UUID().uuidString)","sessionId":"00000007-0000-4000-8000-000000000007","shells":[],"layout":null,"updatedAt":"2026-10-16T00:00:00Z"}}"#)
    do {
      _ = try await created
      XCTFail("a Session from elsewhere must not be accepted")
    } catch {
      guard case .invalidResponse = error as? AxoClientError else { return XCTFail("\(error)") }
    }
  }

  func testAPromptMustBeAcceptedAndAnOfflineHostFailsAtOnce() async throws {
    let (account, channel) = try await connect()
    let connection = HostConnection(account: account, host: host)
    let commandId = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    async let refused: Void = connection.promptPi(in: 3, text: "run the tests", commandId: commandId)
    let first = try await request(channel, 0)
    let inner = try XCTUnwrap((first["params"] as? [String: Any])?["params"] as? [String: Any])
    XCTAssertEqual(inner["text"] as? String, "run the tests")
    XCTAssertEqual(inner["commandId"] as? String, "6f9619ff-8b86-d011-b42d-00c04fc964ff", "lowercased, as the relay keys it")
    XCTAssertEqual(inner["sessionId"] as? String, SessionID.fixture(3).rawValue)
    channel.reply(to: try XCTUnwrap(first["id"] as? Int), result: #"{"accepted":false}"#)
    do {
      try await refused
      XCTFail("a refusal must not count as sent")
    } catch {
      guard case .invalidResponse = error as? AxoClientError else { return XCTFail("\(error)") }
    }

    async let offline: Void = connection.promptPi(in: 3, text: "again", commandId: UUID())
    let second = try await request(channel, 1)
    channel.send(raw: #"{"jsonrpc":"2.0","id":\#(try XCTUnwrap(second["id"] as? Int)),"error":{"code":-32005,"message":"Host offline; nothing queued"}}"#)
    do {
      try await offline
      XCTFail()
    } catch {
      guard case .serverRejected(let code, _) = error as? AxoClientError else { return XCTFail("\(error)") }
      XCTAssertEqual(code, -32005)
    }
  }

  func testOpeningAskForAWindowOrWhatFollowsWhatIsHeld() async throws {
    let (account, channel) = try await connect()
    async let windowed = account.open(3, on: host.hostId, window: 500)
    let first = try await request(channel, 0)
    XCTAssertEqual(first["method"] as? String, "axo.client.session.open")
    let params = try XCTUnwrap(first["params"] as? [String: Any])
    XCTAssertEqual(params["window"] as? [String: Int], ["last": 64])
    XCTAssertNil(params["have"])
    channel.reply(
      to: try XCTUnwrap(first["id"] as? Int),
      result: #"{"epoch":1,"records":[{"cursor":2,"id":"e2","format":"pi/3","line":"{}","hash":"sha256:\#(String(repeating: "0", count: 64))"}],"cursor":2,"older":2,"progress":[{"slot":"message","snapshot":null}]}"#)
    let opened = try await windowed
    XCTAssertEqual(opened.records.map(\.cursor), [2])
    XCTAssertEqual(opened.progress, [ProgressSnapshot(slot: "message", snapshot: .null)])

    async let resumed = account.open(3, on: host.hostId, have: (epoch: 1, cursor: 2))
    let second = try await request(channel, 1)
    let have = try XCTUnwrap((second["params"] as? [String: Any])?["have"] as? [String: Int])
    XCTAssertEqual(have, ["epoch": 1, "cursor": 2])
    XCTAssertNil((second["params"] as? [String: Any])?["window"])
    channel.reply(to: try XCTUnwrap(second["id"] as? Int), result: #"{"epoch":1,"records":[],"cursor":2,"older":null,"progress":[]}"#)
    _ = try await resumed
  }

  func testNoticesBecomeEventsAndAcknowledgementsAndClosesAreSent() async throws {
    let (account, channel) = try await connect()
    guard case .hello? = try await next(account) else { return XCTFail() }
    let session = "00000003-0000-4000-8000-000000000003"
    channel.send(raw: #"{"jsonrpc":"2.0","method":"axo.client.session.records","params":{"garbage":true}}"#)
    channel.send(raw: #"{"jsonrpc":"2.0","method":"axo.client.session.records","params":{"sessionId":"\#(session)","epoch":1,"records":[{"cursor":3,"id":"e3","format":"pi/3","line":"{}","hash":"sha256:\#(String(repeating: "0", count: 64))"}],"cursor":3}}"#)
    channel.send(raw: #"{"jsonrpc":"2.0","method":"axo.client.session.progress","params":{"sessionId":"\#(session)","slot":"question","snapshot":{"kind":"confirm"}}}"#)
    channel.send(raw: #"{"jsonrpc":"2.0","method":"axo.client.session.reset","params":{"sessionId":"\#(session)","epoch":2,"keep":1}}"#)
    channel.send(raw: #"{"jsonrpc":"2.0","method":"axo.client.hosts","params":{"hosts":[]}}"#)
    guard case .records(let id, 1, let records, 3)? = try await next(account) else { return XCTFail("the garbage is dropped") }
    XCTAssertEqual(id, 3)
    XCTAssertEqual(records.map(\.id), ["e3"])
    guard case .progress(_, "question", let snapshot)? = try await next(account) else { return XCTFail() }
    XCTAssertEqual(snapshot["kind"]?.stringValue, "confirm")
    guard case .reset(_, 2, 1)? = try await next(account) else { return XCTFail() }
    guard case .hosts([])? = try await next(account) else { return XCTFail() }

    await account.acknowledge(3, cursor: 3)
    await account.close(3)
    let ack = try await request(channel, 0)
    XCTAssertEqual(ack["method"] as? String, "axo.client.session.ack")
    XCTAssertNil(ack["id"], "an acknowledgement is not answered")
    XCTAssertEqual((ack["params"] as? [String: Any])?["cursor"] as? Int, 3)
    let close = try await request(channel, 1)
    XCTAssertEqual(close["method"] as? String, "axo.client.session.close")
  }

  func testAConnectionWhoseHelloIsRefusedIsClosedAndConnectingFails() async throws {
    let transport = FakeTransport()
    let account = AccountConnection(transport: transport, clientID: clientID)
    async let connected: Void = account.connect()
    let channel = try await transport.channel(0)
    let first = try await request(channel, 0)
    XCTAssertEqual(first["method"] as? String, "axo.client.hello")
    channel.send(raw: #"{"jsonrpc":"2.0","id":\#(try XCTUnwrap(first["id"] as? Int)),"error":{"code":-32602,"message":"no thanks"}}"#)
    do {
      try await connected
      XCTFail("a refused hello must fail")
    } catch {
      guard case .serverRejected(let code, _) = error as? AxoClientError else { return XCTFail("\(error)") }
      XCTAssertEqual(code, -32602)
    }
    XCTAssertTrue(channel.isClosed)
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

extension SessionToken {
  /// A well-formed token for tests; `seed` makes different ones.
  static func fixture(_ seed: UInt8 = 0) -> SessionToken {
    let secret = Data((0..<32).map { UInt8(($0 &+ Int(seed)) & 0xFF) }).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return SessionToken("axo1.6b0f0e0e-2c43-4b8e-9d0a-0d8f7b2b9c11.\(secret)")!
  }
}
