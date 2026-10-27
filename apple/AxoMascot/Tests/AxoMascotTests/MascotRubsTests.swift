import XCTest

@testable import AxoMascot

final class MascotRubsTests: XCTestCase {
  private let start = Date(timeIntervalSinceReferenceDate: 0)

  /// Moves through `ys`, one every `every` seconds; the reactions that came out.
  private func rub(_ ys: [Double], every: TimeInterval = 0.05, rubs: inout MascotRubs, from: TimeInterval = 0)
    -> [MascotReaction]
  {
    ys.enumerated().compactMap { index, y in
      rubs.move(y: y, at: start.addingTimeInterval(from + Double(index) * every))
    }
  }

  /// Down and up `times` times between 0.3 and 0.7 of the mascot's height.
  private func strokes(_ times: Int) -> [Double] {
    [0.5] + (0..<times).flatMap { _ in [0.7, 0.3] }
  }

  func testRubbingUpAndDownMakesItHappy() {
    var rubs = MascotRubs()
    XCTAssertEqual(rub(strokes(2), rubs: &rubs), [.happy])
  }

  func testOneStrokeIsADragNotARub() {
    var rubs = MascotRubs()
    XCTAssertEqual(rub([0.2, 0.4, 0.6, 0.8], rubs: &rubs), [])
  }

  func testJitterIsNotAStroke() {
    var rubs = MascotRubs()
    XCTAssertEqual(rub([0.5, 0.55, 0.5, 0.56, 0.49, 0.55, 0.5, 0.56, 0.5], rubs: &rubs), [])
  }

  func testSlowStrokesDoNotAddUp() {
    var rubs = MascotRubs()
    XCTAssertEqual(rub(strokes(3), every: 1, rubs: &rubs), [])
  }

  func testLiftingTheFingerStartsOver() {
    var rubs = MascotRubs()
    XCTAssertEqual(rub([0.5, 0.7, 0.3], rubs: &rubs), [])
    rubs.end()
    XCTAssertEqual(rub([0.5, 0.7, 0.3], rubs: &rubs, from: 0.2), [])
  }

  func testALongRubSmilesOnlyOnceInAWhile() {
    var rubs = MascotRubs()
    // 0.05 s a move: about 2.4 s of rubbing.
    XCTAssertEqual(rub(strokes(24), rubs: &rubs), [.happy, .happy])
  }
}
