import Foundation

/// Relay messages larger than one frame (RFD0016, Transport): the sender cuts the message's UTF-8
/// bytes into chunks, each sent base64-encoded in an `axo.transport.fragment` notification, and
/// the receiver puts them back together before reading the message. The bounds match the
/// TypeScript and Rust sides (`packages/axo-api/src/fragments.ts`).
enum Fragments {
  static let method = "axo.transport.fragment"
  static let discardMethod = "axo.transport.discard"
  /// One frame's largest message.
  static let frameBytes = 65_536
  /// Bytes of a message in one fragment.
  static let chunkBytes = 46_080
  /// The largest message that may be put back together: room for one 12 MiB Pi line.
  static let messageBytes = 16 * 1_048_576
  /// Messages that may be partly received at once.
  static let partialMessages = 4
  /// Dropped messages remembered, so their late fragments are ignored.
  static let discardedMessages = 64
  /// A partial message that gets no fragment for this long is dropped: its discard notice was lost.
  static let partialTimeout: TimeInterval = 60

  /// The frames that carry `message`: itself when it fits in one, otherwise its fragments in
  /// order. Nil when it is larger than any message may be.
  static func split(_ message: Data, messageID: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()) -> [Data]? {
    guard message.count > frameBytes else { return [message] }
    guard message.count <= messageBytes else { return nil }
    let count = (message.count + chunkBytes - 1) / chunkBytes
    return (0..<count).map { index in
      let chunk = message.subdata(in: (message.startIndex + index * chunkBytes)..<(message.startIndex + min(message.count, (index + 1) * chunkBytes)))
      let fragment = FragmentNotification(params: .init(messageId: messageID, index: index, count: count, data: chunk.base64EncodedString()))
      return (try? JSONEncoder().encode(fragment)) ?? Data()
    }
  }
}

/// What a received frame turned out to be.
enum FragmentOutcome: Equatable {
  /// A whole message: an ordinary frame, or the last fragment of one.
  case message(Data)
  /// More fragments are needed, or it was a late fragment of a dropped message.
  case pending
  /// The sender broke the rules; the connection closes.
  case invalid(String)
}

/// Puts one connection's fragmented messages back together. Not thread-safe: one reader owns it.
struct FragmentAssembler {
  private struct Partial {
    let count: Int
    var bytes = 0
    var chunks: [Int: Data] = [:]
    /// When its latest fragment came.
    var last: Date
  }

  private var partials: [String: Partial] = [:]
  private var discarded: [String] = []

  /// Takes one received frame, which came at `now`.
  mutating func receive(_ frame: Data, at now: Date = Date()) -> FragmentOutcome {
    expire(now)
    guard let header = try? JSONDecoder().decode(MethodHeader.self, from: frame) else { return .message(frame) }
    switch header.method {
    case Fragments.method:
      guard let params = try? JSONDecoder().decode(FragmentNotification.self, from: frame).params else {
        return .invalid("malformed fragment")
      }
      return receive(params, at: now)
    case Fragments.discardMethod:
      if let id = try? JSONDecoder().decode(DiscardNotification.self, from: frame).params.messageId { discard(id) }
      return .pending
    default:
      return .message(frame)
    }
  }

  private mutating func receive(_ fragment: FragmentNotification.Params, at now: Date) -> FragmentOutcome {
    let maxCount = (Fragments.messageBytes + Fragments.chunkBytes - 1) / Fragments.chunkBytes
    guard fragment.count >= 2, fragment.count <= maxCount, fragment.index >= 0, fragment.index < fragment.count,
      !fragment.messageId.isEmpty, fragment.messageId.count <= 64
    else { return .invalid("malformed fragment") }
    if discarded.contains(fragment.messageId) { return .pending }
    guard let chunk = Data(base64Encoded: fragment.data) else { return .invalid("malformed fragment") }
    let last = fragment.index == fragment.count - 1
    guard last ? (!chunk.isEmpty && chunk.count <= Fragments.chunkBytes) : chunk.count == Fragments.chunkBytes else {
      return .invalid("fragment size")
    }
    var partial = partials[fragment.messageId] ?? Partial(count: fragment.count, last: now)
    guard partial.count == fragment.count else { return .invalid("fragment count changed") }
    if partials[fragment.messageId] == nil, partials.count >= Fragments.partialMessages {
      return .invalid("too many partial messages")
    }
    guard partial.chunks[fragment.index] == nil else { return .invalid("fragment repeated") }
    guard partial.bytes + chunk.count <= Fragments.messageBytes else { return .invalid("message too large") }
    partial.chunks[fragment.index] = chunk
    partial.bytes += chunk.count
    partial.last = now
    guard partial.chunks.count == partial.count else {
      partials[fragment.messageId] = partial
      return .pending
    }
    partials[fragment.messageId] = nil
    var whole = Data(capacity: partial.bytes)
    for index in 0..<partial.count { whole.append(partial.chunks[index]!) }
    guard String(data: whole, encoding: .utf8) != nil else { return .invalid("message is not UTF-8") }
    return .message(whole)
  }

  /// Drops the partials that got no fragment for `Fragments.partialTimeout`, so a lost discard
  /// notice does not hold a place for the rest of the connection.
  private mutating func expire(_ now: Date) {
    for (id, partial) in partials where now.timeIntervalSince(partial.last) >= Fragments.partialTimeout {
      discard(id)
    }
  }

  private mutating func discard(_ messageID: String) {
    partials[messageID] = nil
    guard !discarded.contains(messageID) else { return }
    discarded.append(messageID)
    if discarded.count > Fragments.discardedMessages { discarded.removeFirst() }
  }
}

private struct MethodHeader: Decodable { let method: String? }

struct FragmentNotification: Codable {
  struct Params: Codable {
    let messageId: String
    let index: Int
    let count: Int
    let data: String
  }

  var jsonrpc = "2.0"
  var method = Fragments.method
  let params: Params
}

private struct DiscardNotification: Decodable {
  struct Params: Decodable { let messageId: String }
  let params: Params
}
