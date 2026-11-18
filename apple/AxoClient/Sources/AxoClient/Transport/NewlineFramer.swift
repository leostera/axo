import Foundation

/// Splits a byte stream into newline-terminated messages, as axod frames JSON-RPC.
///
/// Each byte is scanned once however many reads a message spans, so a 16 MiB message costs the
/// same as many small ones: whole-catalog replies grow with every Session, and rescanning the
/// buffer on every read made them quadratic.
struct NewlineFramer {
  struct MessageTooLong: Error {}

  let maximumMessageBytes: Int
  private var pending = Data()

  init(maximumMessageBytes: Int) {
    self.maximumMessageBytes = maximumMessageBytes
  }

  /// Takes the next bytes read and hands `message` each complete, non-empty message in order.
  /// Throws once a message is longer than `maximumMessageBytes`; the stream is unusable after.
  mutating func append(_ data: Data, message: (Data) -> Void) throws {
    // Bytes already pending hold no newline, so only the new ones need scanning.
    var cursor = pending.count
    pending.append(data)
    var start = 0
    try pending.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
      guard let base = bytes.baseAddress else { return }
      while cursor < bytes.count, let hit = memchr(base + cursor, 0x0A, bytes.count - cursor) {
        let end = base.distance(to: UnsafeRawPointer(hit))
        guard end - start <= maximumMessageBytes else { throw MessageTooLong() }
        if end > start { message(Data(bytes: base + start, count: end - start)) }
        start = end + 1
        cursor = start
      }
    }
    if start > 0 { pending = Data(pending[(pending.startIndex + start)...]) }
    guard pending.count <= maximumMessageBytes else { throw MessageTooLong() }
  }
}
