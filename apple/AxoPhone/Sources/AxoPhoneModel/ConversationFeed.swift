import Foundation
import Observation

/// One chat's conversation as the screen lists it: rows that are made once and kept, in the order
/// they came.
///
/// The transcript is one value, and changes with every word of a reply; a screen that read it
/// whole would lay out the whole conversation again each time. The feed holds each row as an
/// object of its own instead. A change to the transcript changes the rows it touches, in place,
/// and adds the new ones; a row's view observes its row alone, so a reply being written redraws
/// that reply, and the list redraws only when a row is added.
///
/// Rows only ever go on the end, and keep their places: a row never moves, and none is taken out
/// from under the reader while what it shows is still coming. The exceptions are a page of older
/// history, which goes on the top; a message the person took back; and a transcript read again
/// from the start (a cut, or a reload), which starts the rows again.
@MainActor
@Observable
public final class ConversationFeed {
  /// One row: a message, a message on its way, or one the agent took while busy. Its `id` is the
  /// key its message keeps from first words to record, so it is the same object all along.
  @MainActor
  @Observable
  public final class Item: Identifiable {
    public let id: String
    public fileprivate(set) var row: ConversationRow
    /// How many characters of its words are out while they are let out, by the feed's clock; nil
    /// when it shows whole.
    public fileprivate(set) var revealed: Int?
    /// A tool's row only: its place among the tools used one after another.
    public fileprivate(set) var group: ToolGroupPlace?
    /// A tool's row only: the reader opened it, to all it was given and printed. Kept here, not
    /// in the row's view, so the list sizes it in the frame it opens in (a view's own state sizes
    /// its cell a frame late, its new lines drawn over the rows below meanwhile), and so it stays
    /// open as its cell scrolls away and back.
    public fileprivate(set) var open = false

    init(_ row: ConversationRow) {
      id = row.id
      self.row = row
    }
  }

  /// What is at the end of the conversation: it changes when a row is added at the end or the
  /// last one grows, which is when a reader at the end follows.
  public struct End: Equatable, Sendable {
    public var count = 0
    public var lastKey: String?
    public var lastLength = 0
  }

  /// The rows, top to bottom.
  public private(set) var items: [Item] = []
  /// Whether the agent is working: a tool that has not answered yet is running.
  public private(set) var working = false
  /// Whether a tool it called has not answered yet.
  public private(set) var callingTools = false
  /// What the agent is asking the person, while it waits.
  public private(set) var question: ChatQuestion?
  public private(set) var end = End()
  /// How the messages written while the chat is on screen come in. Rows read it; never observed.
  @ObservationIgnored public let reveal = ConversationReveal()
  /// Whether messages come in at all: off where motion is reduced.
  @ObservationIgnored public var animates = true {
    didSet { if animates != oldValue { rebuild() } }
  }
  /// Whether the chat is on screen. Off it, nothing is let out: what arrives just shows.
  @ObservationIgnored public private(set) var onScreen = false
  /// Lets a reply's words out, a step every `RevealPace.frame`, while one is being let out. The
  /// feed's own, so no view has to appear, or be laid out, for a reply to come out and what waits
  /// behind it to follow (RFD0039).
  @ObservationIgnored private var clock: Task<Void, Never>?
  /// The rows being let out now: what the clock steps.
  @ObservationIgnored private var revealing: [Item] = []
  /// Called once the rows have changed (one added, taken away, or grown), in the same turn: the list
  /// lays itself out at once, so a row and the room made for it are drawn in the same frame.
  @ObservationIgnored public var changed: ((_ grew: Set<String>) -> Void)?
  /// The rows changed since the list was last told, by id.
  @ObservationIgnored private var touched: Set<String> = []
  /// Whether the clock runs on its own; tests step it with `tick(after:)`.
  @ObservationIgnored private let ticks: Bool

  @ObservationIgnored private var transcript = ChatTranscript()
  @ObservationIgnored private var pending: [HostWorkbenchModel.PendingPrompt] = []
  @ObservationIgnored private var byID: [String: Item] = [:]
  /// Bumped each time the chat comes on screen: what it holds then is history, shown as it is.
  @ObservationIgnored private var visit = 0

  public nonisolated init() { ticks = true }

  nonisolated init(ticks: Bool) { self.ticks = ticks }

  /// The row with `id`, while the feed holds it.
  public func item(_ id: String) -> Item? { byID[id] }

  /// The row the reader just opened or folded, for the list to keep where it is; read once.
  @ObservationIgnored public private(set) var held: String?

  /// Opens a row, or folds it, for the reader: it stays where it is, and what is below moves.
  public func toggleOpen(_ id: String) {
    guard let item = byID[id] else { return }
    item.open.toggle()
    touched.insert(id)
    held = id
    tell()
    held = nil
  }

  /// The chat's transcript or its pending messages changed.
  func update(transcript: ChatTranscript, pending: [HostWorkbenchModel.PendingPrompt]) {
    self.transcript = transcript
    self.pending = pending
    rebuild()
  }

  /// The chat came on screen: everything it holds now just appears.
  public func opened() {
    visit += 1
    onScreen = true
    rebuild()
  }

  /// The chat left the screen: what is being let out shows whole, and what arrives just shows.
  public func closed() {
    onScreen = false
    rebuild()
  }

  /// Lets every reply being let out on by `seconds`. Rows whose words are all out and final show
  /// as they are, and what waited behind them comes.
  func tick(after seconds: Double) {
    var done = false
    var behind = false
    for item in revealing {
      guard case .message(let shown) = item.row, case .reveal(let final, let hurry) = shown.presentation else { continue }
      let text = shown.message.text
      let at = RevealPace.next(shown: reveal.revealed(shown.id), of: text, after: seconds, hurry: hurry)
      reveal.reveal(shown.id, upTo: at)
      if at >= text.count, final {
        reveal.finished(shown.id)
        done = true
      } else {
        if item.revealed != at {
          item.revealed = at
          touched.insert(item.id)
        }
        // A step may let nothing out (the pace keeps whole words): it is still on its way.
        if at < text.count { behind = true }
      }
    }
    if done {
      rebuild()
    } else {
      tell()
      // All that has come is out, and more is still to come: nothing to do until it does, and
      // the update that brings it starts the clock again.
      if !behind { runClock(false) }
    }
  }

  /// Runs the clock while something is being let out, and stops it when nothing is.
  private func runClock(_ revealing: Bool) {
    guard ticks else { return }
    if !revealing {
      clock?.cancel()
      clock = nil
      return
    }
    guard clock == nil else { return }
    clock = Task { [weak self] in
      var last = ContinuousClock.now
      while !Task.isCancelled {
        try? await Task.sleep(for: RevealPace.frame)
        guard !Task.isCancelled else { return }
        let now = ContinuousClock.now
        let elapsed = now - last
        last = now
        guard let self else { return }
        self.tick(after: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
      }
    }
  }

  private func rebuild() {
    let shown: [ConversationReveal.Shown] =
      animates && onScreen
      ? reveal.shown(sessionId: "\(visit)", messages: transcript.messages, live: transcript.live)
      : transcript.messages.map { .init(message: $0, isLive: false, presentation: .plain) }
        + transcript.live.map { .init(message: $0, isLive: true, presentation: .plain) }
    keep(ConversationRow.rows(shown: shown, pending: pending, queued: transcript.queued))
    group()
    // A row being let out shows what is out of it; one that is not, all of it.
    let wasRevealing = revealing
    revealing = items.filter { item in
      guard case .message(let shown) = item.row, case .reveal = shown.presentation else { return false }
      return true
    }
    for item in wasRevealing where !revealing.contains(where: { $0 === item }) {
      item.revealed = nil
      touched.insert(item.id)
    }
    for item in revealing {
      let out = reveal.revealed(item.id)
      if item.revealed != out {
        item.revealed = out
        touched.insert(item.id)
      }
    }
    runClock(!revealing.isEmpty)
    let working = transcript.activity == .working
    if self.working != working { self.working = working }
    let callingTools = working && transcript.messages.contains { $0.tool?.status == .running }
    if self.callingTools != callingTools { self.callingTools = callingTools }
    if question != transcript.question { question = transcript.question }
    tell()
  }

  /// Tells the list which rows changed, if any did.
  private func tell() {
    let grew = touched
    touched = []
    changed?(grew)
  }

  /// Brings the rows to `wanted`, the order the conversation would have them in now, without
  /// moving a row already held: a held row is changed where it is, a new one goes on the end (or
  /// the top, before every held row: an older page).
  private func keep(_ wanted: [ConversationRow]) {
    // A recorded message the transcript no longer has: it was cut back or read again from the
    // start. Nothing held can be trusted to be in its place; the rows start again.
    let inTranscript = Set(transcript.messages.map(\.key)).union(transcript.live.map(\.key))
    if items.contains(where: { item in
      if case .message(let shown) = item.row, !shown.isLive { return !inTranscript.contains(item.id) }
      return false
    }) {
      items = []
      byID = [:]
    }

    var top: [Item] = []
    var bottom: [Item] = []
    var reachedHeld = false
    var wantedIDs = Set<String>()
    for row in wanted {
      wantedIDs.insert(row.id)
      if let item = byID[row.id] {
        reachedHeld = true
        if item.row != row {
          item.row = row
          touched.insert(item.id)
        }
      } else {
        let item = Item(row)
        byID[row.id] = item
        if reachedHeld || items.isEmpty { bottom.append(item) } else { top.append(item) }
      }
    }
    let recorded = Set(transcript.messages.map(\.key))
    let queued = Set(transcript.queued.map(\.key))
    let kept = items.filter { item in
      wantedIDs.contains(item.id) || stays(item, recorded: recorded, queued: queued)
    }
    for item in items where !kept.contains(where: { $0 === item }) { byID[item.id] = nil }
    let next = top + kept + bottom
    if next.map(ObjectIdentifier.init) != items.map(ObjectIdentifier.init) { items = next }

    let last = items.last
    let end = End(count: items.count, lastKey: last?.id, lastLength: last.map(Self.length) ?? 0)
    if self.end != end { self.end = end }
  }

  /// Tools used one after another show as one block: each tool's row learns its place in it.
  private func group() {
    let places = ToolGroupPlace.places(items.map { item in
      if case .message(let shown) = item.row { return shown.message.tool }
      return nil
    })
    for (item, place) in zip(items, places) where item.group != place {
      item.group = place
      touched.insert(item.id)
    }
  }

  /// Whether a row the conversation does not list now stays anyway: what it shows is still coming.
  private func stays(_ item: Item, recorded: Set<String>, queued: Set<String>) -> Bool {
    switch item.row {
    case .message(let shown):
      // A reply whose words were cleared before its record came: it stays as it was until the
      // record takes its place. One with no stamp to know its record by goes when it is cleared.
      return shown.message.replyKey != nil
    case .pending, .queued:
      // Taken by the log, its message held back behind a reply still being let out: it stays
      // until that message takes its place. Taken back by the person, or run as a command, it goes.
      return recorded.contains(item.id) || queued.contains(item.id)
    }
  }

  /// How much a row shows, for following it as it grows.
  private static func length(_ item: Item) -> Int {
    switch item.row {
    case .message(let shown): shown.message.text.count + (shown.message.tool?.output.count ?? 0)
    case .pending(let prompt): prompt.text.count
    case .queued(let prompt): prompt.text.count
    }
  }
}
