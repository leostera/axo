import AxoPhoneModel
import XCTest

final class MascotFlightTests: XCTestCase {
  func testAHarderPullThrowsItHigher() {
    let tug = MascotFlight.released(travel: 0.05, drawn: false)
    let pull = MascotFlight.released(travel: 0.25, drawn: false)
    XCTAssertLessThan(tug.peak, pull.peak)
    XCTAssertEqual(MascotFlight.released(travel: 0.42, drawn: false).peak, MascotFlight.highestHop, accuracy: 0.001)
    XCTAssertEqual(
      MascotFlight.released(travel: 0.65, drawn: false).peak, MascotFlight.highestHop, accuracy: 0.001,
      "past two thirds down it hops no higher: it only leaves the screen once drawn")
  }

  func testItRisesTopsOutAndLandsWhereItStarted() {
    let flight = MascotFlight.released(travel: 0.15, drawn: false)
    XCTAssertEqual(flight.height(after: flight.duration / 2), flight.peak, accuracy: 0.001)
    XCTAssertGreaterThan(flight.height(after: flight.duration / 4), 0)
    XCTAssertEqual(flight.height(after: flight.duration), 0)
    XCTAssertEqual(flight.height(after: flight.duration + 1), 0, "it lands and stays: no bounce")
  }

  func testAHopDoesNotTurnButASlingDoes() {
    let hop = MascotFlight.released(travel: 0.15, drawn: false)
    XCTAssertEqual(hop.angle(after: hop.duration / 2), 0)
    let sling = MascotFlight.released(travel: 0.7, drawn: true)
    XCTAssertNotEqual(sling.angle(after: 0.2), 0)
  }

  func testASlingLeavesTheScreenAndAHopNeverDoes() {
    let sling = MascotFlight.released(travel: 0.7, drawn: true)
    let passes = try! XCTUnwrap(sling.time(toPass: 900))
    XCTAssertEqual(sling.height(after: passes), 900, accuracy: 0.001)
    XCTAssertNil(MascotFlight.released(travel: 0.65, drawn: false).time(toPass: 900))
  }
}
