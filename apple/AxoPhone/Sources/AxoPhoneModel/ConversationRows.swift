import Foundation

/// The conversation's rows, top to bottom, as one list: what is recorded, the person's messages on
/// their way, and the reply being written.
///
/// Messages only ever append: each row keeps its place as the conversation goes on. A message sent
/// while the agent was idle starts the next reply, so it shows above that reply's first words
/// (which may reach the phone before its record does); one sent while the agent was busy waits
/// behind the reply being written, so it shows below it. A pending message and its record share a
/// key, so it does not move, or vanish from under the reader, when the record arrives. What the
/// log holds as queued (RFD0033) waits behind the reply too, in the order Pi took it, under that
/// same key.
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

  public static func rows(
    shown: [ConversationReveal.Shown], pending: [HostWorkbenchModel.PendingPrompt], queued: [QueuedPrompt] = []
  ) -> [ConversationRow] {
    let firstLive = shown.firstIndex(where: \.isLive) ?? shown.endIndex
    let recordedKeys = Set(shown.map(\.id))
    let queued = queued.filter { !recordedKeys.contains($0.key) }
    let held = recordedKeys.union(queued.map(\.key))
    let waiting = pending.filter { !held.contains($0.key) }
    return shown[..<firstLive].map(Self.message)
      + waiting.filter { !$0.behindReply }.map(Self.pending)
      + shown[firstLive...].map(Self.message)
      + queued.map(Self.queued)
      + waiting.filter(\.behindReply).map(Self.pending)
  }
}
