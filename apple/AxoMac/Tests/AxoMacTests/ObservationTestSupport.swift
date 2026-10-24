import Observation
import os

/// Whether running `body` changes any observable state that `read` accesses.
@MainActor
func observesChange(of read: () -> Void, during body: () async -> Void) async -> Bool {
  let changed = OSAllocatedUnfairLock(initialState: false)
  withObservationTracking(read) { changed.withLock { $0 = true } }
  await body()
  return changed.withLock { $0 }
}
