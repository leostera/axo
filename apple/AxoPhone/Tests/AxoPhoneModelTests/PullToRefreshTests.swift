import AxoPhoneModel
import XCTest

final class PullToRefreshTests: XCTestCase {
  private let height = 800.0

  /// The offset UIKit shows for a finger `travel` (a fraction of the screen) past the top.
  private func overscroll(_ travel: Double) -> Double {
    let c = PullToRefresh.rubberBand
    return (1 - 1 / (travel * height * c / height + 1)) * height
  }

  func testTheFingersTravelIsReadBackFromTheRubberBand() {
    for travel in [0.1, 0.3, 0.5, 0.8] {
      XCTAssertEqual(PullToRefresh.fingerTravel(overscroll: overscroll(travel), height: height), travel, accuracy: 1e-9)
    }
  }

  func testALongPullNeedsNearlyTheWholeScreen() {
    var pull = PullToRefresh(armTravel: PullToRefresh.longPull)
    pull.pulled(to: overscroll(0.42), height: height, touching: true)
    XCTAssertEqual(pull.progress, 0.6, accuracy: 1e-9)
    pull.pulled(to: overscroll(0.65), height: height, touching: true)
    XCTAssertNotEqual(pull.phase, .armed, "not yet: still short of near the bottom")
    pull.pulled(to: overscroll(0.71), height: height, touching: true)
    XCTAssertEqual(pull.phase, .armed)
    XCTAssertTrue(pull.released())
    XCTAssertEqual(pull.phase, .refreshing)
  }

  func testLettingGoShortOfDrawnDoesNotRefresh() {
    var pull = PullToRefresh()
    pull.pulled(to: overscroll(0.15), height: height, touching: true)
    XCTAssertFalse(pull.released())
    pull.pulled(to: 0, height: height, touching: false)
    XCTAssertEqual(pull.phase, .idle)
  }

  func testAFlingsBounceNeverDrawsItAllTheWay() {
    var pull = PullToRefresh()
    pull.pulled(to: overscroll(0.9), height: height, touching: false)
    XCTAssertEqual(pull.phase, .pulling(0.99))
    XCTAssertFalse(pull.released())
  }

  func testPullsWhileRefreshingAreIgnoredUntilItFinishes() {
    var pull = PullToRefresh()
    pull.pulled(to: overscroll(0.32), height: height, touching: true)
    XCTAssertTrue(pull.released())
    pull.pulled(to: 30, height: height, touching: false)
    pull.pulled(to: 0, height: height, touching: false)
    XCTAssertEqual(pull.phase, .refreshing)
    pull.finished()
    XCTAssertEqual(pull.phase, .idle)
  }
}
