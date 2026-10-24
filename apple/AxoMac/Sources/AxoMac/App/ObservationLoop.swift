import Foundation
import Observation

/// Calls `onChange` with `read()`'s value now and after every change to the observable state it
/// reads, until cancelled. Changes are delivered on a later main-actor turn (after the mutation
/// completes), and repeated equal values are skipped.
@MainActor
final class ObservationLoop {
  private var isCancelled = false

  @discardableResult
  static func observe<Value: Equatable>(
    _ read: @escaping @MainActor () -> Value,
    onChange: @escaping @MainActor (Value) -> Void
  ) -> ObservationLoop {
    let loop = ObservationLoop()
    var lastValue: Value?
    func track() {
      guard !loop.isCancelled else { return }
      let value = withObservationTracking(read) {
        Task { @MainActor in track() }
      }
      if lastValue != value {
        lastValue = value
        onChange(value)
      }
    }
    track()
    return loop
  }

  func cancel() { isCancelled = true }
}
