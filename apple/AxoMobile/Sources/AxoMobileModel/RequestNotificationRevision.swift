import Foundation

public enum RequestNotificationRevision {
  /// JSON's exact-integer range, monotonic even after an old backup or a backward clock step.
  public static func next(after previous: Int64?, now: Date = .now) -> Int64? {
    let maximum: Int64 = 9_007_199_254_740_991
    guard previous.map({ $0 >= 0 && $0 < maximum }) ?? true,
      let clock = Int64(exactly: (now.timeIntervalSince1970 * 1000).rounded(.down)), clock >= 0
    else { return nil }
    let base = max(previous ?? 0, clock)
    guard base < maximum else { return nil }
    return base + 1
  }
}
