import Foundation

/// Apps to a local axod: newline-delimited JSON over a Unix socket, to a listener checked to be
/// axod before anything is sent (RFD0069).
public struct UnixSocketTransport: AxoTransport {
  public let socketPath: UnixSocketPath
  /// Who must be listening.
  public let peer: AxodPeer

  public init(socketPath: UnixSocketPath, peer: AxodPeer = .axod) {
    self.socketPath = socketPath
    self.peer = peer
  }

  public func connect() async throws -> any AxoMessageChannel {
    let channel = UnixSocketChannel(socketPath: socketPath, peer: peer)
    try await channel.connect()
    return channel
  }
}

/// One Unix-socket connection, framing messages by newline.
///
/// `@unchecked Sendable` invariants: `pendingData` is touched only from the connection's read
/// callbacks on the serial `queue`; `UnixSocketConnection` and the stream continuation are
/// themselves thread-safe.
final class UnixSocketChannel: AxoMessageChannel, @unchecked Sendable {
  /// The largest single message accepted; a longer line ends the connection. Whole-catalog
  /// replies (`axo.session.list`, the first `axo.session.events` batch) grow with every
  /// Session, so this must stay far above any realistic catalog. At 64 KiB, sixty Sessions with
  /// UUID IDs no longer fit and Axo could never get past its launch splash.
  static let maximumMessageBytes = 16 * 1024 * 1024

  private let socketPath: UnixSocketPath
  private let peer: AxodPeer
  private let connection = UnixSocketConnection()
  private let queue = DispatchQueue(label: "dev.leostera.axo.rpc")
  private let dataContinuation: AsyncStream<Data>.Continuation
  private var pendingData = Data()

  let messages: AsyncStream<Data>

  init(socketPath: UnixSocketPath, peer: AxodPeer) {
    let (messages, dataContinuation) = AsyncStream<Data>.makeStream()
    self.messages = messages
    self.dataContinuation = dataContinuation
    self.socketPath = socketPath
    self.peer = peer
  }

  /// Connects and checks the listener; a missing or refusing socket fails at once.
  func connect() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async { [self] in
        do {
          try connection.open(path: socketPath, peer: peer)
        } catch {
          dataContinuation.finish()
          continuation.resume(throwing: error)
          return
        }
        connection.startReading(
          on: queue, received: { [weak self] in self?.receive($0) },
          ended: { [dataContinuation] in dataContinuation.finish() })
        continuation.resume()
      }
    }
  }

  func close() {
    connection.cancel()
    dataContinuation.finish()
  }

  private func receive(_ data: Data) {
    pendingData.append(data)

    while let newline = pendingData.firstIndex(of: 0x0A) {
      let message = Data(pendingData[..<newline])
      pendingData.removeSubrange(pendingData.startIndex...newline)
      guard message.count <= Self.maximumMessageBytes else {
        dataContinuation.finish()
        connection.cancel()
        return
      }
      if !message.isEmpty {
        dataContinuation.yield(message)
      }
    }

    if pendingData.count > Self.maximumMessageBytes {
      dataContinuation.finish()
      connection.cancel()
    }
  }

  func send(_ message: Data) async throws {
    var framedMessage = message
    framedMessage.append(0x0A)
    try await connection.send(framedMessage)
  }
}
