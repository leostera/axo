import Foundation

/// Axo thrown straight up from where it sits: gravity alone decides how high it goes, when it
/// lands and how far it turns on the way. Heights are in points above its resting place.
public struct MascotFlight: Equatable, Sendable {
  /// Points per second squared: a light, cartoon gravity.
  public static let gravity = 2600.0
  /// A pull just short of drawn throws it this high; a tiny tug, `lowestPeak`.
  public static let highestHop = 150.0
  public static let lowestPeak = 14.0
  /// A full pull throws it this high: well past the top of any phone.
  public static let slingPeak = 1400.0

  /// Upward speed as it leaves, points per second.
  public let speed: Double
  /// Degrees per second, constant in flight (no air, no torque).
  public let spin: Double

  public init(speed: Double, spin: Double = 0) {
    self.speed = speed
    self.spin = spin
  }

  /// The throw for a pull let go at `progress` (0 to 1): short of drawn it hops, higher the
  /// further it was pulled; drawn, it is slung with a spin.
  public static func released(at progress: Double, drawn: Bool) -> MascotFlight {
    if drawn {
      return MascotFlight(speed: speed(toReach: slingPeak), spin: -720)
    }
    let peak = lowestPeak + (highestHop - lowestPeak) * min(max(progress, 0), 1)
    return MascotFlight(speed: speed(toReach: peak))
  }

  /// The launch speed that tops out at `peak`: v² = 2gh.
  public static func speed(toReach peak: Double) -> Double {
    (2 * gravity * peak).squareRoot()
  }

  public var peak: Double { speed * speed / (2 * Self.gravity) }
  /// Up and back down to where it started.
  public var duration: TimeInterval { 2 * speed / Self.gravity }

  /// Height `t` seconds after leaving: h = vt − gt²/2, and on the ground once it is back.
  public func height(after t: TimeInterval) -> Double {
    guard t > 0, t < duration else { return 0 }
    return speed * t - Self.gravity * t * t / 2
  }

  public func angle(after t: TimeInterval) -> Double {
    spin * min(max(t, 0), duration)
  }

  /// When it is first higher than `height`, if it ever is: out of sight above the screen.
  public func time(toPass height: Double) -> TimeInterval? {
    guard height < peak else { return nil }
    // The earlier root of h = vt − gt²/2.
    let discriminant = speed * speed - 2 * Self.gravity * height
    return (speed - discriminant.squareRoot()) / Self.gravity
  }
}
