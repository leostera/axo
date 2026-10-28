import Foundation

/// Where each layer of a stack of screens sits, and where a swipe takes the stack.
///
/// The layers are numbered from the bottom. One of them is *home* (the conversation): at rest it
/// covers everything below it. Swiping right pushes home aside to show the layer beneath, with a
/// strip of home left at the edge; swiping right again pushes that one aside too, home with it.
/// Swiping left brings them back, one at a time. Layers *above* home are not under anything:
/// swiping left on home pulls the next one in from the right, over it, leaving a strip of home.
///
/// The stack has one position, a number from 0 (the bottom layer showing) to the top layer's
/// index. A drag moves it continuously, so every layer follows the finger together; at rest it is
/// whole: the layer showing.
public struct LayerStackGeometry: Equatable, Sendable {
  public let count: Int
  public let home: Int
  public let width: Double

  /// How far a layer moves to show the one beneath (or comes in over the one below): most of the
  /// screen, leaving a strip to tap or drag back. Proportions of the original phone menu.
  public var reveal: Double { min(width * 0.79, 360) }

  /// How far a finger must go before a drag can be a swipe of the stack rather than a scroll.
  public static let swipeStart: Double = 24
  /// How much more sideways than up or down a drag must be to move the stack: a scroll that
  /// drifts, even a lot, stays a scroll.
  public static let swipeSlope: Double = 2.5

  /// What one drag on the stack is. It starts undecided and is decided once, for good: a drag
  /// that began as a scroll never turns into a swipe, however it ends.
  public enum Drag: Equatable, Sendable {
    case undecided
    /// The stack follows the finger.
    case swipe
    /// Someone else's: a scroll up or down, or a code block scrolling sideways.
    case scroll

    /// The drag after the finger has gone `width` points sideways and `height` up or down;
    /// `sidewaysScrolling` says a sideways scroll view has taken it.
    public func next(width: Double, height: Double, sidewaysScrolling: Bool) -> Drag {
      guard self == .undecided else { return self }
      if sidewaysScrolling || abs(height) >= LayerStackGeometry.swipeStart { return .scroll }
      if abs(width) >= LayerStackGeometry.swipeStart && abs(width) >= abs(height) * LayerStackGeometry.swipeSlope {
        return .swipe
      }
      return .undecided
    }
  }

  public init(count: Int, home: Int, width: Double) {
    precondition(count > 0 && (0..<count).contains(home), "home is one of the layers")
    self.count = count
    self.home = home
    self.width = width
  }

  /// The position while a layer showing is dragged `translation` points (rightwards positive).
  /// Past the first or last layer the stack gives a little and stops.
  public func position(showing layer: Int, dragged translation: Double) -> Double {
    let raw = Double(layer) - translation / max(reveal, 1)
    let last = Double(count - 1)
    if raw < 0 { return -Self.give(-raw) }
    if raw > last { return last + Self.give(raw - last) }
    return raw
  }

  /// Resistance past the ends: a fifth of the overshoot, never more than a tenth of a layer.
  private static func give(_ overshoot: Double) -> Double { min(overshoot * 0.2, 0.1) }

  /// How far right of the screen's left edge `layer` sits at `position`.
  public func offset(of layer: Int, at position: Double) -> Double {
    if layer <= home {
      // How many layers above the one showing this is: 0 or less, in place; 1, pushed aside to
      // leave its strip; 2, pushed out by the one beneath it, which now leaves the strip.
      let above = Double(layer) - position
      if above <= 0 { return 0 }
      if above <= 1 { return above * reveal }
      return reveal + min(above - 1, 1) * (width - reveal)
    }
    // A layer above home comes in from the right over the one below it.
    return width - shown(layer, at: position) * reveal
  }

  /// 0 when `layer` is where it rests under or off the stack, 1 when it is fully moved: pushed
  /// aside (a layer up to home) or fully in (a layer above home). Drives its shadow and corners.
  public func moved(_ layer: Int, at position: Double) -> Double {
    layer <= home ? clamp(Double(layer) - position) : shown(layer, at: position)
  }

  /// Whether any of `layer` can be seen at `position`: not lying under the layer above it, nor
  /// off the right edge. A layer that cannot be seen is kept (with its state) but not drawn.
  public func isOnScreen(_ layer: Int, at position: Double) -> Bool {
    if offset(of: layer, at: position) >= width { return false }
    // The layer above lies flat on it (the one above home only ever covers part of home).
    if layer < home, position >= Double(layer + 1) { return false }
    return true
  }

  /// How much `layer` is dimmed: as it is pushed aside, or as the layer above home covers it.
  public func dimming(of layer: Int, at position: Double) -> Double {
    let pushed = layer <= home ? clamp(Double(layer) - position) : 0
    let covered = layer + 1 > home && layer + 1 < count ? shown(layer + 1, at: position) : 0
    return max(pushed, covered)
  }

  /// The layer whose strip shows beside the layer showing, which a tap brings back: the one
  /// pushed aside above it, or the one a layer above home came in over. None at home.
  public func edgeLayer(showing layer: Int) -> Int? {
    if layer < home { return layer + 1 }
    if layer > home { return layer - 1 }
    return nil
  }

  /// How wide the strip of `edgeLayer(showing:)` is.
  public var edgeWidth: Double { width - reveal }

  /// Where a swipe that ended after `translation` points, moving at `velocity` points a second,
  /// settles. A flick goes one layer in its direction however short it was; a slow drag settles
  /// on the nearest layer; a flick back against the drag stays. A swipe moves one layer at most:
  /// two swipes to go two layers.
  public func target(showing layer: Int, dragged translation: Double, velocity: Double) -> Int {
    var target = Int(position(showing: layer, dragged: translation).rounded())
    if abs(velocity) >= Self.flickSpeed {
      let along = translation == 0 || (velocity > 0) == (translation > 0)
      // Rightwards goes down the stack.
      target = along ? layer + (velocity > 0 ? -1 : 1) : layer
    }
    return min(max(target, layer - 1, 0), layer + 1, count - 1)
  }

  /// Points a second; a deliberate flick of the thumb is several times this.
  public static let flickSpeed = 300.0

  private func shown(_ layer: Int, at position: Double) -> Double { clamp(position - Double(layer - 1)) }
  private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}
