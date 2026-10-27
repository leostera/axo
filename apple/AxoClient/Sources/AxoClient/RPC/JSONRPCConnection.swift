import Foundation

/// JSON-RPC 2.0 calls to one host over a persistent connection, many in flight at once
/// (axod answers each as it completes, matched by id).
///
/// Invariants:
/// - Every call ends exactly once: with its reply, its timeout, its task's cancellation, or the
///   end of its connection. Nothing is left waiting for a reply that will not come.
/// - A connection on which a call timed out is retired: new calls open a fresh connection, so a
///   wedged connection is replaced, while calls already in flight on it still complete. A retired
///   connection closes once its last call has ended.
/// - At most one connect is in progress; concurrent first calls share it.
/// - A connection's handshake (if any) runs on each new connection before any other call can use
///   it, and a connection whose handshake fails is closed, never used.
/// - Ids are unique across connections, so a late reply can only match its own call, which
///   has already ended, and is dropped.
public actor JSONRPCConnection {
  private let transport: any AxoTransport
  private let handshake: Handshake?
  private var current: Link?
  private var connecting: Task<Link, Error>?
  private var nextID = 1
  private var calls: [Int: Call] = [:]
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let notificationSink: AsyncStream<JSONRPCNotification>.Continuation
  private let lossSink: AsyncStream<Void>.Continuation

  /// Yields each time the connection in use ends (dropped, or `disconnect()`) with no newer one
  /// to take over. Notifications stop until the next call connects again, so a caller that wants
  /// them reconnects. Never finishes on its own.
  public nonisolated let connectionLost: AsyncStream<Void>

  /// Messages the host sent without being asked (JSON-RPC notifications), in order, from every
  /// connection this object opens. Never finishes on its own.
  public nonisolated let notifications: AsyncStream<JSONRPCNotification>

  /// What a host needs said on every new connection before anything else, such as agreeing on a
  /// protocol version. `LinkCaller` calls go on that connection only.
  public typealias Handshake = @Sendable (LinkCaller) async throws -> Void

  /// Calls on one particular connection, for a handshake.
  public struct LinkCaller: Sendable {
    fileprivate let connection: JSONRPCConnection
    fileprivate let link: Link

    public func call<Params: Encodable & Sendable, Result: Decodable & Sendable>(
      _ method: String, params: Params, timeout: Duration
    ) async throws -> Result {
      try await connection.perform(method, params: params, timeout: timeout, on: link)
    }
  }

  public init(transport: any AxoTransport, handshake: Handshake? = nil) {
    self.transport = transport
    self.handshake = handshake
    (notifications, notificationSink) = AsyncStream.makeStream(
      bufferingPolicy: .bufferingNewest(1024))
    (connectionLost, lossSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  /// Calls `method` and decodes its result, or fails with an `AxoClientError` (or
  /// `CancellationError`). `timeout` bounds the wait for the reply, not the connect, which the
  /// transport bounds.
  public func call<Params: Encodable & Sendable, Result: Decodable & Sendable>(
    _ method: String, params: Params, timeout: Duration
  ) async throws -> Result {
    try Task.checkCancellation()
    let link = try await openLink()
    return try await perform(method, params: params, timeout: timeout, on: link)
  }

  private func perform<Params: Encodable & Sendable, Result: Decodable & Sendable>(
    _ method: String, params: Params, timeout: Duration, on link: Link
  ) async throws -> Result {
    let id = nextID
    nextID += 1
    let request = try encoder.encode(JSONRPCRequest(id: id, method: method, params: params))

    let reply = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
        let timer = Task { [weak self] in
          try await Task.sleep(for: timeout)
          await self?.end(id, with: .failure(AxoClientError.requestTimedOut))
        }
        calls[id] = Call(continuation: continuation, link: link, timer: timer)
        link.inFlight += 1
        Task { await self.send(request, for: id, on: link) }
      }
    } onCancel: {
      Task { await self.end(id, with: .failure(CancellationError())) }
    }
    return try decodeResult(reply)
  }

  /// Opens a connection (running its handshake) if there is none, without calling anything.
  public func connect() async throws {
    try Task.checkCancellation()
    _ = try await openLink()
  }

  /// Closes the connection now. Calls in flight fail with `connectionClosed`; the next call
  /// connects again.
  public func disconnect() {
    guard let link = current else { return }
    linkEnded(link)
  }

  // MARK: - Connections

  fileprivate final class Link: @unchecked Sendable {
    let channel: any AxoMessageChannel
    var inFlight = 0
    var isRetired = false
    /// It passed its handshake and served calls (and notifications).
    var wasCurrent = false

    init(channel: any AxoMessageChannel) {
      self.channel = channel
    }
  }

  private struct Call {
    let continuation: CheckedContinuation<Data, Error>
    let link: Link
    let timer: Task<Void, Error>
  }

  private func openLink() async throws -> Link {
    if let current { return current }
    if let connecting { return try await connecting.value }
    let task = Task { [transport] in
      let channel = try await transport.connect()
      return try await self.start(channel)
    }
    connecting = task
    defer {
      if connecting == task { connecting = nil }
    }
    return try await task.value
  }

  /// Starts reading a new connection, runs the handshake on it, and only then makes it current.
  private func start(_ channel: any AxoMessageChannel) async throws -> Link {
    let link = adopt(channel)
    if let handshake {
      do {
        try await handshake(LinkCaller(connection: self, link: link))
      } catch {
        linkEnded(link)
        throw error
      }
    }
    current = link
    link.wasCurrent = true
    return link
  }

  private func adopt(_ channel: any AxoMessageChannel) -> Link {
    let link = Link(channel: channel)
    Task { [weak self] in
      for await message in channel.messages {
        await self?.receive(message)
      }
      await self?.linkEnded(link)
    }
    return link
  }

  private func send(_ request: Data, for id: Int, on link: Link) async {
    do {
      try await link.channel.send(request)
    } catch {
      end(id, with: .failure(AxoClientError.connectionClosed))
    }
  }

  private func receive(_ message: Data) {
    guard let header = try? decoder.decode(JSONRPCMessageHeader.self, from: message) else { return }
    // Replies carry our numeric id; late or foreign replies have no call waiting for them.
    if let id = header.id {
      end(id, with: .success(message))
    } else if let method = header.method {
      notificationSink.yield(JSONRPCNotification(method: method, message: message))
    }
  }

  /// Ends a call if it has not ended yet. A timeout retires its connection.
  private func end(_ id: Int, with result: Swift.Result<Data, Error>) {
    guard let call = calls.removeValue(forKey: id) else { return }
    call.timer.cancel()
    call.continuation.resume(with: result)
    call.link.inFlight -= 1
    if case .failure(AxoClientError.requestTimedOut) = result {
      retire(call.link)
    }
    closeIfIdle(call.link)
  }

  private func retire(_ link: Link) {
    link.isRetired = true
    if current === link { current = nil }
  }

  private func closeIfIdle(_ link: Link) {
    if link.isRetired, link.inFlight == 0 { link.channel.close() }
  }

  private func linkEnded(_ link: Link) {
    // Once only: a link ends by being closed here and again when its reader sees the close.
    let lost = link.wasCurrent && (current == nil || current === link)
    link.wasCurrent = false
    retire(link)
    if lost { lossSink.yield() }
    for (id, call) in calls where call.link === link {
      end(id, with: .failure(AxoClientError.connectionClosed))
    }
    link.channel.close()
  }

  // MARK: - Messages

  private func decodeResult<Result: Decodable>(_ reply: Data) throws -> Result {
    let decoded: JSONRPCReply<Result>
    do {
      decoded = try decoder.decode(JSONRPCReply<Result>.self, from: reply)
    } catch {
      throw AxoClientError.invalidResponse("could not decode the reply: \(error)")
    }
    if let error = decoded.error {
      throw AxoClientError.serverRejected(code: error.code, message: error.message)
    }
    guard let result = decoded.result else {
      throw AxoClientError.invalidResponse("the reply has neither a result nor an error")
    }
    return result
  }
}

private struct JSONRPCRequest<Params: Encodable>: Encodable {
  let jsonrpc = "2.0"
  let id: Int
  let method: String
  let params: Params
}

/// A message the host sent unprompted: its method and the whole message to decode `params` from.
public struct JSONRPCNotification: Sendable {
  public let method: String
  public let message: Data

  /// Decodes the notification's `params`.
  public func params<Params: Decodable>(as type: Params.Type) throws -> Params {
    try JSONDecoder().decode(NotificationEnvelope<Params>.self, from: message).params
  }
}

private struct NotificationEnvelope<Params: Decodable>: Decodable {
  let params: Params
}

/// Just enough of a message to route it.
private struct JSONRPCMessageHeader: Decodable {
  let id: Int?
  let method: String?

  private enum CodingKeys: String, CodingKey { case id, method }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try? container.decodeIfPresent(Int.self, forKey: .id)
    method = try? container.decodeIfPresent(String.self, forKey: .method)
  }
}

private struct JSONRPCReply<Result: Decodable>: Decodable {
  let result: Result?
  let error: JSONRPCErrorObject?
}

private struct JSONRPCErrorObject: Decodable {
  let code: Int
  let message: String
}
