import Foundation

/// Spots a rub: a finger or pointer dragged up and down over Axo, which makes it happy ^_^.
///
/// Positions are vertical, in mascot heights (`y / height`), so the rule holds at any size. A
/// stroke is a run in one direction of at least `strokeLength`; `strokesToRub` strokes, each
/// within `strokeGap` of the last, are a rub. Once happy, Axo ignores rubbing for `happyFor`, so
/// one long rub smiles once every so often rather than on every stroke.
public struct MascotRubs: Sendable {
  public static let strokeLength = 0.15
  /// Down, up, down, up.
  public static let strokesToRub = 4
  public static let strokeGap: TimeInterval = 0.6
  /// About as long as the `happy` animation.
  public static let happyFor: TimeInterval = 1.2

  /// The furthest point of the stroke under way, and which way it is going (+1 down, -1 up).
  private var extreme: Double?
  private var direction: Double = 0
  private var strokes = 0
  private var lastStroke: Date?
  private var happyUntil: Date?

  public init() {}

  /// A move to `y` (in mascot heights); `.happy` when this move completes a rub.
  public mutating func move(y: Double, at now: Date) -> MascotReaction? {
    if let happyUntil, now < happyUntil { return nil }
    happyUntil = nil
    guard let from = extreme else {
      extreme = y
      return nil
    }
    if direction != 0, (y - from) * direction > 0 {
      // Further the same way.
      extreme = y
      return nil
    }
    guard abs(y - from) >= Self.strokeLength else { return nil }
    // A new stroke: the first, or a turn back the other way.
    if let lastStroke, now.timeIntervalSince(lastStroke) > Self.strokeGap { strokes = 0 }
    direction = y > from ? 1 : -1
    extreme = y
    strokes += 1
    lastStroke = now
    guard strokes >= Self.strokesToRub else { return nil }
    strokes = 0
    lastStroke = nil
    happyUntil = now.addingTimeInterval(Self.happyFor)
    return .happy
  }

  /// The finger or pointer lifted: the next touch starts a new rub.
  public mutating func end() {
    extreme = nil
    direction = 0
    strokes = 0
    lastStroke = nil
  }
}
