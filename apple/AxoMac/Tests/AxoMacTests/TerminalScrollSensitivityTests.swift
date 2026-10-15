import XCTest

@testable import AxoMac

final class TerminalScrollSensitivityTests: XCTestCase {
  func testSliderEndpointsMatchSupportedSensitivityRange() {
    XCTAssertEqual(TerminalScrollSensitivity.multiplier(atSliderPosition: 0), 0.1, accuracy: 0.0001)
    XCTAssertEqual(TerminalScrollSensitivity.multiplier(atSliderPosition: 1), 3.0, accuracy: 0.0001)
    XCTAssertEqual(TerminalScrollSensitivity.sliderPosition(for: 0.1), 0, accuracy: 0.0001)
    XCTAssertEqual(TerminalScrollSensitivity.sliderPosition(for: 3.0), 1, accuracy: 0.0001)
  }

  func testSliderCenterIsNeutralSensitivity() {
    XCTAssertEqual(
      TerminalScrollSensitivity.multiplier(atSliderPosition: 0.5),
      TerminalScrollSensitivity.defaultMultiplier,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      TerminalScrollSensitivity.sliderPosition(for: TerminalScrollSensitivity.defaultMultiplier),
      0.5,
      accuracy: 0.0001
    )
  }

  func testSliderPositionAndMultiplierRoundTrip() {
    for multiplier in [0.1, 0.4, 1.0, 1.6, 3.0] {
      let position = TerminalScrollSensitivity.sliderPosition(for: multiplier)
      XCTAssertEqual(
        TerminalScrollSensitivity.multiplier(atSliderPosition: position),
        multiplier,
        accuracy: 0.0001
      )
    }
  }

  func testOutOfRangeAndNonFiniteValuesAreBounded() {
    XCTAssertEqual(TerminalScrollSensitivity.boundedMultiplier(-1), 0.1)
    XCTAssertEqual(TerminalScrollSensitivity.boundedMultiplier(4), 3.0)
    XCTAssertEqual(TerminalScrollSensitivity.boundedMultiplier(.nan), 1.0)
    XCTAssertEqual(TerminalScrollSensitivity.multiplier(atSliderPosition: .infinity), 1.0)
  }
}
