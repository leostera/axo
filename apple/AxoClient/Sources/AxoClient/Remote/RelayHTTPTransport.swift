import AxoProtocol
import Foundation

/// watchOS permits URLSession HTTPS but blocks ordinary apps from opening WebSockets (TN3135).
/// This carries the existing protocol-2 frames over an acknowledged HTTPS mailbox instead.
public struct RelayHTTPTransport: AxoTransport {
  private let endpoint: RelayEndpoint
  private let clientID: ClientID
  private let tokens: any SessionTokenProvider
  private let session: URLSession

  public init(endpoint: RelayEndpoint = .production, clientID: ClientID, tokens: any SessionTokenProvider,
    session: URLSession = RelayCredentials.makeURLSession()
  ) {
    self.endpoint = endpoint
    self.clientID = clientID
    self.tokens = tokens
    self.session = session
  }

  public func connect() async throws -> any AxoMessageChannel {
    let (messages, sink) = AsyncStream<Data>.makeStream()
    let connection = HTTPRelayConnection(url: endpoint.accountClientHTTPURL(clientID: clientID), tokens: tokens, session: session, sink: sink)
    do {
      try await connection.open()
      return HTTPRelayChannel(connection: connection, messages: messages, sink: sink)
    } catch { sink.finish(); throw error }
  }
}

/// Explicit selection also lets integration tests exercise HTTPS on macOS/iOS.
public enum AccountTransportMode: Sendable {
  case webSocket, https

  public static var platformDefault: Self {
    #if os(watchOS)
      .https
    #else
      .webSocket
    #endif
  }
}

private struct HTTPRelayRequest: Encodable {
  let connectionId: String
  let action: String
  let after: Int64
  let frame: String?
}
private struct HTTPRelayPage: Decodable {
  struct Frame: Decodable { let sequence: Int64; let frame: String }
  let frames: [Frame]
}

private final class HTTPRelayChannel: AxoMessageChannel, @unchecked Sendable {
  let messages: AsyncStream<Data>
  private let connection: HTTPRelayConnection
  private let sink: AsyncStream<Data>.Continuation
  private let lock = NSLock()
  private var closed = false
  private var reader: Task<Void, Never>?

  init(connection: HTTPRelayConnection, messages: AsyncStream<Data>, sink: AsyncStream<Data>.Continuation) {
    self.connection = connection
    self.messages = messages
    self.sink = sink
    reader = Task { [weak self, connection] in
      do { while !Task.isCancelled { try await connection.poll() } } catch {}
      self?.close()
    }
  }

  func send(_ message: Data) async throws {
    guard lock.withLock({ !closed }) else { throw AxoClientError.connectionClosed }
    do { try await connection.send(message) }
    catch { close(); throw error }
  }

  func close() {
    guard lock.withLock({ if closed { return false }; closed = true; return true }) else { return }
    reader?.cancel()
    sink.finish()
    Task { [connection] in await connection.close() }
  }
}

private actor HTTPRelayConnection {
  private let id = UUID().uuidString.lowercased()
  private let url: URL
  private let tokens: any SessionTokenProvider
  private let session: URLSession
  private let sink: AsyncStream<Data>.Continuation
  private var cursor: Int64 = 0
  private var closed = false
  private var assembler = FragmentAssembler()

  init(url: URL, tokens: any SessionTokenProvider, session: URLSession, sink: AsyncStream<Data>.Continuation) {
    self.url = url
    self.tokens = tokens
    self.session = session
    self.sink = sink
  }

  func open() async throws { _ = try await exchange("connect") }
  func poll() async throws {
    let clock = ContinuousClock()
    let start = clock.now
    let receivedFrames = try await exchange("poll")
    let elapsed = start.duration(to: clock.now)
    // A proxy returning empty responses immediately must not spin the Watch at full speed.
    if !receivedFrames, elapsed < .milliseconds(250) { try await Task.sleep(for: .milliseconds(250) - elapsed) }
  }

  func send(_ message: Data) async throws {
    guard message.count <= 1_048_576, let frames = Fragments.split(message) else {
      throw AxoClientError.invalidResponse("The client request is too large")
    }
    for frame in frames {
      guard let text = String(data: frame, encoding: .utf8) else { throw AxoClientError.invalidResponse("Invalid UTF-8 frame") }
      _ = try await exchange("send", frame: text)
    }
  }

  func close() {
    closed = true
    // Closing must not start an orphan request after an owner invalidates its URLSession or
    // clears its credentials. The server releases this client when its 45-second lease ends.
  }

  private func request(_ action: String, frame: String?) async throws -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = action == "poll" ? 25 : 15
    request.httpBody = try JSONEncoder().encode(HTTPRelayRequest(connectionId: id, action: action, after: cursor, frame: frame))
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return try await RelayCredentials.authorize(request, with: tokens)
  }

  private func exchange(_ action: String, frame: String? = nil) async throws -> Bool {
    guard !closed, !Task.isCancelled else { throw AxoClientError.connectionClosed }
    let request = try await request(action, frame: frame)
    guard !closed, !Task.isCancelled else { throw AxoClientError.connectionClosed }
    let (data, response) = try await session.data(for: request, delegate: NoHTTPRelayRedirects())
    guard !closed, !Task.isCancelled else { throw AxoClientError.connectionClosed }
    guard let http = response as? HTTPURLResponse else { throw AxoClientError.invalidResponse("No HTTP relay response") }
    switch http.statusCode {
    case 200: break
    case 401, 403: throw RelayError.signInRequired
    case 409: throw AxoClientError.connectionClosed
    default: throw RelayError.httpStatus(http.statusCode)
    }
    guard data.count <= 2 * 1_048_576 else { throw AxoClientError.invalidResponse("HTTP relay response too large") }
    let page = try JSONDecoder().decode(HTTPRelayPage.self, from: data)
    guard page.frames.count <= 16 else { throw AxoClientError.invalidResponse("Too many HTTP relay frames") }
    for frame in page.frames {
      guard frame.sequence > 0 else { throw AxoClientError.invalidResponse("Invalid HTTP relay sequence") }
      if frame.sequence <= cursor { continue } // Concurrent send/poll responses may overlap.
      guard frame.sequence == cursor + 1, frame.frame.utf8.count <= 128 * 1024 else {
        throw AxoClientError.invalidResponse("HTTP relay frame sequence has a gap")
      }
      switch assembler.receive(Data(frame.frame.utf8)) {
      case .message(let message): sink.yield(message)
      case .pending: break
      case .invalid(let reason): throw AxoClientError.invalidResponse("Invalid relay fragment: \(reason)")
      }
      cursor = frame.sequence
    }
    return !page.frames.isEmpty
  }
}

private final class NoHTTPRelayRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
