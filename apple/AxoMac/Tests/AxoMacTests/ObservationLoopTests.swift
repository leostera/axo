import Observation
import XCTest

@testable import AxoMac

@MainActor
@Observable
private final class Counter {
  var value = 0
  var unrelated = 0
}

@MainActor
final class ObservationLoopTests: XCTestCase {
  func testDeliversInitialValueThenDistinctChangesUntilCancelled() async throws {
    let counter = Counter()
    var delivered: [Int] = []
    let loop = ObservationLoop.observe({ counter.value }) { delivered.append($0) }
    XCTAssertEqual(delivered, [0], "the current value is delivered immediately")

    counter.value = 1
    try await waitUntil { delivered == [0, 1] }
    counter.value = 1  // Equal write: observed, but not redelivered.
    counter.unrelated = 5  // Not read: not observed.
    counter.value = 2
    try await waitUntil { delivered == [0, 1, 2] }

    loop.cancel()
    counter.value = 3
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(delivered, [0, 1, 2])
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition() {
      guard ContinuousClock.now < deadline else { return XCTFail("timed out") }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}
