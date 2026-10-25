import AxoProtocol


/// When to reattach a surface whose output stream Axod ended. Reattaching is rate-limited so a
/// failing stream cannot spin, but a stream that ends again inside the window is reattached
/// once the window passes, never dropped: dropping it would leave the pane frozen on its last
/// screen with a live program behind it.
struct ReattachThrottle {
  static let minimumInterval: Duration = .seconds(2)

  enum Decision: Equatable {
    case now
    case after(Duration)
  }

  private var lastAttempt: [ShellID: ContinuousClock.Instant] = [:]

  /// Decides for `shellID` and records the attempt at the time it will happen.
  mutating func decide(for shellID: ShellID, at now: ContinuousClock.Instant) -> Decision {
    guard let last = lastAttempt[shellID], now - last < Self.minimumInterval else {
      lastAttempt[shellID] = now
      return .now
    }
    let next = last + Self.minimumInterval
    lastAttempt[shellID] = next
    return .after(next - now)
  }

  mutating func forget(_ shellID: ShellID) {
    lastAttempt[shellID] = nil
  }
}
