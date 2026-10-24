import CoreFoundation
import Foundation
import os

/// Reports main run-loop iterations that keep the main thread busy long enough to delay
/// terminal frames: libghostty's ticks and the presentation of rendered frames both run on the
/// main thread, so a busy iteration is felt as typing or resize lag.
///
/// It observes the run loop instead of polling it, so an idle app costs nothing. Long
/// iterations are logged (`event=main.stall`) and every busy iteration over the frame budget is a
/// signpost interval for Instruments.
@MainActor
final class MainThreadStallMonitor {
  /// One frame at 60 Hz: anything longer drops a frame.
  nonisolated static let frameBudget: Duration = .milliseconds(16)
  /// Long enough to be felt; logged.
  nonisolated static let reportThreshold: Duration = .milliseconds(50)

  private var observer: CFRunLoopObserver?
  private let onBusy: @MainActor (Duration) -> Void

  /// - Parameter onBusy: called with each iteration longer than `frameBudget`; logs by default.
  init(onBusy: @escaping @MainActor (Duration) -> Void = MainThreadStallMonitor.record(busy:)) {
    self.onBusy = onBusy
  }

  func start() {
    guard observer == nil else { return }
    var busySince: ContinuousClock.Instant?
    let onBusy = onBusy
    let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
    let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, CFIndex.max) {
      _, activity in
      switch activity {
      case .afterWaiting:
        busySince = .now
      case .beforeWaiting:
        guard let start = busySince else { return }
        busySince = nil
        let busy = ContinuousClock.now - start
        if busy > Self.frameBudget { onBusy(busy) }
      default:
        break
      }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    self.observer = observer
  }

  func stop() {
    guard let observer else { return }
    CFRunLoopObserverInvalidate(observer)
    self.observer = nil
  }

  static func record(busy: Duration) {
    AxoTrace.signposter.emitEvent("main.busy", "\(AxoTrace.milliseconds(busy), privacy: .public) ms")
    guard busy > reportThreshold else { return }
    AxoTrace.latency.notice(
      "event=main.stall busy_ms=\(AxoTrace.milliseconds(busy), privacy: .public)")
  }
}
