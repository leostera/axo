import Foundation

/// When a conversation follows what is new and when it leaves the reader where they are.
///
/// The rules, as the original app had them:
/// - The first page of a conversation opens at its end, without animating.
/// - Something new at the end (a message, the reply growing, a question) follows it only when
///   the reader is already at the end; otherwise the reader keeps their place and is told
///   ("Jump to new message").
/// - Sending something always goes to the end: the reader wants to see it go.
/// - Reaching the end, however it happens, clears "new".
/// - Going to the end counts as being there until the reader scrolls away: a lazy list can land
///   a little short of an end it had only estimated, and that must not stop it following.
public struct ScrollFollow: Equatable, Sendable {
  /// What the screen should do about a change.
  public enum Move: Equatable, Sendable {
    case stay
    /// Go to the end at once (the first page).
    case jumpToEnd
    /// Go to the end, animated.
    case followToEnd
  }

  /// The reader is at (or within a few points of) the end.
  public private(set) var isAtEnd = true
  /// Something arrived below the reader since they scrolled up.
  public private(set) var hasNew = false
  private var hasShownContent = false

  public init() {}

  /// The reader scrolled; `atEnd` says whether the end is in view.
  public mutating func readerScrolled(atEnd: Bool) {
    isAtEnd = atEnd
    if atEnd { hasNew = false }
  }

  /// The content at the end changed: a new message, or the reply or a tool's output grew.
  public mutating func contentChangedAtEnd() -> Move {
    guard hasShownContent else {
      hasShownContent = true
      isAtEnd = true
      return .jumpToEnd
    }
    if isAtEnd { return .followToEnd }
    hasNew = true
    return .stay
  }

  /// The person sent a message.
  public mutating func sent() -> Move {
    hasNew = false
    isAtEnd = true
    return .followToEnd
  }

  /// The person asked to go to the end.
  public mutating func jumpRequested() -> Move {
    hasNew = false
    isAtEnd = true
    return .followToEnd
  }
}
