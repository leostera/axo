import Foundation
import JSONRPC
import Network

extension Duration {
  var milliseconds: Int {
    let components = components
    guard components.seconds >= 0 else { return 1 }
    guard components.seconds < 20 else { return 20_000 }
    let whole = components.seconds * 1_000
    let fractional = components.attoseconds / 1_000_000_000_000_000
    return Int(min(20_000, max(1, whole + fractional)))
  }

  var nanoseconds: UInt64 {
    let components = components
    let seconds = UInt64(max(0, components.seconds))
    let attoseconds = UInt64(max(0, components.attoseconds))
    return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
  }
}

/// Newline-delimited JSON-RPC over a Unix socket.
///
/// `@unchecked Sendable` invariants: `pendingData` is touched only from NWConnection callbacks on
/// the serial `queue`; `readiness` only under `stateLock`; `NWConnection` and the stream
/// continuation are themselves thread-safe.
final class UnixSocketTransport: @unchecked Sendable {
  private static let maximumMessageBytes = 64 * 1024
  private static let connectionTimeout: DispatchTimeInterval = .seconds(1)

  private let connection: NWConnection
  private let queue = DispatchQueue(label: "dev.leostera.axo.rpc")
  private let stateLock = NSLock()
  private let dataContinuation: AsyncStream<Data>.Continuation
  private var readiness: CheckedContinuation<Void, Error>?
  private var pendingData = Data()

  private let dataSequence: AsyncStream<Data>

  init(socketPath: UnixSocketPath) {
    let (dataSequence, dataContinuation) = AsyncStream<Data>.makeStream()
    self.dataSequence = dataSequence
    self.dataContinuation = dataContinuation
    self.connection = NWConnection(
      to: .unix(path: socketPath.value),
      using: .tcp
    )
  }

  var dataChannel: JSONRPC.DataChannel {
    JSONRPC.DataChannel(
      writeHandler: { [self] data in try await send(data) },
      dataSequence: dataSequence
    )
  }

  func connect() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      stateLock.lock()
      readiness = continuation
      stateLock.unlock()

      connection.stateUpdateHandler = { [weak self] state in
        self?.handle(state: state)
      }
      connection.start(queue: queue)
      queue.asyncAfter(deadline: .now() + Self.connectionTimeout) { [weak self] in
        guard let self,
          self.finishReadiness(
            .failure(UnixSocketRPCError.connectionFailed("connection timed out")))
        else {
          return
        }
        self.connection.cancel()
        self.dataContinuation.finish()
      }
    }
  }

  func close() {
    connection.cancel()
    dataContinuation.finish()
  }

  private func handle(state: NWConnection.State) {
    switch state {
    case .ready:
      guard finishReadiness(.success(())) else { return }
      receiveNext()
    case .failed(let error):
      finishReadiness(.failure(UnixSocketRPCError.connectionFailed(error.localizedDescription)))
      dataContinuation.finish()
    case .cancelled:
      finishReadiness(.failure(UnixSocketRPCError.connectionFailed("connection was cancelled")))
      dataContinuation.finish()
    case .waiting(let error):
      // A missing or refusing Unix socket is reported as waiting for a better network path,
      // which never comes; fail now instead of at the connection timeout (axod probes during
      // a restart would each stall for a second).
      guard finishReadiness(.failure(UnixSocketRPCError.connectionFailed(error.localizedDescription)))
      else { return }
      connection.cancel()
      dataContinuation.finish()
    case .setup, .preparing:
      break
    @unknown default:
      finishReadiness(.failure(UnixSocketRPCError.connectionFailed("unknown connection state")))
      dataContinuation.finish()
    }
  }

  @discardableResult
  private func finishReadiness(_ result: Result<Void, Error>) -> Bool {
    stateLock.lock()
    let continuation = readiness
    readiness = nil
    stateLock.unlock()
    guard let continuation else { return false }
    continuation.resume(with: result)
    return true
  }

  private func receiveNext() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumMessageBytes) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      if error != nil {
        self.dataContinuation.finish()
        self.connection.cancel()
        return
      }
      if let data, !data.isEmpty {
        self.receive(data)
      }
      if isComplete {
        self.dataContinuation.finish()
      } else {
        self.receiveNext()
      }
    }
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

  private func send(_ message: Data) async throws {
    var framedMessage = message
    framedMessage.append(0x0A)

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(
        content: framedMessage,
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(
              throwing: UnixSocketRPCError.connectionFailed(error.localizedDescription)
            )
          } else {
            continuation.resume()
          }
        })
    }
  }
}
