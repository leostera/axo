import AxoPhoneModel
import XCTest

final class MascotFlightTests: XCTestCase {
  func testAHarderPullThrowsItHigher() {
    let tug = MascotFlight.released(at: 0.1, drawn: false)
    let pull = MascotFlight.released(at: 0.9, drawn: false)
    XCTAssertLessThan(tug.peak, pull.peak)
    XCTAssertEqual(MascotFlight.released(at: 0.99, drawn: false).peak, 149, accuracy: 1)
  }

  func testItRisesTopsOutAndLandsWhereItStarted() {
    let flight = MascotFlight.released(at: 0.5, drawn: false)
    XCTAssertEqual(flight.height(after: flight.duration / 2), flight.peak, accuracy: 0.001)
    XCTAssertGreaterThan(flight.height(after: flight.duration / 4), 0)
    XCTAssertEqual(flight.height(after: flight.duration), 0)
    XCTAssertEqual(flight.height(after: flight.duration + 1), 0, "it lands and stays: no bounce")
  }

  func testAHopDoesNotTurnButASlingDoes() {
    let hop = MascotFlight.released(at: 0.5, drawn: false)
    XCTAssertEqual(hop.angle(after: hop.duration / 2), 0)
    let sling = MascotFlight.released(at: 1, drawn: true)
    XCTAssertNotEqual(sling.angle(after: 0.2), 0)
  }

  func testASlingLeavesTheScreenAndAHopNeverDoes() {
    let sling = MascotFlight.released(at: 1, drawn: true)
    let passes = try! XCTUnwrap(sling.time(toPass: 900))
    XCTAssertEqual(sling.height(after: passes), 900, accuracy: 0.001)
    XCTAssertNil(MascotFlight.released(at: 0.99, drawn: false).time(toPass: 900))
  }
}
