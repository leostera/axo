import AxoPhoneModel
import XCTest

final class PullToRefreshTests: XCTestCase {
  func testPullingDrawsItAndLettingGoRefreshes() {
    var pull = PullToRefresh()
    pull.pulled(to: 45, touching: true)
    XCTAssertEqual(pull.phase, .pulling(0.5))
    pull.pulled(to: 120, touching: true)
    XCTAssertEqual(pull.phase, .armed)
    XCTAssertTrue(pull.released())
    XCTAssertEqual(pull.phase, .refreshing)
    XCTAssertEqual(pull.progress, 1)
  }

  func testLettingGoShortOfDrawnDoesNotRefresh() {
    var pull = PullToRefresh()
    pull.pulled(to: 60, touching: true)
    XCTAssertFalse(pull.released())
    pull.pulled(to: 20, touching: false)
    pull.pulled(to: 0, touching: false)
    XCTAssertEqual(pull.phase, .idle)
  }

  func testAFlingsBounceNeverDrawsItAllTheWay() {
    var pull = PullToRefresh()
    pull.pulled(to: 200, touching: false)
    XCTAssertEqual(pull.phase, .pulling(0.99))
    XCTAssertFalse(pull.released())
  }

  func testPullsWhileRefreshingAreIgnoredUntilItFinishes() {
    var pull = PullToRefresh()
    pull.pulled(to: 100, touching: true)
    _ = pull.released()
    // The content springs back while the refresh runs.
    pull.pulled(to: 30, touching: false)
    pull.pulled(to: 0, touching: false)
    XCTAssertEqual(pull.phase, .refreshing)
    pull.finished()
    XCTAssertEqual(pull.phase, .idle)
  }
}
