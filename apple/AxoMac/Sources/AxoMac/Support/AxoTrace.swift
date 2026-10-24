import Foundation
import os

/// Latency tracing for user-visible actions. Read with:
/// `log show --last 10m --predicate 'subsystem == "dev.leostera.axo"' --info`
enum AxoTrace {
  static let commands = Logger(subsystem: "dev.leostera.axo", category: "commands")
  static let surfaces = Logger(subsystem: "dev.leostera.axo", category: "surfaces")

  /// Milliseconds since `start`, for log fields.
  static func elapsed(since start: ContinuousClock.Instant) -> String {
    let duration = ContinuousClock.now - start
    let milliseconds = Double(duration.components.seconds) * 1_000
      + Double(duration.components.attoseconds) / 1e15
    return String(format: "%.1f", milliseconds)
  }
}
