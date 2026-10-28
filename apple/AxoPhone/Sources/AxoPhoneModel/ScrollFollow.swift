import Foundation

/// When a conversation follows what is new and when it leaves the reader where they are.
///
/// Only the reader decides whether to follow, by how they scroll:
/// - The conversation follows its end until the reader scrolls away from it, and follows again
///   once they come back to it (or ask to: "Jump to new message", or by sending something).
/// - What the screen does itself (going to the end, an animated jump still under way while more
///   arrives) never stops the following: only a finger does. A jump that lands short of an end
///   that moved meanwhile catches up when it settles.
/// - While the finger is on the conversation it is never moved under it.
/// - Following, new content keeps the end in view at once, without animating; not following, it
///   leaves the reader be and says something new is below.
public struct ScrollFollow: Equatable, Sendable {
  /// What the screen should do.
  public enum Move: Equatable, Sendable {
    case stay
    /// Put the end in view now, without animating: following as content grows.
    case keepAtEnd
    /// Scroll to the end, animated: the reader asked to go there.
    case goToEnd
  }

  /// How the conversation is being scrolled, from the scroll view's phase.
  public enum Scrolling: Equatable, Sendable {
    /// Still.
    case idle
    /// A finger is down but has not scrolled it (yet): a tap, on the conversation or on a
    /// button over it, decides nothing.
    case touched
    /// The finger is moving it, or it is coasting from a flick.
    case byReader
    /// The screen is scrolling it (an animated jump).
    case byScreen
  }

  /// Whether the conversation keeps its end in view as content arrives.
  public private(set) var isFollowing = true
  /// Something arrived below while the reader was elsewhere.
  public private(set) var hasNew = false
  private var scrolling = Scrolling.idle

  public init() {}

  /// The content at the end changed: a new message, the reply or a tool's output grew, the
  /// first page arrived.
  public mutating func contentChangedAtEnd() -> Move {
    guard isFollowing else {
      hasNew = true
      return .stay
    }
    // Not under the reader's finger; an animated jump is overtaken, and lands at the true end.
    return scrolling == .byReader ? .stay : .keepAtEnd
  }

  /// The scroll view started or stopped moving; `atEnd` says whether the end is in view.
  public mutating func scrollingChanged(to now: Scrolling, atEnd: Bool) -> Move {
    let was = scrolling
    scrolling = now
    guard now == .idle else { return .stay }
    switch was {
    case .byReader:
      // Where the reader let it come to rest decides.
      isFollowing = atEnd
      if atEnd { hasNew = false }
      return .stay
    case .byScreen:
      // A jump that the end outran: finish the way.
      return isFollowing && !atEnd ? .keepAtEnd : .stay
    case .idle, .touched:
      return .stay
    }
  }

  /// The view grew taller at the bottom or the keyboard rose: a follower keeps the end in view.
  public mutating func bottomInsetGrew() -> Move {
    isFollowing && scrolling != .byReader ? .keepAtEnd : .stay
  }

  /// The person sent a message: they want to see it go.
  public mutating func sent() -> Move { goToEnd() }

  /// The person asked to go to the end.
  public mutating func jumpRequested() -> Move { goToEnd() }

  private mutating func goToEnd() -> Move {
    isFollowing = true
    hasNew = false
    return .goToEnd
  }
}
