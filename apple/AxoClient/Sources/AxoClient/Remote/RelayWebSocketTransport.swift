import AxoProtocol
import Foundation

/// The part of a WebSocket the channel uses, so tests can play the peer.
protocol WebSocketTasking: Sendable {
  func send(text: String) async throws
  func receive() async throws -> URLSessionWebSocketTask.Message
  func closeConnection()
}

/// Connections to one host through the account's relay: JSON-RPC text frames over a WebSocket,
/// authenticated with the session token and no cookies. It plugs into `JSONRPCConnection`
/// exactly where the Unix socket does.
public struct RelayWebSocketTransport: AxoTransport {
  /// Larger than the relay's biggest frame (a terminal output batch is up to 128 KiB).
  static let maximumMessageBytes = 512 * 1024
  static let connectTimeout: Duration = .seconds(10)

  private let endpoint: RelayEndpoint
  private let host: RemoteHostRef
  private let tokens: any SessionTokenProvider
  private let session: URLSession

  public init(
    endpoint: RelayEndpoint = .production, host: RemoteHostRef,
    tokens: any SessionTokenProvider, session: URLSession = RelayCredentials.makeURLSession()
  ) {
    self.endpoint = endpoint
    self.host = host
    self.tokens = tokens
    self.session = session
  }

  public func connect() async throws -> any AxoMessageChannel {
    var request = URLRequest(url: endpoint.clientSocketURL(hostID: host.hostId))
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
/// The relay gives each client a bounded number of unacknowledged frames, so every received
/// text frame is acknowledged. A binary frame is a protocol violation: the connection closes
/// rather than guessing.
final class RelayWebSocketChannel: AxoMessageChannel, @unchecked Sendable {
  private static let acknowledgement = #"{"jsonrpc":"2.0","method":"axo.transport.ack","params":{"frames":1}}"#

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
    guard !isClosed, let text = String(data: message, encoding: .utf8) else {
      throw AxoClientError.connectionClosed
    }
    do {
      try await task.send(text: text)
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
    while !isClosed, !Task.isCancelled {
      let frame: URLSessionWebSocketTask.Message
      do {
        frame = try await task.receive()
      } catch {
        break
      }
      guard case .string(let text) = frame else { break }
      continuation.yield(Data(text.utf8))
      Task { [task] in try? await task.send(text: Self.acknowledgement) }
    }
    close()
  }
}
