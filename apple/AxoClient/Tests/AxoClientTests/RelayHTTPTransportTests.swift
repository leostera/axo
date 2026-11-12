import AxoProtocol
import Foundation
import XCTest
@testable import AxoClient

final class RelayHTTPTransportTests: XCTestCase {
  private func setup(_ handler: @escaping @Sendable (URLRequest, [String: Any]) throws -> (Int, Data)) -> (RelayHTTPTransport, URLSession) {
    let key = UUID().uuidString
    HTTPStubProtocol.register(key, handler)
    addTeardownBlock { HTTPStubProtocol.unregister(key) }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HTTPStubProtocol.self]
    config.httpAdditionalHeaders = ["X-HTTP-Test": key]
    let session = URLSession(configuration: config)
    let transport = RelayHTTPTransport(clientID: ClientID(rawValue: "watch-http-test")!, tokens: StaticSessionToken(.fixture()), session: session)
    return (transport, session)
  }

  private static func page(_ frames: [(Int, String)] = []) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["frames": frames.map { ["sequence": $0.0, "frame": $0.1] }])
  }

  func testAccountHandshakeUsesOnlyHTTPSAndBearerAuthentication() async throws {
    let (transport, session) = setup { request, envelope in
      XCTAssertEqual(request.url?.scheme, "https")
      XCTAssertEqual(request.url?.path, "/api/v1/account/client/http")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(SessionToken.fixture().value)")
      XCTAssertFalse(request.httpShouldHandleCookies)
      if envelope["action"] as? String == "send", let frame = envelope["frame"] as? String {
        let call = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        XCTAssertEqual(call["method"] as? String, "axo.client.hello")
        let params = try XCTUnwrap(call["params"] as? [String: Any])
        XCTAssertEqual(params["protocolVersion"] as? Int, 2)
        let reply = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": call["id"]!, "result": ["hosts": [], "sessions": []]])
        return (200, try Self.page([(1, String(decoding: reply, as: UTF8.self))]))
      }
      return (200, try Self.page())
    }
    defer { session.invalidateAndCancel() }
    let account = AccountConnection(transport: transport, clientID: ClientID(rawValue: "watch-http-test")!)
    var events = account.events.makeAsyncIterator()
    try await account.connect()
    guard case .hello(let hello) = await events.next() else { return XCTFail("HTTP hello did not reach the account model") }
    XCTAssertTrue(hello.hosts.isEmpty)
    await account.disconnect()
  }

  func testOverlappingPagesDoNotDuplicateMessagesAndFragmentsAreReassembled() async throws {
    let large = Data(("{\"result\":\"" + String(repeating: "a", count: 90_000) + "\"}").utf8)
    let fragments = try XCTUnwrap(Fragments.split(large))
    let (transport, session) = setup { _, envelope in
      if envelope["action"] as? String == "send" {
        return (200, try Self.page(fragments.enumerated().map { ($0.offset + 1, String(decoding: $0.element, as: UTF8.self)) }))
      }
      return (200, try Self.page())
    }
    defer { session.invalidateAndCancel() }
    let channel = try await transport.connect()
    defer { channel.close() }
    var messages = channel.messages.makeAsyncIterator()
    try await channel.send(Data("{\"id\":1}".utf8))
    let message = await messages.next()
    XCTAssertEqual(message, large)
    // A duplicate page does not yield the large message again.
    try await channel.send(Data("{\"id\":2}".utf8))
    channel.close()
    let next = await messages.next()
    XCTAssertNil(next)
  }

  func testSequenceGapClosesInsteadOfSilentlySkippingAReply() async throws {
    let (transport, session) = setup { _, envelope in
      if envelope["action"] as? String == "send" { return (200, try Self.page([(2, "{}")])) }
      return (200, try Self.page())
    }
    defer { session.invalidateAndCancel() }
    let channel = try await transport.connect()
    defer { channel.close() }
    do { try await channel.send(Data("{}".utf8)); XCTFail("A gap must be rejected") }
    catch { XCTAssertTrue(error is AxoClientError) }
    var messages = channel.messages.makeAsyncIterator()
    let end = await messages.next()
    XCTAssertNil(end)
  }

  func testRevokedSignInIsReportedAsAuthenticationFailure() async throws {
    let (transport, session) = setup { _, _ in (401, Data("{}".utf8)) }
    defer { session.invalidateAndCancel() }
    do { _ = try await transport.connect(); XCTFail("Revoked token cannot connect") }
    catch { XCTAssertEqual(error as? RelayError, .signInRequired) }
  }

  func testDefaultTransportIsPlatformSpecific() {
    #if os(watchOS)
      guard case .https = AccountTransportMode.platformDefault else { return XCTFail("watchOS must never default to WebSockets") }
    #else
      guard case .webSocket = AccountTransportMode.platformDefault else { return XCTFail("Existing desktop/phone transport must be preserved") }
    #endif
  }
}

private final class HTTPStubProtocol: URLProtocol, @unchecked Sendable {
  typealias Handler = @Sendable (URLRequest, [String: Any]) throws -> (Int, Data)
  private static let lock = NSLock()
  private static var handlers: [String: Handler] = [:]
  static func register(_ key: String, _ handler: @escaping Handler) { lock.lock(); defer { lock.unlock() }; handlers[key] = handler }
  static func unregister(_ key: String) { lock.lock(); defer { lock.unlock() }; handlers[key] = nil }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let key = request.value(forHTTPHeaderField: "X-HTTP-Test") ?? ""
      Self.lock.lock(); let handler = Self.handlers[key]; Self.lock.unlock()
      guard let handler else { throw URLError(.cancelled) }
      var bytes = request.httpBody
      if bytes == nil, let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
          let count = stream.read(&buffer, maxLength: buffer.count)
          guard count > 0 else { break }
          body.append(buffer, count: count)
        }
        bytes = body
      }
      let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes ?? Data()) as? [String: Any])
      let (status, body) = try handler(request, envelope)
      let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}
