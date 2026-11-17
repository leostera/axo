import Foundation

/// The conversation's rows, top to bottom, as one list: what is recorded, the person's messages on
/// their way, and the reply being written.
///
/// Messages only ever append: each row keeps its place as the conversation goes on. A message sent
/// while the agent was idle starts the next reply, so it shows above that reply's first words
/// (which may reach the phone before its record does); one sent while the agent was busy waits
/// behind the reply being written, so it shows below it. A pending message and its record share a
/// key, so it does not move, or vanish from under the reader, when the record arrives.
///
/// What the log holds as queued (RFD0033) waits where it was sent: after the reply that was being
/// written then (its `at`), with what the run writes later below it, rather than sinking below
/// every new reply. Until that reply is recorded it has no place yet, and is the newest thing.
public enum ConversationRow: Identifiable, Equatable, Sendable {
  case message(ConversationReveal.Shown)
  case pending(HostWorkbenchModel.PendingPrompt)
  case queued(QueuedPrompt)

  public var id: String {
    switch self {
    case .message(let shown): shown.id
    case .pending(let prompt): prompt.key
    case .queued(let prompt): prompt.key
    }
  }

  /// `shown` is the conversation's messages in order, then the reply being written; it may stop
  /// short of them all (a reply still being let out holds back what follows it).
  public static func rows(
    shown: [ConversationReveal.Shown], pending: [HostWorkbenchModel.PendingPrompt], queued: [QueuedPrompt] = []
  ) -> [ConversationRow] {
    let recordedKeys = Set(shown.map(\.id))
    let queued = queued.filter { !recordedKeys.contains($0.key) }
    let held = recordedKeys.union(queued.map(\.key))
    let waiting = pending.filter { !held.contains($0.key) }
    let anchored = queued.filter { $0.at != nil }.sorted { $0.at! < $1.at! }
    var rows: [ConversationRow] = []
    var next = anchored.startIndex
    var startedReply = false
    for (index, message) in shown.enumerated() {
      if message.isLive, !startedReply {
        // A message sent while idle starts the reply being written: above its first words.
        rows += waiting.filter { !$0.behindReply }.map(Self.pending)
        startedReply = true
      }
      while next < anchored.endIndex, anchored[next].at! <= index {
        rows.append(.queued(anchored[next]))
        next += 1
      }
      rows.append(.message(message))
    }
    if !startedReply { rows += waiting.filter { !$0.behindReply }.map(Self.pending) }
    rows += anchored[next...].map(Self.queued)
    return rows
      + queued.filter { $0.at == nil }.map(Self.queued)
      + waiting.filter(\.behindReply).map(Self.pending)
  }
}
