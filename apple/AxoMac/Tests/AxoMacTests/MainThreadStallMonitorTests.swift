import XCTest

@testable import AxoMac

@MainActor
final class MainThreadStallMonitorTests: XCTestCase {
  func testReportsAMainRunLoopIterationThatOverrunsTheFrameBudget() async throws {
    var busy: [Duration] = []
    let monitor = MainThreadStallMonitor { busy.append($0) }
    monitor.start()
    defer { monitor.stop() }

    // The monitor measures from the run loop's next wake-up; let it sleep once first.
    try await Task.sleep(for: .milliseconds(50))
    // Wake the main run loop with work that blocks it for 80 ms.
    RunLoop.main.perform { usleep(80_000) }
    CFRunLoopWakeUp(CFRunLoopGetMain())
    let deadline = ContinuousClock.now + .seconds(2)
    while !busy.contains(where: { $0 >= .milliseconds(80) }), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }

    XCTAssertTrue(busy.contains { $0 >= .milliseconds(80) }, "observed: \(busy)")
    XCTAssertTrue(busy.allSatisfy { $0 > MainThreadStallMonitor.frameBudget })
  }

  func testStoppedMonitorReportsNothing() async throws {
    var busy: [Duration] = []
    let monitor = MainThreadStallMonitor { busy.append($0) }
    monitor.start()
    monitor.stop()

    try await Task.sleep(for: .milliseconds(50))
    RunLoop.main.perform { usleep(40_000) }
    CFRunLoopWakeUp(CFRunLoopGetMain())
    try await Task.sleep(for: .milliseconds(150))

    XCTAssertEqual(busy, [])
  }
}
