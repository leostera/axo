import Foundation

/// Pull-to-refresh, as Axo plays it: pulling the conversation down past its top winds Axo up,
/// letting go once it is drawn far enough refreshes, and Axo shows the refresh until it ends.
///
/// The view feeds it how far the content is pulled past its top, and whether a finger is on the
/// screen; only a finger can draw it all the way (a fling's bounce cannot), and only letting go
/// while drawn starts a refresh. While refreshing, pulls are ignored.
public struct PullToRefresh: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case idle
    /// Drawn this far, from 0 to just under 1.
    case pulling(Double)
    /// Drawn all the way: letting go refreshes.
    case armed
    case refreshing
  }

  /// How far to pull, in points, to draw it all the way.
  public static let distance: Double = 90

  public private(set) var phase: Phase = .idle

  public init() {}

  /// From 0 (at rest) to 1 (drawn, or refreshing).
  public var progress: Double {
    switch phase {
    case .idle: 0
    case .pulling(let progress): progress
    case .armed, .refreshing: 1
    }
  }

  /// The content is `overscroll` points past its top.
  public mutating func pulled(to overscroll: Double, touching: Bool) {
    guard phase != .refreshing else { return }
    let progress = min(max(overscroll / Self.distance, 0), 1)
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
