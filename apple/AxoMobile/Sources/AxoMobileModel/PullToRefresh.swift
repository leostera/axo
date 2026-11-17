import Foundation

/// Pull-to-refresh, as Axo plays it: pulling the conversation down past its top winds Axo up,
/// letting go once it is drawn far enough refreshes, and Axo shows the refresh until it ends.
///
/// How far it is pulled is how far the finger has travelled, as a fraction of the scroll view's
/// height (the conversation, between its bars; about three quarters of the screen): the scroll view only reports its rubber-banded offset, which grows ever slower, so
/// `fingerTravel` undoes UIKit's rubber band to get the finger back. Only a finger can draw it
/// all the way (a fling's bounce cannot), and only letting go while drawn starts a refresh.
/// While refreshing, pulls are ignored.
public struct PullToRefresh: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case idle
    /// Drawn this far, from 0 to just under 1.
    case pulling(Double)
    /// Drawn all the way: letting go refreshes.
    case armed
    case refreshing
  }

  /// UIScrollView's rubber band: an offset `o` past the edge of a view `d` tall comes from a
  /// finger `x` past it, with o = (1 − 1 / (x·c/d + 1))·d.
  public static let rubberBand = 0.55
  /// A short pull, for a chat with messages: about 90 points of rubber band.
  public static let shortPull = 0.3
  /// The new chat's: from where its Axo sits, a third of the way down the screen, to about four
  /// fifths down (measured in the simulator: a drag to two thirds down reads 0.42, to 88% 0.83).
  public static let longPull = 0.7

  public private(set) var phase: Phase = .idle
  /// How far the finger has travelled, as a fraction of the scroll view's height.
  public private(set) var travel: Double = 0
  /// The travel that draws it all the way.
  public var armTravel: Double

  public init(armTravel: Double = PullToRefresh.shortPull) {
    self.armTravel = armTravel
  }

  /// The finger's travel, as a fraction of `height`, that rubber-bands to `overscroll`:
  /// x/d = o / (c·(d − o)).
  public static func fingerTravel(overscroll: Double, height: Double) -> Double {
    guard overscroll > 0, height > overscroll else { return overscroll > 0 ? .infinity : 0 }
    return overscroll / (rubberBand * (height - overscroll))
  }

  /// From 0 (at rest) to 1 (drawn, or refreshing).
  public var progress: Double {
    switch phase {
    case .idle: 0
    case .pulling(let progress): progress
    case .armed, .refreshing: 1
    }
  }

  /// The content is `overscroll` points past its top, in a scroll view `height` points tall.
  public mutating func pulled(to overscroll: Double, height: Double, touching: Bool) {
    guard phase != .refreshing else { return }
    travel = Self.fingerTravel(overscroll: overscroll, height: height)
    let progress = min(max(travel / armTravel, 0), 1)
    if progress <= 0 {
      phase = .idle
    } else if progress >= 1, touching {
      phase = .armed
    } else {
      phase = .pulling(min(progress, 0.99))
    }
  }

  /// The finger lifted; true when that starts a refresh.
  public mutating func released() -> Bool {
    guard phase == .armed else { return false }
    phase = .refreshing
    return true
  }

  /// The refresh is over.
  public mutating func finished() {
    phase = .idle
  }
}
