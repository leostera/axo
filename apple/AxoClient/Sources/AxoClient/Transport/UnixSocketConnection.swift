import Darwin
import Foundation

/// A connected Unix socket whose listener was checked (`AxodPeer`) before any byte goes out.
/// Network.framework hides the descriptor, and the audit token can only be read from it, so this
/// drives a plain BSD socket: reads from a dispatch source, writes on a queue of their own.
///
/// `@unchecked Sendable` invariants: `descriptor`, `source` and `cancelled` change only under
/// `lock`. The descriptor is closed exactly once, on `writeQueue` after the read source is
/// cancelled, so no write or read ever uses a closed (or reused) descriptor.
final class UnixSocketConnection: @unchecked Sendable {
  private static let readChunkBytes = 64 * 1024

  private let lock = NSLock()
  private let writeQueue = DispatchQueue(label: "dev.leostera.axo.rpc.write")
  private var descriptor: Int32 = -1
  private var source: DispatchSourceRead?
  private var cancelled = false

  /// Connects to `path` and checks the listener with `peer`. Blocks only as long as a local
  /// connect does; call it off the main thread.
  func open(path: UnixSocketPath, peer: AxodPeer) throws {
    let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard socket >= 0 else { throw AxoClientError.connectionFailed(Self.describe(errno)) }
    var owned = true
    defer { if owned { Darwin.close(socket) } }
    _ = fcntl(socket, F_SETFD, FD_CLOEXEC)
    var noSigPipe: Int32 = 1
    setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    try Self.connect(socket, to: path)
    try peer.check(socket)
    guard fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK) == 0 else {
      throw AxoClientError.connectionFailed(Self.describe(errno))
    }
    try lock.withLock {
      guard !cancelled, descriptor < 0 else { throw AxoClientError.connectionFailed("connection was cancelled") }
      descriptor = socket
    }
    owned = false
  }

  /// Delivers what arrives to `received` on `queue`, then `ended` once, when the peer closes,
  /// reading fails, or the connection is cancelled.
  func startReading(on queue: DispatchQueue, received: @escaping (Data) -> Void, ended: @escaping () -> Void) {
    lock.lock()
    guard !cancelled, descriptor >= 0, source == nil else {
      lock.unlock()
      queue.async(execute: ended)
      return
    }
    let socket = descriptor
    let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
    var buffer = [UInt8](repeating: 0, count: Self.readChunkBytes)
    source.setEventHandler { [weak self] in
      while true {
        let count = buffer.withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress, $0.count) }
        if count > 0 {
          received(Data(buffer[..<count]))
          continue
        }
        if count < 0, errno == EINTR { continue }
        if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
        self?.cancel()
        return
      }
    }
    // Runs once the event handler is done; only then may the descriptor go.
    source.setCancelHandler { [writeQueue] in
      writeQueue.async { Darwin.close(socket) }
      ended()
    }
    self.source = source
    lock.unlock()
    source.resume()
  }

  /// Writes all of `data`, or fails with `connectionClosed`.
  func send(_ data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      writeQueue.async { [self] in
        let socket: Int32? = lock.withLock { cancelled || descriptor < 0 ? nil : descriptor }
        guard let socket, Self.writeAll(socket, data) else {
          continuation.resume(throwing: AxoClientError.connectionClosed)
          return
        }
        continuation.resume()
      }
    }
  }

  /// Ends the connection: reads end, writes in flight fail, later ones fail at once.
  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled else { return }
    cancelled = true
    guard descriptor >= 0 else { return }
    // Wakes a write waiting for room and makes the next read see the end.
    shutdown(descriptor, SHUT_RDWR)
    if let source {
      source.cancel()
    } else {
      let socket = descriptor
      writeQueue.async { Darwin.close(socket) }
    }
  }

  private static func writeAll(_ socket: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { bytes -> Bool in
      var offset = 0
      while offset < bytes.count {
        let written = Darwin.write(socket, bytes.baseAddress! + offset, bytes.count - offset)
        if written > 0 {
          offset += written
        } else if written < 0, errno == EINTR {
          continue
        } else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
          var ready = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
          // `cancel` shuts the socket down, which wakes this.
          if poll(&ready, 1, -1) < 0, errno != EINTR { return false }
        } else {
          return false
        }
      }
      return true
    }
  }

  private static func connect(_ socket: Int32, to path: UnixSocketPath) throws {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    // `UnixSocketPath` guarantees the path and its terminator fit.
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      let bytes = Array(path.value.utf8)
      buffer.copyBytes(from: bytes)
      buffer[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { throw AxoClientError.connectionFailed(describe(errno)) }
  }

  private static func describe(_ code: Int32) -> String {
    String(cString: strerror(code))
  }
}
