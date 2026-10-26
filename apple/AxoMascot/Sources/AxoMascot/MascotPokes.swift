import Foundation

/// How Axo answers being poked: a few pokes make it giggle; poking on and on annoys it.
public enum MascotReaction: Equatable, Sendable {
  case giggle
  case annoyed
}

/// Counts quick pokes on the mascot.
///
/// Pokes less than `streakGap` apart form a streak. The first pokes of a streak giggle; the
/// `annoyedAt`-th annoys it, and while it is annoyed further pokes do nothing, so it calms down
/// before the next streak starts.
public struct MascotPokes: Sendable {
  public static let streakGap: TimeInterval = 0.7
  public static let annoyedAt = 4
  /// About as long as the `annoyed` animation.
  public static let annoyedFor: TimeInterval = 1.2

  private var streak = 0
  private var lastPoke: Date?
  private var annoyedUntil: Date?

  public init() {}

  public mutating func poke(at now: Date) -> MascotReaction? {
    if let annoyedUntil, now < annoyedUntil { return nil }
    annoyedUntil = nil
    if let lastPoke, now.timeIntervalSince(lastPoke) <= Self.streakGap {
      streak += 1
    } else {
      streak = 1
    }
    lastPoke = now
    guard streak >= Self.annoyedAt else { return .giggle }
    streak = 0
    lastPoke = nil
    annoyedUntil = now.addingTimeInterval(Self.annoyedFor)
    return .annoyed
  }
}
