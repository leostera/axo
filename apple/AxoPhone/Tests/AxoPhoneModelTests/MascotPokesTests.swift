import XCTest

@testable import AxoPhoneModel

final class MascotPokesTests: XCTestCase {
  private let start = Date(timeIntervalSinceReferenceDate: 0)

  private func pokes(at seconds: [TimeInterval]) -> [MascotReaction?] {
    var pokes = MascotPokes()
    return seconds.map { pokes.poke(at: start.addingTimeInterval($0)) }
  }

  func testAFewPokesGiggle() {
    XCTAssertEqual(pokes(at: [0, 0.4]), [.giggle, .giggle])
  }

  func testTheFourthQuickPokeAnnoysIt() {
    XCTAssertEqual(pokes(at: [0, 0.3, 0.6, 0.9]), [.giggle, .giggle, .giggle, .annoyed])
  }

  func testPokesWhileAnnoyedAreIgnoredThenAStreakStartsOver() {
    XCTAssertEqual(
      pokes(at: [0, 0.3, 0.6, 0.9, 1.2, 1.8, 2.2, 2.4]),
      [.giggle, .giggle, .giggle, .annoyed, nil, nil, .giggle, .giggle])
  }

  func testSlowPokesNeverAnnoyIt() {
    XCTAssertEqual(pokes(at: [0, 1, 2, 3, 4]), Array(repeating: .giggle, count: 5))
  }
}
