import AxoProtocol
import Foundation
import Network
import XCTest

@testable import AxoClient

/// The real URLSession WebSocket against a loopback server: what actually goes on the wire.
final class RelayWebSocketLoopbackTests: XCTestCase {
  func testTheUpgradeCarriesTheSessionTokenAndNoCookiesAndFramesAreAcknowledged() async throws {
    let server = try LoopbackRelay()
    defer { server.stop() }
    let port = try await server.start()

    // A cookie for the same host must not reach the relay.
    let origin = URL(string: "http://127.0.0.1:\(port)")!
    HTTPCookieStorage.shared.setCookie(
      HTTPCookie(properties: [
        .domain: "127.0.0.1", .path: "/", .name: "CF_Authorization", .value: "browser-cookie",
      ])!)
    defer { HTTPCookieStorage.shared.removeCookies(since: .distantPast) }

    let host = RemoteHostRef(hostId: UUID(), hostGeneration: UUID())
    let transport = RelayWebSocketTransport(
      endpoint: try XCTUnwrap(RelayEndpoint(origin: origin, allowInsecureLoopback: true)),
      host: host, tokens: StaticSessionToken(try XCTUnwrap(SessionToken.fixture(3))))
    let rpc = JSONRPCConnection(transport: transport)
    let reply: Echo = try await rpc.call("echo", params: Echo(value: "ping"), timeout: .seconds(15))
    XCTAssertEqual(reply.value, "pong")

    let seen = try await server.upgradeHeaders()
    XCTAssertEqual(seen["authorization"], "Bearer \(SessionToken.fixture(3).value)")
    XCTAssertNil(seen["cookie"], "no cookie may accompany the session token")
    try await server.waitForAcknowledgement()
    await rpc.disconnect()
  }

  func testARefusedUpgradeIsReportedAsSignInRequired() async throws {
    let server = try RefusingServer(status: "403 Forbidden")
    defer { server.stop() }
    let port = try await server.start()
    let transport = RelayWebSocketTransport(
      endpoint: try XCTUnwrap(
        RelayEndpoint(origin: URL(string: "http://127.0.0.1:\(port)")!, allowInsecureLoopback: true)),
      host: RemoteHostRef(hostId: UUID(), hostGeneration: UUID()),
      tokens: StaticSessionToken(try XCTUnwrap(SessionToken.fixture(4))))
    do {
      _ = try await transport.connect()
      XCTFail("a refused upgrade must not connect")
    } catch {
      XCTAssertEqual(error as? RelayError, .signInRequired)
    }
  }
}

private final class HeaderRecord: @unchecked Sendable {
  private let lock = NSLock()
  private var headers: [String: String]?
  func set(_ value: [String: String]) { lock.withLock { headers = value } }
  func get() -> [String: String]? { lock.withLock { headers } }
}

/// A one-connection WebSocket relay: records the upgrade, answers `echo` calls, notes acks.
private final class LoopbackRelay: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "loopback-relay")
  private let lock = NSLock()
  private var acknowledged = false
  private var connections: [NWConnection] = []

  init() throws {
    let options = NWProtocolWebSocket.Options()
    options.autoReplyPing = true
    let record = HeaderRecord()
    headerRecord = record
    // The handler must be set before the options are copied into the listener's parameters.
    options.setClientRequestHandler(queue) { _, additionalHeaders in
      var seen: [String: String] = [:]
      for header in additionalHeaders { seen[header.name.lowercased()] = header.value }
      record.set(seen)
      return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
    }
    let parameters = NWParameters.tcp
    parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
    listener = try NWListener(using: parameters, on: .any)
  }

  private let headerRecord: HeaderRecord

  func start() async throws -> UInt16 {
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { return }
      lock.withLock { self.connections.append(connection) }
      connection.start(queue: queue)
      receive(on: connection)
    }
    return try await withCheckedThrowingContinuation { continuation in
      let resumed = NSLock()
      var done = false
      listener.stateUpdateHandler = { [listener] state in
        resumed.lock()
        defer { resumed.unlock() }
        guard !done else { return }
        switch state {
        case .ready:
          done = true
          continuation.resume(returning: listener.port!.rawValue)
        case .failed(let error):
          done = true
          continuation.resume(throwing: error)
        default: break
        }
      }
      listener.start(queue: queue)
    }
  }

  func stop() {
    listener.cancel()
    lock.withLock { self.connections }.forEach { $0.cancel() }
  }

  private func receive(on connection: NWConnection) {
    connection.receiveMessage { [weak self] data, context, _, error in
      guard let self, error == nil else { return }
      let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
        as? NWProtocolWebSocket.Metadata
      if metadata?.opcode == .text, let data, let text = String(data: data, encoding: .utf8) {
        if text.contains("axo.transport.ack") {
          lock.withLock { self.acknowledged = true }
        } else if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = object["id"]
        {
          let reply = #"{"jsonrpc":"2.0","id":\#(id),"result":{"value":"pong"}}"#
          let out = NWProtocolWebSocket.Metadata(opcode: .text)
          connection.send(
            content: Data(reply.utf8),
            contentContext: NWConnection.ContentContext(identifier: "reply", metadata: [out]),
            completion: .idempotent)
        }
      }
      receive(on: connection)
    }
  }

  func upgradeHeaders() async throws -> [String: String] {
    try await wait { self.headerRecord.get() }
  }

  func waitForAcknowledgement() async throws {
    _ = try await wait { self.acknowledged ? true : nil }
  }

  private func wait<Value>(_ read: @escaping () -> Value?) async throws -> Value {
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline {
      if let value = lock.withLock({ read() }) { return value }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw AxoClientError.requestTimedOut
  }
}

/// Answers every connection with a bare HTTP status, as the relay does for a caller it refuses.
private final class RefusingServer: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "refusing-server")
  private let status: String

  init(status: String) throws {
    self.status = status
    listener = try NWListener(using: .tcp, on: .any)
  }

  func start() async throws -> UInt16 {
    listener.newConnectionHandler = { [status, queue] connection in
      connection.start(queue: queue)
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(
          content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
      }
    }
    return try await withCheckedThrowingContinuation { continuation in
      let guardLock = NSLock()
      var done = false
      listener.stateUpdateHandler = { [listener] state in
        guardLock.lock()
        defer { guardLock.unlock() }
        guard !done else { return }
        switch state {
        case .ready:
          done = true
          continuation.resume(returning: listener.port!.rawValue)
        case .failed(let error):
          done = true
          continuation.resume(throwing: error)
        default: break
        }
      }
      listener.start(queue: queue)
    }
  }

  func stop() { listener.cancel() }
}
