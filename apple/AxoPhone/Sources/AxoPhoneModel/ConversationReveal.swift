import Foundation

/// How a message written while its chat is on screen is presented, as on the web (ed8f8b0,
/// 362cdd6, ba4bc87).
///
/// What the chat opened with, and older pages read in above, are history and just appear. So does
/// a batch caught up at once, as after a reconnect: it was written while nobody watched. What is
/// written while the chat is on screen is presented: a reply (and its thinking), seen live or
/// arriving on its own, is let out a word at a time from its first live words through its record,
/// and nothing after it shows until all of it is out; anything else rises in. The person's own
/// messages were on screen already, as pending.
///
/// A reference the screen holds without observing: a row the lazy list makes again (scrolled away
/// and back) asks it what to do, and does not play its entrance twice or restart its words.
@MainActor
public final class ConversationReveal {
  /// How one message shows.
  public enum Presentation: Equatable, Sendable {
    /// As it is.
    case plain
    /// Rising in, once.
    case rise
    /// Its words let out; `final`: no more is coming, so once all of it is out what follows shows.
    /// `hurry`: more is waiting behind it, so it catches up faster rather than holding it back.
    case reveal(final: Bool, hurry: Bool)
  }

  public struct Shown: Identifiable, Equatable, Sendable {
    public let message: ChatMessage
    public let isLive: Bool
    public let presentation: Presentation
    public var id: String { message.key }

    public init(message: ChatMessage, isLive: Bool, presentation: Presentation) {
      self.message = message
      self.isLive = isLive
      self.presentation = presentation
    }
  }

  private var sessionId: String?
  private var known: Set<String> = []
  private var rising: Set<String> = []
  private var revealing: Set<String> = []
  private var done: Set<String> = []
  /// How much of each revealing message is out, so a row made again goes on from there.
  private var progress: [String: Int] = [:]

  public init() {}

  /// What the conversation shows, in order: its records, then the reply being written; cut short
  /// after a reply whose words are not all out yet.
  public func shown(sessionId: String?, messages: [ChatMessage], live: [ChatMessage]) -> [Shown] {
    let all = messages.map { ($0, false) } + live.map { ($0, true) }
    if self.sessionId != sessionId || (known.isEmpty && !messages.isEmpty) {
      // A chat just opened, or its history just came in: what is recorded is history.
      self.sessionId = sessionId
      known = Set(messages.map(\.key))
      rising = []
      revealing = []
      done = []
      progress = [:]
    }
    let lastKnown = all.lastIndex { known.contains($0.0.key) } ?? -1
    let arrived = all.enumerated().filter { index, entry in
      index > lastKnown && !known.contains(entry.0.key) && entry.0.role != .user
    }.map(\.element)
    // Pieces of one record (thinking, words, tool calls) share its id before the `#`.
    let recordsArrived = Set(arrived.filter { !$0.1 }.map { $0.0.id.split(separator: "#").first.map(String.init) ?? $0.0.id })
    let caughtUp = recordsArrived.count > 1
    for (message, _) in all { known.insert(message.key) }
    for (message, isLive) in arrived {
      let isText = message.role == .assistant || message.role == .thinking
      if isText && (isLive || !caughtUp) {
        revealing.insert(message.key)
      } else if !caughtUp {
        rising.insert(message.key)
      }
    }

    var shown: [Shown] = []
    for (index, (message, isLive)) in all.enumerated() {
      let key = message.key
      let presentation: Presentation
      if revealing.contains(key), !done.contains(key) {
        let more = index < all.count - 1
        presentation = .reveal(final: !isLive || more, hurry: more)
      } else if rising.contains(key) {
        presentation = .rise
      } else {
        presentation = .plain
      }
      shown.append(Shown(message: message, isLive: isLive, presentation: presentation))
      // What comes after a reply waits until all of it is out.
      if case .reveal = presentation { break }
    }
    return shown
  }

  /// How much of `key` is out already.
  public func revealed(_ key: String) -> Int { progress[key] ?? 0 }

  /// `key` has `count` characters out.
  public func reveal(_ key: String, upTo count: Int) { progress[key] = count }

  /// All of `key`, final, is out: it shows as it is from now on, and what follows it may show.
  public func finished(_ key: String) {
    done.insert(key)
    progress[key] = nil
  }

  /// `key` has risen in; made again, it just appears.
  public func rose(_ key: String) { rising.remove(key) }
}

/// The pace a reply's words are let out at: even, a word at a time, speeding up with the backlog
/// so what is shown never falls far behind what the Mac sent in its uneven bursts.
public enum RevealPace {
  /// The fewest characters a second; a backlog is caught up within about `catchUp`.
  public static let charactersPerSecond: Double = 90
  public static let catchUp: Double = 0.6
  /// How often what is shown moves on: smooth enough, without parsing a long reply every frame.
  public static let frame: Duration = .milliseconds(32)

  /// With more waiting behind the reply: the least pace and the catch-up time then.
  public static let hurriedCharactersPerSecond: Double = 400
  public static let hurriedCatchUp: Double = 0.15

  /// How much of `text` shows `elapsed` seconds after `shown` characters did: never half a word.
  public static func next(shown: Int, of text: String, after elapsed: Double, hurry: Bool = false) -> Int {
    let length = text.count
    let at = min(shown, length)
    guard at < length else { return length }
    let rate = hurry
      ? max(hurriedCharactersPerSecond, Double(length - at) / hurriedCatchUp)
      : max(charactersPerSecond, Double(length - at) / catchUp)
    let target = min(length, at + max(1, Int((rate * elapsed).rounded())))
    return wordEnd(in: text, from: target)
  }

  /// The end of the word `at` falls in.
  static func wordEnd(in text: String, from at: Int) -> Int {
    let rest = text.dropFirst(at)
    guard let space = rest.firstIndex(where: \.isWhitespace) else { return text.count }
    return at + rest.distance(from: rest.startIndex, to: space)
  }
}
