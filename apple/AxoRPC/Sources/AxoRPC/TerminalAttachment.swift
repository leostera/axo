import AxoProtocol
import Darwin
import Foundation

/// One open attachment to an Axod shell (attach protocol v2).
///
/// Axod is the only reader of the shell's PTY. `outputDescriptor` is the attach socket, which
/// carries the replay followed by live output until the shell's PTY reaches end of file.
/// `ptyDescriptor` is the PTY master, for input, resizing and termios/foreground queries only;
/// reading it would steal output from Axod, and changing its file status flags would affect
/// Axod's own descriptor because the open file description is shared.
///
/// The attachment owns both descriptors until `close()`. Ghostty duplicates them when a surface
/// adopts them, so callers close the attachment right after handing it over.
public final class TerminalAttachment: @unchecked Sendable {
  public let outputDescriptor: Int32
  public let ptyDescriptor: Int32
  /// Bytes of replay at the start of the output stream.
  public let replayByteCount: UInt64
  private let lock = NSLock()
  private var closed = false

  init(outputDescriptor: Int32, ptyDescriptor: Int32, replayByteCount: UInt64) {
    self.outputDescriptor = outputDescriptor
    self.ptyDescriptor = ptyDescriptor
    self.replayByteCount = replayByteCount
  }

  deinit { close() }

  public func close() {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { return }
    closed = true
    Darwin.close(outputDescriptor)
    Darwin.close(ptyDescriptor)
  }

  /// Opens an attachment. Blocks for at most `timeout` per step; call it off the main thread.
  public static func open(
    socketPath: UnixSocketPath,
    shellID: ShellID,
    timeout: Duration = .seconds(3)
  ) throws -> TerminalAttachment {
    let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard socket >= 0 else { throw TerminalAttachmentError.system("socket", errno) }
    var ownsSocket = true
    defer { if ownsSocket { Darwin.close(socket) } }
    _ = fcntl(socket, F_SETFD, FD_CLOEXEC)
    var noSigPipe: Int32 = 1
    setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    var receiveTimeout = timeval(
      tv_sec: Int(timeout.components.seconds),
      tv_usec: Int32(timeout.components.attoseconds / 1_000_000_000_000)
    )
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

    try connect(socket, to: socketPath)
    try writeAll(socket, Array("\(shellID.rawValue)\n".utf8))

    var header = [UInt8](repeating: 0, count: 8)
    try readExact(socket, into: &header)
    let length = header.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    if length == UInt64.max {
      var code = [UInt8](repeating: 0, count: 1)
      try readExact(socket, into: &code)
      throw TerminalAttachmentError.rejected(TerminalAttachmentError.Rejection(code: code[0]))
    }
    let pty = try receiveDescriptor(socket)

    // Ghostty polls the output stream itself; the handshake timeouts must not apply to it.
    var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))
    ownsSocket = false
    return TerminalAttachment(outputDescriptor: socket, ptyDescriptor: pty, replayByteCount: length)
  }

  private static func connect(_ socket: Int32, to path: UnixSocketPath) throws {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      let bytes = Array(path.value.utf8.prefix(capacity - 1))
      buffer.copyBytes(from: bytes)
      buffer[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { throw TerminalAttachmentError.system("connect", errno) }
  }

  private static func writeAll(_ socket: Int32, _ bytes: [UInt8]) throws {
    var offset = 0
    while offset < bytes.count {
      let written = bytes[offset...].withUnsafeBytes { Darwin.write(socket, $0.baseAddress, $0.count) }
      if written < 0 {
        if errno == EINTR { continue }
        throw TerminalAttachmentError.system("write", errno)
      }
      offset += written
    }
  }

  private static func readExact(_ socket: Int32, into buffer: inout [UInt8]) throws {
    var offset = 0
    while offset < buffer.count {
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(socket, $0.baseAddress! + offset, $0.count - offset)
      }
      if count == 0 { throw TerminalAttachmentError.closed }
      if count < 0 {
        if errno == EINTR { continue }
        throw TerminalAttachmentError.system("read", errno)
      }
      offset += count
    }
  }

  private static func receiveDescriptor(_ socket: Int32) throws -> Int32 {
    let controlLength = cmsgSpace(MemoryLayout<Int32>.size)
    let payload = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    let control = UnsafeMutableRawPointer.allocate(
      byteCount: controlLength, alignment: MemoryLayout<cmsghdr>.alignment)
    let vector = UnsafeMutablePointer<iovec>.allocate(capacity: 1)
    defer {
      payload.deallocate()
      control.deallocate()
      vector.deallocate()
    }
    payload.storeBytes(of: 0, as: UInt8.self)
    control.initializeMemory(as: UInt8.self, repeating: 0, count: controlLength)
    vector.initialize(to: iovec(iov_base: payload, iov_len: 1))

    var message = msghdr()
    message.msg_iov = vector
    message.msg_iovlen = 1
    message.msg_control = control
    message.msg_controllen = socklen_t(controlLength)
    var received: Int
    repeat {
      received = recvmsg(socket, &message, 0)
    } while received < 0 && errno == EINTR
    if received < 0 { throw TerminalAttachmentError.system("recvmsg", errno) }
    guard received == 1, payload.load(as: UInt8.self) == UInt8(ascii: "1"),
      message.msg_flags & MSG_CTRUNC == 0
    else { throw TerminalAttachmentError.missingDescriptor }

    let header = control.load(as: cmsghdr.self)
    guard header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS,
      Int(header.cmsg_len) >= cmsgLength(MemoryLayout<Int32>.size)
    else { throw TerminalAttachmentError.missingDescriptor }
    let descriptor = control.loadUnaligned(fromByteOffset: cmsgLength(0), as: Int32.self)
    guard descriptor >= 0 else { throw TerminalAttachmentError.missingDescriptor }
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    return descriptor
  }

  private static func cmsgAlign(_ length: Int) -> Int {
    let alignment = MemoryLayout<UInt32>.size
    return (length + alignment - 1) & ~(alignment - 1)
  }

  private static func cmsgLength(_ length: Int) -> Int {
    cmsgAlign(MemoryLayout<cmsghdr>.size) + length
  }

  private static func cmsgSpace(_ length: Int) -> Int {
    cmsgAlign(MemoryLayout<cmsghdr>.size) + cmsgAlign(length)
  }
}

public enum TerminalAttachmentError: Error, Equatable, CustomStringConvertible {
  public enum Rejection: Equatable, Sendable {
    case shellNotOpen
    case daemonBusy
    case other(UInt8)

    init(code: UInt8) {
      switch code {
      case 2: self = .shellNotOpen
      case 4: self = .daemonBusy
      default: self = .other(code)
      }
    }
  }

  case rejected(Rejection)
  case closed
  case missingDescriptor
  case system(String, Int32)

  public var description: String {
    switch self {
    case .rejected(.shellNotOpen): "The shell is no longer open."
    case .rejected(.daemonBusy): "axod is busy attaching terminals."
    case .rejected(.other(let code)): "axod rejected the terminal attachment (code \(code))."
    case .closed: "axod closed the terminal attachment."
    case .missingDescriptor: "axod did not provide a terminal descriptor."
    case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
    }
  }
}
