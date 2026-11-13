import XCTest

@testable import AxoMac

final class IdlePiLimitsSectionTests: XCTestCase {
  func testLimitsReadAsTheyAreAndAStoredValueIsAlwaysAChoice() {
    XCTAssertEqual(
      [0, 15, 60, 120, 90].map(IdlePiLimitsSection.minutesLabel),
      ["Never", "15 min", "1 hour", "2 hours", "90 min"])
    XCTAssertEqual([0, 20].map(IdlePiLimitsSection.limitLabel), ["None", "20 Pis"])
    XCTAssertEqual(IdlePiLimitsSection.choices([0, 10, 30], including: 30), [0, 10, 30])
    XCTAssertEqual(IdlePiLimitsSection.choices([0, 10, 30], including: 25), [0, 10, 25, 30])
    XCTAssertEqual(IdlePiLimitsSection.choices([0, 10], including: nil), [0, 10])
  }
}
