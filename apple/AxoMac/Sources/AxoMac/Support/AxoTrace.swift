import Foundation
import os

/// Latency tracing for user-visible actions. Read with:
/// `log show --last 10m --predicate 'subsystem == "dev.leostera.axo"' --info`
enum AxoTrace {
  static let commands = Logger(subsystem: "dev.leostera.axo", category: "commands")
  static let surfaces = Logger(subsystem: "dev.leostera.axo", category: "surfaces")
  /// Input and frame latency: main-thread stalls and delayed libghostty ticks.
  static let latency = Logger(subsystem: "dev.leostera.axo", category: "latency")
  /// Intervals and events for Instruments (os_signpost, subsystem `dev.leostera.axo`, category
  /// `latency`); near free unless Instruments is recording.
  static let signposter = OSSignposter(logger: latency)

  /// An Instruments interval for one user command, from request to the model applying Axod's
  /// answer. Begin at the top of the command and end it with `defer`.
  struct Interval {
    fileprivate let name: StaticString
    fileprivate let state: OSSignpostIntervalState
  }

  static func beginInterval(_ name: StaticString) -> Interval {
    Interval(name: name, state: signposter.beginInterval(name))
  }

  static func endInterval(_ interval: Interval) {
    signposter.endInterval(interval.name, interval.state)
  }

  /// Milliseconds since `start`, for log fields.
  static func elapsed(since start: ContinuousClock.Instant) -> String {
    milliseconds(ContinuousClock.now - start)
  }

  /// `duration` in milliseconds, for log fields.
  static func milliseconds(_ duration: Duration) -> String {
    let milliseconds = Double(duration.components.seconds) * 1_000
      + Double(duration.components.attoseconds) / 1e15
    return String(format: "%.1f", milliseconds)
  }
}
