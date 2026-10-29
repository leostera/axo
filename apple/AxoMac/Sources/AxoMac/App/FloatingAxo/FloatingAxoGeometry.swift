import CoreGraphics
import Foundation

/// How fast the pointer was going when it let go: from the samples of the last `window`
/// seconds, so an old part of the drag (or a pause before letting go) does not count.
struct ThrowVelocity {
  static let window: TimeInterval = 0.08
  /// Points per second; flicks faster than this are clamped, so Axo stays on screen.
  static let fastest: CGFloat = 6000

  private var samples: [(at: TimeInterval, point: CGPoint)] = []

  mutating func add(_ point: CGPoint, at time: TimeInterval) {
    samples.append((time, point))
    samples.removeAll { time - $0.at > Self.window * 2 }
  }

  mutating func reset() {
    samples.removeAll()
  }

  func velocity(at time: TimeInterval) -> CGVector {
    let recent = samples.filter { time - $0.at <= Self.window }
    guard let first = recent.first, let last = recent.last, last.at > first.at else { return .zero }
    let seconds = last.at - first.at
    let dx = (last.point.x - first.point.x) / seconds
    let dy = (last.point.y - first.point.y) / seconds
    let speed = (dx * dx + dy * dy).squareRoot()
    guard speed > Self.fastest else { return CGVector(dx: dx, dy: dy) }
    let scale = Self.fastest / speed
    return CGVector(dx: dx * scale, dy: dy * scale)
  }
}

/// A flat ledge Axo can land on: the visible part of a window's top edge, in AppKit screen
/// coordinates (y up).
struct Ledge: Equatable {
  var y: CGFloat
  var minX: CGFloat
  var maxX: CGFloat
}

enum WindowLedges {
  /// Ledges narrower than this are not worth landing on.
  static let narrowest: CGFloat = 40

  /// The top edges of `windows` (front to back, AppKit coordinates) that no window in front
  /// covers: Axo lands on what it can see.
  static func ledges(of windows: [CGRect]) -> [Ledge] {
    var ledges: [Ledge] = []
    for (index, window) in windows.enumerated() {
      var spans = [(window.minX, window.maxX)]
      // A window in front covers the edge where its rectangle holds the edge's height.
      for front in windows[..<index] where front.minY < window.maxY && window.maxY <= front.maxY {
        spans = spans.flatMap { span -> [(CGFloat, CGFloat)] in
          let cut = (max(span.0, front.minX), min(span.1, front.maxX))
          guard cut.0 < cut.1 else { return [span] }
          return [(span.0, cut.0), (cut.1, span.1)].filter { $0.0 < $0.1 }
        }
      }
      ledges += spans.filter { $0.1 - $0.0 >= narrowest }.map { Ledge(y: window.maxY, minX: $0.0, maxX: $0.1) }
    }
    return ledges
  }
}

/// Click or drag: a press that moves less than this is a click.
enum DragThreshold {
  static let distance: CGFloat = 4

  static func isDrag(from start: CGPoint, to point: CGPoint) -> Bool {
    hypot(point.x - start.x, point.y - start.y) >= distance
  }
}

/// Clicking an Axo blows it up: each click is a puff of air, and the twentieth in a row
/// (`pokesToBurst`) bursts it. Stop clicking for a moment (`holdsBreath`) and the air leaks out.
struct Inflation {
  static let pokesToBurst: Double = 20
  /// After a click it holds its breath this long, then leaks `leakPerSecond` clicks' worth of air
  /// a second: clicked about once a second or slower, it never bursts.
  static let holdsBreath: TimeInterval = 0.6
  static let leakPerSecond: Double = 2
  /// As big as it gets, just before it bursts.
  static let biggest: CGFloat = 2.2

  private var air: Double = 0
  private var since: Date?

  /// A click at `now`: how full it is (0 to 1), and whether that burst it.
  mutating func poke(at now: Date) -> (fullness: Double, bursts: Bool) {
    air = remaining(at: now) + 1
    since = now
    return (min(1, air / Self.pokesToBurst), air >= Self.pokesToBurst)
  }

  /// How full it is at `now`, from 0 to 1.
  func fullness(at now: Date) -> Double {
    min(1, remaining(at: now) / Self.pokesToBurst)
  }

  /// How much bigger than itself it is at `now`.
  func scale(at now: Date) -> CGFloat {
    1 + (Self.biggest - 1) * CGFloat(fullness(at: now))
  }

  private func remaining(at now: Date) -> Double {
    guard let since else { return 0 }
    let leaking = max(0, now.timeIntervalSince(since) - Self.holdsBreath)
    return max(0, air - leaking * Self.leakPerSecond)
  }
}
