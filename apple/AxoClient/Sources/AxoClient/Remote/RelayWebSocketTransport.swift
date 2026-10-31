import AxoProtocol
import Foundation

/// The part of a WebSocket the channel uses, so tests can play the peer.
protocol WebSocketTasking: Sendable {
  func send(text: String) async throws
  func receive() async throws -> URLSessionWebSocketTask.Message
  func closeConnection()
}

/// The account's socket (RFD0018): JSON-RPC text frames over one WebSocket to this client's
/// ClientDO, authenticated with the session token and no cookies. It plugs into
/// `JSONRPCConnection` exactly where the Unix socket does.
public struct RelayWebSocketTransport: AxoTransport {
  /// One frame; larger messages come in fragments.
  static let maximumMessageBytes = 128 * 1024
  static let connectTimeout: Duration = .seconds(10)

  private let endpoint: RelayEndpoint
  private let clientID: ClientID
  private let tokens: any SessionTokenProvider
  private let session: URLSession

  public init(
    endpoint: RelayEndpoint = .production, clientID: ClientID,
    tokens: any SessionTokenProvider, session: URLSession = RelayCredentials.makeURLSession()
  ) {
    self.endpoint = endpoint
    self.clientID = clientID
    self.tokens = tokens
    self.session = session
  }

  public func connect() async throws -> any AxoMessageChannel {
    var request = URLRequest(url: endpoint.accountClientSocketURL(clientID: clientID))
    request.timeoutInterval = Double(Self.connectTimeout.components.seconds)
    request = try await RelayCredentials.authorize(request, with: tokens)
    let task = session.webSocketTask(with: request)
    task.maximumMessageSize = Self.maximumMessageBytes
    task.resume()
    do {
      // A ping is answered only after the upgrade succeeded.
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        task.sendPing { error in
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
      }
    } catch {
      let status = (task.response as? HTTPURLResponse)?.statusCode
      task.cancel(with: .goingAway, reason: nil)
      switch status {
      case 401, 403: throw RelayError.signInRequired
      case .some(let status) where status != 101: throw RelayError.httpStatus(status)
      default: throw AxoClientError.connectionFailed(error.localizedDescription)
      }
    }
    return RelayWebSocketChannel(task: task)
  }
}

extension URLSessionWebSocketTask: WebSocketTasking {
  func send(text: String) async throws {
    try await send(.string(text))
  }

  func closeConnection() {
    cancel(with: .normalClosure, reason: nil)
  }
}

/// One open relay connection.
///
/// Messages larger than a frame arrive in fragments and leave in them; a binary frame, or a
/// fragment that breaks the rules, is a protocol violation: the connection closes rather than
/// guessing.
final class RelayWebSocketChannel: AxoMessageChannel, @unchecked Sendable {
  let messages: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  private let task: any WebSocketTasking
  private let lock = NSLock()
  private var closed = false
  private var reader: Task<Void, Never>?

  init(task: any WebSocketTasking) {
    self.task = task
    (messages, continuation) = AsyncStream<Data>.makeStream()
    reader = Task { [weak self] in await self?.readUntilEnd() }
  }

  func send(_ message: Data) async throws {
    guard !isClosed, let frames = Fragments.split(message) else {
      throw AxoClientError.connectionClosed
    }
    do {
      for frame in frames {
        guard let text = String(data: frame, encoding: .utf8) else { throw AxoClientError.connectionClosed }
        try await task.send(text: text)
      }
    } catch {
      close()
      throw AxoClientError.connectionClosed
    }
  }

  func close() {
    let wasOpen = lock.withLock { () -> Bool in
      defer { closed = true }
      return !closed
    }
    guard wasOpen else { return }
    reader?.cancel()
    task.closeConnection()
    continuation.finish()
  }

  private var isClosed: Bool { lock.withLock { closed } }

  private func readUntilEnd() async {
    var assembler = FragmentAssembler()
    reading: while !isClosed, !Task.isCancelled {
      let frame: URLSessionWebSocketTask.Message
      do {
        frame = try await task.receive()
      } catch {
        break
      }
      guard case .string(let text) = frame else { break }
      switch assembler.receive(Data(text.utf8)) {
      case .message(let message): continuation.yield(message)
      case .pending: continue
      case .invalid: break reading
      }
    }
    close()
  }
}
